import SwiftUI
import UIKit

/// Watches the physical device orientation so the app can react to the user
/// simply *turning the phone sideways* — the gesture that opens the camera.
/// The camera screen then forces the *interface* into landscape itself (see
/// `InterfaceOrientationLock`), so this observer only needs the coarse
/// landscape-vs-portrait signal, not the specific edge.
///
/// `UIDevice.orientation` also reports `.faceUp` / `.faceDown` / `.unknown`;
/// those are ignored so a phone resting on a table never flips the UI. Note it
/// tracks *physical* orientation and keeps firing even while the interface is
/// locked to landscape — which is what lets "turn back to portrait" still exit.
@Observable
@MainActor
final class OrientationObserver {
    private(set) var isLandscape = false

    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    func start() {
        guard monitorTask == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        isLandscape = UIDevice.current.orientation.isLandscape

        monitorTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification)
            for await _ in stream {
                guard let self else { return }
                let orientation = UIDevice.current.orientation
                // Only act on real interface orientations, never face-up/down.
                guard orientation.isValidInterfaceOrientation else { continue }
                self.isLandscape = orientation.isLandscape
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}
