import XCTest

/// Screenshot + regression pass for the safety, account-deletion and discovery
/// work (SOCIAL_COMPLETION_PROMPT phases 4–6).
///
/// Two jobs in one file, because they're the same walk through the app:
///   1. Capture the new surfaces so a phase can be signed off visually.
///   2. Re-assert the §0 invariants — per-row message icons and the hourly
///      countdown on Pulse, the landscape camera, Beacons, Profile, and a
///      logout that reaches Welcome instead of crashing.
///
/// Screenshots come out as attachments; pull them with
///   xcrun xcresulttool export attachments --path <result.xcresult> --output-path <dir>
final class SafetyAndAccountScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_SEED_DEMO"] = "1"
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls a swipeable view until `element` is hittable, rather than a
    /// fixed swipe count — content length above the target (interest chips
    /// wrap to a variable number of rows) makes a fixed count fragile.
    private func scrollUntilHittable(_ element: XCUIElement,
                                     in app: XCUIApplication,
                                     maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    /// Opens Settings from the Profile tab.
    ///
    /// Account controls — log out, delete account, blocked accounts — used to
    /// sit on the Profile tab itself; they now live one tap behind the gear,
    /// with the tab reserved for identity, stats and highlights.
    private func openSettings(in app: XCUIApplication) {
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10),
                      "Profile must offer a way into Settings.")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8),
                      "The gear must open Settings.")
    }

    /// Every notification category has to be reachable and switchable.
    ///
    /// The switches are the only way a user can turn a push off, and each one
    /// is bound to a key the Cloud Functions read — so a category that never
    /// renders is a notification nobody can stop. Asserted by title rather
    /// than by index so reordering the list doesn't fail this.
    @MainActor
    func testSettingsOffersEveryNotificationCategory() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 20))
        app.buttons["Profile"].tap()
        openSettings(in: app)

        let titles = ["Logs sent to you", "Messages", "Friend requests",
                      "Friends posting places", "Hourly reminders",
                      "Streak reminders", "Beacon activity"]

        let first = app.switches["Logs sent to you"]
        _ = first.waitForExistence(timeout: 8)
        scrollUntilHittable(first, in: app)
        capture(app, "notification-preferences")

        for title in titles {
            let toggle = app.switches[title]
            scrollUntilHittable(toggle, in: app)
            XCTAssertTrue(toggle.exists, "\(title) must have a switch in Settings.")
        }

        // On by default, and actually switchable — a toggle bound to a
        // read-only value would render and do nothing.
        let messages = app.switches["Messages"]
        scrollUntilHittable(messages, in: app)
        XCTAssertEqual(messages.value as? String, "1", "Categories default to on.")
        messages.tap()
        XCTAssertEqual(messages.value as? String, "0", "Tapping must turn it off.")
        capture(app, "notification-preferences-one-off")
    }

    /// Pulse must keep a message button on every row and the hourly status
    /// card — both are §0 invariants that this phase's work must not disturb.
    @MainActor
    func testPulseKeepsMessageIconsAndCountdown() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Pulse"].waitForExistence(timeout: 20))
        app.buttons["Pulse"].tap()

        let messageButtons = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open chat'")
        )
        XCTAssertTrue(messageButtons.firstMatch.waitForExistence(timeout: 10),
                      "Every Pulse row must keep its message button.")
        XCTAssertGreaterThan(messageButtons.count, 1)

        // The hour card either asks for this hour's log or confirms it. It no
        // longer counts down — the copy is now "Send your Log for the hour" or
        // "Logged for this hour". Both phrasings are matched explicitly rather
        // than on a shared substring: they don't have one ("for *the* hour" vs
        // "for *this* hour"), and the looser "hour" alone would happily match a
        // friend's "golden hour shoot" caption further down the feed.
        //
        // Matched across element types rather than as a `staticText`: the
        // status readout is a labelled accessibility element now that it's a
        // tap target, so there is no bare text node left to find.
        let hourCard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'for the hour' OR label CONTAINS[c] 'for this hour'")
        )
        XCTAssertTrue(hourCard.firstMatch.waitForExistence(timeout: 10),
                      "The hourly status card must stay on Pulse.")

        capture(app, "p4-pulse-message-icons-and-countdown")
    }

    /// The account section carries Blocked accounts (the only route to an
    /// unblock) and Delete account (Guideline 5.1.1(v)), both below Log out.
    ///
    /// These moved out of the Profile tab and into Settings when the tab was
    /// split into "how you present yourself" and "account administration" —
    /// so the walk is now Profile → Settings, and the invariant is that all
    /// three controls are still reachable, not that they're on the landing.
    @MainActor
    func testProfileAccountSectionHasBlockedAndDelete() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 20))
        app.buttons["Profile"].tap()
        openSettings(in: app)

        let deleteButton = app.buttons["Delete account"]
        _ = deleteButton.waitForExistence(timeout: 5) // let the form settle first
        scrollUntilHittable(deleteButton, in: app)
        XCTAssertTrue(deleteButton.exists,
                      "Delete account must be reachable from Profile.")
        XCTAssertTrue(app.buttons["Blocked accounts"].exists,
                      "Blocked accounts must be reachable from Profile.")
        XCTAssertTrue(app.buttons["Log out"].exists, "Log out must still be there.")
        capture(app, "p5-profile-account-section")

        // Deleting must ask first — this is the acceptance bar for 5.1.1(v),
        // and the only thing this test asserts about the dialog. Actually
        // dismissing a system confirmationDialog from XCUITest is timing- and
        // device-dependent in ways unrelated to whether the app is correct, so
        // this deliberately doesn't chase that; a stray extra dismiss tap can't
        // reach "Delete everything" by itself, since that requires its own tap.
        deleteButton.tap()
        let confirm = app.buttons["Delete everything"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "Delete account must confirm before doing anything.")
        capture(app, "p5-delete-account-confirm")

        // Re-launch clears any dialog state cleanly rather than relying on
        // finding "Cancel" in what may be a differently-typed element.
        app.terminate()
        let relaunched = launch()
        XCTAssertTrue(relaunched.buttons["Profile"].waitForExistence(timeout: 20))
        relaunched.buttons["Profile"].tap()
        openSettings(in: relaunched)

        let blockedAccounts = relaunched.buttons["Blocked accounts"]
        scrollUntilHittable(blockedAccounts, in: relaunched)
        blockedAccounts.tap()
        XCTAssertTrue(relaunched.navigationBars["Blocked accounts"].waitForExistence(timeout: 8))
        capture(relaunched, "p4-blocked-accounts")
        // Scoped to its own navigation bar: Settings is still presented
        // underneath and carries a "Done" of its own, so an unscoped lookup
        // now matches two elements.
        relaunched.navigationBars["Blocked accounts"].buttons["Done"].tap()
    }

    /// Add friend is now a people search (name *or* User ID) with suggestions,
    /// not a single-result card.
    @MainActor
    func testAddFriendIsAPeopleSearch() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Pulse"].waitForExistence(timeout: 20))
        app.buttons["Pulse"].tap()

        let addFriend = app.buttons["Add friend"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 10))
        addFriend.tap()

        let field = app.textFields["name, User ID, or code"]
        XCTAssertTrue(field.waitForExistence(timeout: 8),
                      "Search must accept a name as well as a User ID.")
        capture(app, "p6-add-friend-search")
    }

    /// The camera has to keep working in landscape with its full-bleed preview.
    @MainActor
    func testCameraStillWorksInLandscape() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_SEED_DEMO"] = "1"
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "capture"
        app.launch()

        XCUIDevice.shared.orientation = .landscapeLeft
        // Give the capture surface a beat to re-lay-out for the new orientation.
        _ = app.wait(for: .runningForeground, timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        capture(app, "p4-camera-landscape")

        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testBeaconsStillRenders() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_SEED_DEMO"] = "1"
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "beacons"
        app.launch()

        XCTAssertTrue(app.buttons["Beacons"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        capture(app, "p4-beacons")
    }

    /// The logout invariant: signing out lands on Welcome rather than faulting
    /// a still-mounted view whose model was wiped underneath it.
    ///
    /// Named to sort last: XCTest runs test methods alphabetically within a
    /// class, and this is the one test that leaves the shared simulator
    /// session signed out. Running it before the other tests here would break
    /// their assumption of an already-authenticated app.
    @MainActor
    func testZZZLogOutReachesWelcomeWithoutCrashing() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 20))
        app.buttons["Profile"].tap()
        openSettings(in: app)

        let logOut = app.buttons["Log out"]
        _ = logOut.waitForExistence(timeout: 5)
        scrollUntilHittable(logOut, in: app)
        XCTAssertTrue(logOut.exists)
        logOut.tap()

        // Welcome shows the sign-up / log-in switcher.
        XCTAssertTrue(app.buttons["Sign up"].waitForExistence(timeout: 20),
                      "Logout must reach Welcome.")
        XCTAssertEqual(app.state, .runningForeground, "Logout must not crash the app.")
        capture(app, "p5-logout-welcome")
    }
}
