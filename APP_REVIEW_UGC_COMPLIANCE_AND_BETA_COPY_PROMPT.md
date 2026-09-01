# Fix prompt: Guideline 1.2 UGC compliance, beta copy, and the fourth-submission audit

Three rejections so far (ATT label, iPad camera splash, `bluetooth-peripheral`). Each was fixed in isolation. This pass went looking for what would trip the *next* submission and found one outright rejection trigger plus a category of missing safety infrastructure that App Review checks specifically on social apps.

Everything below is applied unless marked otherwise.

---

## 1 — Shipping UI described the app as a beta (Guideline 2.1)

**Risk:** App Review rejects a binary whose UI or metadata describes itself as a beta, trial, demo, or test version. `ProWelcomeView` is the *first screen on a fresh install* — the first thing a reviewer sees — and it read:

> "Every premium feature we build, free for as long as you're with us in beta."

**Fix — applied.** `explog/ProWelcomeView.swift` now reads "…free for as long as you're with us." The surrounding doc comments were changed from "beta thank-you" to "founding-member thank-you" so the word doesn't creep back via copy-paste.

This is the single highest-confidence item in this document: it is a named, documented rejection reason and it was on screen one.

## 2 — Guideline 1.2 (User-Generated Content): the missing fourth requirement

Apple asks a UGC app for four things. Ralli had three:

| Requirement | Before | Now |
|---|---|---|
| Report offensive content | ✅ `Safety.swift` | ✅ + comments, beacons |
| Block abusive users | ✅ `Safety.swift` | ✅ |
| Published contact info | ✅ `support@ralli.app` | ✅ + Settings links |
| **Filter objectionable material** | ❌ **missing** | ✅ server + client |
| **Terms/EULA acceptance** | ❌ **missing** | ✅ gated sign-up |

### 2a — No terms agreement existed anywhere

Sign-up was name + email + password. Nothing asked the user to accept anything, and there was no in-app Terms of Use, Privacy Policy, or community guidelines link at all. For a social app this is the most common 1.2 rejection after missing block/report.

**Fix — applied.** New `explog/Legal.swift`:

- `LegalConsentRow` — a checkbox on the sign-up form. `canSubmit` now requires it, and `submit()` guards on it independently so a future caller can't route around the button's disabled state. The copy states the zero-tolerance rule App Review looks for and links both documents inline.
- `LegalLinksSection` — Privacy Policy, Terms of Use, Community Guidelines, and Contact support, added to `SettingsView`.
- Both are driven by the same URL constants, so the links and the consent sentence can't drift apart.

Covered by `explogUITests/SignUpConsentTests.swift`, which drives the real screen: a fully filled form must still not create an account until the box is ticked.

### 2b — Nothing filtered what users posted

`cleanText` trimmed and truncated. It did not look at the content. Captions, comments, place names, beacon notes, display names and handles all went straight to other users.

**Fix — applied, both halves.**

- **Server (`functions/index.js`)** — `moderateText()` / `containsObjectionable()`, applied to `publishLog` (caption), `addComment`, `upsertSpot` (name, summary), `createBeacon` (note), `createProfile` (name), and `normalizeHandle`. This is the enforcement layer: it's the chokepoint a client can't skip. Rejects with a guidelines message rather than silently redacting, so the author learns the rule.
- **Client (`explog/ContentFilter.swift`)** — the same rule, for immediate feedback, *and* as the only check on profile `name`/`bio`/`city`, which are written straight to Firestore under the `onlySoftProfileFields` rule and never touch a Cloud Function.

Both normalize the cheap evasions (leetspeak, separator-spacing, combining marks) before matching, and both build the pattern with per-character `+` quantifiers rather than collapsing repeated letters — collapsing was tried first and is wrong, because it turns "coon" into "con" and starts rejecting "con artist".

Both were tested against a false-positive corpus (Scunthorpe, assess, Penistone, Niger, raccoon, con artist, Ford Escort, spice rack) and an evasion corpus (`n i g g e r`, `f.a.g`, `p0rn`, `niiiigger`, `ret@rd`). **Known accepted tradeoff:** the idiom "a chink in the armour" is blocked. `escort` was deliberately *removed* from the list — a police escort is not solicitation, and an ambiguous term belongs in the report queue where a human decides.

