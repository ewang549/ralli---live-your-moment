import XCTest

/// Drives the Beacons spot picker against real MapKit.
///
/// The picker it replaced was backed by a local `@Query` over `Spot`, which is
/// only ever populated by DEBUG seed data — so for a real account it was always
/// empty, and no unit test would have caught that, because the view was correct
/// and the data source simply didn't exist. The only proof that matters here is
/// that typing a place name in a running app produces results, so that's what
/// this drives.
///
/// Needs network for `MKLocalSearchCompleter`; skips rather than fails when
/// suggestions never arrive, so an offline machine doesn't redden the suite.
final class SpotSearchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTypingAPlaceNameOffersSuggestionsAndAMapConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "newbeacon"
        app.launch()

        let picker = app.buttons["Search for a place"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30),
                      "The New beacon sheet must offer location search, not a local dropdown.")
        picker.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Spot search needs a text field.")
        field.tap()
        field.typeText("Blue Bottle Coffee")

        // MapKit suggestions arrive asynchronously; the header only renders once
        // there's at least one.
        let header = app.staticTexts["Places"].firstMatch
        guard header.waitForExistence(timeout: 20) else {
            throw XCTSkip("No MapKit suggestions — needs network.")
        }

        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "spot-search-results"
        list.lifetime = .keepAlways
        add(list)

        // The first suggestion under the header, whatever it happens to be:
        // asserting on a specific business would make this a test of Apple's
        // index rather than of the picker.
        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")
        ).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15),
                      "Typing a real place must surface it as a suggestion.")
        suggestion.tap()

        // Selecting resolves coordinates and shows the map confirmation.
        let confirm = app.buttons["Use this place"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 25),
                      "Picking a suggestion must pin it on a map to confirm.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "spot-search-map-confirmation"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Confirming a place must reach the server and come back with a real spot.
    ///
    /// Split from the test above because this one needs `upsertSpot` deployed,
    /// so a failure here means something different: the picker works, the
    /// backend doesn't. Creates a genuine `spots/{id}` document — that's the
    /// point, and it's shared by construction, so anyone else searching the same
    /// name finds it rather than minting a duplicate.
    @MainActor
    func testConfirmingAPlaceCreatesAServerBackedSpot() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "newbeacon"
        app.launch()

        let picker = app.buttons["Search for a place"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        picker.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Blue Bottle Coffee")

        let suggestion = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")
        ).firstMatch
        guard suggestion.waitForExistence(timeout: 25) else {
            throw XCTSkip("No MapKit suggestions — needs network.")
        }
        suggestion.tap()

        let confirm = app.buttons["Use this place"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 25))
        confirm.tap()

        // Back on the beacon sheet with the place chosen. The prompt is gone
        // only if the round trip returned a spot and it was mirrored locally.
        XCTAssertTrue(waitForDisappearance(of: app.buttons["Search for a place"].firstMatch),
                      "Confirming must return a real spot and select it.")
        XCTAssertTrue(app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'Blue Bottle'")
        ).firstMatch.waitForExistence(timeout: 10),
                      "The chosen place must be shown as selected.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "spot-confirmed-on-beacon"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// "Where are you" answered without typing.
    ///
    /// The picker only ever had two ways in — a name you typed, or a spot Ralli
    /// already knew — while the one `CLLocationManager` in the app fetched a fix
    /// purely to bias search relevance and never surfaced it. This drives the
    /// third way: tap, and a real named place comes back.
    ///
    /// Needs a location fix, so it grants the prompt and skips rather than fails
    /// when nothing arrives — a simulator with no simulated location has nowhere
    /// to be standing.
    @MainActor
    func testUsingCurrentLocationResolvesAPlaceWithoutTyping() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "newbeacon"

        app.launch()

        let picker = app.buttons["Search for a place"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        // The sheet animates in, and a tap that lands mid-presentation is
        // swallowed — leaving the beacon composer up and nothing to find.
        XCTAssertTrue(picker.waitForHittable(), "The place picker never settled.")
        picker.tap()

        // Opening the picker asks for location (search biasing already did), and
        // the alert belongs to Springboard rather than the app — an unanswered
        // one leaves the status `.notDetermined` and no fix ever arrives.
        grantLocationIfAsked()

        let here = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] 'Use current location'")
        ).firstMatch
        XCTAssertTrue(here.waitForExistence(timeout: 15),
                      "The picker must offer somewhere to go without typing.")
        here.tap()
        grantLocationIfAsked()

        // The same map confirmation a typed result reaches — the whole point of
        // routing this into `pending` rather than building a second flow.
        let confirm = app.buttons["Use this place"].firstMatch
        let arrived = confirm.waitForExistence(timeout: 30)

        // Attached either way: when this skips, the screen is the only thing
        // that says whether the fix never came or MapKit had nothing there.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "spot-search-current-location"
        shot.lifetime = .keepAlways
        add(shot)

        guard arrived else {
            throw XCTSkip("No location fix or no MapKit response — needs a simulated location and network.")
        }
    }

    /// Answers the system location prompt if it's up, and does nothing if it
    /// isn't — the grant persists across launches, so it only appears once.
    @MainActor
    private func grantLocationIfAsked(timeout: TimeInterval = 5) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Allow Once", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: timeout) {
                button.tap()
                return
            }
        }
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

private extension XCUIElement {
    /// Existing isn't the same as tappable: a sheet mid-presentation reports its
    /// buttons as present while every tap on them goes nowhere.
    func waitForHittable(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHittable { return true }
            usleep(200_000)
        }
        return false
    }
}
