# Fix prompt: audience leak, reactions not reaching chat, camera freezing, and five smaller bugs

Nine issues, ordered by severity. The first is the most serious — a real privacy/correctness bug, not a cosmetic one. Everything below is grounded in the current code; read each section's file/line references before changing anything.

---

## 1 — Sending to specific people/a group actually broadcasts to *all* friends

This is the most serious bug in this batch. `ShareLogViews.swift`'s `SendToFriendsView.send()` correctly creates a separate local `Clip` per selected chat — so *on your own device* it looks properly scoped. But only the first created clip ever reaches the server:

```swift
if let first = created.first {
    Task { await logSync.publish(first, context: modelContext) }
}
```

`LogSync.publish` defaults to `audience: .friends`, which calls `publishLog` with `audience: "friends"` and nothing else identifying who it's for. On the server, `functions/index.js`'s `listFriendLogs` (~line 1544) does this:

```js
const [friendUids, blockedUids] = await Promise.all([
  edgeUids(uid, "friends"),
  edgeUids(uid, "blocked"),
]);
...
db.collection("logs").where("authorUid", "in", chunk)...
```

It returns **every** log where `authorUid` is one of the caller's friends — there is no concept anywhere in `publishLog` or `listFriendLogs` of "who this specific log was sent to." Selecting 2 out of 10 friends in the send screen makes no difference server-side: any of your friends who pulls their feed via `listFriendLogs` can see it, because the backend only ever recorded *that you posted something*, never *who it was for*. The "pick specific people" UI is real and scoped locally, but it doesn't correspond to anything the backend enforces.

**Fix — both sides:**

1. **`publishLog`** (`functions/index.js` ~line 1333): accept an optional `recipientUids: string[]` in the request data when `audience === "friends"`. Store it on the `logs/{id}` doc as `recipientUids`. When absent, leave existing behavior alone (so this doesn't require a data migration for old logs).
2. **`listFriendLogs`** (~line 1544): after fetching the candidate logs, add a filter — a log is visible to the caller if `!log.recipientUids` (legacy log, old broadcast behavior) **or** `log.recipientUids.includes(uid)` **or** `log.authorUid === uid` (you can always see your own).
3. **Client, `SendToFriendsView.send()`:** resolve the actual recipients from `selected` before publishing — for a `.friend(Friend)` audience that's `friend.remoteUID`; for a `.group(Chat)` audience, every non-`isMe` member's `remoteUID`. Combine all selected chats' recipient uids into one array and pass it into `logSync.publish(first, context:, recipientUids: combined)`.
4. **`LogSync.publish`** needs a new parameter (`recipientUids: [String] = []`) threaded into the `publishLog` payload (`payload["recipientUids"] = recipientUids` when non-empty).

Test with three friends: send to only one of them, and confirm the other two — who are still your friends — genuinely cannot see it via their own `listFriendLogs` pull. That's the actual test; confirming it shows correctly in your own sender-side UI is not sufficient, since that part already worked.

## 2 — Reacting to a friend's video in Pulse doesn't show up in the chat

This one broke as a side effect of the Stream-messaging fix landing correctly (`StreamConfig.isEnabled` now correctly reflects a real connected Stream user, not the old permanently-`false` constant). `FriendLogActions.react(with:)` (`StackedClipViews.swift`) broadcasts a reaction like this:

```swift
let message = Message.reaction(emoji, to: clip, from: me, in: chat)
modelContext.insert(message)
chat.messages.append(message)
```

`Message` is a local SwiftData model. The *only* thing that ever reads `chat.messages`/renders a `Message.isReaction` bubble is `MessageThreadView`/`ChatDrawerView.MessageBubble` — the local-only fake chat renderer that's used when `StreamConfig.isEnabled == false`. Now that real accounts correctly render `StreamThreadView` (actual Stream Chat) instead, this locally-inserted `Message` has no effect on the real Stream channel at all — it's invisible to Stream's own message list, so the reaction never appears in the real thread on either side. The bottom-left reaction badge on the clip itself still works fine (that's pure local `clip.reactions`, unaffected) — it's specifically the "also show up in the DM" half that's now dead code.

