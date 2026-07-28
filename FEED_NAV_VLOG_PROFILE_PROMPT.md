# Feed Navigation, Daily Vlog, and Profile Overhaul

Seven items, grounded in the current code. One (item 4, follow-yourself) already appears fixed — verify, don't re-touch, unless you find it's regressed. The rest are real, substantial work — items 2, 3, and 5 in particular involve real new data-navigation concepts (hour indexing across people, day-level video stitching) that don't exist anywhere in the codebase yet, so don't treat them as small UI tweaks.

Do not touch anything outside what's described here — camera, messaging, and the other open prompts are unrelated to this pass.

---

## 1 — Hour navigation on the friend-pairing screen

`FriendPairFeedView` (`StackedClipViews.swift` ~line 213) currently pages **vertically between friends**, and each pair always shows `friend.latestClip` / `me`'s latest clip — whichever clip is simply the most recent, with no concept of "which hour." There is no hour-navigation concept anywhere in this file today.

**Build a shared hour-resolution helper** (`Friend` extension or a small standalone function), since this same concept is needed again in items 2 and 3:

```swift
extension Friend {
    /// This friend's clip captured during the clock hour containing `date`, if any.
    func clip(forHourContaining date: Date) -> Clip? {
        clips.first { Calendar.current.isDate($0.capturedAt, equalTo: date, toGranularity: .hour) }
    }
}
```

In `FriendPairFeedView`:

1. Add `@State private var viewingHour: Date = .now` (or similar), representing which hour's pair is currently shown.
2. Replace `friend.latestClip` / `me?.latestClip` in `pairPage(for:height:)` with `friend.clip(forHourContaining: viewingHour)` / `me?.clip(forHourContaining: viewingHour)`.
3. Add left/right tap zones over the pair (an invisible `HStack` of two equal-width tappable regions, or a `.contentShape` split down the middle) — tapping the left half moves `viewingHour` back one hour (`Calendar.current.date(byAdding: .hour, value: -1, to: viewingHour)`), tapping the right half moves it forward one hour, clamped so you can't navigate into the future beyond the current hour.
4. When there's no clip for the viewed hour, `StackedClipPane`'s existing `noClipPlaceholder` already handles a nil clip — confirm it still reads sensibly for "this specific hour had nothing" rather than only "no clip ever," since the copy currently says "no clip yet" which may need to become hour-aware phrasing.
5. Keep the existing vertical friend-to-friend paging exactly as it is — this is an *additional*, orthogonal navigation axis (horizontal tap = hour, vertical swipe = friend), not a replacement.

## 2 — "All Friends" hour view: quarter-height continuous feed

`AllFriendsFeedView` (`StackedClipViews.swift` ~line 689) currently pages **full-screen per friend** (`.scrollTargetBehavior(.paging)`, comment: "one per full screen, paging vertically"). The new spec wants something different: every friend's clip for one specific hour, each at roughly a quarter of the screen's height, in one continuously scrollable list — not full-screen paging.

**Rebuild the layout, keep the underlying pieces:**

