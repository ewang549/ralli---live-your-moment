# Fix prompt: friend-pairing screen shows the wrong "your log," and Beacon date/time display

Two real, grounded fixes.

---

## 1 — Friend-pairing screen shows your video in every pairing, not just the friend you actually sent it to

This is the real bug behind "sending to one person sends to everyone" — the send itself is correctly scoped server-side (verified exhaustively, not touching that code again), but the **friend-pairing screen's display of "your own log" is not scoped to which friend you sent it to.**

`StackedClipViews.swift`'s `pairPage(for:height:)` (~line 374):

```swift
let myClip = me?.clip(forHourContaining: viewingHour)
```

`Friend.clip(forHourContaining:)` (`HourAxis.swift` ~line 22) searches your *entire* clip history for the given hour and returns the most recent match, with no concept of which chat that clip was sent through. So if you send a video to Friend A only, that becomes your one clip for the hour — and this lookup surfaces it in the "your log" pane **regardless of which friend you're currently paired with** as you page through your roster (Friend B, Friend C, anyone). It looks like everyone received it because your own pane doesn't know or care who a clip was actually addressed to; it just shows "whatever I made this hour."

For contrast, `GroupClipFeedView`'s `entries` (~line 676) already gets this right — it resolves each member's clip from `chat.sortedClips` (scoped to that specific chat), not from the member's whole history. `FriendPairFeedView` is the one place that didn't follow that pattern for the "you" pane.

**Fix:** resolve "my" clip from the actual DM chat with the friend currently being viewed, not from unscoped history:

```swift
extension Chat {
    /// The clip I sent into this specific chat during the hour containing `date`.
    func myClip(forHourContaining date: Date) -> Clip? {
        clips
            .filter { $0.author?.isMe == true && Calendar.current.isDate($0.capturedAt, equalTo: date, toGranularity: .hour) }
            .max { $0.capturedAt < $1.capturedAt }
    }
}
```

And in `pairPage`, use the DM-resolution helper already in this same view (`dmChat(with:)`, ~line 433, currently used by the reply button) instead of the unscoped friend-wide lookup:

```swift
let dm = dmChat(with: friend)
let myClip = dm?.myClip(forHourContaining: viewingHour)
```

This makes the "you" pane correctly show nothing when paired with a friend you didn't send anything to that hour, and the real clip only when paired with the friend you actually sent it to.

**Do not touch** `send()`, `LogSync.publish`/`publishPending`, or anything in `functions/index.js` (`publishLog`/`listFriendLogs`/`cleanRecipientUids`) for this — that entire path has been re-verified multiple times and is correct. This fix is scoped entirely to the display logic in `StackedClipViews.swift`.

## 2 — Show the beacon's actual date/time prominently, not just a countdown

Confirmed: nowhere in the Beacons UI is the actual scheduled date/time ever shown. `BeaconCountdownChip` (`BeaconsFeedView.swift` ~line 265) only ever renders a **relative** countdown ("2 hr 15 min", "Live now") — never an absolute date/time like "Sat, Jul 26 · 3:00 PM." `BeaconFeedCard`'s hero (~line 371) shows the countdown chip as a small badge over the image, and `ActivityDetailSheet` (~line 563) doesn't show the date/time anywhere at all — venue, address, distance, description, and the attendee roster are all there, but not when it's actually happening.

**Fix — add the real date/time in both places, prominently, alongside (not replacing) the existing countdown, since both are useful for different reasons:**

1. **`BeaconFeedCard`'s hero** (~line 388, the `VStack` holding the spot name): add a formatted absolute date/time line directly under the spot name — something like `beacon.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())` (e.g., "Sat, Jul 26 · 3:00 PM") — right there with the name and category/distance line, so it's one of the first things visible on the card, not buried in a corner badge.
2. **`ActivityDetailSheet`**: add the same formatted date/time as its own clearly-labeled line near the very top of the content — directly after or alongside the venue name (~line 594), before the address/description/AI-insight sections. This is the "more details" page, and the date needs to be one of the first things read, not something you scroll to find.
3. Keep `BeaconCountdownChip` where it already is in both places — the relative urgency signal ("starts in 20 min," "live now") is still useful alongside the absolute date/time, not a replacement for it.

---

## Verification

- **1:** send a video to exactly one friend; page through the friend-pairing screen and confirm your own pane is empty for every friend except the one you actually sent it to.
- **2:** open the Beacons feed and a beacon's detail page and confirm the actual date/time is visible immediately, alongside the existing countdown, on both screens.