**Fix:** `react(with:)` needs to send an actual Stream message into the real channel, not a local `Message` row. Use the same channel-resolution the rest of the app already relies on (`chat.streamChannelId`/`chat.streamMemberIds` from `StreamThreadView.swift`, and `StreamTokenProvider.joinChannel` to guarantee membership first) — get a `ChatChannelController` for that channel id via `chatClient.channelController(for:)` and send a message through it (Stream's `sendMessage` API), with the reaction emoji and a reference to the clip (custom `extraData` carrying the clip id/type is the natural place, or at minimum plain text like "❤️ reacted to your log" if a richer custom-rendered attachment is a bigger lift than this pass should take on). Confirm on the receiving device that the message actually shows up in `StreamThreadView`'s real message list, not just that the sender's own bottom-left badge updated.

## 3 — Camera freezes, and the mirror/rotation questions likely trace to the same cause

`CameraModel.configure()` (`CameraCaptureView.swift` ~line 1503) does full `AVCaptureSession` reconfiguration — `beginConfiguration()`, remove/add inputs and outputs, `commitConfiguration()` — synchronously, wherever it's called from. It's called from `startIfAvailable` (session launch) and from `flip()` (~line 1636), which is invoked directly by the flip-camera button's tap action — i.e., **on the main thread**. `AVCaptureSession` configuration is documented by Apple as something that should never run on the main thread — it can block for a noticeable, sometimes long stretch while the hardware capture pipeline reconfigures, and while it's blocked, the entire UI (including the shutter button) is unresponsive. This matches "freezes... this is big when it freezes i cant even take a photo" precisely — the freeze *is* the main thread being blocked by session reconfiguration, most likely triggered by a camera flip, but potentially also felt on initial camera open.

**Fix:** move all `AVCaptureSession` lifecycle work onto a dedicated serial background queue, and only touch UI-facing `@Published`/`@Observable` state back on the main actor once the work finishes:

```swift
private let sessionQueue = DispatchQueue(label: "com.ej.explog.camera.session")

func startIfAvailable(maxDuration: TimeInterval) {
    guard hasCamera, !session.isRunning else { return }
    self.maxDuration = maxDuration
    sessionQueue.async { [weak self] in
        self?.configure()
        self?.session.startRunning()
    }
}

func flip() {
    sessionQueue.async { [weak self] in
        guard let self else { return }
        self.currentPosition = self.currentPosition == .back ? .front : .back
        self.configure()
        Task { @MainActor in self.applyTorch() }
    }
}
```

(Adjust for whatever `currentPosition`/other properties actually need main-actor-safe access — the core requirement is that `beginConfiguration()`/`addInput`/`addOutput`/`commitConfiguration()`/`startRunning()`/`stopRunning()` never execute on the thread that's also handling button taps.) `stop()` (~line 1724) already dispatches `stopRunning()` to a background queue — bring `configure()`/`flip()` in line with that same discipline rather than leaving them as the one exception.

This is also the most likely explanation for the rotation/mirror flakiness reported alongside the freeze: if the main thread is blocked mid-flip, `applyInterfaceRotation()`/`applyMirroring()` calls that land during that window can appear to "not take," or a stale frame lingers on screen looking like the wrong orientation/mirror state until the block clears. The mirroring fix already in place (`applyMirroring()` unconditionally sets `isVideoMirrored = false` on both capture outputs, ~line 1620) is correct for the *recorded* file — the live preview is deliberately still mirrored for a front-camera selfie by design (that's expected, not a bug). Fix the threading first, then re-test whether a genuine mirroring bug remains in the *saved* file specifically (not the live preview) before changing that code again.

On "should ALWAYS be landscape": the interface is already fully locked to `.landscape` (`InterfaceOrientationLock.lockLandscape()`), which permits both landscape edges but not portrait. If the camera is opened while the phone is physically held portrait, iOS has to animate the interface into landscape — that visible rotation is an inherent consequence of allowing capture to start before the phone is in position, not a bug in the lock itself. If a smoother experience is wanted, the actual fix would be product-level (e.g., show a "rotate your device" prompt and hold off opening the camera UI until the phone is physically landscape) rather than a code correctness bug — flag this distinction rather than silently building a rotate-prompt without confirming that's actually wanted.

## 4 — A friend's public Beacon doesn't show up in your Friends tab

`BeaconsFeedView.swift`'s `filtered` (~line 27):

```swift
.filter { segment == .publicFeed ? $0.isPublic : !$0.isPublic }
```

The Friends segment explicitly excludes any beacon marked `isPublic`, even one hosted by an actual friend. The backend already returns it correctly — `listFriendBeacons` (`functions/index.js` ~line 1997) filters only by `hostUid in [you + your friends]`, with no `isPublic` condition at all, so a friend's public beacon syncs down locally just fine (`BeaconSync`, confirmed: `host: byUID[remote.hostUid]` only resolves to a real `Friend` row for an actual friend or yourself — a stranger's public beacon has `beacon.host == nil`). The bug is purely this one client-side filter treating "Friends" and "Public" as mutually exclusive categories.

**Fix:** change the Friends-segment condition to be about *who hosted it*, not whether it's public:

```swift
.filter { segment == .publicFeed ? $0.isPublic : $0.host != nil }
```

This makes a friend's public beacon appear in both tabs (Friends tab because the host resolves to a real `Friend`, Public tab because `isPublic == true`), while a stranger's public beacon still only shows in Public (no local `Friend` row for the host), and a friend's private beacon still only shows in Friends — matching what you described.

## 5 — Bookmarked place videos can't be reopened

`BookmarkedPlacesView.swift`'s `card(_:)` (~line 45) renders the thumbnail and a bookmark-remove button, but nothing in the card is tappable to actually view the clip — there's no `Button`/`NavigationLink`/`.onTapGesture` wrapping the media itself.

**Fix:** wrap the card's tappable area (excluding the bookmark-remove button, which needs to keep its own tap target) so tapping it opens the same full-screen clip viewer the main Places feed already uses for that clip — reuse whatever `NichePlacesView` presents when you tap a clip there (its `showDetail`/`SpotDetailView` path), rather than building a second, separate player. If the main feed's viewer expects a `Spot` plus its list of clips rather than a single `SpotClip` in isolation, pass `clip.spot` and let it land on the specific bookmarked clip within that place's feed.

## 6 — Following yourself is possible

`UserProfileView.swift`'s `toggleFollow()` (~line 896) guards on `isRemote` but never checks whether the viewed profile is the signed-in user themself. This is reachable whenever a `PublicProfileSheet` opens for your own account without resolving to your local "me" `Friend` row first (e.g., finding yourself through search or a public feed rather than your own profile tab).

**Fix:** add a same-account guard wherever the follow button's enabled state is decided — compare `profileForActions.uid` (or equivalent) against `Auth.auth().currentUser?.uid`, and hide or disable the follow button entirely when they match, the same way you'd never see a "block" or "add friend" action on your own profile.

## 7 — Profile pictures / leftover demo data

The avatar pipeline itself (`ProfileSetupView`/`UserProfileView`'s upload → `FirestoreService.uploadAvatarPhoto` → `updateSoftFields(["avatarURL": ...])` → `FriendGraph.sync()` copying `profile.avatarURL` → `AvatarView`'s three-tier local/remote/placeholder render) is fully wired and correct end-to-end per the code — this is not the same bug as before. Two real, separate things are likely behind what you're seeing:

**7a — Leftover DEBUG demo data on a real account.** `SeedData` is correctly gated behind `#if DEBUG` and never runs in a TestFlight/Release build — but if this device ever ran a Debug build against your real signed-in account (very plausible, given how much of this has been tested directly via Xcode), the seeded demo friends (Jordan, Maya, Sam — emoji-only, no real photos) got inserted into the *same local store* your real account uses, and nothing ever removes them: `FriendGraph.sync()`'s cleanup (`Models.swift`, the un-friend loop) explicitly skips any row with an empty `remoteUID`, which is exactly what demo rows have, so they're never touched by cleanup and persist indefinitely. `UserProfileView.swift` already has a `clearDemoData()` function and a "Clear demo" button (~line 350) that does exactly the right cleanup — but it's gated behind `#if DEBUG` too, so a real Release/TestFlight build has no way to trigger it. This is very likely what reads as "profile pictures not working" — the demo rows genuinely have no real photo, only an emoji, and they're sitting mixed into your real friend list.

**Fix:** run the equivalent of `clearDemoData()` unconditionally (not `#if DEBUG`-gated) once for any real signed-in account — the safest place is right after a real profile resolves successfully in `AuthGateView.resolveProfile()`, since a genuine production account should never legitimately have `isDemo` rows at all. This makes it self-healing rather than requiring a manual debug action.

**7b — Silent upload failure, for a genuinely new/real photo that still doesn't show.** `ProfileSetupView.submit()` calls `try? await FirestoreService.uploadAvatarPhoto(at: localURL)` — if this throws (a very real possibility during onboarding specifically, since it runs right after account creation while the auth token may still be propagating, the same race `AuthGateView.resolveProfile()` already has a 3-attempt backoff for), the `try?` swallows it silently: no retry, no error shown, and the profile completes with no `avatarURL` ever recorded, permanently. Harden this the same way `resolveProfile()` already handles the identical race — wrap the upload in a short retry-with-backoff instead of a single `try?`, and surface a failure if all attempts are exhausted so the user knows to try again rather than ending up with a silently-missing photo forever.

## 8 — Video loop shows a black flash between loops

`ClipView.swift`'s `LoopingVideoView.PlayerContainerView` uses a single `AVPlayerLooper` over one `AVPlayerItem`. A brief black frame at the loop boundary is a known `AVPlayerLooper` characteristic when there's nothing buffered and ready exactly at the seam — the player has momentarily nothing to display while it resets to the start.

**Fix directions to try, in order of effort:** first, ensure the asset is fully loaded before playback starts rather than being handed straight to `AVPlayerItem(url:)` cold (preload with `AVURLAsset(url:).loadValuesAsynchronously(forKeys: ["duration", "tracks"])` before constructing the item, so the player never has to stall waiting on the asset). If the gap persists, set `player.automaticallyWaitsToMinimizeStalling = false` on the `AVQueuePlayer`. If it's still visible, the more involved fix is queuing two copies of the same item into the `AVQueuePlayer` up front (matching what `AVPlayerLooper` does internally, but with more buffer margin) so there's always a second item ready before the first ends. Verify each step actually removes the flash rather than assuming the first attempt worked — this class of AVFoundation timing issue is easy to think is fixed when it's just less frequent.

## 9 — General freeze/inefficiency scan

Beyond the camera session-threading issue in §3 (the clearest, most direct hit), no other main-thread-blocking pattern was found on this pass that rises to the same severity. If freezing is still reported somewhere else after §3 lands, the next places worth checking specifically (not fixed here since nothing concrete was found yet): any other `AVCapture*`/`AVAsset` work called directly from a button action or `.onAppear` without hopping off the main thread first, and any `try? context.fetch(...)` running inside a computed property that gets re-evaluated on every view redraw rather than cached — neither was confirmed as an actual bug here, just worth a second look if freezes persist after the camera fix specifically.

---

## Verification

- **1:** send a video to exactly one friend out of several; confirm the other friends cannot see it in their own feed. This is the one that actually matters — confirming your own sender-side UI looks right is not enough, since that part was never the bug.
- **2:** react to a friend's video from Pulse; confirm the reaction shows up in the real Stream chat thread on both accounts, not just the bottom-left badge on the clip.
- **3:** flip the camera repeatedly and confirm the UI never freezes/becomes unresponsive; take a photo immediately after a flip to confirm the shutter isn't blocked.
- **4:** a friend's public beacon appears in both your Friends and Public tabs; a stranger's public beacon appears only in Public; a friend's private beacon appears only in Friends.
- **5:** tap a bookmarked clip and confirm it opens and plays.
- **6:** confirm there's no way to follow your own account from any entry point (search, public feed, profile).
- **7:** confirm a fresh real account, never touched by a Debug build, shows no demo entries; if this device has prior demo data, confirm it's gone after the fix without touching real friends.
- **8:** watch a looping clip through at least three full loops and confirm no black flash at the seam.
