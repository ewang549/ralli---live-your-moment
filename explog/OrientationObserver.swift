import SwiftUI
import UIKit
import os

private let observerLog = Logger(subsystem: "com.ej.explog", category: "orientation")

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
    // Debounces a burst of raw sensor notifications into one committed update.
    // Under a hardware rotation lock, `UIDevice.current.orientation` was
    // observed (via `observerLog`) to bounce — landscapeRight, then briefly
    // something else, then landscapeRight again — within the same fraction of
    // a second the phone is turned. `update(for:)` used to run on every one of
    // those, so `isLandscape` flipped true, then false, then true right back,
    // and `MainTabView`'s `.onChange(of: orientation.isLandscape)` opened the
    // camera, closed it, and reopened it in that same instant — the fullscreen
    // cover presenting and dismissing so fast it just looked like "the camera
    // never opened." Waiting for the raw signal to hold still for one beat
    // before acting on it collapses that whole bounce into a single update.
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    func start() {
        observerLog.notice("start() called, monitorTask already running = \(self.monitorTask != nil)")
        guard monitorTask == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observerLog.notice("beginGeneratingDeviceOrientationNotifications called; initial UIDevice.current.orientation.rawValue = \(UIDevice.current.orientation.rawValue)")
        update(for: UIDevice.current.orientation)

        monitorTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification)
            for await _ in stream {
                guard let self else { return }
                let orientation = UIDevice.current.orientation
                observerLog.notice("orientationDidChangeNotification fired, raw = \(orientation.rawValue), isValidInterfaceOrientation = \(orientation.isValidInterfaceOrientation)")
                // Only act on real interface orientations, never face-up/down.
                guard orientation.isValidInterfaceOrientation else { continue }
                self.debounceTask?.cancel()
                self.debounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled, let self else { return }
                    observerLog.notice("debounce settled on raw = \(orientation.rawValue), committing update(for:)")
                    self.update(for: orientation)
                }
            }
        }
    }

    private func update(for orientation: UIDeviceOrientation) {
        isLandscape = orientation.isLandscape
        landscapeEdge = orientation.isLandscape ? orientation : nil
        observerLog.notice("update(for:) raw = \(orientation.rawValue) -> isLandscape = \(self.isLandscape), landscapeEdge = \(String(describing: self.landscapeEdge?.rawValue))")
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}
