# Before anything else: check what's already fixed, then close what's left

I read the actual current code for all four of these before writing this, and the situation is different from what a fresh bug list would suggest: **for all four issues, a real, correct-looking fix already exists in the project** (uncommitted, in the working tree — `git status` shows `CameraCaptureView.swift`, `ShareLogViews.swift`, `functions/index.js`, `ClipView.swift`, `NichePlacesView.swift`, `LogSync.swift` all modified). If these are still showing up live, the most likely explanation isn't missing code — it's that the fixes haven't reached the device being tested yet. Rewriting already-correct systems risks breaking work that's actually solid. **Do the verification steps in each section first.** Only write new code where a section says the gap is real.

---

## 1 — Camera: rotation and mirroring

**What's already in the code:** the entire rotation system was rewritten to use `AVCaptureDevice.RotationCoordinator` (`CameraCaptureView.swift`, `startTrackingRotation(for:)` ~line 1596), replacing the old manual `UIInterfaceOrientation`-to-angle table. The code comments document exactly why the old approach broke: the `.landscape` mask permits both landscape edges, and turning the phone end-for-end between them doesn't change the screen's size — so the old `onChange(of: screen.size)` trigger never fired on a 180° flip, leaving every frame after that upside down until something else changed the screen shape. `RotationCoordinator` is KVO-driven off actual device gravity instead, so it doesn't have that blind spot. Output mirroring is explicitly pinned to `false` on both `movieOutput` and `photoOutput` (`applyMirroring()` ~line 1647) so the saved file is never mirrored on either camera. Session reconfiguration (`configure`, `flip`) also already runs on a dedicated `sessionQueue`, off the main thread, so a flip shouldn't freeze the UI anymore.

**Verify first:** delete the app from the test device entirely, rebuild fresh from Xcode, and reinstall — don't just relaunch an existing install, since a stale binary is the single most likely reason a fix that's clearly in the source still looks broken live. Test rotating the phone 180° within landscape (not just portrait↔landscape) specifically, since that's the exact case the rewrite targeted.

**If it's still genuinely wrong after a clean rebuild:** the one place mirroring is *not* explicitly controlled is the live preview layer (`CameraPreview.PreviewView.applyRotation`, ~line 1901) — it only pushes rotation, and relies on `AVCaptureVideoPreviewLayer`'s automatic mirroring default (which should mirror the front camera only, never the back one). If the back camera's preview is still mirrored on a genuinely fresh build, don't guess — pin it explicitly instead of relying on the default, the same way the outputs already are:

```swift
func applyMirroring(_ mirrored: Bool) {
    guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
    connection.automaticallyAdjustsVideoMirroring = false
    connection.isVideoMirrored = mirrored
}
```

Call it with `mirrored: currentPosition == .front` alongside the rotation push, so the preview's mirroring is a known, explicit value instead of an inherited default — same principle already applied to the outputs, just not yet extended to this one connection.

## 2 — Sending to specific people/a group broadcasts to everyone

**What's already in the code:** this is fully implemented, both sides. `ShareLogViews.swift`'s `send()` (~line 170) walks only the selected chats, collects the real `remoteUID` of every non-`isMe` member across them into a `recipients` set, and refuses to publish at all if it resolves to nobody real (`if !addressed.isEmpty`). It passes `recipientUids: addressed` into `logSync.publish(...)`. `LogSync.publish` threads it into the `publishLog` payload. Server-side, `functions/index.js`'s `publishLog` (~line 1404) reads `recipientUids` for a friends-audience post and records it on the log; `listFriendLogs` (~line 1606) filters a log out unless `!Array.isArray(log.recipientUids)` (legacy log, old behavior preserved) or `log.recipientUids.includes(uid)` or the caller is the author. This is a correct, complete implementation of exactly the fix this bug needs.

**Verify first, and this one matters more than the others:** `functions/index.js` is a **Cloud Function**. A correct change sitting in this file does **nothing** on the live server until it's deployed. Run:

```
firebase deploy --only functions
```

If this hasn't been run since these changes were made, the live `publishLog`/`listFriendLogs` your app is actually calling are still the *old* code, no matter how correct the local file is — this alone would fully explain "it still sends to everyone," independent of anything being wrong with the code itself.

**If it's still broadcasting after confirming both a fresh app build *and* a fresh functions deploy:** check that `selected` in `SendToFriendsView` genuinely contains only the chats you tapped (add a temporary log of `recipients` right before publish and confirm it's not larger than expected) before assuming the bug is back — the logic as written is correct, so a regression here would mean something upstream (the row-selection UI itself) is marking more chats selected than it should.

