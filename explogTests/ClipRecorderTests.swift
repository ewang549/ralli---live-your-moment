import Testing
import AVFoundation
import CoreMedia
@testable import explog

/// The duration cap and the "did anything actually get written" answer used to
/// belong to `AVCaptureMovieFileOutput`. Moving the recording onto our own
/// `AVAssetWriter` — so that a camera flip mid-take doesn't finalize the file —
/// moved both into `ClipRecorder`, which puts them in reach of a test.
///
/// These drive the recorder with synthesised buffers rather than a camera, so
/// they run on the simulator. What they can't cover is the flip itself: that
/// needs two real cameras and a real session.
struct ClipRecorderTests {
    /// A blank frame stamped at `seconds` on the session timeline.
    private func videoBuffer(at seconds: Double,
                             width: Int = 320, height: Int = 240) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription else { return nil }

        // 30fps, so the stamps line up with something a camera would produce.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "recorder-test-\(UUID().uuidString).mov")
    }

    /// Feeding past the cap has to end the take on its own. This is the one
    /// `maxRecordedDuration` used to enforce inside AVFoundation, so nothing
    /// else stops a held shutter now.
    @Test func theDurationCapEndsTheTakeOnItsOwn() async throws {
        let recorder = ClipRecorder()
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let finished = await withCheckedContinuation { continuation in
            var resumed = false
            recorder.start(url: url, maxDuration: 0.5,
                           videoSettings: nil, audioSettings: nil) { succeeded in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: succeeded)
            }
            // A full second of frames against a half-second cap — the recorder
            // should have closed the file well before the last of them.
            recorder.queue.async {
                for frame in 0..<30 {
                    guard let buffer = self.videoBuffer(at: Double(frame) / 30) else { continue }
                    recorder.append(buffer, isVideo: true)
                }
            }
        }

        #expect(finished)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // And what it wrote is a real movie, capped at roughly the limit
        // rather than at the full second it was fed.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0)
        #expect(duration < 0.9)
    }

    /// An explicit stop keeps whatever has been written so far — this is the
    /// shutter being released before the cap.
    @Test func stoppingEarlyKeepsTheFootageSoFar() async throws {
        let recorder = ClipRecorder()
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let finished = await withCheckedContinuation { continuation in
            recorder.start(url: url, maxDuration: 60,
                           videoSettings: nil, audioSettings: nil) { succeeded in
                continuation.resume(returning: succeeded)
            }
            recorder.queue.async {
                for frame in 0..<10 {
                    guard let buffer = self.videoBuffer(at: Double(frame) / 30) else { continue }
                    recorder.append(buffer, isVideo: true)
                }
                recorder.stop()
            }
        }

        #expect(finished)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.duration).seconds > 0)
    }

    /// Stopping before a single frame arrives must report failure rather than
    /// hand back a file. The old path checked only that *something* existed at
    /// the path, which is how a truncated take passed for a successful one.
    @Test func aTakeThatNeverSawAFrameReportsFailure() async throws {
        let recorder = ClipRecorder()
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let finished = await withCheckedContinuation { continuation in
            recorder.start(url: url, maxDuration: 5,
                           videoSettings: nil, audioSettings: nil) { succeeded in
                continuation.resume(returning: succeeded)
            }
            recorder.stop()
        }

        #expect(!finished)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The flip's signature at the buffer level: frames of a different size
    /// arriving partway through a take, because the two cameras needn't agree.
    /// The file's size is fixed at its first frame, so these have to be scaled
    /// into it rather than rejected — otherwise the flip still ends the clip.
    @Test func framesThatChangeSizeMidTakeStillLand() async throws {
        let recorder = ClipRecorder()
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let finished = await withCheckedContinuation { continuation in
            recorder.start(url: url, maxDuration: 60,
                           videoSettings: nil, audioSettings: nil) { succeeded in
                continuation.resume(returning: succeeded)
            }
            recorder.queue.async {
                for frame in 0..<6 {
                    guard let buffer = self.videoBuffer(at: Double(frame) / 30) else { continue }
                    recorder.append(buffer, isVideo: true)
                }
                // "Flip": same timeline, different frame size.
                for frame in 6..<12 {
                    guard let buffer = self.videoBuffer(at: Double(frame) / 30,
                                                        width: 240, height: 320) else { continue }
                    recorder.append(buffer, isVideo: true)
                }
                recorder.stop()
            }
        }

        #expect(finished)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        #expect(track != nil)
        // One continuous video track, not a file that ended at the size change.
        let size = try await track?.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 240))
    }
}
