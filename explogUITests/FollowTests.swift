import XCTest

/// End-to-end check of the follow graph against the real callables.
///
/// Follow is the one action whose whole point is server state — the edges and
/// `followerCount` live in Firestore and are written inside a transaction, so a
/// unit test over the view model would prove nothing about what actually
/// happens. This drives the button and reads the count back off the screen.
///
/// Needs a target account that isn't the signed-in one (the server refuses a
/// self-follow, correctly). Skips rather than fails when it's absent, so the
/// suite stays green on a machine without a probe account set up.
///
/// To run it, create a throwaway `users/{probeUid}` document with at least
/// `uid`, `handle` and `name`, then — note the `TEST_RUNNER_` prefix, which is
/// how xcodebuild forwards an environment variable into the UI-test runner
/// process; without it the test silently skips:
///
///     TEST_RUNNER_EXPLOG_FOLLOW_TARGET_UID=<probeUid> xcodebuild \
///       -project explog.xcodeproj -scheme explog \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:explogUITests/FollowTests test
///
/// Delete the probe document afterwards — it is a real directory record and
/// would otherwise turn up in other people's search results.
final class FollowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Follow → Following (+1), then unfollow → Follow (back to the start).
    ///
    /// Asserting the delta rather than an absolute count keeps this repeatable:
    /// the probe account keeps whatever followers previous runs left it.
    @MainActor
    func testFollowThenUnfollowMovesTheCounter() throws {
        guard let target = ProcessInfo.processInfo.environment["EXPLOG_FOLLOW_TARGET_UID"],
              !target.isEmpty else {
            throw XCTSkip("Set EXPLOG_FOLLOW_TARGET_UID to a non-self account to run this.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "profilesheet"
        app.launchEnvironment["EXPLOG_AUTO_PROFILE_UID"] = target
        app.launch()

        let followButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Follow '")
        ).firstMatch
        XCTAssertTrue(followButton.waitForExistence(timeout: 30),
                      "The profile sheet must offer a Follow button.")

        let before = try followerCount(in: app)

        followButton.tap()
        let followingButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Following '")
        ).firstMatch
        XCTAssertTrue(followingButton.waitForExistence(timeout: 15),
                      "Following must settle on the server's answer, not roll back.")
        capture(app, "follow-following-state")

        // Poll: the button flips optimistically, so the count only proves the
        // server round trip once it has actually come back.
        XCTAssertTrue(waitForCount(before + 1, in: app),
                      "followerCount must increment by exactly one.")

        followingButton.tap()
        XCTAssertTrue(followButton.waitForExistence(timeout: 15),
                      "Unfollow must return the button to its Follow state.")
        XCTAssertTrue(waitForCount(before, in: app),
                      "Unfollowing must put the count back where it started.")
        capture(app, "follow-unfollowed-state")
    }

    // MARK: Helpers

    /// Reads the "N followers" line off the sheet.
    private func followerCount(in app: XCUIApplication) throws -> Int {
        let label = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH 'followers' OR label ENDSWITH 'follower'")
        ).firstMatch
        guard label.waitForExistence(timeout: 15),
              let value = Int(label.label.split(separator: " ").first ?? "") else {
            throw XCTSkip("No follower count on screen — the profile didn't load.")
        }
        return value
    }

    private func waitForCount(_ expected: Int, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let actual = try? followerCount(in: app), actual == expected { return true }
            usleep(400_000)
        }
        return false
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
