# Fix prompt: unused Bluetooth background mode + full App Review audit

New rejection, plus a full pass over the rest of the app for anything else likely to trip App Review before the next submission. The Bluetooth fix is applied below; everything else is what was checked and cleared, so this doubles as a pre-submission checklist.

---

## 1 — Unused `bluetooth-peripheral` background mode (this rejection)

**Rejection:** "The app declares support for bluetooth-peripheral in the UIBackgroundModes key in your Info.plist but we are unable to locate any Bluetooth Low Energy functionality."

**Root cause:** `Config/Info.plist` (the file both Debug and Release configs point `INFOPLIST_FILE` at) declared:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
    <string>bluetooth-peripheral</string>
</array>
```

`remote-notification` is legitimate — push notifications are real (`PushNotifications.swift`, APNs/FCM wired through `AppDelegate`). `bluetooth-peripheral` isn't backed by anything: a full search of the codebase turns up no `CoreBluetooth` import, no `CBPeripheralManager`/`CBCentralManager`, nothing. It's a leftover value that never had a feature behind it — Ralli's "Beacon" feature is a Firestore-backed location/presence concept (`BeaconSync.swift`, `BeaconsFeedView.swift`), not literal Bluetooth LE. The name overlap is almost certainly how this got added at some point and never removed.

**Fix — applied.** Removed `bluetooth-peripheral` from `Config/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

**Before resubmitting:**
- [ ] Confirm no other target/scheme has its own separate Info.plist re-adding this (checked: both Debug and Release configs share `Config/Info.plist` via `INFOPLIST_FILE`, so one edit covers both).
- [ ] If Ralli ever does add real Bluetooth-based functionality later (e.g. proximity-based beacon detection via actual BLE), re-add the background mode *and* implement it via `CoreBluetooth`, and per Apple's instructions include a screen recording of the real usage in the Review Notes field on that submission — don't add the entitlement ahead of the feature again.

## 2 — Full audit: what else was checked

Went through the areas App Review most commonly flags. Everything below was checked against the actual code, not assumed.

**Privacy — usage description strings.** Every runtime permission prompt has a matching, accurate `Info.plist` string: camera, microphone, location-when-in-use, photo library (read), photo library (add). No permission API is called without one. ✅ clear.

**Privacy — App Tracking Transparency.** Already resolved in a prior submission: no code does cross-app/company tracking under Apple's definition, and the App Privacy label in App Store Connect was corrected to reflect that. ✅ clear (verify the label is still accurate if any new SDK gets added).

**Sign in with Apple (Guideline 4.8).** Only requires Sign in with Apple if the app offers a third-party social login. Checked: Ralli's only auth path is Firebase email/password (`AuthGateView.swift`'s `WelcomeView`) — no Google/Facebook/other social sign-in SDK anywhere in the project. Since there's no third-party login to match, Sign in with Apple isn't required. ✅ clear.

**Account deletion (Guideline 5.1.1(v)).** Apps that support account creation must offer in-app account deletion. Checked: `SettingsView.swift`'s `deleteAccount()` calls `FirestoreService.deleteAccount()` behind a confirmation dialog, and actually removes the account server-side, not just signs out locally. ✅ clear.

**Placeholder/incomplete content (Guideline 2.1).** Searched for lorem ipsum, "coming soon", TODO/FIXME strings, and other obvious placeholder text reachable outside `#if DEBUG`. None found. ✅ clear.

**Other background modes / entitlements vs. actual usage.** `UIBackgroundModes` now only declares `remote-notification`, which is real. No other background-capable entitlement (background location, background fetch, background audio, etc.) is declared, so there's nothing else in this category to mismatch. ✅ clear.

**Crash risk on launch.** One `fatalError` exists, in `explogApp.swift` if `ModelContainer` creation fails — this is the standard SwiftData boilerplate pattern (matches Apple's own project templates) and would only fire on a genuinely corrupt on-disk store, not a normal launch path. Not treated as a rejection risk, but worth knowing it's there if a future rejection cites a launch crash.

**Encryption export compliance.** No `ITSAppUsesNonExemptEncryption` key is set in `Config/Info.plist`. This isn't a rejection cause by itself — Apple will just ask the standard export-compliance question on every submission in App Store Connect. Since Ralli only uses standard HTTPS/TLS (exempt), you can optionally add this to skip that prompt on future uploads:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Not required, just a submission-flow convenience — flagging it as optional rather than doing it automatically, since it's worth double-checking no custom encryption was added elsewhere first.

**In-app purchase / payment guidelines (3.1.1).** No StoreKit, no `SKPaymentQueue`, no in-app purchase code anywhere in the project. Not applicable — nothing to check here yet, but relevant again the moment any paid feature is added (a "Restore Purchases" affordance would become required at that point).

## 3 — Already-fixed items from prior sessions, for reference

Two other rejections were already resolved before this one and don't need re-verifying here unless they resurface:

- **ATT / App Privacy tracking label** (`APP_REVIEW_ATT_AND_IPAD_CAMERA_FIX_PROMPT.md`, §1) — label corrected, no tracking code exists.
- **iPad camera reading as an unresponsive splash screen** (`APP_REVIEW_ATT_AND_IPAD_CAMERA_FIX_PROMPT.md`, §2) — close button and full control layer now guaranteed to appear even if the forced landscape rotation silently fails, which is what iPad was doing.

---

## Verification

- **1:** Build and inspect the compiled `Info.plist` in the `.app` bundle (or Xcode's target Info tab) to confirm `UIBackgroundModes` contains only `remote-notification`. Resubmit and confirm this specific rejection doesn't recur.
- **2:** No code changes were needed for the audit items — they're confirmations to keep on hand for Review Notes or if a related rejection shows up later. If you add any new SDK, permission, background mode, or payment feature going forward, re-run this same checklist against it before submitting.