## 3 — Slow playback and a black screen between loops (video), and photos going black too

**What's already in the code:** `StackedClipPane` no longer remounts a photo's view on every clock tick — it now only keys the clock-cycle-based `.id()` for `clip.kind == .video` (~`StackedClipViews.swift` line 67), which was the fix for photos flickering to the placeholder. `LoopingVideoView.PlayerContainerView.configure` (`ClipView.swift` ~line 211) now preloads the asset's duration/tracks before building the `AVPlayerItem`, specifically to avoid the exact black-frame-at-the-loop-seam problem, and sets `automaticallyWaitsToMinimizeStalling = false`.

**This part is a real, still-open gap** — you're reporting it's still happening, and unlike the other three, I don't have a clean explanation for why the existing preload fix wouldn't be enough, which means it likely isn't the whole fix. Two things to actually change:

1. **Photos going black "between replays" is a distinct symptom from the video loop-seam issue**, and since photos no longer remount on the clock cycle, a black flash on a photo points somewhere else — most likely the *page transition* in the paging stack itself (`FriendPairFeedView`/`AllFriendsFeedView`/`GroupClipFeedView`, all using `LazyVStack` + `.scrollTargetBehavior(.paging)`), not the individual clip view. Check whether `ClipSyncClock.resync()` (called on a page change) or the stack's own re-render is forcing something above `StackedClipPane` to redraw/remount during a page transition, showing a blank frame independent of what `ClipView` itself does. If a photo is genuinely never supposed to show anything but itself once mounted, the fix is likely to stop the container list itself from momentarily un-rendering content during a page swipe — investigate with the actual paging transition, not the media player.
2. **For video specifically**, if the asset-preload fix isn't enough, the next real step (not yet tried) is queuing two instances of the item into the `AVQueuePlayer` up front — closer to what `AVPlayerLooper` is meant to smooth over, but with an explicit second item ready rather than relying on the looper to prepare one in time:

```swift
let item1 = AVPlayerItem(asset: asset)
let item2 = AVPlayerItem(asset: asset)
let player = AVQueuePlayer(items: [item1, item2])
looper = AVPlayerLooper(player: player, templateItem: item1)
```

Test this specifically against the black-flash symptom rather than assuming it helps — this class of AVFoundation buffering issue is genuinely easy to think is fixed when it's just become less frequent.

## 4 — Profile picture shows the default emoji instead of the real photo, specifically from Places

**What's already in the code:** `SpotClip.authorAvatarURL` exists and is populated from the server (`LogSync.swift` ~line 350, `RemotePublicLog.authorAvatarURL` ~line 445), and `NichePlacesView.swift`'s `authorAvatarURL`/`authorProfile` (~lines 237–272) build a real URL from it and pass `remotePhotoURL: authorAvatarURL` through. This is the same three-tier pattern (local file → remote URL → emoji) used everywhere else avatars show correctly.

**Verify first:** per the separate note already given about this — a Places row's avatar only back-fills on the **next** `syncPublicDown`, which runs when the Places tab is opened. If you're checking a row that was already on screen *before* the avatar-URL plumbing was added, or before this session's `syncPublicDown` ran at all, it will still show the placeholder until that sync happens once. Force it by leaving Places and reopening it, or backgrounding and relaunching the app, before concluding the fix isn't working.

**If it's still the emoji after a fresh sync on a fresh build:** the most likely remaining gap is a log published *before* `authorAvatarURL` existed on the backend — an old `logs/{id}` doc simply has no such field to serve, emoji is all there ever was for that specific post. Confirm by testing with a *brand-new* post made after this fix, not an old one already sitting in the feed, before treating this as unresolved.

---

## What to actually do, in order

1. Deploy the Cloud Functions (`firebase deploy --only functions`) — do this regardless of anything else, since it's cheap, necessary for §2 regardless of any other finding, and costs nothing if it turns out to already be deployed.
2. Delete the app from the test device and do a completely fresh build + install.
3. Re-test all four with a fresh device and fresh backend. Re-test §2 specifically with a brand-new send, and §4 specifically with a brand-new post — not existing content from before these fixes landed.
4. Only for whatever is still actually broken after 1–3, apply the additional changes described in that section (§1's preview-mirroring pin, §3's queued-item change or paging-transition investigation). Don't touch the parts already confirmed correct above.
