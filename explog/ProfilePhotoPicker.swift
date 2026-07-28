import SwiftUI
import PhotosUI
import UIKit

/// Saves a picked or captured photo to Documents, mirroring how `Clip` media
/// is stored on disk — the model then only ever needs a file name.
enum AvatarPhotoStore {
    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let fileName = "avatar-\(UUID().uuidString).jpg"
        let url = URL.documentsDirectory.appending(path: fileName)
        do {
            try data.write(to: url)
            return fileName
        } catch {
            return nil
        }
    }
}

/// Wraps any label (typically an orb avatar) with a tap target that offers
/// "Take Photo" or "Choose from Camera Roll", saves whatever comes back
/// locally, and hands the new file name to the caller.
///
/// Neither path needs a Photo Library permission prompt: `PhotosPicker` runs
/// out-of-process (no grant required at all — the picker just shows the
/// library), and the camera path already has `NSCameraUsageDescription` from
/// the main capture flow.
struct AvatarPhotoButton<Label: View>: View {
    let onPicked: (String) -> Void
    @ViewBuilder var label: () -> Label

    @State private var showOptions = false
    @State private var showPhotosPicker = false
    @State private var showCamera = false
    @State private var photosPickerItem: PhotosPickerItem?
    /// The picked photo, held until it has been framed. Both sources — library
    /// and camera — funnel through here, so cropping isn't something one path
    /// gets and the other doesn't.
    @State private var pendingCrop: PendingCrop?

    /// `fullScreenCover(item:)` needs an `Identifiable`, and `UIImage` has no
    /// identity of its own — two picks of the same photo are different events.
    private struct PendingCrop: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        Button { showOptions = true } label: { label() }
            .buttonStyle(.plain)
            .confirmationDialog("Profile photo", isPresented: $showOptions, titleVisibility: .visible) {
                if cameraAvailable {
                    Button("Take Photo") { showCamera = true }
                }
                Button("Choose from Camera Roll") { showPhotosPicker = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
            .onChange(of: photosPickerItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    // Framed before it's saved, never straight to disk: the
                    // display sites all centre-crop, so an unframed photo is a
                    // guess about where the subject is.
                    pendingCrop = PendingCrop(image: image)
                    photosPickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker { image in
                    showCamera = false
                    guard let image else { return }
                    // Queued behind the camera cover's own dismissal. Two
                    // full-screen covers on one view can't transition at the
                    // same time — setting this synchronously here means the
                    // crop screen is asked for while the camera is still going
                    // away, and SwiftUI silently drops it.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        pendingCrop = PendingCrop(image: image)
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $pendingCrop) { pending in
                AvatarCropView(image: pending.image) { cropped in
                    guard let fileName = AvatarPhotoStore.save(cropped) else { return }
                    onPicked(fileName)
                }
            }
    }
}

/// A small coral camera badge, meant to ride the bottom-trailing corner of an
/// avatar to signal "tap to change your photo."
struct AvatarPhotoBadge: View {
    var body: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Theme.accent))
            .overlay(Circle().strokeBorder(Theme.base, lineWidth: 2))
    }
}

/// Native camera capture, wrapped for SwiftUI. `UIImagePickerController` (not
/// the AVFoundation session `CameraCaptureView` uses) is the right tool here —
/// a single still photo with the system's own review/retake UI, no bespoke
/// viewfinder needed for something as small as an avatar.
private struct CameraImagePicker: UIViewControllerRepresentable {
    /// nil means the user cancelled without capturing anything.
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
