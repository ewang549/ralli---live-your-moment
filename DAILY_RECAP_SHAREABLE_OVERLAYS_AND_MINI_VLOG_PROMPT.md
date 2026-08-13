# Feature prompt: Daily Recap — overlay every clip with its time/caption/stickers, add a stitched mini-vlog, add a shareable link, plus two more growth-loop features (Instagram Story export, a non-user Beacon preview link)

Growth rationale: Daily Recap is the one asset in Ralli that's naturally worth posting *outside* the app, the same way Snapchat/BeReal/Spotify Wrapped content spreads — but today it's neither fully "watchable" as one piece nor shareable at all. Beacons are the other natural growth surface: meetup coordination that's inherently visible to people not yet on the app. Five items total, in roughly increasing order of effort. Each section states what already exists so this doesn't get rebuilt from scratch.

---

## 1 — Each clip in the recap should show its time, caption, and any stickers/drawings overlaid — not just raw media

**Already exists, don't rebuild:**
- If the user added stickers or hand-drawn strokes at capture time, they're already burned into the clip's actual pixels — `OverlayBurnIn.burn()` (`OverlayBurnIn.swift:46-62`) runs on "Next" in `PostCaptureReview.advance()` (`PostCaptureReview.swift:475-496`) whenever `hasOverlays` is true (`PostCaptureReview.swift:99-101`), regardless of whether the log is later sent. So stickers/drawings already show up wherever this clip is displayed, recap included.
- The hour timestamp and caption are **not** baked into pixels — they're plain data (`Clip.capturedAt`, `Clip.label`) drawn live at playback via `HourOverlay` (`HourOverlay.swift:14-29`) and a caption helper (`StackedClipViews.swift:250-258`), composed together inside `StackedClipPane` (`StackedClipViews.swift:139-149`) — the shared pane every feed (Pulse, the chat feeds) already uses to show this correctly.

**The actual gap:** `DailyVlogView`'s `DayRecapPage` renders the bare `ClipView` directly (`DailyVlogView.swift:302`: `ClipView(clip: clip, isActive: true, contentMode: .fit)`) — no `HourOverlay`, no caption, nothing. That's why the recap shows raw media with no time/caption today; stickers/drawings only appear if they happened to be burned in at capture.

**Fix:** swap `DayRecapPage`'s bare `ClipView` for `StackedClipPane` (matching how every other feed composes the hour banner + caption over a clip), or, if `StackedClipPane` brings along UI that doesn't belong in the recap (author chip, action rail), add the same `HourOverlay` + caption composition directly to `DayRecapPage` instead — but reuse the existing `HourOverlay`/caption components rather than writing a third, divergent implementation (which is what `MontageView.swift` did — see below — and is exactly the inconsistency to avoid repeating).

## 2 — A "mini vlog": all the day's clips stitched into one continuous video, in hourly order, with the same overlay on each segment

**Already exists, don't rebuild:**
- `VlogComposer.swift` already does real multi-clip stitching via `AVMutableComposition` (`makeComposition`, lines 22-68), used today by `DailyVlogView.save()` (`DailyVlogView.swift:183-205`) to export a combined `.mp4` to Photos. It's a solid base to extend — but it only concatenates raw video tracks: no photos, no overlay compositing of any kind.
- `OverlayBurnIn.burnVideo` (`OverlayBurnIn.swift:219-266`) is the compositing technique to reuse for baking an overlay into a video: it builds an `AVMutableVideoComposition` via `.videoComposition(with:)` and composites a Core Image overlay over every frame (deliberately not `AVVideoCompositionCoreAnimationTool` — see the file's own comment on why that's untestable in this project).
- **`MontageView.swift` is a separate, unrelated screen** — a slideshow with an auto-advance timer that draws its own third, independent caption/hour UI (plain `Text`, not `HourOverlay`) and produces no video file at all. It appears superseded by `DailyVlogView`, which has an explicit code comment (`DailyVlogView.swift:210-219`) explaining why it plays clips individually today. Don't extend `MontageView` — it's the wrong base, and its caption UI is exactly the kind of one-off reimplementation this feature should avoid creating another of.
- Photos are a known, already-flagged gap, not new information: `VlogComposer`'s own doc comment (lines 9-13) and `DailyVlogView.stillsLeftOut` (`DailyVlogView.swift:71-77`, surfaced in the footer at lines 461-468) already call out that stills are left out of the stitched export today.

