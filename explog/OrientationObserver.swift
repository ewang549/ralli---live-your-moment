import SwiftUI
import UIKit

/// Watches the physical device orientation so the app can react to the user
/// simply *turning the phone sideways* — the gesture that opens the camera.
/// The camera screen then forces the *interface* into landscape itself (see
/// `InterfaceOrientationLock`), which pins one specific edge — so this reports
/// both the coarse landscape-vs-portrait signal that opens and closes the
/// camera, and which edge, which is what re-pins the lock on a 180° flip.
///
/// `UIDevice.orientation` also reports `.faceUp` / `.faceDown` / `.unknown`;
/// those are ignored so a phone resting on a table never flips the UI. Note it
/// tracks *physical* orientation and keeps firing even while the interface is
/// locked to landscape — which is what lets "turn back to portrait" still exit.
@Observable
@MainActor
final class OrientationObserver {
    private(set) var isLandscape = false

    /// Which landscape edge the phone is on, `nil` in portrait. Separate from
    /// `isLandscape` because turning the phone end-for-end between the two
    /// landscape edges leaves that flag — and the screen's size — unchanged,
    /// so it's the only signal that the pinned interface orientation has gone
    /// stale and needs re-pointing.
    private(set) var landscapeEdge: UIDeviceOrientation?

    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    func start() {
        guard monitorTask == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        update(for: UIDevice.current.orientation)

        monitorTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification)
            for await _ in stream {
                guard let self else { return }
                let orientation = UIDevice.current.orientation
                // Only act on real interface orientations, never face-up/down.
                guard orientation.isValidInterfaceOrientation else { continue }
                self.update(for: orientation)
            }
        }
    }

    private func update(for orientation: UIDeviceOrientation) {
        isLandscape = orientation.isLandscape
        landscapeEdge = orientation.isLandscape ? orientation : nil
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}
