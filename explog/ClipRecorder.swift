import AVFoundation

/// Writes a take to disk one sample buffer at a time, through an
/// `AVAssetWriter` this app owns rather than through the capture session.
///
/// The camera used to record with `AVCaptureMovieFileOutput`, which cannot
/// survive a camera flip. Swapping cameras means removing the session's video
/// input (`CameraModel.configure`), that tears down the connection feeding the
/// movie output, and AVFoundation finalizes the file on the spot. The clip came
/// back truncated at the moment of the flip — and since the finish delegate
/// only checked that *a* file existed on disk, the truncated take was accepted
/// as a successful capture, so it read as "flipping cuts the recording off".
///
/// Owning the writer decouples the file from the session's plumbing. Buffers
/// arrive through `AVCaptureVideoDataOutput` / `AVCaptureAudioDataOutput`,
/// which stay attached across a reconfigure, so a flip is a brief gap in the
/// sample stream instead of the end of the recording. Timestamps need no
/// rebasing across that gap: every buffer is stamped by the session's own
/// clock, and that clock keeps running while the inputs are swapped.
///
/// Every method runs on `queue`, which the capture outputs also deliver on —
/// so buffers and state changes are already ordered against each other with no
/// further locking. The recorder owns that queue rather than being handed one,
/// so there is no window in which the two could be set up out of order.
final class ClipRecorder {
    /// A take that's been asked for but hasn't opened a file yet.
    private struct Armed {
        let url: URL
        let maxDuration: TimeInterval
        let videoSettings: [String: Any]?
        let audioSettings: [String: Any]?
        let completion: (Bool) -> Void
    }

    /// A take with a file open under it.
    private struct Take {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        /// Source time the movie's timeline was opened at — the first video
        /// frame's stamp. The duration cap is measured from here.
        let startedAt: CMTime
        let maxDuration: TimeInterval
        let completion: (Bool) -> Void
    }

    private enum State {
        case idle
        case armed(Armed)
        case recording(Take)
        /// `finishWriting` is in flight. Buffers still arriving are dropped
        /// rather than appended to inputs that have been marked finished.
        case finishing
    }

    /// Set this as both capture outputs' delegate queue.
    let queue = DispatchQueue(label: "com.ej.explog.camera.buffers")
    private var state: State = .idle

    /// Arms a take at `url`, calling `completion` with whether a playable file
    /// was written once it ends — on the cap, on `stop()`, or on failure.
    ///
    /// The file isn't opened here. It waits for the first video buffer, which
    /// is what supplies the frame size to write at and the timestamp the
    /// movie's timeline starts from.
    func start(url: URL,
               maxDuration: TimeInterval,
               videoSettings: [String: Any]?,
               audioSettings: [String: Any]?,
               completion: @escaping (Bool) -> Void) {
        queue.async {
            guard case .idle = self.state else { return }
            self.state = .armed(Armed(url: url,
                                      maxDuration: maxDuration,
                                      videoSettings: videoSettings,
                                      audioSettings: audioSettings,
                                      completion: completion))
        }
    }

    /// Ends the take early and closes the file. A no-op when nothing is running.
    func stop() {
        queue.async { self.finish() }
    }

    /// Feeds one buffer in. Called from the capture outputs' delegate, which is
    /// already on `queue`.
    func append(_ buffer: CMSampleBuffer, isVideo: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard CMSampleBufferDataIsReady(buffer) else { return }

        switch state {
        case .idle, .finishing:
            return

        case .armed(let armed):
            // Audio can't open the file: the timeline starts at the first
            // *video* frame, and sound ahead of that has nowhere to land.
            guard isVideo else { return }
            guard let take = openFile(for: armed, firstVideo: buffer) else {
                state = .idle
                armed.completion(false)
                return
            }
            state = .recording(take)
            write(buffer, isVideo: true, to: take)

        case .recording(let take):
            write(buffer, isVideo: isVideo, to: take)
        }
    }

    // MARK: - Internals

    private func openFile(for armed: Armed, firstVideo buffer: CMSampleBuffer) -> Take? {
        // A stale file at this path would make `AVAssetWriter` refuse to start.
        try? FileManager.default.removeItem(at: armed.url)
        guard let writer = try? AVAssetWriter(outputURL: armed.url, fileType: .mov) else { return nil }

        var videoSettings = armed.videoSettings ?? Self.fallbackVideoSettings(for: buffer)
        // The two cameras needn't agree on frame size, and the file's size is
        // fixed at its first frame. Scaling mismatched buffers rather than
        // rejecting them is what lets a flip keep writing into the same movie.
        videoSettings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: armed.audioSettings)
        // Buffers arrive as fast as the sensor makes them and can't be held
        // back, so the writer must take them in order and in real time rather
        // than waiting to fill its queue.
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(video), writer.canAdd(audio) else { return nil }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { return nil }

        let startedAt = CMSampleBufferGetPresentationTimeStamp(buffer)
        writer.startSession(atSourceTime: startedAt)
        return Take(writer: writer, video: video, audio: audio,
                    startedAt: startedAt, maxDuration: armed.maxDuration,
                    completion: armed.completion)
    }

    private func write(_ buffer: CMSampleBuffer, isVideo: Bool, to take: Take) {
        guard take.writer.status == .writing else { return }
        let input = isVideo ? take.video : take.audio
        // Not ready means the writer is still draining; dropping the buffer is
        // the documented real-time behaviour, and a gap in stamps is fine.
        if input.isReadyForMoreMediaData { input.append(buffer) }

        // The hard cap `AVCaptureMovieFileOutput.maxRecordedDuration` used to
        // enforce, now ours. Measured on the video timeline, so the gap a flip
        // leaves counts toward it exactly as recorded time does.
        guard isVideo else { return }
        let elapsed = CMSampleBufferGetPresentationTimeStamp(buffer) - take.startedAt
        if elapsed.seconds >= take.maxDuration { finish() }
    }

    private func finish() {
        switch state {
        case .idle, .finishing:
            return

        case .armed(let armed):
            // Stopped before a single frame arrived — nothing was ever opened,
            // so there is no file to hand back.
            state = .idle
            armed.completion(false)

        case .recording(let take):
            state = .finishing
            take.video.markAsFinished()
            take.audio.markAsFinished()
            take.writer.finishWriting { [weak self] in
                let succeeded = take.writer.status == .completed
                // Back on the queue to clear state, so the next `start()` —
                // which also goes through the queue — can't slip in ahead of it.
                self?.queue.async { self?.state = .idle }
                take.completion(succeeded)
            }
        }
    }

    /// Used only when the capture output declines to recommend settings.
    private static func fallbackVideoSettings(for buffer: CMSampleBuffer) -> [String: Any] {
        let dimensions = CMSampleBufferGetFormatDescription(buffer)
            .map(CMVideoFormatDescriptionGetDimensions)
            ?? CMVideoDimensions(width: 1920, height: 1080)
        return [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height)]
    }
}