**This is genuinely new work, not a small extension:** nothing today stitches multiple clips *and* bakes a different overlay into each segment of one continuous file. Concretely:
1. Extend `VlogComposer`'s composition step to build an `AVMutableVideoComposition` (not just a plain `AVMutableComposition`) with a distinct `AVMutableVideoCompositionInstruction` per source clip's `CMTimeRange`, each applying that clip's own hour/caption/sticker overlay via the same Core-Image-over-`CIImage` approach `burnVideo` already uses — just parameterized per-segment instead of one overlay for the whole asset.
2. Render photo stills into the composition too: a still needs to become a fixed-duration video segment (pick a duration — 2-3s is the common convention for this kind of recap) with its own overlay burned in the same way, which means writing a "photo → short video clip" step that doesn't exist anywhere in the app yet (closest precedent: `burnPhoto`'s `UIGraphicsImageRenderer` compositing, but that produces a JPEG, not a video frame sequence — this needs an `AVAssetWriter` pass generating frames from the static image instead).
3. Order clips hourly (the recap's existing `hourGroups` grouping in `DailyVlogView` is the source of truth for order — reuse it rather than re-deriving order from `capturedAt`).
4. Surface the result as an in-app playable "watch as one video" experience (a single `AVPlayer` over the stitched output), separate from the existing "step through clips one at a time" `DayRecapPage` browsing and separate from the existing Photos-export button in `save()` — this is a new watch surface, not a replacement for either existing behavior.

## 3 — A share button that generates a link to the day's recap

**Nothing to reuse here — this is entirely new infrastructure**, confirmed via a full repo search: no universal-link/associated-domains entitlement (`explog.entitlements` only has `aps-environment`), no custom URL scheme, no `ShareLink(` usage anywhere, no Firebase Dynamic Links config, and `functions/index.js`'s only raw HTTP (`onRequest`) endpoint is the unrelated `streamMessageWebhook` (line 2765) — every other Cloud Function is an authenticated `onCall` RPC, not something a signed-out browser or non-user can hit.

**Building this means, in order:**
1. A Firestore doc representing a publicly-viewable recap — analogous to how `publishLog` (`functions/index.js:1351`) already writes a public `logs/{id}` doc for Places, but scoped to "this user's clips for this day" rather than one clip.
2. A new `onRequest` Cloud Function that serves a web page (or a redirect into a lightweight web view) for a given recap id — pulling the referenced clips' media URLs and rendering them, unauthenticated. Decide up front how much of the recap a non-user actually sees (all clips? a preview + "download Ralli to see more," similar to the Partiful/Luma pattern of using the invite itself as the funnel) — this is a product decision as much as an engineering one, worth confirming before building.
3. An associated-domains entitlement + Apple App Site Association file if opening the link on an iPhone with Ralli installed should deep-link straight into the app instead of a web page (recommended, but adds real setup: a hosted `.well-known/apple-app-site-association` file and a matching domain).
4. Client-side: a share button in `DailyVlogView` that calls the new Cloud Function to mint/fetch the link, then hands it to `ShareLink` (or `UIActivityViewController`) — the actual sharing UI is the easy part; the link-generation backend is the real scope of this item.

Given the scope gap between items 1-2 (extending existing systems) and item 3 (new backend infrastructure + a product decision about what non-users see), consider shipping 1 and 2 first and scoping 3 as a separate follow-up pass.

## 4 — One-tap "share to Instagram Story" export from Daily Recap, watermarked like BeReal's

Growth rationale: the whole point is turning a private daily habit into free, repeated advertising in front of every user's followers who aren't on Ralli yet — the mechanic that drove a meaningful share of BeReal's growth.

**Reusable precedent, nothing Instagram-specific exists yet:** `PostCaptureReview.swift:639-659`'s `saveComposite()` is the closest thing in the codebase to this — it flattens a `ZStack` (media + look + drawings + stickers) into a `UIImage` via `ImageRenderer`, sized to `UIScreen.main.bounds` at `UIScreen.main.scale`. That's the right technique for producing the Story background image, but today it only calls `UIImageWriteToSavedPhotosAlbum` — it stops at "save to Photos," it doesn't hand off to Instagram. `DailyVlogView.swift:183-205`'s `save()` is the equivalent precedent for the video case (stitches via `VlogComposer`, writes via `PHPhotoLibrary`).

**Confirmed via full repo search: nothing Instagram-related exists.** No `instagram-stories://` URL scheme usage, no pasteboard-based Story handoff, no watermark logic anywhere. `UIPasteboard` today is used only for plain-text copy (chat text, friend codes) — not the sticker-background image handoff Instagram's Story sharing needs. This is genuinely new integration work, though a well-documented one: Instagram's iOS Story sharing doesn't require an API key for a basic image/video handoff — it works by writing specific keys (`com.instagram.sharedSticker.backgroundImage`, and optionally a `.stickerImage`/attributed link) into `UIPasteboard.general.items` as an `NSDictionary`, then opening `instagram-stories://share`, with a plain `UIActivityViewController` share-sheet fallback when Instagram isn't installed or the scheme fails to open.

**Fix — build in this order:**
1. Add a query to `Info.plist`'s `LSApplicationQueriesSchemes` for `instagram-stories` (required before `canOpenURL(_:)` will report Instagram as installed).
2. Reuse `saveComposite()`'s `ImageRenderer` flattening technique, but generate the export from Daily Recap content — either one representative clip/cover image, or (better for the growth goal, since it's more distinctive content) a flattened composite of the day's recap layout itself, with the Ralli logo/wordmark burned in as the watermark, matching BeReal's own visible-branding approach.
3. Write the composited image into the pasteboard with Instagram's expected keys, attempt `instagram-stories://share`, and fall back to `UIActivityViewController` (which still lets the user manually pick Instagram, just without the pre-filled Story canvas) if Instagram isn't installed or the scheme open fails.
4. Add the share button to `DailyVlogView`'s existing chrome, near (but distinct from) the Photos-export `save()` button and the link-share button from item 3 above.

