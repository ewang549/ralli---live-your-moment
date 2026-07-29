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

/// Saves a wide photo — a beacon's cover — the same way `AvatarPhotoStore` does,
/// downscaled first.
///
/// A cover is drawn as a 150pt-tall banner, so a full-resolution camera capture
/// is several megabytes of detail nothing will ever show, paid for once on
/// upload and again on every download. 1600px on the long edge is still more
/// than the largest device draws.
enum CoverPhotoStore {
    private static let maxDimension: CGFloat = 1600

    static func save(_ image: UIImage) -> String? {
        guard let data = downscaled(image).jpegData(compressionQuality: 0.8) else { return nil }
        let fileName = "beacon-cover-\(UUID().uuidString).jpg"
        let url = URL.documentsDirectory.appending(path: fileName)
        do {
            try data.write(to: url)
            return fileName
        } catch {
            return nil
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDimension else { return image }
        let scale = maxDimension / longEdge
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // `UIGraphicsImageRenderer` applies the image's orientation for us, so a
        // photo shot in portrait doesn't come back on its side.
        return UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// The cover-photo equivalent of `AvatarPhotoButton`: same two sources, same
/// "hand the caller a file name" contract.
///
/// No crop step, unlike the avatar path — `AvatarCropView` frames to a circle,
/// which is the wrong shape for a banner, and every place a cover is drawn
/// already centre-crops to fill. Passing `nil` back means "remove the cover".
struct CoverPhotoButton<Label: View>: View {
    let onPicked: (String?) -> Void
    /// Whether to offer removal — only meaningful once one has been picked.
    var canRemove: Bool = false
    @ViewBuilder var label: () -> Label

    @State private var showOptions = false
    @State private var showPhotosPicker = false
    @State private var showCamera = false
    @State private var photosPickerItem: PhotosPickerItem?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Both sources are queued behind the dialog's own dismissal rather than
    /// presented from inside it.
    ///
    /// This composer is itself a sheet, and asking for a second presentation
    /// while the confirmation dialog is still going away means SwiftUI silently
    /// drops it — tapping "Choose from Camera Roll" did nothing at all. Same
    /// hazard `AvatarPhotoButton` already works around for its camera cover; it
    /// bites the library path too once the whole thing is inside a sheet.
    private func present(_ flag: @escaping (Bool) -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            flag(true)
        }
    }

    var body: some View {
        Button { showOptions = true } label: { label() }
            .buttonStyle(.plain)
            .confirmationDialog("Cover photo", isPresented: $showOptions, titleVisibility: .visible) {
                if cameraAvailable {
                    Button("Take Photo") { present { showCamera = $0 } }
                }
                Button("Choose from Camera Roll") { present { showPhotosPicker = $0 } }
                if canRemove {
                    Button("Remove Photo", role: .destructive) { onPicked(nil) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photosPickerItem, matching: .images)
            .onChange(of: photosPickerItem) { _, item in
                guard let item else { return }
                Task {
                    defer { photosPickerItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let fileName = CoverPhotoStore.save(image) else { return }
                    onPicked(fileName)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraImagePicker { image in
                    showCamera = false
                    guard let image, let fileName = CoverPhotoStore.save(image) else { return }
                    onPicked(fileName)
                }
                .ignoresSafeArea()
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
