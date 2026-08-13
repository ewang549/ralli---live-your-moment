# Fix prompt: message notifications don't work — root cause found, it's a dashboard config gap, not a code bug

Other notification types (friend requests, friend accepted, etc.) work. Message notifications — someone texts you and you should get a push showing who and what they said — do not. Investigated the full pipeline, client and server, and the code is correct end to end. The actual gap is a one-time setup step in the Stream Dashboard that was never done.

## Root cause

**The Stream Chat webhook was never registered in the Stream Dashboard.**

- `functions/index.js:2765-2813` (`exports.streamMessageWebhook`) is a fully correct HTTP Cloud Function: it verifies Stream's `x-signature` via `serverClient.verifyWebhook()`, filters for `message.new` events, resolves recipients (excluding the sender and any blocked users), and calls the same `notify()` helper (`functions/index.js:2630-2699`) that already successfully sends friend-request and friend-accepted pushes — reading `users/{uid}/devices` and sending via `getMessaging().sendEachForMulticast`, with per-token error logging.
- The difference: `onFriendRequest`/`onFriendAccepted` are Firestore `onDocumentCreated` triggers, which fire automatically the instant Firestore is written — no external configuration needed. `streamMessageWebhook` is a plain HTTP endpoint. It only runs if Stream's own servers call it, which requires setting a webhook URL in Stream's Dashboard (Chat → Webhook & Events) pointing at `https://us-central1-explog-723b7.cloudfunctions.net/streamMessageWebhook`, with the `message.new` event enabled.
- Searched the entire repo — client Swift, `functions/index.js`, `test-stream.js`, every doc/runbook — for anything that sets this programmatically (`updateAppSettings`, `webhook_url`, etc.). There is none. Nothing in this codebase can configure that dashboard setting; it's a manual step, and unlike the earlier APNs `.p8` key upload (which did get done), this one appears to have been missed entirely.
- On the client: there's deliberately no `ChatClient.addDevice`/native Stream push-provider registration anywhere (`StreamConfig.swift`, `StreamTokenProvider.swift`, `PushNotifications.swift`, `explogApp.swift`). That's correct, not a gap — this app doesn't use Stream's own APNs/FCM push integration; it relays through this webhook into the app's own existing FCM pipeline instead. There's nothing missing to add here.
- Client-side notification routing for messages is also already implemented and just waiting for a payload to arrive: `PushNotifications.swift`'s `PushDestination.init(payload:)` already handles `type: "message"` → `.thread(channelId:)` (lines 29-34).

**Don't touch, all correct:** `streamMessageWebhook`'s handler code, `notify()` and its preference-gating, APNs token registration/save in `PushNotifications.swift`, and the client's message-tap routing.

## Fix — not a code change

1. In the [Stream Dashboard](https://dashboard.getstream.io/), open this app's Chat settings → **Webhook & Events**.
2. Set the **Webhook URL** to `https://us-central1-explog-723b7.cloudfunctions.net/streamMessageWebhook`.
3. Enable the `message.new` event (and confirm the webhook secret used for signature verification matches whatever `serverClient.verifyWebhook()` expects — check `functions/index.js` / Functions config for the expected secret if the dashboard asks you to set one).
4. Confirm `firebase deploy --only functions` has actually been run recently. There's no evidence in this pass of a recent deploy, and `PUSH_NOTIFICATIONS_NOT_DELIVERING_PROMPT.md` flagged the same open question earlier — a correct function sitting undeployed would look identical to this bug from the outside. Redeploy if there's any doubt.

## Verification

Have a friend send you a message from a different device/account while the app is backgrounded or closed. Confirm a push notification arrives showing the sender's name and the message text, and that tapping it opens that conversation thread directly (the routing code for this is already in place — this step is really confirming the whole pipeline end to end, not testing anything new).
