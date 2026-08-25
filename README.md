# Ralli

**Life, on the hour.**

Ralli is a native iOS social app built around one idea: capture one honest, unedited moment of your day, once per hour, and send it directly to the specific friends you choose — not broadcast to a public feed by default.

> Bundle ID: `com.ej.explog` · formerly developed under the working name **"Explog"**

Share one honest moment a day with your closest friends, discover what's happening nearby, and never miss a plan again.

---

## Table of Contents

- [Why Ralli Exists](#why-ralli-exists)
- [Design Principles](#design-principles)
- [Features](#features)
- [Technical Architecture](#technical-architecture)
- [Project Status](#project-status)
- [Framing for Writing About Ralli](#framing-for-writing-about-ralli)

---

## Why Ralli Exists

Ralli is a direct reaction against the dominant social media pattern of the last decade: performance for an algorithm, curated highlight reels, public metrics (likes, followers, virality) as the primary currency, and content optimized for strangers rather than close friends.

Its positioning is closer to what BeReal pioneered — an authentic, prompted capture — but expands the concept significantly:

- **Hourly cadence** instead of once-daily
- **Recipient-scoped sharing** — you choose who sees each moment, not an all-or-nothing broadcast
- **A full secondary layer** of features (local place discovery, real-time meetup coordination, integrated chat) built around that core hourly-capture habit

---

## Design Principles

A few principles recur throughout the product's design decisions:

- **Recipient-scoped by default, not broadcast.** A log goes to the specific friend(s) selected — never the whole friend list. This was a deliberately engineered constraint, enforced server-side.
- **Honesty over production value.** No filters, no heavy editing tools beyond basic stickers/text/drawing. The captured moment stays close to raw.
- **Hourly cadence, not daily.** The whole product reinforces "what are you doing *this hour*" — a live per-hour countdown on the home screen, an hour-scoped navigation model, and a cooldown that aligns to the top of each clock hour rather than a rolling 60-minute timer.
- **Never crop a user's footage.** Video is always shown in full, aspect-ratio-correct, letterboxed if necessary — never cropped to fill a container.
- **What you see while creating is what gets sent.** Post-capture edits (text, stickers, drawing) render identically at every downstream stage — captured, previewed, sent, viewed — with no surprise cropping or repositioning.
- **Warm, human, calm visual identity.** A single confident brand accent (`#FF5A5F` light / `#FF7B7F` dark) used sparingly against a quiet neutral canvas, with one primary accent action per screen. Full light/dark mode support is an area of ongoing refinement.
- **Real names, real relationships.** Built around a genuine friend graph (mutual following/friend requests) rather than public follower counts, though the Places layer supports public, location-scoped discovery for anyone.

---

## Features

### Logs — the hourly capture
The foundational unit of the app: a short video or photo captured once per hour and sent to one or more friends, a group, or optionally posted publicly via Places. Each log carries a burned-in timestamp overlay, an optional caption, optional stickers/drawing, and an optional mute toggle for video. Capture is hard landscape-only, with a full-bleed viewfinder that survives a live camera flip mid-recording.

### Pulse — the home feed
The home/inbox screen: friends and groups ordered by recency of interaction, with unread indicators, quick filters (All, Unread, Today, Streaks, Groups), and an "All Friends" view with hour-by-hour navigation across your whole friend group.

### Friend-pairing / one-on-one viewing
Tapping into a friend opens a paired, stacked view — their log for the current hour on top, your log to *that specific friend* underneath — with reactions and replies overlaid.

### Places — local discovery
A public, location-tagged content layer separate from friends-only sharing. Users post video/photo publicly to a real-world location; anyone can browse before deciding to go. Supports likes, comments, view counts, bookmarking, and sharing a place to a friend via chat.

### Beacons — real-time meetup coordination
A live, time-boxed "I'm here, come join" mechanic. Drop a Beacon with a start time, capacity, description, and public/friends-only visibility. Beacons expire (currently a 6-hour window) both server-side and in local caching.

### Daily Recap (Daily Vlog)
An automatically assembled highlight reel stitched from a user's own hourly logs across a day, navigable clip-by-clip, with a "download to Photos" export.

### Chat / messaging
Real-time one-on-one and group messaging built on the **Stream Chat SDK** (`stream-chat-swift` / `stream-chat-swiftui`), with custom features layered on top — e.g., reacting to a friend's log posts a message showing the emoji reaction overlaid on a snapshot of that log.

### Profile
A main profile view (Highlights — public Places posts, plus stats), an edit-profile flow (name, handle, bio, avatar with crop support), and settings (account, notifications, privacy/support links).

### Social graph
A mutual friend/follow system with request-and-accept semantics, underpinning delivery scoping for logs, Pulse ordering, and chat channel membership.

### Notifications
Push notifications via **Firebase Cloud Messaging** for incoming logs, chat messages, friend requests, streak-lapse reminders, and (in progress) nearby public posts. Per-category preferences are stored per-account and checked server-side, defaulting to on.

---

## Technical Architecture

### Platform and language
Native iOS, written entirely in **Swift** with **SwiftUI** for the UI layer and **SwiftData** for local, on-device persistence. No cross-platform framework — a from-scratch native build. Current snapshot: ~23,500 lines of Swift (client) and ~3,000 lines of JavaScript (server, Cloud Functions).

### Backend — Firebase
- **Firebase Authentication** — email/password sign-in, persistent keychain-backed sessions with silent background token refresh.
- **Cloud Firestore** — primary database (user profiles, logs, friend/follow relationships, chats, beacons, spots, likes/comments, device tokens). Security rules close most collections to direct client access (`allow read, write: if false`); nearly all mutations route through Cloud Functions callables so the client can't bypass business logic like recipient scoping or block-list filtering.
- **Cloud Functions** (Node.js, `firebase-functions/v2` `onCall`, plus `onSchedule` and `onRequest` handlers) — implements essentially all business logic: publishing logs, friend graph management, beacon creation/join/listing, Places search, likes/comments/view tracking, push notifications, and the Stream Chat webhook.
- **Cloud Storage** — all uploaded media (logs, avatars, beacon cover photos).
- **Firebase Cloud Messaging (FCM)** — push delivery on top of APNs.

### Real-time chat — Stream Chat SDK
`stream-chat-swift`, `stream-chat-swiftui`, and `stream-core-swift` handle message delivery, read state, and real-time infrastructure. Cloud Functions mint Stream user tokens and manage channel membership server-side, keeping the Stream API secret off the client. Custom features (like log-reaction messages) are built as a thin layer on top of Stream's primitives using structured `extraData`.

### Local persistence — SwiftData
`@Model` classes with `@Relationship` inverses: `Friend`, `Clip` (a single log), `Chat`, `Message` (legacy, being phased out in favor of Stream's own model), `SpotClip`/`Spot` (Places), and `Beacon`. Sync classes (`LogSync`, `BeaconSync`, etc.) pull server state into the local store and push local writes up via Cloud Functions callables, including retry-pending handling for offline sends.

### Camera and media pipeline
Built directly on **AVFoundation** — `AVCaptureSession` with `AVCaptureDevice.RotationCoordinator` for rotation handling and explicit front-camera mirroring control. Recording uses a custom architecture (`AVCaptureVideoDataOutput`/`AVCaptureAudioDataOutput` raw sample buffers through a custom asset-writer wrapper) instead of `AVCaptureMovieFileOutput`, specifically because the simpler API can't survive a live camera flip mid-recording. Post-capture overlays (text, stickers, drawing) are burned into the video's pixels via `AVMutableVideoComposition` and `AVVideoCompositionCoreAnimationTool` before upload.

### Design system
A centralized `Theme` module defines the visual language as adaptive, light/dark-aware color tokens (via a custom `Color(light:dark:)` initializer) — one coral accent, a small set of adaptive base/surface/text colors, and consistent `.rounded` typography used throughout, including the signature hour-stamp treatment.

### Development workflow
Developed in Xcode, version-controlled with Git, hosted on GitHub. Feature-branch workflow alongside `main`.

---

## Project Status

Ralli is in **active beta development**, distributed via **TestFlight** ahead of a full App Store release. The core feature set — hourly logs, Pulse, Places, Beacons, Daily Recap, chat, notifications, friend graph — is built and functional. Ongoing work includes:

- Performance optimization (log-load speed, message-send latency)
- UI consistency fixes (aspect-ratio handling across feed screens, light/dark mode support)
- Notification reliability
- Feature refinements (place-sharing to friends, beacon cover photos, likes/comments/view-count tracking)

---

## Framing for Writing About Ralli

Useful angles for essays, pitches, or articles:

- **The authenticity/anti-algorithm thesis** — positioned against curated social media, in the lineage of BeReal but differentiated by hourly (not daily) cadence and recipient-scoped (not broadcast) sharing.
- **The "close friends" thesis** — optimizes for small, real friend groups rather than public reach, follower counts, or algorithmic distribution: a bet that the future of social apps is smaller and more intentional, not bigger and more viral.
- **The multi-feature ecosystem thesis** — not just a camera app; it bundles hourly logging with local discovery (Places) and real-time coordination (Beacons), on the premise that "what my friends are doing right now," "where should I go," and "let's meet up" are naturally connected problems.
- **The engineering-craft angle** — a native, from-scratch iOS app with a deliberate, principled architecture: real-time chat via Stream rather than reinventing messaging infrastructure, careful attention to never degrading video quality/framing, and a security model where the client is never trusted to enforce its own business rules.
