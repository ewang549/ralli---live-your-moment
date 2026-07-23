import SwiftUI
import SwiftData
import AVFoundation
import Combine

/// Capture a log: a short video or a photo.
/// The maximum clip length comes from the surface that opened the camera —
/// 2s for a pulse check-in, 5s for a place/experience (see `CaptureContext`).
/// On simulator (no camera) it falls back to composing a stylized "vibe" clip.
struct CameraCaptureView: View {
    /// Which surface launched capture; drives the recording cap.
    var context: CaptureContext = .pulse

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraModel()

    @State private var mode: CaptureMode = .video
    @State private var captured: CapturedMedia?

    enum CaptureMode: CaseIterable {
        case video
        case photo
    }

    private var maxDuration: TimeInterval { context.maxClipDuration }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.hasCamera {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                SimulatedViewfinder()
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    Spacer()
                    if camera.hasCamera {
                        Button {
                            camera.flip()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Circle().fill(.black.opacity(0.35)))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if !camera.hasCamera {
                    Text("No camera here — composing a vibe clip instead")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 8)
                }

                // Video label reflects the context cap (2s pulse / 5s place).
                Picker("Mode", selection: $mode) {
                    Text(context.videoModeLabel).tag(CaptureMode.video)
                    Text("Photo").tag(CaptureMode.photo)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .padding(.bottom, 18)

                RecordButton(mode: mode, maxDuration: maxDuration, isRecording: camera.isRecording) {
                    capture()
                }
                .padding(.bottom, 40)
            }
        }
        // Push the context's cap into the session before the first recording.
        .task { camera.startIfAvailable(maxDuration: maxDuration) }
        .onChange(of: maxDuration) { _, newValue in camera.updateMaxDuration(newValue) }
        .onDisappear { camera.stop() }
        .sheet(item: $captured) { media in
            SendLogView(media: media) {
                dismiss()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func capture() {
        if camera.hasCamera {
            switch mode {
            case .photo:
                camera.capturePhoto { fileName in
                    if let fileName { captured = CapturedMedia(kind: .photo, assetFileName: fileName) }
                }
            case .video:
                camera.recordClip { fileName in
                    if let fileName { captured = CapturedMedia(kind: .video, assetFileName: fileName) }
                }
            }
        } else {
            captured = CapturedMedia(kind: .vibe, assetFileName: nil)
        }
    }
}

struct CapturedMedia: Identifiable {
    let id = UUID()
    let kind: ClipKind
    let assetFileName: String?
}

// MARK: - Record button with a progress ring sized to the context's cap

private struct RecordButton: View {
    let mode: CameraCaptureView.CaptureMode
    /// Ring fills over exactly this many seconds, matching the hardware cap.
    let maxDuration: TimeInterval
    let isRecording: Bool
    let action: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.6), lineWidth: 5)
                    .frame(width: 78, height: 78)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 78, height: 78)
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(isRecording ? Theme.accent : .white)
                    .frame(width: isRecording ? 34 : 62, height: isRecording ? 34 : 62)
                    .animation(.spring(duration: 0.25), value: isRecording)
            }
        }
        .disabled(isRecording)
        .onChange(of: isRecording) { _, recording in
            if recording && mode == .video {
                progress = 0
                withAnimation(.linear(duration: maxDuration)) { progress = 1 }
            } else {
                progress = 0
            }
        }
    }
}

// MARK: - Simulated viewfinder (simulator / no camera permission)

private struct SimulatedViewfinder: View {
    @State private var shift = false

    var body: some View {
        LinearGradient(colors: [Color(hue: shift ? 0.62 : 0.55, saturation: 0.6, brightness: 0.35),
                                Color(hue: shift ? 0.95 : 0.85, saturation: 0.6, brightness: 0.2)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay(
            Text("📹")
                .font(.system(size: 70))
                .opacity(0.5)
                .scaleEffect(shift ? 1.1 : 0.9)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { shift = true }
        }
    }
}

// MARK: - Camera plumbing

final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var isRecording = false
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoCompletion: ((String?) -> Void)?
    private var photoCompletion: ((String?) -> Void)?
    private var currentPosition: AVCaptureDevice.Position = .back
    /// Hard cap enforced by AVFoundation itself; set from the launching context.
    private var maxDuration: TimeInterval = CaptureContext.pulse.maxClipDuration

    var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil ||
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    func startIfAvailable(maxDuration: TimeInterval) {
        self.maxDuration = maxDuration
        guard hasCamera, !session.isRunning else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.configure()
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        movieOutput.maxRecordedDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)
        session.commitConfiguration()
    }

    /// Re-caps an already-running session (e.g. capture reopened from Places).
    func updateMaxDuration(_ seconds: TimeInterval) {
        maxDuration = seconds
        movieOutput.maxRecordedDuration = CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func flip() {
        currentPosition = currentPosition == .back ? .front : .back
        configure()
    }

    func recordClip(completion: @escaping (String?) -> Void) {
        guard !isRecording else { return }
        videoCompletion = completion
        isRecording = true
        let url = URL.documentsDirectory.appending(path: "clip-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func capturePhoto(completion: @escaping (String?) -> Void) {
        photoCompletion = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            // maxRecordedDuration reached surfaces as an error with a successful file; keep it.
            let succeeded = FileManager.default.fileExists(atPath: outputFileURL.path)
            self.videoCompletion?(succeeded ? outputFileURL.lastPathComponent : nil)
            self.videoCompletion = nil
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        DispatchQueue.main.async {
            guard let data = photo.fileDataRepresentation() else {
                self.photoCompletion?(nil)
                self.photoCompletion = nil
                return
            }
            let fileName = "photo-\(UUID().uuidString).jpg"
            let url = URL.documentsDirectory.appending(path: fileName)
            try? data.write(to: url)
            self.photoCompletion?(fileName)
            self.photoCompletion = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
