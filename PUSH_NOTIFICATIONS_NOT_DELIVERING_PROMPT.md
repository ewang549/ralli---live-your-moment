# Fix prompt: notifications don't work — full pipeline audit result

I had the code audited end-to-end: permission request, APNs registration, FCM token save, Firestore read/write paths, the Cloud Functions `notify()` sender, all the trigger points, and the notification-preferences gating added recently. **Every piece of code is correctly wired.** This isn't the usual case of "here's the bug, fix it" — the likely causes are outside the code, in Firebase Console configuration and deployment state. Read this in full before touching anything; there's a real risk of a coding agent "fixing" code that already works and wasting time.

---

## What's already confirmed correct (do not re-touch)

- **Permission + APNs registration** (`explogApp.swift`): `AppDelegate` correctly requests authorization, calls `registerForRemoteNotifications()`, and forwards the APNs device token to `Messaging.messaging().apnsToken` in `didRegisterForRemoteNotificationsWithDeviceToken`.
- **FCM token save** (`PushNotifications.swift`): `MessagingDelegate.didReceiveRegistrationToken` → `saveToken(_:)` writes to `users/{uid}/devices/{token}` — exactly the path the backend reads from.
- **Backend `notify()` helper** (`functions/index.js:2533-2562`): correct payload shape, correctly imports `getMessaging`, no silent error-swallowing on the send call itself.
- **All trigger points** (`onFriendRequest`, `onFriendAccepted`, `streamMessageWebhook`, `streakReminder`, `hourlyLogReminder`) are correctly exported and would deploy as-is.
- **Notification-preferences gating** (`notificationsAllowed`, `functions/index.js:2524-2530`, and the client mirror in `NotificationPreferences.swift:60-62`): specifically checked for the classic "absent prefs = treated as off" bug — confirmed this is NOT happening. Missing docs, missing fields, and missing keys all default to allowed (`true`); only an explicit `false` suppresses. This was clearly deliberately guarded against already — leave it alone.
- **Firestore rules**: no blockage on `notificationPrefs` writes or `devices/{token}` read/write/delete.
- **`GoogleService-Info.plist`**: looks properly configured, real project/bundle IDs, no placeholder values.
- **Entitlements**: `aps-environment` is set and correctly referenced in both build configs.

## Do this first — not code changes, verification steps

**1. Check Firebase Console for an APNs credential.** This is the single most common cause of "everything in the code is right but nothing ever arrives on device." Go to Firebase Console → Project Settings → Cloud Messaging → Apple app configuration, for project `explog-723b7` / bundle `com.ej.explog`. Confirm an APNs Auth Key (.p8) or certificate is actually uploaded and valid. FCM will accept the send call and report success even if this is missing or expired — the failure is silent from the app/backend's perspective, since APNs itself is what rejects the message downstream.

**2. Deploy the Cloud Functions.** The two most recent commits substantially modified `functions/index.js` (one added ~2,000 lines), and there's no evidence in the repo of a deploy having run since. If `notify()`/the preference-gating logic exists in the local code but was never pushed live, the deployed functions could be running an older version — or, if any of these are newly added functions, might not exist server-side at all yet. Run:
```
firebase deploy --only functions
```
from the `functions/` directory, watch for deploy errors, then trigger a real event (send a friend request, send a message) and check:
```
firebase functions:log
```
for delivery errors or confirmation that `sendEachForMulticast` executed.

**3. Confirm the `aps-environment` matches how the test build is actually signed.** The entitlement is currently hardcoded to `development`. If you're testing via TestFlight or any build signed with a Distribution provisioning profile, this needs to be `production` — Xcode usually swaps this automatically at archive time, but if anything about signing is off, a dev-signed token won't validate against a prod-signed binary or vice versa. Confirm which environment the actual test device/build used and that it matches.

**4. Confirm a device token actually gets written.** On a real device, grant notification permission, then check the Firestore console directly for a new document under `users/{your-uid}/devices/`. If no document appears, the break is on-device (permission not actually granted, or APNs registration failing silently) rather than anywhere in the backend — check Xcode's console output for `didFailToRegisterForRemoteNotificationsWithError` (see the code note below).

## Two small, real code fixes worth making while in this area

These aren't the root cause, but they're genuine gaps that make this kind of issue harder to diagnose next time — worth fixing alongside the verification steps above, not as a substitute for them.

**A. `didFailToRegisterForRemoteNotificationsWithError` only prints, it doesn't log.** In `explogApp.swift`'s `AppDelegate`, this handler currently just does a bare `print(...)`, which won't reliably show up when filtering device logs by the app's subsystem. Switch it to `os.Logger` (matching whatever logging pattern the rest of the app uses) so a registration failure is actually visible when debugging on a real device:

```swift
func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    logger.error("APNs registration failed: \(error.localizedDescription)")
}
```

**B. `updateSoftFields` (`FirestoreService.swift:571-579`) uses `.updateData()` wrapped in `try?`, silently swallowed.** If a very new account opens Settings before its `users/{uid}` document has been created by whatever normally creates it, `updateData()` throws (it requires the document to already exist) and the preference save is silently dropped with no error surfaced to the user — they'd see the toggle flip in the UI but nothing would actually persist. Switch to `setData(payload, merge: true)`, which creates the document if it doesn't exist instead of requiring it to already be there:

```swift
try await db.collection("users").document(uid).setData(payload, merge: true)
```

---

## Verification

- Confirm the APNs key/cert is present and valid in Firebase Console before doing anything else — this alone is the most likely fix.
- After deploying functions, trigger a friend request or message between two real test accounts/devices and confirm a push actually arrives.
- Toggle a notification preference off in Settings, confirm that category stops arriving while others still do (re-validates the gating logic still works after any changes).
- Check `users/{uid}/devices` in the Firestore console has a real token document for your test device after granting permission.
