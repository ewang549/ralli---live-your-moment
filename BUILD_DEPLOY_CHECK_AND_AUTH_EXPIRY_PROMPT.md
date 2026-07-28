# Fix prompt: confirm the pending fixes are actually shipped, and diagnose the login-expiry error

Two very different problems bundled here. Read both sections — the first isn't a code fix, it's a verification step that needs to happen before anything else, because it explains why four already-fixed bugs still look broken.

---

## 0 — Do this first: the four previously-reported fixes are already correctly written in the code, but sitting uncommitted

I re-read the current code fresh, with no assumptions from earlier reports, specifically to check whether these were real:

- **Friend-pairing screen gap** (`StackedClipViews.swift`, `pairPage`): fixed — each card is now anchored to the edge nearest the other (`.bottom`/`.top` alignment) instead of centered in its half-height slot, with a code comment explaining exactly why the old centering doubled up as a large visible gap.
- **Unread indicator firing on your own sends** (`Models.swift`): fixed — `hasUnread` now compares against a new `lastIncomingActivityAt` property, scoped to `author?.isMe != true`, instead of the old any-party `lastActivityAt`.
- **Camera flip mid-recording** (`CameraCaptureView.swift`): fixed at an architectural level — recording no longer goes through `AVCaptureMovieFileOutput` (which finalizes the file the instant its connection is touched, which is what caused a flip to truncate the clip) but through `AVCaptureVideoDataOutput`/`AVCaptureAudioDataOutput` sample buffers into a custom `ClipRecorder` writer, which keeps writing regardless of which camera the buffers are currently coming from. There's a code comment explicitly narrating this exact bug and why the new design fixes it.
- **All Friends inconsistent row sizes** (`StackedClipViews.swift`, `row(for:width:height:)`): fixed — every row now gets an identical fixed `width × height` frame, with `.fit` content mode letterboxing internally for any clip whose aspect ratio doesn't match, instead of each row sizing itself to its own clip's aspect ratio.

**But `git status` on the repo shows every one of these files as modified-but-uncommitted, and the most recent actual commit predates all of this work.** This means the fixes exist in the working tree but were never committed, never pushed, and — critically — never rebuilt into whatever binary is actually installed on the test device. That's almost certainly why these still look broken to the person testing the app: the code is right, the running build isn't using it.

**Do this now, in order, before touching any more code:**
1. `git add -A && git commit -m "..."` — commit the pending work.
2. `git push` — push it.
3. **Delete the app from the test device entirely** (not just relaunch it — a stale build can persist through a simple reinstall depending on how Xcode caches derived data), then do a clean build and reinstall (`Product → Clean Build Folder` in Xcode, then rebuild and run, or push a new TestFlight build if that's the distribution path).
4. Only after confirming the device is running a build compiled from the current commit, re-test all four items. If any are still visibly broken after confirming a genuinely fresh build, that's a real regression worth a new, separate report — but don't assume that until step 3 is confirmed done, since testing a stale build will reproduce all four "bugs" even though the code is already fixed.

## 1 — Login shows a "reauthenticate" / "expired credentials" error on original, correct credentials

Investigated the full client-side auth path — it's clean. `Auth.auth().signIn(withEmail:password:)` (`AuthGateView.swift`) uses Firebase's default persistence (keychain-backed, indefinite — no custom override anywhere in the app). Session restoration uses the standard `addStateDidChangeListener` (`AuthSession.swift`), not a custom/reimplemented refresh loop. No `getIDTokenForcingRefresh` calls anywhere (only the safe, non-forcing `getIDToken()`, which lets Firebase silently refresh in the background). The only two `signOut()` call sites in the entire app are both explicitly user-triggered — Settings' logout button and the final step of account deletion — nothing automatic, nothing on launch or backgrounding.

**The error text itself is Firebase's own message, passed through unmodified** (`AuthGateView.swift`'s catch block does `errorMessage = error.localizedDescription` — no custom interpretation or mislabeling). That means this isn't an app-code bug misreading a normal condition as an error — it's a real error code Firebase Auth is actually returning for that sign-in attempt.

**Most likely causes, in order of likelihood — these need to be checked outside the code, in Firebase Console and on-device:**

1. **Refresh tokens were revoked for this account.** Check Firebase Console → Authentication → find the user → look for a revocation event, or check whether any Cloud Function in `functions/index.js` calls `admin.auth().revokeRefreshTokens(uid)` anywhere (grep for it) — if some other flow (e.g. account-deletion cleanup, a security/moderation action) is calling this on the wrong condition, that would force exactly this symptom on next launch.
2. **The account was disabled or the password was changed** via Firebase Console or another device — check the account's status directly in Console.
3. **Device clock skew.** Firebase Auth validates token timestamps and will reject sign-in attempts if the device's clock is meaningfully out of sync with real time — check the test device's date/time settings (especially if "Set Automatically" was ever toggled off).
4. **Provisioning/Team ID change invalidating the keychain.** If the app was ever re-signed under a different Apple Developer Team ID or switched provisioning profiles between builds, the keychain items Firebase Auth relies on for persistence become silently unreadable, which manifests as exactly this kind of forced-relogin-with-error symptom. Worth checking if signing configuration changed recently.

**One real, small code improvement worth making regardless of root cause:** since Firebase's raw `localizedDescription` is currently shown to users verbatim, a `user-token-expired`/`requires-recent-login`/`invalid-credential` error currently displays Firebase's generic internal wording rather than something a user can actually act on. Add a translation layer in `AuthGateView.swift`'s catch block that maps the common Firebase Auth error codes (`AuthErrorCode`) to clearer in-app messaging — e.g. "Your session expired, please sign in again" for expiry-related codes, "That email/password doesn't match" for `wrong-password`/`invalid-credential`, etc. This won't fix the underlying cause, but it stops the app from surfacing confusing raw SDK error text, and makes it much easier to tell users apart (someone truly locked out) from a token hiccup (someone who just needs to resubmit) going forward.

---

## Verification

- **0:** confirm the device under test is running a build compiled after committing and pushing the pending changes — check the build's commit hash/timestamp if possible, not just "I reinstalled it." Re-test all four items only after this is confirmed.
- **1:** check Firebase Console for the affected account's status and any revocation events; check the test device's clock settings; check for any `revokeRefreshTokens` calls in `functions/index.js`. If a genuine root cause is found, report it back — this needs a diagnosis before a code fix can be targeted correctly, since the client code itself isn't the source of the problem.
