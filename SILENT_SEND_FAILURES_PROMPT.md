# Fix prompt: sends fail silently (videos and messages)

Confirmed in code, not guessed. Both the video/log send path and the message send path already catch their own failures — they just never tell the user. The UI shows the same "sent" experience whether the send actually worked or silently died on the network.

Do not touch anything outside what's described here.

## A — `SendLogView` never surfaces `LogSync` failures

`SendLogView.send()` and `sendPublic()` (`SendLogView.swift`) fire `logSync.publish(...)` in a detached `Task`, then call `dismiss()` immediately — by design, so a slow upload doesn't block the capture flow. That part is fine and shouldn't change.

The problem: `LogSync.publish()` (`LogSync.swift`) already catches failures correctly —

```swift
} catch {
    lastError = "Couldn't share that log."
    syncLog.error("publish failed: \(error.localizedDescription, privacy: .public)")
}
```

— but `lastError` is `private(set)` on an `@Observable` class and **no view anywhere reads it**. A failed upload looks identical to a successful one: the composer dismissed, the clip is sitting locally with `isPublished == false`, and the recipient never receives anything, with no signal to the sender that anything went wrong.

**Fix — surface failure without blocking the optimistic dismiss:**

1. Give `Clip` (or derive from existing fields) a simple state the UI can react to: unsent/pending, published, failed. `clip.remoteID.isEmpty` already distinguishes unpublished from published — add a way to distinguish "still trying" from "gave up," e.g. a `publishFailed: Bool` set by `LogSync.publish()` in the `catch` block (in addition to setting `lastError`).
2. Somewhere the user will actually see it after dismissing — Pulse's chat row, or a lightweight toast/banner surfaced app-wide when `logSync.lastError` changes — show that a send failed, with a tap-to-retry that calls `logSync.publish(clip, context:, audience:)` again. A `LogSync.publishPending(context:)` already exists and does most of this (retries anything with an empty `remoteID`) — wire a manual retry entry point to it, or call it opportunistically (app foreground, Pulse appears) so failed sends recover on their own without the user having to notice anything broke.
3. Do not change the "dismiss immediately" UX — the fix is making failure visible afterward, not making send synchronous.

## B — `StreamThreadView` swallows channel sync failures

```swift
newController.synchronize { error in
    if let error { print("Channel sync failed: \(error)") }
}
controller = newController
```

`controller` is assigned unconditionally, regardless of whether `synchronize` succeeds. `ChatChannelView` renders normally on top of a controller that may not actually be synced to the server, so the composer looks usable even when the channel never came up — messages can appear to send locally and never arrive.

**Fix:**

1. Don't assign `controller` (or at least don't leave `failed` at its default) until `synchronize` reports success. Move `controller = newController` into the completion closure's success path, and set `failed = true` on the error path (mirroring the existing `catch` block below it, which already does this correctly for the `joinChannel`/`channelController(createChannelWithId:)` failure case — this is the same treatment, just for the async `synchronize` call that currently isn't checked).
2. Replace the bare `print` with the existing logger pattern used elsewhere in the file (`os.Logger`), so a real device log shows the failure even without Xcode attached, which will help diagnose anything that still slips through.

## Verification

- Force a publish failure (airplane mode mid-send, or temporarily point `publishLog` at a bad path) and confirm the sender sees *something* indicating the send didn't go through, and that retrying (automatically or via tap) succeeds once connectivity is back.
- Force a channel sync failure (invalid channel id, or airplane mode when opening a thread) and confirm `StreamThreadView` shows the existing "Couldn't open this conversation" state instead of a live-looking but non-functional composer.
- Confirm a normal, successful send/message still dismisses immediately with no added delay — this must stay a background, non-blocking operation.
- Re-test a real end-to-end send (video log and a text message) between two accounts on working network and confirm both arrive — if either still doesn't, capture the exact error now visible in the UI/logs (which won't exist until this fix lands) and report back with that instead of continuing to guess blind.
