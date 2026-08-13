# Fix prompt: raw POI category text, "use current location" for beacons/spots, unified tap=hour/swipe=day navigation

Three items. The third applies one consistent rule across all three navigable log-viewing screens: tap steps one hour at a time and rolls naturally into the next/previous day if you keep going, while swipe is a separate, bigger jump straight to the start of the adjacent day.

---

## 1 — Location category sometimes shows the raw `MKPOICategoryXxxx` string

There's no formatting step anywhere in the pipeline — this isn't an incomplete mapping falling back to a raw value, there is no mapping at all. MapKit's raw enum value is captured and stored verbatim:

```swift
// SpotSearchView.swift:138, inside SpotSearchModel.select(_:)
category: item.pointOfInterestCategory?.rawValue ?? "",
```

That string round-trips unchanged through `PendingSpot` (`SpotSearchView.swift:87`), into `Spot.category` on both the SwiftData model and the Firestore upsert (`SpotSearchView.swift:172`, `Models.swift:677,698-702`), and back down again on sync (`Spot.mirror(_:into:)`, `SpotSearchView.swift:38`, copies it verbatim). It's then interpolated directly into display text with no processing at either of the two places it's shown:

- `BeaconsFeedView.swift:447`: `Text("\(spot.category) · \(spot.distanceMiles, specifier: "%.1f") mi away")`
- `NichePlacesView.swift:792`: same pattern.

