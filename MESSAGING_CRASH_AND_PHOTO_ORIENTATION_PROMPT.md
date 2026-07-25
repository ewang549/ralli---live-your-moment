# Fix prompt: messages not sending, sheet-presentation crash, photo orientation

Three unrelated bugs, each confirmed in code. Do not touch anything outside what's described here.

---

## A — Messages never actually send (root cause, not a network issue)

`StreamConfig.swift`:

```swift
static let userToken = ""
static var isEnabled: Bool { !userToken.isEmpty }
```

`userToken` is a `static let` hardcoded to `""` — it is never assigned anything else anywhere in the codebase, so `StreamConfig.isEnabled` is **permanently `false`** in every build, for every account, signed in or not.

Every chat surface branches on this flag:

```swift
// ChatDrawerView.swift — both ChatDrawerView and ChatDetailView do this
if StreamConfig.isEnabled {
    StreamThreadView(channelId: chat.streamChannelId, ...)   // real Stream Chat
} else {
    MessageThreadView(chat: chat)                            // local-only, SwiftData, no network
}
```

Since `isEnabled` is always false, the app always renders `MessageThreadView` — a fully local thread that inserts `Message` rows into SwiftData and never touches the network. Sending a message *looks* successful (it appears immediately in your own thread, same device) but it never reaches the other person, in either direction. This is independent of everything fixed in the last two prompts (channel creation, chat-row creation) — those are correct and irrelevant to this, because the app was never using Stream at all.

Historical note in the file explains the empty token was originally about not committing a long-lived dev credential — legitimate concern, but the real per-user flow (`StreamTokenProvider.fetchToken`, called from `AuthGateView.connectStream()` on sign-in, connecting `chatClient` with a token bound to the real Firebase user) was built afterward and nobody updated this gate to reflect it.

**Fix:** `StreamConfig.isEnabled` should reflect whether the app's `chatClient` is actually connected to a real Stream user — not this leftover constant. Something like:

```swift
static var isEnabled: Bool {
    InjectedValues[\.chatClient].currentUserId != nil
}
```

(or equivalent — check however `chatClient.currentUserId` is accessed elsewhere in the codebase, e.g. `ExplogViewFactory`, and match that pattern). The intent: `isEnabled` should be true exactly when `connectStream(as:)` has successfully run for the current session, false only when genuinely signed out / not yet connected — not tied to a hardcoded string that can never change.

Leave `MessageThreadView` in place as the signed-out/dev fallback — that's still a legitimate use for it. Just fix what decides which one shows.

## B — AttributeGraph / sheet presentation crash

`PulseHomeView.swift` chains all of its presentations on one view node:

```swift
.fullScreenCover(item: $openedFriend) { ... }
.fullScreenCover(item: $openedGroup) { ... }
.fullScreenCover(isPresented: $showAllFriends) { ... }
.fullScreenCover(isPresented: $showHourlyWall) { ... }
.fullScreenCover(item: $quickChat) { ... }
.sheet(isPresented: $showFriendHub) { ... }
.sheet(isPresented: $showNewGroup) { ... }
```

Seven presentation modifiers stacked on the same node is exactly the "Nested or Clashing Modifiers" pattern that produces the `AttributeGraph`/`PairPreferenceCombiner` recursion crash you saw — SwiftUI's presentation graph gets confused about which modifier owns the transition, and `quickChat` (the per-row message button — the thing you'd tap right before hitting the messaging bug in A) is one of the five `fullScreenCover`s involved.

**Fix:** consolidate the five `fullScreenCover` triggers into a single enum-backed destination with one `.fullScreenCover(item:)`, which is the standard SwiftUI pattern for "several mutually-exclusive full-screen destinations from one view":

```swift
private enum PulseDestination: Identifiable {
    case friend(Friend)
    case group(Chat)
    case allFriends
    case hourlyWall
    case quickChat(Chat)

    var id: String {
        switch self {
        case .friend(let f): "friend-\(f.id)"
        case .group(let g): "group-\(g.id)"
        case .allFriends: "allFriends"
        case .hourlyWall: "hourlyWall"
        case .quickChat(let c): "quickChat-\(c.id)"
        }
    }
}

@State private var destination: PulseDestination?
```

Replace the five `@State` optionals/bools (`openedFriend`, `openedGroup`, `showAllFriends`, `showHourlyWall`, `quickChat`) with the one `destination` enum, update every call site that sets them (the row's `onTap`/`onChat` closures, the "All friends" card, the hourly banner tap) to set `destination = .friend(...)` etc., and replace the five modifiers with one:

```swift
.fullScreenCover(item: $destination) { dest in
    switch dest {
    case .friend(let friend): FriendPairFeedView(friends: roster, me: me, startingFriend: friend)
    case .group(let group): GroupClipFeedView(chat: group)
    case .allFriends: AllFriendsFeedView(friends: roster)
    case .hourlyWall: PulseFeedView()
    case .quickChat(let chat): NavigationStack { ChatDetailView(chat: chat) { destination = nil } }
    }
}
```

Leave the two `.sheet` modifiers (`showFriendHub`, `showNewGroup`) as-is for now — they're a different presentation style (`.sheet` vs `.fullScreenCover`) and less likely to be the specific collision, but if the crash recurs after this change, apply the same enum consolidation to those too.

## C — Photos come out rotated after landscape capture

`CameraCaptureView.swift`'s `applyInterfaceRotation()` already sets `connection.videoRotationAngle` identically on both `movieOutput` and `photoOutput` (plus the preview layer), driven by the same `interfaceRotationAngle()` value. This is correctly built and, per your report, video capture is now fine — so the rotation-angle plumbing itself is not the problem.

This points at a known `AVCapturePhotoOutput` quirk: `videoRotationAngle` on the photo connection is not as reliably honored for still capture as it is for `AVCaptureMovieFileOutput` on all devices/iOS versions — the still can come back with pixel data or EXIF orientation that doesn't match what the connection angle implied, even though the exact same angle correctly rotates recorded video.

**Fix — verify and correct the still explicitly, rather than trusting the connection angle alone**, in `photoOutput(_:didFinishProcessingPhoto:)` (`CameraCaptureView.swift` ~line 1624):

1. Before writing `photo.fileDataRepresentation()` to disk, check the actual pixel dimensions/orientation of the resulting image against what `rotationAngle` (the same value used for the connection) implies — e.g., decode into a `UIImage`/`CGImage` and compare `width`/`height` against the expected landscape aspect.
2. If it doesn't match, re-render the image with the correct rotation baked into the pixel data (a `UIGraphicsImageRenderer` draw with the appropriate rotation transform, or setting `kCGImagePropertyOrientation` correctly if you're keeping it EXIF-based) before writing `data.write(to: url)`.
3. Whichever approach you take, make it explicit and self-verifying rather than assuming the connection angle alone produces a correctly-oriented file — that assumption is what's currently failing for stills specifically while holding for video.

---

## Verification

- **A:** sign into two real accounts on two simulators/devices, send a text both directions, confirm it actually appears on the *other* device (not just locally) — this is the test that was impossible to pass before this fix regardless of anything else being correct.
- **B:** rapidly tap between a friend's row (message button), a group row, "All friends," and the hourly banner from Pulse — repeatedly, including mid-transition taps — and confirm no crash. This was the actual crash trigger per the trace (mid-transition state churn on a sheet).
- **C:** take a still photo while landscape-locked, immediately check the post-capture review screen (not just later in the feed) — confirm it's landscape, not rotated.
- Confirm nothing else on Pulse changed — the row layout, streaks, filters, and the friend/group open behavior should all look and behave exactly as before, just routed through one destination state instead of five.
