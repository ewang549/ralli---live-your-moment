import XCTest

/// Drives the real Daily Recap screen to prove the two things the feature
/// changed are actually wired into the app, not just into the composer.
///
/// The unit tests in `RecapReelTests` decode frames and read pixels — they prove
/// the reel is built correctly. What they can't reach is the screen: whether the
/// stamp is on the recap at all, and whether there is a way in to the stitched
/// reel. That's what these cover.
final class RecapOverlayAndReelTests: XCTestCase {

    private func openRecap() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Let the roster and first sync settle so the day has its real clips.
        sleep(5)

        let entry = app.buttons["Daily recap"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no way in to the daily recap")
        entry.tap()
        sleep(2)
        return app
    }

    /// Walks back through the archive looking for a day that actually has a log,
    /// since today may well be empty. Returns whether one was found.
    @discardableResult
    private func findADayWithAClip(_ app: XCUIApplication, days: Int = 12) -> Bool {
        for _ in 0..<days {
            if app.staticTexts["No logs on this day"].firstMatch.exists == false {
                return true
            }
            // A horizontal swipe steps a whole day back on this screen.
            app.swipeRight(velocity: .fast)
            usleep(700_000)
        }
        return app.staticTexts["No logs on this day"].firstMatch.exists == false
    }

    /// The way into the stitched reel exists on the recap's chrome, beside the
    /// existing Photos export rather than replacing it.
    func testRecapOffersBothWatchAsOneVideoAndSaveToPhotos() {
        let app = openRecap()

        let watch = app.buttons["Watch this day as one video"].firstMatch
        XCTAssertTrue(watch.waitForExistence(timeout: 10),
                      "the stitched-reel entry point is missing from the recap")

        // The export it sits next to is still there — the reel is additive.
        XCTAssertTrue(app.buttons["Save this day to Photos"].firstMatch.exists,
                      "the Photos export was replaced rather than joined")

        add(screenshot(app, named: "recap-chrome"))
    }

    /// Item 1: a clip in the recap carries its hour stamp, the same one every
    /// other feed draws. `HourOverlay` labels itself "Filmed at <hour>", so the
    /// stamp being on screen is directly observable.
    func testRecapClipsShowTheirHourStamp() throws {
        let app = openRecap()

        guard findADayWithAClip(app) else {
            throw XCTSkip("no logs in the archive on this device to render a stamp over")
        }

        let stamp = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Filmed at'"))
            .firstMatch
        XCTAssertTrue(stamp.waitForExistence(timeout: 5),
                      "the recap drew a clip with no hour stamp over it")

        add(screenshot(app, named: "recap-clip-with-stamp"))
    }

    /// Item 2: the reel opens, builds, and plays without taking the app down.
    ///
    /// Deliberately not asserting on pixels here — that's what the unit tests
    /// do against decoded frames. This is about the screen surviving a real
    /// stitch of whatever is on the device.
    func testWatchingTheStitchedReelOpensAndSurvives() throws {
        let app = openRecap()

        let watch = app.buttons["Watch this day as one video"].firstMatch
        XCTAssertTrue(watch.waitForExistence(timeout: 10))

        // Walk the archive for a day that can actually be stitched. A day whose
        // logs are all synced-but-not-downloaded has nothing on disk to feed the
        // composer, and the button says so by staying disabled — so "found a
        // clip" isn't the same question as "found something stitchable".
        var found = watch.isEnabled
        for _ in 0..<25 where !found {
            app.swipeRight(velocity: .fast)
            usleep(700_000)
            found = watch.isEnabled
        }
        guard found else {
            // Reached when the signed-in account's own logs are all vibe clips
            // — generated art with no media behind them, which cannot become
            // video. Correct behaviour, but it leaves this screen unexercised.
            throw XCTSkip("no day in this account's archive has stitchable media")
        }
        watch.tap()

        // Stitching encodes stills into frames, so give it real time.
        XCTAssertTrue(app.staticTexts["Your day, stitched"].firstMatch.waitForExistence(timeout: 15),
                      "the reel screen never came up")
        sleep(12)
        add(screenshot(app, named: "recap-reel-playing"))

        XCTAssertEqual(app.state, .runningForeground, "the app died while stitching the reel")
        XCTAssertFalse(app.staticTexts["Stitching your day…"].firstMatch.exists,
                       "the reel never finished stitching")

        // And it closes cleanly, which is where the scratch files are released.
        app.buttons["Close"].firstMatch.tap()
        usleep(800_000)
        XCTAssertEqual(app.state, .runningForeground, "the app died closing the reel")
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
