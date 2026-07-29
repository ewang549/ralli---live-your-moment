import XCTest

/// Beacons never went away.
///
/// The server has always stopped returning one six hours past its start, so a
/// fresh install looked fine — but nothing removed a row that had already synced
/// onto the device, and nothing on the feed asked how old a row was. Any device
/// that had seen a beacon kept showing it forever.
///
/// That is only reproducible with an expired beacon already in the local store,
/// which no sync will ever hand you, so `EXPLOG_SEED_EXPIRED_BEACON=1` writes one
/// directly alongside a live one. The live beacon is the control: without it a
/// blank feed would pass this test for the wrong reason.
final class BeaconExpiryFeedTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAnExpiredBeaconAlreadyInTheStoreIsNotShown() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_SEED_DEMO"] = "1"
        app.launchEnvironment["EXPLOG_SEED_EXPIRED_BEACON"] = "1"
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "publicbeacons"
        app.launch()

        // The control first: reaching it proves the feed rendered and the seed
        // landed, so the absence checked below means "filtered out" rather than
        // "never arrived".
        XCTAssertTrue(app.staticTexts["LIVE SEED"].firstMatch.waitForExistence(timeout: 40),
                      "The live seeded beacon must render — otherwise this proves nothing.")
        XCTAssertFalse(app.staticTexts["EXPIRED SEED"].firstMatch.exists,
                       "A beacon past its six-hour window must not render, "
                       + "even when it's already cached locally.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "beacons-expired-filtered"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
