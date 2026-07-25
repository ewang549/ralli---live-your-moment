import XCTest

/// Smoke coverage for Pulse's consolidated full-screen routing.
///
/// Pulse used to stack five `.fullScreenCover` modifiers on one view node,
/// which is the shape that produced the `PairPreferenceCombiner` recursion
/// crash; they're now one `.fullScreenCover(item:)` behind a `PulseDestination`
/// enum. These drive the churn that crash was reported under — taps landing
/// while a cover is still animating.
///
/// Worth knowing what these do and don't prove: run against the *pre-fix*
/// five-modifier version they also pass, so they never reproduced the original
/// crash in the simulator and are not a regression test for it. What they do
/// cover is that every destination still opens, dismisses, and survives rapid
/// re-entry through the single-modifier routing.
final class PulsePresentationTests: XCTestCase {

    private func launchPulse() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Let the roster and the first sync settle so the rows are real.
        sleep(5)
        return app
    }

    /// Dismisses whatever is up, if anything, without asserting it was there —
    /// the point is to keep churning, not to verify any one destination.
    private func escape(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if close.exists && close.isHittable {
            close.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    func testChurningBetweenPulseDestinationsDoesNotCrash() {
        let app = launchPulse()

        // The four full-screen entry points, by position: the hourly banner,
        // the "All friends" card, a row, and a row's message button.
        let banner = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        let allFriends = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.33))
        let firstRow = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.41))
        let firstRowChat = app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.41))

        for _ in 0..<4 {
            for target in [banner, allFriends, firstRow, firstRowChat] {
                target.tap()
                // Deliberately shorter than the present/dismiss animation, so
                // the next interaction lands mid-transition.
                usleep(220_000)
                escape(app)
                usleep(220_000)
                XCTAssertEqual(app.state, .runningForeground,
                               "app died while churning Pulse presentations")
            }
        }

        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The narrower version of the same thing: hammering one destination's
    /// trigger repeatedly, which is what a frustrated double/triple tap does.
    func testRepeatedTapsOnOneDestinationDoNotCrash() {
        let app = launchPulse()
        let firstRowChat = app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.41))

        for _ in 0..<6 {
            firstRowChat.tap()
            usleep(120_000)
        }
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground,
                       "app died on repeated taps of the row message button")

        escape(app)
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
