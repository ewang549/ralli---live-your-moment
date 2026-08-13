# Fix prompt: reaction chat image — the crop is already fixed, the emoji badge still needs a cleaner "poking out of the corner" treatment

One item, and good news first: the crop bug documented earlier is already fixed in the code. What's left is purely a polish request on the emoji badge, confirmed against a real screenshot of a sent reaction.

## What's already fixed — don't redo this

`ReactionSticker.swift` no longer force-crops the log. `renderSize(aspectRatio:)` (lines 33-38) now sizes the canvas to the clip's own aspect ratio instead of a fixed 540×960 portrait card, and `composite(clip:emoji:)` (lines 81-91) uses `.aspectRatio(contentMode: .fit)` into that already-correctly-shaped canvas — a whole-frame fit with nothing to letterbox, not the `.fill`+`.clipped()` crop the earlier prompt flagged. The attached screenshot confirms this: the sent reaction shows the full landscape log, uncropped, matching how it looks everywhere else in the app.

## What still needs work: the emoji badge should read as a distinct bubble sitting on the corner, not a watermark stamped inside the frame

Current implementation (`ReactionSticker.swift:99-119`): the emoji sits in a soft dark circle, bottom-left, inset from the edges by `unit * 0.055` (about 5.5% of the shot's short edge) — fully inside the image, flush against the content. In the screenshot this reads as a badge stamped *onto* the picture rather than a separate element sitting *on top of* the message bubble the way a reaction/tapback normally does in a chat UI (think iMessage tapbacks, which visually poke half on/half off the bubble they're attached to) — that's the "cleaner" look being asked for.

**Fix — make the badge sit on the corner rather than inside it:**
1. Reduce the inset so the badge's circle visually overlaps the image's own rounded corner rather than sitting padded inward from it — effectively let it hang slightly past where the image's rounded-corner clip would otherwise cut it off, the way a badge "pokes out" of a bubble corner. Concretely, move the badge's anchor closer to `(0, size.height)` (the true bottom-left corner) rather than inset by the current padding, e.g. reduce or remove the `unit * 0.055` padding on the badge's own `VStack`/`HStack` (line 119) while keeping enough margin that the circle isn't clipped by the image's own corner radius.
2. Tighten the circle itself so it reads as a clean minimal badge rather than a busy stamp: consider shrinking `unit * 0.24` (emoji font size, line 105) and `unit * 0.055` (internal padding, line 106) slightly, and re-check the shadow (`unit * 0.03` radius, line 115) isn't adding visual noise at the smaller size.
3. If the app's message bubble rendering (wherever `StreamThreadPoster.postReaction`'s attachment is displayed — check `StreamThreadView.swift`) draws the image inside its own rounded-rect bubble shape, consider whether the badge should actually be drawn *outside* the composited image entirely — as a small SwiftUI overlay on the message cell itself, positioned to overlap the bubble's bottom-left corner — rather than baked into the JPEG pixels. That would let it render sharp at any zoom/scale and sit truly on top of the bubble's rounded edge instead of being constrained to sit inside the image's own bounds. This is a bigger change (touches the chat message rendering, not just `ReactionSticker`), so only take this path if the simpler corner-overlap adjustment in steps 1-2 doesn't look clean enough on its own.

## Verification

React to a friend's landscape log with an emoji, open the resulting message in the thread, and confirm: the full log shows uncropped (already working — just confirm it's still true), and the emoji reads as a small distinct badge sitting right on the bottom-left corner of the image rather than padded inward from the edges like a watermark.