1. Remove `.scrollTargetBehavior(.paging)` and the full-height `StackedClipPane` sizing — replace with a plain `ScrollView(.vertical)` + `LazyVStack`, each row sized to `proxy.size.height / 4` (or a fixed fraction — "roughly one-quarter," not necessarily exact), using the horizontal/landscape video treatment already established elsewhere (letterboxed `contentMode: .fit`, matching the other open prompt's treatment for post-capture/Places — don't reintroduce vertical-crop full-bleed here).
2. Add the same `@State private var viewingHour: Date = .now` + left/right tap-to-shift-hour zones as item 1, applied once at the screen level (tapping either side shifts *everyone's* videos to the adjacent hour together, not per-row).
3. For `entries`, keep listing every friend (not just ones with a clip for the viewed hour) — use `friend.clip(forHourContaining: viewingHour)` from item 1's helper, and when it's `nil`, render a plain black rectangle with the friend's name/hour label rather than `StackedClipPane`'s existing emoji-and-"no clip yet" placeholder — the spec specifically wants a black screen in that slot, not the decorative empty state used elsewhere.
4. "Smooth and continuous, like unrolling a long sheet of paper" — a plain `ScrollView` with `LazyVStack` already behaves this way once paging is removed; the main risk is re-triggering the same kind of remount/flicker issue fixed elsewhere for individual clips (`StackedClipPane`'s clock-cycle `.id()`, already correctly scoped to `clip.kind == .video` only) — keep that existing fix intact rather than reintroducing a per-scroll remount here.

## 3 — "Logged this hour" button + Daily Vlog

**The status banner** is `HourlyCadenceBanner` (`PulseChrome.swift` ~line 15), used from `PulseHomeView` (~line 87). Current behavior: `progressRing` shows either a countdown-in-minutes or a checkmark, `title(remaining:)` returns "Next log in MM:SS" / "Logged this hour", and a `subtitle` line underneath reads "Ralli runs on the hour. Post yours." / "You're on the board — next hour opens soon."

**Fix, per the spec exactly:**

1. Change `title(remaining:)` to return **"Send your Log for the hour"** when not posted, **"Logged for this hour"** when posted — drop the countdown/minutes text from the title entirely.
2. Remove `subtitle` and its `Text(subtitle)` row — no second line of text at all.
3. Simplify `progressRing` — keep the two icon states (checkmark when posted, using `Theme.mint`; whatever "red" icon reads best when not posted, using `Theme.accent`) but remove the numeric minutes display inside the ring, since the spec says "just the label and icon" with no countdown anywhere on this control.
4. Shrink the now-single-line title's font/sizing enough to leave visible room on the right side of the banner, and add a second button layered there — pick an icon that reads as "daily recap/reel" (e.g. `film.stack` or `rectangle.stack.fill.badge.play`) — that presents a new `DailyVlogView`.

**Build `DailyVlogView` (new):**

1. Given a day, gather that day's clips for the signed-in user (`me.clips.filter { Calendar.current.isDate($0.capturedAt, equalTo: day, toGranularity: .day) }`, sorted by `capturedAt`), across every hour that has one.
2. Stitch them into one continuous horizontal video with `AVMutableComposition`: insert each video clip's track sequentially via `insertTimeRange(_:of:at:)`. Photo-kind and vibe-kind clips have no video track to insert directly — the straightforward approach is a short fixed-duration still-image segment per photo (composited via `AVMutableVideoComposition` with a `CALayer`/`AVVideoCompositionCoreAnimationTool`, or a simpler still-to-video conversion utility if one already exists anywhere in the project); if that's a significantly bigger lift than the rest of this pass, it's reasonable to stitch video-kind clips only for a first version and note the gap rather than silently dropping photos with no explanation — this is a real engineering trade-off, not a small detail.
3. Export via `AVAssetExportSession` to a local file; add a "Download" action using `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:) }` (with the same photo-library permission handling the rest of the app already uses for camera-roll access).
4. Left/right tap zones (same pattern as items 1 and 2) move to the previous/next day's vlog. If a day has zero clips, show a clear empty state rather than an export of nothing.

## 4 — Prevent following yourself

Already fixed — `UserProfileView.swift`'s `toggleFollow()` (~line 914) already guards `guard isRemote, !isMe, !followWorking else { return }`. Verify this is still true on the branch you're working from and that it wasn't reverted; do not re-implement it from scratch.

## 5 — Profile tab overhaul

`UserProfileView.swift` today is one monolithic view mixing identity fields (name, bio, city, age), the privacy toggle, avatar editing, log out, and delete account all together — there is no existing split between "Edit Profile," "Settings," and a browsable main profile screen. This needs restructuring into three surfaces:

**Edit Profile (new screen, opened from a button on the main Profile tab):**
- Name, age, city, bio, avatar photo picker, and the public/private toggle (`me.isPrivate` binding, currently ~line 164) — move all of this here from the current monolithic view.

**Settings (new/expanded tab or screen):**
- Email, phone number, log out (~line 374), delete account (~line 429), and any other account-level (not identity/appearance) fields currently mixed into `UserProfileView`.
- Use judgment on anything not explicitly listed above — the dividing line is "how you present yourself" (Edit Profile) vs. "account/security administration" (Settings).

**Main Profile tab (redesigned, the landing screen):**
- A "Highlights" section: every video the user has posted (`me.clips` filtered to `kind == .video` and possibly `.photo`, sorted newest-first), in a grid.
- Each video gets a 3-dot menu, bottom-right corner, with at minimum: delete video, and an "Insights" view. "Insights" needs real numbers — check what's actually tracked server-side today before inventing fields: `SpotClip` already has `likeCount`/`likedByMe` and `comments` for public posts (`Models.swift` ~line 536), but a plain (non-public) `Clip` sent to friends currently has none of that — reactions (`clip.reactions`) exist, but view/save counts do not. Decide, and note in your implementation, whether Insights only applies meaningfully to public Places posts (where the numbers already exist) versus friends-only logs (where they'd need new tracking added) — don't fabricate numbers that aren't backed by anything real.
- A stats section: "experiences attended" (count of beacons the user has joined — `Friend.joinedBeacons.count`, already exists as a relationship on `Friend`, `Models.swift`), and "distance traveled" (this doesn't exist anywhere yet — if there's no location history tracked per clip/spot today, this either needs a real data source added or should be scoped down to something derivable now, like distinct places visited via `Spot`/`SpotClip.spot`, rather than inventing a number with nothing behind it).
- Additional stats, pick from ones the current data model actually supports: current streak (`Chat.streak`/`streakCount` already exists on `Friend`, ~line 120), friend count (`friends.filter { !$0.isMe }.count`, trivial), distinct places visited (count of distinct `Spot`s across the user's `SpotClip`s). "Total hours logged" and "cities visited" would need new derivations — total hours logged could reasonably be "count of hourly logs sent" (i.e., total `Clip` count) rather than literal video duration summed, unless real per-clip duration is already tracked somewhere (check before assuming it isn't).

## 6 — Empty caption defaults to "right now" — remove it

Two call sites, both in `ShareLogViews.swift`:

```swift
let finalLabel = label.isEmpty ? "right now" : label     // line 171, SendToFriendsView.send()
let finalLabel = name.isEmpty ? "right now" : name        // line 416, PublicPlacePostView.post()
```

Remove the fallback — just use `label` / `name` directly, so an empty caption stays empty. This is safe: `StackedClipPane`'s caption rendering already guards with `if let caption = clip?.label, !caption.isEmpty { captionOverlay(caption) }`, so an empty string already correctly hides the caption overlay everywhere it's displayed — no downstream UI changes needed beyond removing these two fallback strings.

## 7 — Event date/time on Beacons

`BeaconsFeedView.swift`'s beacon-creation flow currently hardcodes the start time — `startsAt: .now.addingTimeInterval(3600 * 2)` (~line 1006) — with no date/time picker exposed to the user at all.

**Fix:** add a `DatePicker` (`.date` and `.hourAndMinute` components, `in: Date.now...` to disallow scheduling in the past) to the beacon-creation form, bound to a new `@State private var startsAt: Date = .now.addingTimeInterval(3600 * 2)` (keep the same default when the user hasn't touched it), and pass that state value into the `Beacon(...)` initializer instead of the hardcoded literal. Confirm `createBeacon`'s existing `startsAt` handling server-side (`functions/index.js`, already accepts a `data.startsAt` per the earlier Beacons-sync work) passes the real picked value through — check it isn't being overridden or ignored anywhere in `BeaconSync.publish`.

---

## Verification

- **1:** on the friend-pairing screen, tap left/right and confirm both your clip and the friend's clip switch to the adjacent hour together; confirm vertical swiping between friends still works independently.
- **2:** open "All Friends," confirm a continuous (non-paging) scroll of quarter-height horizontal videos, confirm tapping left/right shifts every row to the adjacent hour, and confirm a friend with nothing that hour shows a plain black slot with their name rather than the decorative empty state.
- **3:** confirm the status banner shows only "Send your Log for the hour" / "Logged for this hour" with no countdown or subtitle text; confirm the new button opens a Daily Vlog that plays a stitched video of the day's logs, downloads to Photos, and that left/right moves between days.
- **4:** confirm you still cannot follow yourself from any entry point.
- **5:** confirm Edit Profile, Settings, and the main Profile tab each contain the right fields with nothing duplicated or missing; confirm Highlights shows real posted videos with working delete and Insights actions; confirm every stat shown reflects a real, existing number, not a placeholder.
- **6:** send a log with no caption typed and confirm nothing appears where the caption would be, on every screen that shows it.
- **7:** create a beacon with a specifically chosen future date/time and confirm it displays and syncs with that exact time, not the old hardcoded default.
