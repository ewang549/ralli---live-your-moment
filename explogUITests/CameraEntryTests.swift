import UIKit
import XCTest

/// Opening the camera must never leave a screen with nothing to touch.
///
/// App Review rejected the app for this on an iPad Air (M3): "tapped on camera
/// / the app displayed an unresponsive splash screen". The camera forces the
/// interface into landscape on appear and used to gate its *entire* control
/// layer — the close button included — behind that rotation actually
/// completing. iPad supports all four orientations and is free to decline the
/// forced single-orientation request, and when it does, the rotation's
/// transition coordinator never fires: live viewfinder, no controls, no way
/// out.
///
/// These assert the two guarantees that fix rests on, in the order that
/// matters:
///
/// 1. The close button is hittable the moment the camera is on screen — it is
///    no longer under the reveal gate at all.
/// 2. The rest of the chrome appears on a hard 1.2s backstop even if the
///    rotation never lands.
///
/// Both are checked by hit-testability rather than existence: the reveal gate
/// is `opacity(0) + allowsHitTesting(false)`, so a gated control still shows up
/// in the accessibility tree. `exists` would have passed before the fix; being
/// hittable is what the reviewer could not do.
final class CameraEntryTests: XCTestCase {

    /// The backstop in `CameraCaptureView.task`, plus room for launch jitter.
    private let backstop: TimeInterval = 1.2
    private let backstopSlack: TimeInterval = 2.5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches straight into the capture screen and clears the one-time beta
    /// welcome if this simulator hasn't seen it yet.
    ///
    /// A UI test runs against a *clone* of the simulator, which need not carry
    /// the signed-in session the app requires before it will show any tab — so
    /// credentials come in from the environment rather than living in the repo:
    ///
    ///     TEST_RUNNER_EXPLOG_TEST_LOGIN="email:password:Name" xcodebuild test …
    ///
    /// Without it the test assumes the device is already signed in. Setting it
    /// also suppresses the notification primer, which would otherwise sit over
    /// the camera.
    @MainActor
    private func launchIntoCamera() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "capture"
        if let login = ProcessInfo.processInfo.environment["EXPLOG_TEST_LOGIN"] {
            app.launchEnvironment["EXPLOG_AUTO_AUTH"] = "login:" + login
        }
        app.launch()

        let letsGo = app.buttons["Let's go"].firstMatch
        if letsGo.waitForExistence(timeout: 8) { letsGo.tap() }
        return app
    }

    @MainActor
    func testCloseButtonIsHittableAsSoonAsTheCameraOpens() throws {
        let app = launchIntoCamera()

        let close = app.buttons["Close camera"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 30),
                      "The camera must put a close button on screen.")

        // Tight window on purpose: the close button is outside the reveal gate,
        // so it must not need the 1.2s backstop — or the rotation — to become
        // usable. A pre-fix build fails here even when it renders the viewfinder.
        let appeared = Date()
        var hittable = close.isHittable
        while !hittable && Date().timeIntervalSince(appeared) < backstop * 0.5 {
            usleep(50_000)
            hittable = close.isHittable
        }
        XCTAssertTrue(hittable,
                      "Close must be tappable immediately, without waiting on rotation.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-on-open"
        shot.lifetime = .keepAlways
        add(shot)

        // Unresponsive is the actual complaint, so prove the tap does something.
        close.tap()
        let deadline = Date().addingTimeInterval(10)
        while close.exists && Date() < deadline { usleep(200_000) }
        XCTAssertFalse(close.exists, "Tapping close must dismiss the camera.")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testFullControlLayerAppearsWithinTheBackstop() throws {
        let app = launchIntoCamera()

        let close = app.buttons["Close camera"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 30),
                      "The camera must put a close button on screen.")

        // Everything else is still behind the reveal gate. Whether the forced
        // landscape rotation completes or is declined, the backstop has to have
        // dropped the gate by now.
        for label in ["Shutter", "Flip camera", "Grid", "Capture mode"] {
            let control = app.descendants(matching: .any)[label].firstMatch
            XCTAssertTrue(waitUntilHittable(control, timeout: backstopSlack),
                          "\(label) must be usable within the reveal backstop, "
                          + "with or without a completed rotation.")
        }

        // Settle first: on iPhone the forced rotation does complete, and a
        // screenshot taken the instant the controls go hittable catches the
        // interface mid-turn, which makes the attachment useless for judging
        // how the screen actually looks.
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-controls-revealed"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The same guarantee, one rotation later.
    ///
    /// Leaving landscape drops the chrome deliberately — nothing of ours should
    /// animate while the system spins the interface. On iPhone that only ever
    /// happens on the way out of the camera. On iPad portrait is somewhere the
    /// interface can settle and stay, so the drop has to be temporary or the
    /// screen ends up back where App Review found it: live viewfinder, close
    /// button, nothing else.
    @MainActor
    func testControlsComeBackAfterTheDeviceIsRotatedOutOfLandscape() throws {
        // iPhone-only behaviour is the opposite and deliberately so: the app is
        // portrait-only there, so leaving landscape means the camera is closing
        // and the chrome must stay down.
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "Rotating out of landscape is only recoverable on iPad.")

        let app = launchIntoCamera()

        let close = app.buttons["Close camera"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 30),
                      "The camera must put a close button on screen.")

        let shutter = app.descendants(matching: .any)["Shutter"].firstMatch
        XCTAssertTrue(waitUntilHittable(shutter, timeout: backstopSlack),
                      "Precondition: the controls must be up before rotating.")

        XCUIDevice.shared.orientation = .landscapeLeft
        _ = waitUntilHittable(shutter, timeout: 3)
        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(waitUntilHittable(shutter, timeout: backstopSlack + 2),
                      "Rotating out of landscape must not hide the controls for good.")
        XCTAssertTrue(close.isHittable, "Close must survive the rotation too.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-after-rotation"
        shot.lifetime = .keepAlways
        add(shot)

        XCUIDevice.shared.orientation = .portrait
    }

    private func waitUntilHittable(_ element: XCUIElement,
                                   timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            usleep(100_000)
        }
        return false
    }
}
