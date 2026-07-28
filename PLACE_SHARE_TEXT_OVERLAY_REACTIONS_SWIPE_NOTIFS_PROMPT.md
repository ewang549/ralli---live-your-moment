# Fix prompt: place-sharing, text overlay position, highlights/insights, reaction images, chat swipe-dismiss, notification prefs

Six items, each grounded in the current code.

---

## 1 — Sending a Place to a friend doesn't work (writes to a dead local-only store)

The UI and flow already exist end-to-end — this isn't a missing feature, it's a regression. `SharePlaceSheet` (`NichePlacesView.swift:582-737`) lets you pick a chat and share a spot; its `share(to:)` (lines 697-707):

```swift
private func share(to chat: Chat) {
    let message = Message(chat: chat, author: me, text: "check this spot out 👀", sharedSpotName: spotName)
    message.sharedSpot = clip.spot
    modelContext.insert(message)
    chat.messages.append(message)
    try? modelContext.save()
    sentTo.insert(chat.id)
}
```

This is a pure local SwiftData insert — no network call at all. It only ever gets displayed by `MessageBubble` (`ChatDrawerView.swift:226,300`), which is exclusively used inside `MessageThreadView` — the *legacy*, pre-Stream chat view. But `StreamConfig.isEnabled` (`StreamConfig.swift:55-57`) is true for essentially every real signed-in session now (it used to be permanently false; that was fixed in an earlier round), so `ChatDrawerView`/`ChatDetailView` render `StreamThreadView` instead (`ChatDrawerView.swift:108-129,155-163`) — a view that never reads `Message`/`sharedSpot` at all. The sender sees "Sent" (line 680-683 sets `sentTo`), but the friend receives literally nothing.

**Fix — route this through Stream, matching the pattern `react(with:)`/`StreamThreadPoster.postReaction` already uses** (`StackedClipViews.swift:596-625`, `StreamThreadView.swift:334-374`):

```swift
private func share(to chat: Chat) async {
    if StreamConfig.isEnabled {
        await StreamThreadPoster.postSpotShare(clip.spot, to: chat)
    } else {
        // keep the existing local-store path as the legacy fallback
        let message = Message(chat: chat, author: me, text: "check this spot out 👀", sharedSpotName: spotName)
        message.sharedSpot = clip.spot
        modelContext.insert(message)
        chat.messages.append(message)
        try? modelContext.save()
    }
    sentTo.insert(chat.id)
}
```

Add `StreamThreadPoster.postSpotShare(_:to:)` alongside the existing `postReaction`, following the same join-then-send shape:

```swift
static func postSpotShare(_ spot: Spot, to chat: Chat) async {
    guard let channelId = chat.streamChannelId, let client = ... else { return }
    try? await StreamTokenProvider.joinChannelIfNeeded(channelId: channelId, otherMemberIds: chat.streamMemberIds, name: chat.displayName)
    let controller = client.channelController(for: ChannelId(type: .messaging, id: channelId))
    controller.createNewMessage(
        text: "check this spot out 👀",
        extraData: [
            "ralliSharedSpotId": .string(spot.id.uuidString),
            "ralliSharedSpotName": .string(spot.name),
        ]
    ) { _ in }
}
```

**Then, on the receiving end**, add a bubble renderer in `StreamThreadView` that recognizes `ralliSharedSpotId` in a message's `extraData` and renders a spot-card bubble (name/thumbnail) instead of plain text, matching however `ralliReactionEmoji` extraData is (or will be, per item 4) specially rendered. Tapping that card should navigate to the Place detail screen (`SpotDetailView`, already used from `SpotDetailView.swift:808-817`) scoped to `spot.id` — resolving the spot locally if already synced, or fetching it via the existing `upsertSpot`/spot-lookup path if the receiving friend hasn't seen it yet.

## 2 — Post-capture text should overlay at the position you dragged it to, not show as a generic caption

Confirmed: this isn't a bug where position data gets dropped in a save step — it structurally never had anywhere to go. `TextItem` (`PostCaptureReview.swift:603-610`) does capture full `position`/`scale`/`rotation`/`color`, live, via `MovableOverlay`'s drag/pinch/rotate gestures. But at hand-off, `caption` (lines 65-67) collapses every `TextItem` into one joined plain string, discarding all of that:

