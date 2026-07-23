import XCTest

/// Verifies the three gestures that share the Pulse feed don't cannibalize each
/// other: edge taps step the hour, and vertical scrolling still works.
final class PulseFeedGestureTests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// The hour badge is the only element showing "today"/"yesterday" + a time.
    private func hourBadgeText(_ app: XCUIApplication) -> String {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        return labels.first { $0.contains("AM") || $0.contains("PM") } ?? ""
    }

    func testLeftEdgeTapStepsHourBackward() {
        let app = launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)

        let before = hourBadgeText(app)
        XCTAssertFalse(before.isEmpty, "expected an hour label on screen")

        // Tap inside the left 25% of the feed area.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        sleep(1)

        let after = hourBadgeText(app)
        XCTAssertNotEqual(before, after, "left edge tap should decrement the hour")
    }

    func testRightEdgeTapReturnsToTheOriginalHour() {
        let app = launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)

        let start = hourBadgeText(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        sleep(1)
        let stepped = hourBadgeText(app)
        XCTAssertNotEqual(start, stepped)

        // Right edge walks it forward again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        sleep(1)
        XCTAssertEqual(hourBadgeText(app), start, "right edge tap should re-increment the hour")
    }

    func testCenterTapDoesNotChangeTheHour() {
        let app = launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)

        let before = hourBadgeText(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertEqual(hourBadgeText(app), before, "the middle 50% must be inert for time nav")
    }

    /// The regression that matters: the tap/drag recognizers must not eat the pan.
    func testVerticalScrollingStillWorks() {
        let app = launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)

        let hourBefore = hourBadgeText(app)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.05, thenDragTo: bottom)
        sleep(1)

        // Scrolling must not have been mistaken for an edge tap or a vlog swipe.
        XCTAssertEqual(hourBadgeText(app), hourBefore, "a vertical scroll must not change the hour")
        XCTAssertTrue(app.staticTexts["all friends"].exists, "should still be on the feed")
    }
}
