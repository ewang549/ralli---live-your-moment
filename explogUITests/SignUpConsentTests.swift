import XCTest

/// The Guideline 1.2 consent gate on sign-up.
///
/// App Review checks two things about a user-generated-content app's terms: that
/// the agreement is actually presented before an account exists, and that it
/// says the service won't tolerate objectionable content or abusive users.
/// Both are copy, and copy is exactly the kind of thing that survives a
/// refactor as a control nobody can reach — so this drives the real screen
/// rather than asserting on the constant.
final class SignUpConsentTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Gets past the one-time screens that sit in front of Welcome on a fresh
    /// install. Both are dismissible by name and neither is what's under test.
    @MainActor
    private func launchToWelcome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let letsGo = app.buttons["Let's go"].firstMatch
        if letsGo.waitForExistence(timeout: 20) { letsGo.tap() }

        let notNow = app.buttons["Not now"].firstMatch
        if notNow.waitForExistence(timeout: 20) { notNow.tap() }

        return app
    }

    /// Focuses a field and types into it, waiting for the keyboard first.
    ///
    /// Tapping and typing immediately is the flaky pattern: the tap registers
    /// before the keyboard is up, and the keystrokes go nowhere.
    @MainActor
    private func type(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Missing field for '\(text)'.")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "The keyboard never appeared, so nothing could be typed.")
        field.typeText(text)
    }

    @MainActor
    func testSignUpShowsTheZeroToleranceAgreement() throws {
        let app = launchToWelcome()

        XCTAssertTrue(app.buttons["Create account"].firstMatch.waitForExistence(timeout: 20),
                      "Sign up has to be the screen we landed on.")

        let consent = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'zero tolerance'")).firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 10),
                      "Sign up must state the zero-tolerance policy for objectionable content.")

        let terms = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Terms of Use'")).firstMatch
        XCTAssertTrue(terms.exists, "The agreement must reference the Terms of Use.")

        let privacy = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Privacy Policy'")).firstMatch
        XCTAssertTrue(privacy.exists, "The agreement must reference the Privacy Policy.")
    }

    /// The part that makes it an agreement rather than a notice: filling the
    /// form out completely still doesn't create an account until the box is
    /// ticked.
    @MainActor
    func testAccountCannotBeCreatedWithoutAccepting() throws {
        let app = launchToWelcome()

        let create = app.buttons["Create account"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 20))

        // Typed into each element rather than into the application: `app`
        // dispatches to whatever holds focus, and on a cold simulator that is
        // sometimes nothing at all, which fails as "neither element nor any
        // descendant has keyboard focus" before a single character lands.
        type("Review Tester", into: app.textFields["Your name"].firstMatch, app: app)
        type("review.tester@example.com", into: app.textFields["Email"].firstMatch, app: app)

        app.secureTextFields["Password"].firstMatch.tap()
        // The password field is `.newPassword`, so iOS offers "Use Strong
        // Password?" over it. That sheet swallows most of the keystrokes and
        // leaves a one-character password behind, which disables Create account
        // for a reason that has nothing to do with the terms — exactly the
        // false pass this test exists to avoid.
        let strongPassword = app.buttons["Fill Strong Password"].firstMatch
        if strongPassword.waitForExistence(timeout: 3) {
            app.buttons["Close"].firstMatch.tap()
        }
        type("hunter2hunter2", into: app.secureTextFields["Password"].firstMatch, app: app)

        XCTAssertEqual((app.secureTextFields["Password"].firstMatch.value as? String)?.count, 14,
                       "The password has to have actually landed in the field, or the "
                       + "assertions below would pass for the wrong reason.")

        XCTAssertFalse(create.isEnabled,
                       "A complete form must still not create an account before the terms are accepted.")

        app.buttons["I agree to the Terms of Use and Privacy Policy"].firstMatch.tap()

        XCTAssertTrue(create.isEnabled,
                      "Accepting the terms has to be what unlocks account creation.")
    }
}