```swift
texts.map(\.text).filter{...}.joined(separator: " ")
```

That string becomes `Clip.label` (`Models.swift:341`, a plain `String` with no schema for position/color/scale/rotation), and playback (`StackedClipViews.swift:132-133,226-240`) just renders `clip.label` as one fixed `Text` pinned to the bottom-left — which is exactly the "shows as a caption" complaint. The one place position *is* honored, `saveComposite()` (`PostCaptureReview.swift:534-577`), only runs for the "Save to Photos" button and is explicitly gated off for video (`media.kind != .video`, line 249-252) — it never touches what actually gets sent to the feed/chat.

**Fix — two parts, since photo and video need different approaches:**

**Photos:** burn the text in at save time, the same way `saveComposite()` already does for the Photos-export path — reuse that exact `ImageRenderer`/`staticOverlays` compositing (lines 561-577) when building the `Clip` that gets sent/published, not just when saving to the camera roll. Since photos are static, baking the text into the actual image pixels at the chosen position is the simplest correct fix and needs no new schema.

**Video:** this is a real gap, not a quick fix — there is no video-compositing code anywhere in the repo (confirmed: zero matches for `AVVideoComposition`/`CoreAnimationTool`). Recommend building this via `AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`: construct a `CALayer` per `TextItem` positioned/rotated/scaled to match what the editor showed, animation-tool-composite it into the video's render pipeline at export time (this is the standard AVFoundation approach for burning text/graphics into video and is a self-contained addition — it doesn't touch playback or the rest of the pipeline). This needs to run once, at send-time, producing the final video file that then gets uploaded — not at playback time. Given this is nontrivial, scope it as its own follow-up task if timeline is tight; the photo fix (above) can ship independently and covers the more common case.

Either way, `Clip.label` should stop being treated as "the text overlay" — once positioned overlays are burned into the media itself, `label`/caption can either go away entirely for logs with text items, or continue to serve a separate, genuinely-caption purpose if one is wanted (distinct from what the user drew/typed on the video itself).

## 3 — Profile Highlights: tap-to-play on your own profile is simply missing (Insights/likes/comments/views are already correct — don't touch)

