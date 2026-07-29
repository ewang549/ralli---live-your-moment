import XCTest

/// Drives the beacon composer's cover-photo step against the real
/// `PhotosPicker`.
///
/// Nothing below the UI can prove this works. The picker runs out of process, so
/// a unit test can reach the model fields and the save helper but never the one
/// question that matters — whether tapping "Add a cover photo" actually returns a
/// photo and leaves the composer showing it. That's what this drives.
///
/// Needs at least one image in the simulator's photo library
/// (`xcrun simctl addmedia booted <file>`); skips rather than fails when there
/// isn't one, so a fresh simulator doesn't redden the suite.
final class BeaconCoverPhotoTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTheComposerOffersACoverPhotoStep() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "newbeacon"
        app.launch()

        XCTAssertTrue(app.staticTexts["Add a cover photo"].firstMatch.waitForExistence(timeout: 30),
                      "The New beacon sheet must offer a cover photo.")
        // Stated as optional on purpose — a beacon without one falls back to the
        // place's artwork, and the composer says so rather than implying a photo
        // is required.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Optional'")).firstMatch.exists,
                      "The cover photo has to read as optional.")
    }

    @MainActor
    func testPickingAPhotoLeavesItShowingInTheComposer() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "newbeacon"
        app.launch()

        let prompt = app.staticTexts["Add a cover photo"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "No cover photo step to drive.")
        prompt.tap()

        // "Take Photo" is absent on a simulator with no camera, so the library
        // is the path under test either way.
        let fromLibrary = app.buttons["Choose from Camera Roll"].firstMatch
        XCTAssertTrue(fromLibrary.waitForExistence(timeout: 10),
                      "The cover photo dialog must offer the camera roll.")
        fromLibrary.tap()

        // `PhotosPicker` runs out of process but is remote-hosted inside the
        // app's element tree, so its grid is reached through `app` — not through
        // a separate `XCUIApplication` for Photos, which resolves to nothing.
        // The cells are images carrying the Photos grid's own identifier.
        let photo = app.images
            .matching(identifier: "PXGGridLayout-Info")
            .firstMatch
        guard photo.waitForExistence(timeout: 20) else {
            throw XCTSkip("Simulator photo library is empty — add media first.")
        }
        // Tapped through a coordinate rather than `photo.tap()`. The Photos grid
        // draws its thumbnails in one composited layer, so each cell reports as
        // an image with a frame but not as a hittable element of its own — and
        // `tap()` refuses on that basis. The frame is real, which is all a
        // coordinate needs.
        // Single selection, so picking dismisses the picker on its own.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The composer swaps the prompt for the picture, with a Change
        // affordance over it. Either half proves the file came back and was
        // saved: the label is only rendered when `coverFileName` is non-empty.
        let change = app.staticTexts["Change"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 20),
                      "A picked cover photo must replace the prompt in the composer.")
        XCTAssertFalse(app.staticTexts["Add a cover photo"].firstMatch.exists,
                       "The prompt must give way to the photo it produced.")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "beacon-cover-picked"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The whole round trip: pick a cover, post the beacon, see the photo on the
    /// card and again in the detail sheet.
    ///
    /// Separate from the test above because a failure here means something
    /// different. That one proves the picker works; this one needs the Storage
    /// rule for `beacons/{uid}/` and a `createBeacon` that accepts and returns
    /// `coverImageURL` — so failing here points at the backend, not the UI.
    /// Creates a real beacon, which is the point.
    ///
    /// Needs network for MapKit (a beacon can't be posted without a place) and a
    /// photo in the library; skips rather than fails without either.
    @MainActor
    func testAPostedBeaconShowsItsCoverOnTheCardAndInDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["EXPLOG_AUTO_OPEN"] = "newbeacon"
        app.launch()

        let prompt = app.staticTexts["Add a cover photo"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "No cover photo step to drive.")
        prompt.tap()

        let fromLibrary = app.buttons["Choose from Camera Roll"].firstMatch
        XCTAssertTrue(fromLibrary.waitForExistence(timeout: 10),
                      "The cover photo dialog must offer the camera roll.")
        fromLibrary.tap()

        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard photo.waitForExistence(timeout: 20) else {
            throw XCTSkip("Simulator photo library is empty — add media first.")
        }
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Change"].firstMatch.waitForExistence(timeout: 20),
                      "Cover photo never came back.")

        // A beacon needs a place before Post will fire.
        let placePicker = app.buttons["Search for a place"].firstMatch
        XCTAssertTrue(placePicker.waitForExistence(timeout: 10))
        placePicker.tap()

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
        guard confirm.waitForExistence(timeout: 25) else {
            throw XCTSkip("Place confirmation never arrived — needs network.")
        }
        confirm.tap()

        // A note is the other thing Post insists on. Targeted by placeholder
        // because a vertical `TextField` reports as neither reliably — the
        // element type differs by OS version, the label doesn't.
        let note = app.descendants(matching: .any)
            .matching(NSPredicate(format: "placeholderValue == %@ OR label == %@",
                                  "What's the plan?", "What's the plan?"))
            .firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15), "The composer needs a note field.")
        note.tap()
        note.typeText("Cover photo check")

        let post = app.buttons["Post"].firstMatch
        XCTAssertTrue(post.waitForExistence(timeout: 10))
        XCTAssertTrue(post.isEnabled, "Post should be live with a place and a note.")
        post.tap()

        // Straight onto the card: the host's own file renders without waiting on
        // the upload, which is the whole reason the local file name is kept.
        let cover = app.images["beacon-cover"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 30),
                      "A posted beacon must lead with its cover photo, not the place's artwork.")

        let card = XCTAttachment(screenshot: app.screenshot())
        card.name = "beacon-cover-on-card"
        card.lifetime = .keepAlways
        add(card)

        // And again in the detail sheet — reached through *this* card's Details
        // button, not the feed's first. The feed holds every beacon this account
        // has, so `firstMatch` opens whichever card happens to sort earliest,
        // which is usually somebody else's and has no cover to find.
        let details = app.buttons.matching(identifier: "Details").allElementsBoundByIndex
            .filter { $0.frame.minY > cover.frame.maxY }
            .min { $0.frame.minY < $1.frame.minY }
        guard let details else {
            return XCTFail("No Details button below the covered card.")
        }
        details.tap()

        // Not `app.images[...]`: the detail sheet's cover carries its identifier
        // on a clipped, framed container, which reports as a generic element
        // rather than an image. The identifier is the stable part.
        let detailCover = app.descendants(matching: .any)["beacon-cover-detail"].firstMatch
        XCTAssertTrue(detailCover.waitForExistence(timeout: 20),
                      "The detail sheet must show the cover too.")

        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "beacon-cover-in-detail"
        detail.lifetime = .keepAlways
        add(detail)

        // Everything above could be served by the local file the host picked, so
        // none of it proves the URL survived the round trip. Wiping the store and
        // syncing again does: the beacon can only come back from Firestore, and
        // the cover can only come from `coverImageURL`.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchEnvironment["EXPLOG_RESET_CACHE"] = "1"
        relaunched.launchEnvironment["EXPLOG_AUTO_OPEN"] = "publicbeacons"
        relaunched.launch()

        XCTAssertTrue(relaunched.images["beacon-cover"].firstMatch.waitForExistence(timeout: 60),
                      "After a cache wipe the cover can only come from the server — "
                      + "createBeacon must store and return coverImageURL.")

        let synced = XCTAttachment(screenshot: relaunched.screenshot())
        synced.name = "beacon-cover-after-cache-wipe"
        synced.lifetime = .keepAlways
        add(synced)
    }
}
