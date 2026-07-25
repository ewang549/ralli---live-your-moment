import XCTest

/// The beta thank-you screen: shows once, then never again.
///
/// "Once per install" is the whole requirement and the only part that can
/// really break, so it's asserted the only way that proves anything — by
/// relaunching the app and checking the screen stays gone.
final class ProWelcomeTests: XCTestCase {

    private let headline = "Thank you for being one of our first."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testShowsOnceThenLeadsToSignInAndNeverReturns() throws {
        let app = XCUIApplication()
        // Replays the one-time screen, so the test doesn't depend on this
        // simulator having never run the app before.
        app.launchEnvironment["EXPLOG_RESET_PRO_WELCOME"] = "1"
        app.launch()

        let thankYou = app.staticTexts[headline]
        XCTAssertTrue(thankYou.waitForExistence(timeout: 30),
                      "A fresh install must open on the beta thank-you.")

        XCTAssertTrue(app.staticTexts["Pro"].firstMatch.exists,
                      "The gift line must render the Pro label.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "pro-welcome"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["Let's go"].firstMatch.tap()

        // Dismissing must land on the normal auth flow. Either the sign-in form
        // or the app itself is acceptable — this simulator may already hold a
        // signed-in session — but the thank-you must be gone either way.
        XCTAssertTrue(waitForDisappearance(of: thankYou),
                      "Continuing must dismiss the thank-you.")

        // Second launch, same install, without the replay hook: the flag was
        // persisted on continue, so the screen must not come back.
        app.launchEnvironment.removeValue(forKey: "EXPLOG_RESET_PRO_WELCOME")
        app.terminate()
        app.launch()

        XCTAssertFalse(thankYou.waitForExistence(timeout: 12),
                       "The thank-you must never show a second time.")
    }

    private func waitForDisappearance(of element: XCUIElement,
                                      timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(300_000)
        }
        return false
    }
}