## 5 — Beacons: a "see who's around" preview a non-user can view via a shared link, no login required to peek

Growth rationale: Beacon plans are already visible to people who aren't on the app — referenced in a group chat, mentioned in person — this makes that visibility actually convert, the same funnel Partiful/Luma use (peek without an account, log in only to act).

**Already exists:** `Beacon` (`Models.swift:864-939`) has everything needed to render a preview — `note`, `startsAt`, `capacity`, denormalized `hostUID/hostName/hostEmoji/hostAvatarURL` (893-896), `coverImageURL` (907), and `isPublic` (876, distinguishing friends-only from public beacons — a non-user preview should probably only ever be offered for `isPublic == true` beacons, not friends-only ones). `BeaconSync.swift` handles publish/join today via `onCall` Cloud Functions (`createBeacon` confirmed at `functions/index.js:2250`, plus `listPublicBeacons`/`joinBeacon`/`leaveBeacon`) — all auth-required, which is fine to leave as-is; the new preview surface is additive, not a replacement.

**Confirmed via repo search: no public/unauthenticated viewing surface exists anywhere for beacons** (or anything else) — the only raw HTTP (`onRequest`) Cloud Function in `functions/index.js` is the unrelated `streamMessageWebhook` (line 2765). This needs the same category of new infrastructure as item 3's recap link, applied to beacons instead:
1. A new `onRequest` Cloud Function serving a public preview for a given beacon id — host identity, note, start time, cover image, and an attendee **count** (not full attendee identities: `joinedUIDs` (Models.swift:930) is bare uids with no public-safe name/avatar attached per-attendee — only the host's identity is denormalized for public display today, so showing "who's going" beyond a count needs a new server-side projection that resolves a public-safe subset of attendee identities, which is a real design decision — decide whether "who's around" means a count, host-only, or a limited public attendee list before building).
2. Reuse whatever associated-domains/universal-link setup gets built for item 3's recap share link (build these two together if both are in scope — they need the same entitlement, ASA file, and hosting setup, just different Firestore reads).
3. Client-side: a share button on the Beacon detail/creation flow generating this link, and (if a signed-out user taps it with the app not installed) a plain web page rendering the same preview data.

---

## Verification

- **1:** open Daily Recap and confirm every clip shows its hour and caption overlaid, plus any stickers/drawings that were added at capture — matching exactly what the same clip looks like in Pulse/chat feeds.
- **2:** from Daily Recap, find the new "watch as one video" option, confirm it plays every clip from that day in hourly order as one continuous video (photos included, shown for a consistent duration), with each segment showing that clip's own overlay.
- **3:** tap Share, confirm a link is generated, and confirm opening that link (from a device without Ralli, and from one with it installed) shows the recap content as scoped by the product decision made in step 3.2 above.
- **4:** from Daily Recap, tap the Instagram share button with Instagram installed and confirm it opens directly into Instagram's Story composer with the watermarked recap image pre-loaded; with Instagram not installed, confirm the share sheet fallback still works.
- **5:** create a public beacon, generate its share link, and confirm a signed-out browser/device can view the preview (host, time, note, cover image, attendee count) without logging in, while joining/responding still requires an account.
