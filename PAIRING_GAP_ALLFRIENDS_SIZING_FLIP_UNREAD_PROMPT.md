# Fix prompt: pairing-screen gap, All Friends inconsistent sizing, camera flip mid-recording, unread indicator firing on your own sends

Four items, all grounded in the current code (checked fresh, not assumed from earlier prompts).

---

## 1 — Big gap between the two stacked videos on the friend-pairing screen

`FriendPairFeedView.pairPage(for:height:)` (`StackedClipViews.swift:376-464`). The spacing math itself is fine — `gap` is a fixed `10pt` (line 381), and `cardHeight` is a true half-split of the usable space (`(usable/2)`, line 390). That's not where the visible gap comes from.

The actual cause: each card gets `.aspectRatio(pairRatio, contentMode: .fit).frame(maxHeight: cardHeight)` (lines 425-426, 457-458) — `cardHeight` is only a *ceiling*, not a fixed size (per the comment at 387-389). When a clip's aspect ratio makes its natural, width-constrained height shorter than that ceiling, the card renders smaller than its allotted half-screen slot. Since the containing `VStack(spacing: gap)` (line 407) centers its children by default, each undersized card gets pushed toward the middle of its own slot — which stacks with the fixed `10pt` gap to look like one large gap between the two videos, even though the actual `gap` constant never changed.

**Fix:** don't let each card float centered within a half-screen-tall slot that's larger than the card itself. Either (a) size each card's actual slot to match its content instead of reserving a fixed `cardHeight` ceiling regardless of the clip's real shape, or (b) anchor each card to the edge of its slot nearest the other card (top card aligns to its slot's bottom, bottom card aligns to its slot's top) rather than centering, so the visible gap between the two cards is always exactly `gap` (10pt) regardless of how each card's aspect-fit shrinks it. (b) is the smaller, more targeted change — swap the `VStack`'s implicit center alignment for one that pins both cards toward each other.

## 2 — All Friends feed shows videos at inconsistent sizes across rows

`AllFriendsFeedView.row(for:height:)` (`StackedClipViews.swift:985-1043`). The earlier "eliminate black borders" fix **was** applied here — each row is now sized to that specific clip's own aspect ratio:
```swift
let ratio = clip?.displayAspectRatio ?? Clip.defaultAspectRatio
let cardWidth = min(width, height * ratio).safeDimension
let cardHeight = (cardWidth / ratio).safeDimension
```
then `.frame(width: cardWidth, height: cardHeight)` (line 1017). Since `ratio` varies per friend (each clip's real recorded aspect ratio isn't identical), `cardWidth`/`cardHeight` differ row to row — which is exactly the "different sizes" symptom in image 2.

**This is a real tension with the earlier "no black borders" request, and it needs to be named explicitly:** you can't have both "every row is an identical size" and "no letterbox bars ever, for every clip" unless every clip happens to share the exact same aspect ratio, which they don't. Given this request prioritizes consistent row sizing, the fix is to invert the earlier change: give every row (populated or empty) the same fixed `width × height` frame unconditionally — drop the per-clip `cardWidth`/`cardHeight` derivation (lines 996-997) and use `.frame(width: width, height: height)` for both the populated and empty-slot branches (currently empty slots already get the full box at lines 1022-1023; populated slots should match). `StackedClipPane`'s existing `.fit` content mode (already passed in at line 1015) will letterbox any clip whose aspect ratio doesn't exactly match the row's box — bringing back a thin bar in some cases, but keeping every row the same visual size, which is the more important property here per this request.

## 3 — Camera flip mid-recording — confirmed already working correctly, verify only