**Fix:** add a formatter — either an `MKPointOfInterestCategory` extension or a lookup table keyed on the raw string — that converts values like `"MKPOICategoryLandmark"` into `"Landmark"`, `"MKPOICategoryRestaurant"` into `"Restaurant"`, etc. (Apple's `MKPointOfInterestCategory` has a fixed, documented set of cases — build the table from that list.) **Apply this formatter at the two render sites** (`BeaconsFeedView.swift:447`, `NichePlacesView.swift:792`), not just at the write site (`SpotSearchView.swift:138`) — spots already persisted with raw category strings need to display correctly too, without requiring a data migration. If you also want to clean up the stored value going forward, format it at write time as well, but the render-time fix is the one that actually matters for correctness regardless of when a spot was created.

## 2 — Add a "use current location" option when creating a beacon or posting a spot

Confirmed: `CLLocationManager` exists in exactly one place in the whole codebase (`SpotSearchView.swift`'s `SpotSearchModel`), and its only job is to bias search relevance — `startBiasingToCurrentArea()` (lines 110-118) fetches a location fix purely to recenter the `MKLocalSearchCompleter`'s search region. The coordinate is never reverse-geocoded, never surfaced to the UI, and never turned into a selectable result. The picker itself (`SpotSearchView.swift:255-355`) only offers two sections — "Already on Ralli" and live typed-search suggestions — with no third "wherever I am right now" option; the empty state literally instructs the user to type a place name.

**Fix — a genuinely new code path, not exposing something already built:**

1. Add a "Use current location" row or button to the picker UI, above or alongside the search results.
2. On tap, get the current fix (reuse the same `locationManager` already being used for biasing, or issue a fresh `requestLocation()`).
3. Resolve that coordinate into an actual place: either reverse-geocode it (`CLGeocoder().reverseGeocodeLocation(_:)` or the newer `MKReverseGeocodingRequest`) for a name/address, or — better, since it also gives you a proper POI category and name — run an `MKLocalSearch` centered tightly on that coordinate to get a real `MKMapItem`.
4. Build a `PendingSpot` from that result the same way `select(_ completion:)` already does (`SpotSearchView.swift:124-145`), and route it into `model.pending` so the existing confirmation UI takes over unchanged — no new confirmation flow needed, just a new way to arrive at a `PendingSpot`.

## 3 — Tap = step one hour at a time, rolling naturally into the next/previous day when you keep going; swipe = jump straight to the start of the adjacent day

Clarified rule: **tap keeps stepping hour by hour with no boundary at all** — if you're at 12 PM and keep tapping forward, you go 1 PM, 2 PM, ... 11 PM, then straight into 12 AM (midnight) of the next day, then 1 AM, and so on, exactly like a continuous clock. **Swipe is a separate, bigger move**: it jumps directly to the start of the adjacent day (hour 00:00), regardless of what hour you were on when you swiped — it doesn't care about your current hour-of-day at all, and it doesn't require tapping through every hour to get there. Applies to `FriendPairFeedView`, `AllFriendsFeedView`, and `DailyVlogView`.

**Shared mechanism today:** `EdgeStepZones` (`HourAxis.swift:82-165`) only accepts one pair of closures, `onBack`/`onForward`, and wires both the edge tap (line 158-161) and the horizontal swipe (`swipeCatcher`'s `DragGesture`, lines 131-146) to the exact same two closures — there's no way today for tap and swipe to diverge anywhere this component is used.

**Fix to `EdgeStepZones` itself, shared by all three screens:** add a second, optional pair of closures — `var onSwipeBack: (() -> Void)? = nil`, `var onSwipeForward: (() -> Void)? = nil` — and in the drag handler (lines 139-145), call `(onSwipeBack ?? onBack)()` / `(onSwipeForward ?? onForward)()` instead of `onBack()`/`onForward()` directly. Defaulting to `nil` (falling back to the tap closures) means any call site that doesn't opt in keeps its current behavior unchanged.

### `FriendPairFeedView` and `AllFriendsFeedView`

Both already share one `HourFeedState` per screen (`HourFeedState.swift`), which tracks a single `selectedHour: Date`. Only one addition is actually needed here:

**A new day-jump-to-start method on `HourFeedState`**, for swipe, alongside the existing `jump(toDay:)` (which preserves hour-of-day — leave that one alone, it's used by the calendar picker and isn't part of this request):
```swift
/// Jumps straight to the start of the adjacent day (hour 00:00), discarding
/// the current hour-of-day entirely — used for the swipe gesture, as
/// distinct from `jump(toDay:)`'s hour-preserving jump used by the calendar
/// picker, and distinct from `step(_:)`'s hour-by-hour tap stepping, which
/// already crosses day boundaries naturally via plain calendar arithmetic
/// and needs no change at all.
func stepToStartOfDay(_ delta: Int) {
    guard let targetDay = calendar.date(byAdding: .day, value: delta, to: selectedHour) else { return }
    let start = calendar.startOfDay(for: targetDay)
    selectedHour = min(start, Self.floorToHour(.now, calendar: calendar))
}
```

**`step(_:)` needs no change at all** — it already does plain `calendar.date(byAdding: .hour, ...)` arithmetic with no day-boundary check, which is exactly the "12 PM → 1 PM → ... → 11 PM → 12 AM next day" behavior wanted for tap. Leave it exactly as it is.

Wire tap to the existing `stepHour` (unchanged) and swipe to the new `stepToStartOfDay`, at both call sites (`StackedClipViews.swift:146-148` and `1023,1070-1072`).

### `DailyVlogView` — same rule, translated into its clip-index model

This screen navigates an ordered list of that day's clips (`clips`, lines 56-62) rather than tracking hour-of-day directly, and its existing tap-rollover behavior (`step(_:)`, lines 299-313 — running off either end of a day's clip list calls `onStepDay(±1)` and lands on the neighboring day's last/first clip) is actually **already the right shape for tap** — keep that rollover, don't remove it. One real wrinkle worth knowing about, though: `DailyVlogView.clips` aggregates every clip authored by "me" across *all* chats for the day (line 59, no chat-scoping), while the one-log-per-hour cooldown (`Chat.cooldownRemaining`, `Models.swift:236-243`) is enforced *per chat* — so sending to two different friends within the same clock hour produces two clips in that hour, and plenty of hours will have zero. To make tap here mean "step one hour" rather than "step one clip" (so it lines up with the other two screens' hour-based stepping instead of a raw clip-index), group `clips` by calendar hour and have tap-stepping move to the previous/next hour-*group* that has at least one clip (landing on the first clip chronologically if a group has more than one) — keeping the existing cross-day rollover exactly as it already works when you run off the first/last hour-group of a day.

**Add swipe separately**, wired to the existing `stepDay`/`onStepDay` (`DailyVlogView.swift:48-54`) via the new `onSwipeBack`/`onSwipeForward` from the `EdgeStepZones` change above — this jumps straight to the target day (skipping the hour-by-hour walk entirely), landing on that day's first clip regardless of swipe direction, distinct from tap's continuous hour-by-hour rollover.

---

## Verification

- **1:** browse Places/Beacons until you find a spot whose category previously showed as a raw `MKPOICategoryXxxx` string, and confirm it now shows a readable label like "Landmark" or "Restaurant" — including for spots created before this fix, without needing to re-create them.
- **2:** open the location picker while creating a beacon or posting a spot, tap "use current location," and confirm it resolves to the actual place you're standing at without needing to type anything.
- **3:** on all three screens, start at 12 PM and keep tapping forward — confirm it walks 1 PM, 2 PM, ... through 11 PM and continues into 12 AM of the next day without stopping. Confirm swiping instead jumps immediately to the start of the adjacent day, no matter what hour you were on. On the daily recap, confirm an hour with two clips (sent to two different friends in the same hour) counts as one tap-step, landing on the first of the two.
