# Fix prompt: show a clear date indicator on every log-viewing screen

This matters more than it used to: tap-stepping now moves one hour at a time with no day boundary — tapping repeatedly rolls silently from 11 PM into 12 AM of the next day and keeps going. Without a visible date, a user can drift several days away from "today" without realizing it, since the hour display alone (e.g. "11 PM" → "12 AM" → "1 AM") looks perfectly normal at every step.

Checked all three screens fresh — the actual gap differs per screen, so this needs three different fixes, not one shared change.

---

## 1 — Friend-pairing screen (`FriendPairFeedView`): no date shown at all — highest priority

`timestampBanner` (`StackedClipViews.swift:529-563`) shows only the hour:
```swift
Text(viewingHour.hourOnlyClockTime)
    .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
```
There is no date text anywhere in this screen's chrome. The only hint that you're not viewing the live hour is an icon swap (`clock.arrow.circlepath`, shown when `!hourState.isAtCurrentHour`) — which signals "not live" but never says which day. This is the screen most exposed to the silent-rollover problem, since it's the one where continuous hour-tapping happens most naturally.

**Fix:** add a date label to this banner, using the same source of truth as screen 2 below (`HourFeedState.dayLabel`, already correct). Since this screen's banner is compact (a single capsule), consider a small secondary line under the hour, or append it inline (e.g. "2:00 PM · today" / "2:00 PM · Sat, Jul 25"), matching the pattern already used successfully on the All Friends screen — don't invent a new format, reuse the existing one.

## 2 — All Friends (`AllFriendsFeedView`): date logic is correct, but too easy to miss

Header (`StackedClipViews.swift:1121-1149`) already does the right thing when you've stepped away from the live hour:
```swift
Text(hourState.isAtCurrentHour
     ? "this hour"
     : "\(hourState.hourLabel) · \(hourState.dayLabel)")
    .font(.system(size: 11, weight: .semibold))
```
`HourFeedState.dayLabel` (`HourFeedState.swift:67-72`) is correct and complete — "today"/"yesterday" for recent days, a real formatted date ("Sat, Jul 25") for anything older, no unhelpful fallback. **The gap is prominence, not correctness:** it's an 11pt secondary-color subtitle, and — more importantly — **it disappears entirely while `isAtCurrentHour` is true**, showing just "this hour" with no date at all. Since tap-stepping can silently move you off the current hour into a different day, and the date text only reappears once you're already off-hour, there's a window where a user has drifted without any date cue yet appearing.

**Fix:** always show the date, even in the "this hour"/live state — e.g. "this hour · today" instead of just "this hour" — so the date is a constant, not something that only appears after you've already navigated away. Consider increasing this text's visual weight slightly (it's currently the smallest text on the screen for what is now fairly important orientation information), though the core fix is making it always-present, not just louder.

## 3 — Daily recap (`DailyVlogView`): date shown, low prominence, and using a duplicated implementation

Header (`DailyVlogView.swift:99-138`) already shows a real date via a local helper:
```swift
private func dayTitle(_ day: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(day) { return "today" }
    if calendar.isDateInYesterday(day) { return "yesterday" }
    return day.formatted(.dateTime.weekday(.wide).month().day())
}
```
rendered at `.caption2` (the smallest system text size), 65% opacity, subordinate to the "Daily recap" title. This screen is lower-risk for silent drift than the other two (it steps by whole days already, via `stepDay`, not by individual hours), so this isn't the urgent case — but the date text is still easy to miss, and `dayTitle(_:)` is a near-duplicate of `HourFeedState.dayLabel`'s exact logic maintained separately.

**Fix:** bump this text's prominence a step (it doesn't need to match screen 1's fix in urgency, but `.caption2` at 65% opacity is easy to skim past for what's the primary "which day am I on" indicator for this whole screen). While in this code, consider replacing the local `dayTitle(_:)` with `HourFeedState.dayLabel`'s logic (or extracting one shared formatter both can call) so date-label wording doesn't drift out of sync between screens as either one gets tweaked in the future — not required for this fix, but worth doing while you're touching both.

---

## Verification

- **1:** on the friend-pairing screen, tap forward repeatedly past midnight and confirm the date visibly updates alongside the hour at every step, not just the hour.
- **2:** open All Friends while at the live/current hour and confirm a date is shown even in that state (not just once you've navigated away); step forward past midnight and confirm the date updates correctly.
- **3:** open the daily recap and confirm the date for the currently-viewed day is clearly visible, not just present in small print.
