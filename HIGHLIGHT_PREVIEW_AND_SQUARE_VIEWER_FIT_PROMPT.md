# Fix prompt: highlight preview shows vertical/cropped, and the main log-viewing screen crops horizontal video to a square

Both bugs trace back to the same root cause — a missing `contentMode: .fit` at a handful of call sites — but they're in different screens, so listing them separately with exact locations.

---

## 1 — Highlight tap-to-play shows the video cropped instead of fitted

The tap-to-play added in an earlier round works, but its full-screen player doesn't pass a content mode. `UserProfileView.swift:1085-1117`, `HighlightPlayerView`:

```swift
StackedClipPane(clip: clip,
                authorName: nil,
                authorEmoji: author?.emoji ?? "✨",
                authorHue: author?.hue ?? 0.58,
                roleLabel: "you",
                headerTopPadding: 44,
                avatarSource: author)
```

No `contentMode` is passed, so `StackedClipPane`'s parameter (`StackedClipViews.swift:76`) defaults to `.fill`, which resolves to `AVLayerVideoGravity.resizeAspectFill` (`ClipView.swift:193-195`) — crop-to-fill against the player's portrait-ish frame, cutting off the sides of a landscape recording.

**Fix:** add `contentMode: .fit` to that one call site:

```swift
StackedClipPane(clip: clip,
                authorName: nil,
                authorEmoji: author?.emoji ?? "✨",
                authorHue: author?.hue ?? 0.58,
                roleLabel: "you",
                headerTopPadding: 44,
                avatarSource: author,
                contentMode: .fit)
```

(The Highlights *grid tile* itself is correct and untouched by this — `highlightCell`'s `.aspectRatio(16.0/9.0, contentMode: .fill)` at `UserProfileView.swift:318-329` is a deliberate thumbnail crop, not the bug. Only the full-screen player needs this change.)

## 2 — MAJOR: the main log-viewing screen crops horizontal video into a square

Two specific screens have square-ish viewing frames and never override `StackedClipPane`'s `.fill` default:

**A. Friend-pairing full-screen viewer** — `FriendPairFeedView.pairPage(for:height:)` (`StackedClipViews.swift:359-425`). The frame math (lines 362-370) computes `cardHeight` as roughly half the usable screen height, which on a typical device works out close to the card's width — effectively a square container. Both `StackedClipPane` calls inside it omit `contentMode`:

- Line 383-394 (the friend's clip)
- Line 407-417 (your own clip)

**Fix:** add `contentMode: .fit` to both:

```swift
StackedClipPane(clip: friendClip, ..., contentMode: .fit)   // ~line 383
...
StackedClipPane(clip: myClip, ..., contentMode: .fit)        // ~line 407
```

**B. Group feed viewer** — `GroupClipFeedView.groupCard(entry:width:height:)` (`StackedClipViews.swift:762-785`). Same gap — the `StackedClipPane` call at lines 764-772 has no `contentMode`. Add it there too.

**Do not touch these — already correct, leave exactly as-is:**
- `AllFriendsFeedView.row(for:height:)` (`StackedClipViews.swift:929-949`) already passes `contentMode: .fit` at line 948 — this screen already shows the full video correctly.
- `PulseFeedView.swift`'s `PulseCard` (lines 371-404) intentionally uses the default `.fill` inside its 16:9 thumbnail card — this is the deliberate full-bleed look for the Pulse home wall's feed thumbnails, explicitly commented as such. This is feed-thumbnail UI, not a "viewing screen," and changing it would violate "keep everything else the same."
- `DailyVlogView.swift:268` already correctly uses `contentMode: .fit` — the reference implementation this fix mirrors.
- `StackedClipPane`, `ClipView`, `ClipMediaView`, `LoopingVideoView` themselves need no changes at all — they already correctly plumb `contentMode` through to the underlying `AVLayerVideoGravity`. This fix is scoped entirely to the three missing call-site arguments listed above (A ×2, B ×1) — nothing else in the file should change.

---

## Verification

- Tap a video from your own Profile Highlights and confirm it opens showing the full frame, letterboxed if needed, with nothing cropped from the sides.
- Open the friend-pairing screen (tap into a friend from Pulse) with a horizontally-recorded log and confirm both your clip and your friend's clip show the entire frame, not cropped to a square.
- Open a group chat's clip feed with a horizontally-recorded log and confirm the same.
- Confirm Pulse's home feed thumbnails and the All Friends / Daily Recap screens look exactly as they did before this change — this fix should be invisible everywhere except the three spots listed above.