Checked the current implementation fresh: `CameraModel.flip()` (`CameraCaptureView.swift:1856-1869`) still has no recording-state guard, and that's fine — `configure()` (1709-1753) only ever removes/re-adds *inputs* (line 1714), never `movieOutput`/`photoOutput` (re-added via no-op `canAddOutput` guards, lines 1728-1729, when already attached). So `movieOutput` stays attached across a flip and keeps writing into the same file. Nothing in `flip()`, `flipButton` (778-786), or the double-tap gesture (`552-562`) touches `isRecording` or calls a stop function — `isRecording` is only set by `recordClip()` (1922, on start) and the actual finish delegate callback (1965, on real completion). **No code change needed here — this should already work.** If it's still visibly cutting off recording on a real device despite this, that points to something outside this call chain (a runtime interruption during the brief `beginConfiguration()`/`commitConfiguration()` window, or UI state elsewhere reacting to the flip) — worth a real-device test specifically watching for `AVCaptureSessionWasInterrupted` notifications during a flip, rather than assuming the recording pipeline itself needs rework.

## 4 — Unread indicator lights up from your own outgoing sends, not just incoming ones

Root-caused precisely. `Chat.hasUnread` (`Models.swift:344-347`) compares `lastActivityAt` against `lastReadAt`, and `lastActivityAt` (287-293) is genuinely any-party:
```swift
var lastActivityAt: Date {
    max(sortedClips.first?.capturedAt ?? .distantPast,
        messages.map(\.sentAt).max() ?? .distantPast,
        lastIncomingMessageAt ?? .distantPast,
        lastOutgoingMessageAt ?? .distantPast,
        createdAt)
}
```
`sortedClips.first` and `messages.map(\.sentAt).max()` aren't scoped to "sent by someone else" — and `lastOutgoingMessageAt` is explicitly your own sends. The bug reproduces via `SendToFriendsView.send()` (`ShareLogViews.swift:182-246`), which appends your newly-captured clip to `chat.clips` (line 206) but never calls `chat.markRead()` anywhere in that flow. So sending your own log bumps `lastActivityAt` past `lastReadAt`, and the chat incorrectly shows unread — with no friend involved at all. (The Stream text-message path already avoids this correctly — `OutgoingSendRecorder` in `StreamThreadView.swift:507-518` only calls `markRead()` on the incoming branch — but that guard doesn't cover the separate log-sending screen.)

**Fix — make `hasUnread` author-scoped, rather than patching every send call site to remember to call `markRead()`** (more robust, since a future new send path won't need to remember this rule). Add a genuinely incoming-only signal:
```swift
var lastIncomingActivityAt: Date {
    max(sortedClips.first { $0.author?.isMe != true }?.capturedAt ?? .distantPast,
        messages.filter { $0.author?.isMe != true }.map(\.sentAt).max() ?? .distantPast,
        lastIncomingMessageAt ?? .distantPast)
}
```
and change `hasUnread` to compare against this instead:
```swift
var hasUnread: Bool {
    lastIncomingActivityAt > (lastReadAt ?? .distantPast)
}
```
Leave `lastActivityAt` itself untouched — it's also used for Pulse's list ordering (per the comment at lines 277-280) and correctly needs to stay any-party for that purpose (a friend should still bump to the top of Pulse whether you sent to them or they sent to you — that's a separate, already-correct behavior). This is a new, additional property, not a rewrite of the existing one. Also check `hasActivity`/any similar helper (around lines 350-353) that might assume `lastActivityAt`'s any-party floor (`createdAt`) — a chat you've only ever sent *into* has nothing incoming to be "unread," so `lastIncomingActivityAt` correctly has no `createdAt` floor and should report `.distantPast` (never unread) rather than inheriting that fallback.

---

## Verification

- **1:** open the friend-pairing screen with two clips of different shapes and confirm the gap between them stays visually small and consistent, not a large centered gap.
- **2:** open All Friends with several friends whose clips have differently-shaped source video, and confirm every row renders at the same size (letterboxing where needed) rather than each row being a different size.
- **3:** start recording, flip the camera mid-recording, and confirm it continues recording on the new camera without cutting off (regression check — this should already work; report back if it still fails after confirming no runtime interruption is occurring).
- **4:** send a log or message to a friend and confirm that chat does NOT show as unread from your own send. Have a friend send you something and confirm it DOES show as unread until you open it.