**Good news first:** the likes/comments/views backend from an earlier prompt is fully implemented, not a placeholder — `toggleLikeLog`, `addComment`, `listComments`, `viewLog`, `logStats` all exist server-side (`functions/index.js:1752,1787,1829,1878,1900`) and are transactionally correct (`viewLog` explicitly excludes the author's own views, `toggleLikeLog` uses a transaction to avoid double-count races). Client-side, `EngagementSync.swift` wires all of this with optimistic-update-plus-reconcile, and `ClipView`/`NichePlacesView`'s `.task(id:)`-gated `markViewed` calls are correctly scoped to only the actually-visible pane. **Do not modify this — it's correct and shouldn't be touched again.**

The one real, narrow gap: **your own profile's Highlights tiles have no tap handler at all.** `highlightCell(_:)` (`UserProfileView.swift:271-345`) is a static `ZStack` with no `Button`/`onTapGesture` — the only interactive element is the "…" overflow menu (347-369, "Insights"/"Delete video"). Contrast with *other* users' profiles, where `highlightsSection` (line 765-783) already wraps each tile in `Button { openHighlight(clip) }`.

**Fix:** wrap `highlightCell`'s tile in a tap target that opens an actual playback view for that clip — a full clip player (reuse `ClipView`/whatever `StackedClipPane` already renders for a single clip, presented in a sheet or full-screen cover), not the "jump to Places feed" redirect that `openHighlight` does for other users' profiles (that redirect makes sense for public content browsing, but your own Highlights should open a direct player). Keep the existing overflow menu's "Insights"/"Delete" untouched — this is additive, a new tap affordance alongside it, not a replacement.

## 4 — Reaction messages should show the emoji overlaid on an image of the log, not plain text

Confirmed via the installed SDK version (stream-chat-swift 5.7.0): `ChannelController.createNewMessage` supports an `attachments: [AnyAttachmentPayload]` parameter, and `AnyAttachmentPayload` has a local-file-URL initializer that uploads and attaches an image automatically. There's no server-side "sticker overlay" feature in Stream — the compositing has to happen client-side before upload, but the app already has the exact technique needed: `PostCaptureReview.saveComposite()` (lines 534-554) uses SwiftUI's `ImageRenderer` to flatten a `ZStack` into a `UIImage`. Reuse that same approach here.

**Fix**, in `StreamThreadPoster.postReaction` (`StreamThreadView.swift:341-375`):

1. Get a static frame for the clip: for `.photo` clips, load the asset directly (`clip.assetFileName`/`remoteURLString`); for `.video` clips, extract a frame via `AVAssetImageGenerator.copyCGImage(at:)` (net new — nothing to reuse here, confirmed no existing thumbnail-generation code anywhere in the app).
2. Composite the emoji onto that frame using `ImageRenderer` (same technique as `saveComposite()`) — a simple centered or corner-placed emoji sticker over the frame image is enough; doesn't need to match the editor's positioning system from item 2.
3. Write the composited image to a temp file, then:

```swift
controller.createNewMessage(
    text: "",
    attachments: [AnyAttachmentPayload(localFileURL: tempURL, attachmentType: .image)],
    extraData: [
        "ralliReactionEmoji": .string(emoji),
        "ralliClipId": .string(clip.remoteID.isEmpty ? clip.id.uuidString : clip.remoteID),
        "ralliClipKind": .string(clip.kind.rawValue),
    ]
) { _ in }
```

Keep the existing `extraData` keys so any future clip-linkage logic (e.g. "tap the reaction to jump back to that log") keeps working; drop the plain-text fallback string since the image now carries the meaning.

## 5 — Swipe-right-to-dismiss in chat

This already works in one place and is missing in two others, for a clear structural reason:

- **Already works, no change needed:** `PulseFeedView.swift:39-49` pushes `ChatDetailView` via `NavigationStack.navigationDestination` — that gets the native interactive swipe-back gesture for free, and nothing in the codebase disables it.
- **Broken — needs a fix:** `PulseHomeView.swift:124-138` and `UserProfileView.swift:662-666` both present chat via `.fullScreenCover(item:)` wrapping `ChatDetailView` as the *root* of its own ad-hoc `NavigationStack`. `fullScreenCover` has no built-in dismiss gesture at all (unlike `.sheet`), and being the stack's root means there's no "back" to swipe to either. Dismissal today is only the explicit `CloseButton` (`ChatDetailView.swift:179-183`, wired through the `onClose` closure at line 149).

**Fix:** attach a custom `DragGesture` to the `ChatDetailView`/`StreamThreadView` container used inside both `fullScreenCover` sites, translating a rightward swipe past a threshold into a call to the same `onClose` closure that the existing `CloseButton` already uses:

```swift
.gesture(
    DragGesture(minimumDistance: 20)
        .onEnded { value in
            if value.translation.width > 80 && abs(value.translation.height) < 60 {
                onClose()
            }
        }
)
```

Consider adding a live-tracking offset (`.offset(x: max(0, dragOffset))`) so the view visibly slides with the finger rather than just snapping shut at the threshold, for a smoother feel — optional polish on top of the functional fix. `ChatDrawerView`'s `.sheet`-presented paths already have drag-to-dismiss (vertically) via `.presentationDragIndicator`; leave those as-is since they weren't reported as broken.

## 6 — Notification preferences in Settings

Confirmed from scratch: `SettingsView.swift` has zero notification-related UI today, and there's no per-user notification-preference field anywhere (`Friend`, `RemoteProfile`, or `functions/index.js`). This is a new feature on both ends. Here's the current inventory of what actually gets sent server-side, all funneled through the shared `notify(uid, {...})` helper (`functions/index.js:2436-2463`):

1. Friend request received (`onFriendRequest`, 2479-2490)
2. Friend request accepted (`onFriendAccepted`, 2499-2516)
3. New chat message (`streamMessageWebhook`, 2526-2573)
4. Daily streak-lapse reminder (`streakReminder`, 2581-2613 — a once-daily scheduled nudge, not an hourly one)

None of your four requested categories line up exactly with what exists except "text message notifications" (#3 above). "Hourly reminders to send a log" and "when friends post a public location" don't exist as triggers at all yet, and "when someone sends them a log" also doesn't exist as a distinct notification type today (only chat messages trigger a push, not a log being sent to you specifically).

**Build:**

**Data model** — add `notificationPrefs: [String: Bool]` (or discrete `Bool` fields, simpler to reason about with a small fixed set) to both `Friend` (local SwiftData, for the signed-in user) and `RemoteProfile`/the `users/{uid}` Firestore doc (so Cloud Functions can check it before sending). Default every category to `true`.

**Categories to add**, matching your four plus two worth adding for completeness given what already triggers a notification today but currently has no toggle:

- `logReceived` — new. Fires when a friend sends you a log (needs a new trigger — hook into wherever a log's `recipientUids` gets written server-side at publish time, e.g. `publishLog`, and call `notify()` for each recipient not already covered by the chat-message webhook).
- `hourlyReminder` — new, replacing/supplementing the existing daily `streakReminder`. If "hourly" is meant literally (a nudge every hour you haven't posted that hour, matching the app's hourly-cadence concept), this needs a new scheduled function running hourly rather than once a day — confirm with product intent whether this should replace `streakReminder` or run alongside it before implementing, since firing both could feel like double-nagging.
- `friendPostedLocation` — new. Fires when a friend posts publicly to a Place (hook into wherever a public spot post gets written, e.g. `publishLog` when `audience === "public"`, notifying friends of the poster).
- `chatMessages` — maps directly to the existing `streamMessageWebhook` (#3 above); just add the preference check.
- `friendRequests` — covers the two existing friend-request notification types (#1, #2 above) as one toggle, since splitting "received" from "accepted" is probably more granularity than useful.
- `beaconActivity` — suggested addition: nothing currently notifies about Beacon/meetup activity (someone joining your beacon, a beacon you joined starting soon) even though that's a real-time-sensitive feature; worth adding both the trigger and the toggle if there's time, but flagging as a nice-to-have rather than part of the four explicitly requested.

**Wiring:** centralize the check inside `notify()` itself (`functions/index.js:2436-2463`) — have every call site pass a `prefKey` (e.g. `notify(uid, { prefKey: "chatMessages", ... })`), and have `notify()` look up the recipient's `notificationPrefs[prefKey]` (defaulting to `true` if the field or key is absent, for backward compatibility with existing users who predate this feature) and skip the send if `false`. This avoids duplicating the lookup at each of the 4+ call sites individually.

**Settings UI:** add a new section to `SettingsView.swift` with a toggle per category, backed by the local `Friend.notificationPrefs`, syncing each change to the `users/{uid}` doc the same way other profile edits already do (check `EditProfileView.swift` for the existing profile-field-sync pattern and mirror it).

---

## Verification

- **1:** share a place from one account to a friend; confirm the friend actually receives a message/card for it (not just a local "Sent" checkmark), and tapping it opens the place's detail screen with its videos.
- **2:** add text to a photo log at a specific dragged position, send it, and confirm it appears in that exact position on playback (not as a generic bottom caption). If the video-burn-in half ships separately, confirm at minimum that video logs' captions are clearly understood as a follow-up, not silently regressed.
- **3:** tap a highlight on your own profile and confirm it opens a real player for that clip; confirm the existing Insights sheet still shows correct views/likes/comments (should be entirely unaffected by this change).
- **4:** react to a friend's log with an emoji and confirm the friend sees an image of that specific log with the emoji visibly overlaid, not a text string.
- **5:** open a chat from Pulse's quick-chat / a profile's message button (the two `fullScreenCover` paths) and confirm swiping right dismisses it; confirm the `PulseFeedView`-pushed chat path still works as before.
- **6:** toggle each new notification category off one at a time and confirm that specific type of push stops arriving while the others still do; confirm a fresh/legacy account with no `notificationPrefs` set yet still receives all notifications by default (nothing silently goes dark for existing users).