### 2c — Two UGC surfaces had no report path

`safetyActions` was attached to profiles, logs and chat messages, but not to:

- **Comments** on public place posts (`NichePlacesView.CommentsSheet`) — visible to strangers, no way to report.
- **Public beacons** (`BeaconsFeedView.BeaconFeedCard`) — carry a host-written note and a host-uploaded cover photo, shown to people with no relationship to the host.

**Fix — applied.** Added `SafetyTarget.Kind.comment` and `.beacon` plus `CommentSafety` / `BeaconSafety` modifiers, which skip the menu when there's nobody to report (your own content, or a pre-backend row with no author uid). `REPORT_TARGET_TYPES` on the server accepts both.

Separately: a comment rejected by the server used to vanish with no message. `CommentsSheet` now surfaces the reason.

## 3 — Export compliance (submission convenience, not a rejection)

Added `ITSAppUsesNonExemptEncryption = false` to `Config/Info.plist`. Ralli uses only standard HTTPS/TLS, which is exempt. This answers the export question at build time instead of on every upload.

## 4 — Checked and clear

- **Sign in with Apple (4.8)** — not required: Firebase email/password is the only auth path, no third-party social login anywhere.
- **Account deletion (5.1.1(v))** — `SettingsView.deleteAccount()` → `FirestoreService.deleteAccount()`, server-side, behind a confirmation.
- **IAP (3.1.1)** — no StoreKit anywhere. "Ralli Pro" is presentation-only with no entitlement and nothing to buy, so there's no purchase flow to route through IAP. Re-check the moment a paid tier is real.
- **Background modes** — `remote-notification` only, verified in the *compiled* `Info.plist` inside the built `.app`, not just the source.
- **iPad camera fix** — still present (`revealControls(force:)`, ungated close button). Not regressed.
- **No insecure `http://` URLs, no private-API patterns, no external payment links.**

## 5 — Not fixable in code — do these before submitting

These are the ones that will bite regardless of how clean the binary is.

- [ ] **Host the legal documents.** `Legal.swift` points at `https://ralli.app/privacy`, `/terms`, `/guidelines`. **These are assumed, not verified — a 404 from a legal link is itself a rejection under 2.1.** `PRIVACY_POLICY.md` in this repo is the privacy content; terms and guidelines still need writing. Change the URLs in one place (`Legal.swift`) if they land elsewhere.
- [ ] **Privacy Policy URL in App Store Connect must match** the one in `Legal.swift`.
- [ ] **Provide a demo account in Review Notes.** The app is sign-in-walled. A reviewer who can't get in rejects under 2.1 — this may well be worth double-checking against the previous rejections.
- [ ] **Age rating** should reflect UGC + location sharing.
- [ ] **Honour the 24-hour claim.** The consent copy and Settings state that reports are reviewed within 24 hours, which is Apple's 1.2 requirement. Someone has to actually watch the `reports` collection.
- [ ] **`aps-environment` is `development`** in `explog/explog.entitlements`. Xcode normally rewrites this to `production` when exporting with a distribution profile, so it isn't a rejection cause — but it's worth confirming in the exported build, especially since APNs pushes are already known-broken for a separate reason (no valid APNs key in Firebase Console).

---

## Verification

- **1:** Fresh install → first screen contains no "beta"/"trial"/"preview" wording.
- **2a:** `xcodebuild test -only-testing:explogUITests/SignUpConsentTests` — asserts the agreement is shown and that Create account stays disabled until accepted.
- **2b:** Both filters tested against evasion and false-positive corpora; server functions deployed.
- **2c:** Long-press a comment and a public beacon → Report and Block appear.
- **3:** Confirm the export-compliance question no longer appears on upload.

Deployed: `createProfile`, `checkHandleAvailable`, `publishLog`, `addComment`, `upsertSpot`, `createBeacon`, `reportContent`.
