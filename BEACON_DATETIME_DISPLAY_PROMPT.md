# Fix prompt: show the actual event date/time on Beacons

One real, new task here. The other two things mentioned alongside it (recipient-scoped sends, Daily Recap orientation) are addressed in the note below the prompt, not repeated here — the code for both is already correct and re-touching it again would be a mistake.

---

## Show the beacon's actual date/time prominently, not just a countdown

Confirmed: nowhere in the Beacons UI is the actual scheduled date/time ever shown. `BeaconCountdownChip` (`BeaconsFeedView.swift` ~line 265) only ever renders a **relative** countdown ("2 hr 15 min", "Live now") — never an absolute date/time like "Sat, Jul 26 · 3:00 PM." `BeaconFeedCard`'s hero (~line 371) shows the countdown chip as a small badge over the image, and `ActivityDetailSheet` (~line 563) doesn't show the date/time anywhere at all — venue, address, distance, description, and the attendee roster are all there, but not when it's actually happening.

**Fix — add the real date/time in both places, prominently, alongside (not replacing) the existing countdown, since both are useful for different reasons:**

1. **`BeaconFeedCard`'s hero** (~line 388, the `VStack` holding the spot name): add a formatted absolute date/time line directly under the spot name — something like `beacon.startsAt.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())` (e.g., "Sat, Jul 26 · 3:00 PM") — right there with the name and category/distance line, so it's one of the first things visible on the card, not buried in a corner badge.
2. **`ActivityDetailSheet`**: add the same formatted date/time as its own clearly-labeled line near the very top of the content — directly after or alongside the venue name (~line 594), before the address/description/AI-insight sections. This is the "more details" page the request refers to, and the date needs to be one of the first things read, not something you scroll to find.
3. Keep `BeaconCountdownChip` where it already is in both places — the relative urgency signal ("starts in 20 min," "live now") is still useful alongside the absolute date/time, not a replacement for it.

---

## About the other two things in this message

**"Sending to one friend sends to everyone"** — I have now read `SendToFriendsView.send()`, `LogSync.publish`/`publishPending`, and the server-side `publishLog`/`listFriendLogs`/`cleanRecipientUids` in full, multiple separate times across this project, including checking for any other call site that might bypass the fix (there's only one other: a `#if DEBUG`-only screenshot-automation hook in `MainTabView.swift` that intentionally addresses all friends for generating demo screenshots — not a real send path). The code is correct on every path. **Do not send this back to a coding agent to "fix" again** — there is nothing left to change in the code. The only two things that explain it still happening are: the Cloud Function genuinely hasn't been redeployed (`firebase deploy --only functions` — check the deploy timestamp in the Firebase Console directly, don't assume), or the test was against an old post made before this fix existed (which will always show the old behavior by design). Please confirm one of these directly before this comes back a sixth time.

**"Daily Recap still shows vertically/full-screen"** — also already fixed and verified correct through every layer: `DailyVlogView.swift` passes `contentMode: .fit` into `ClipView`, which passes it to `ClipMediaView`, which correctly maps `.fit` to `AVLayerVideoGravity.resizeAspect` in `LoopingVideoView` (~line 193). This is provably letterboxing correctly in the source. If it's still showing full-screen vertical, the app being tested was built before this change — do a completely clean rebuild (delete the app from the device first, not just relaunch) before concluding anything is still broken here.
