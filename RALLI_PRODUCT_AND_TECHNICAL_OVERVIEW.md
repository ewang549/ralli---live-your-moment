# Ralli: Product and Technical Overview

*A reference document for briefing AI tools on what Ralli is, why it exists, and how it's built.*

---

## 1. What Ralli Is

Ralli (bundle ID `com.ej.explog`, formerly developed under the working name "Explog") is a native iOS social app built around one core idea: **"Life, on the hour."** Instead of a curated highlight reel or an algorithmic feed competing for engagement, Ralli asks users to capture one honest, unedited moment of their day, once per hour, and send it directly to the specific friends they choose — not broadcast to a public audience by default.

The product is a direct reaction against the dominant social media pattern of the last decade: performance for an algorithm, curated highlight reels, public metrics (likes, followers, virality) as the primary currency, and content optimized for strangers rather than close friends. Ralli's positioning is closer to what BeReal pioneered (an authentic, once-a-day capture prompt) but expands the concept significantly: hourly cadence instead of once-daily, recipient-scoped sharing (you choose who sees each moment, not an all-or-nothing broadcast), and a full secondary layer of features (local place discovery, real-time meetup coordination, and integrated chat) built around that core hourly-capture habit.

### The one-line pitch
"Life, on the hour. Share one honest moment a day with your closest friends, discover what's happening nearby, and never miss a plan again."

---

## 2. Core Philosophy and Design Principles

A few principles recur throughout the product's design decisions, and are worth stating explicitly for anyone writing about the app:

- **Recipient-scoped by default, not broadcast.** When you send a log, it goes to the specific friend or friends you selected — not your entire friend list. This was a deliberately engineered constraint (and a real bug that had to be fixed multiple times during development — the server had to be taught to only deliver a log to its named recipients rather than defaulting to "everyone" when a recipient list was empty).
- **Honesty over production value.** No filters, no heavy editing tools beyond basic stickers/text/drawing. The captured moment is close to raw.
- **Hourly cadence, not daily.** The app's rhythm is built around "what are you doing *this hour*," reinforced through the whole product: a live per-hour countdown/prompt on the home screen, an hour-scoped navigation model that lets you step backward and forward through your friends' hours, and a "cooldown" mechanic that aligns to the top of each clock hour rather than a rolling 60-minute timer from your last post.
- **Never crop a user's footage.** A hard product rule enforced repeatedly through development: video is always shown in full, aspect-ratio-correct, letterboxed if necessary — never cropped to fill a container. Screens are sized to match the content's shape wherever possible, rather than the content being forced to match an arbitrary container shape.
- **What you see while creating is what gets sent.** Post-capture edits (text, stickers, drawing) are positioned exactly where the user places them and should render identically at every point downstream — captured, previewed, sent, and viewed by the recipient — with no surprise cropping, resizing, or repositioning between those stages.
- **Warm, human, calm visual identity.** A single confident brand accent color (a warm coral, `#FF5A5F` in light mode / `#FF7B7F` in dark mode) used sparingly against a quiet neutral canvas, with one primary accent action per screen rather than color used decoratively throughout. The interface adapts properly to both system light and dark mode (an area of ongoing refinement, since much of the log-viewing UI was originally built dark-mode-only and is being retrofitted to respect the system appearance setting).
- **Real names, real relationships.** Ralli is built around a genuine friend graph (mutual following/friend requests) rather than public follower counts as the primary social currency, though a "Places" layer does support public, location-scoped content discovery for anyone (not just friends).

---

## 3. Core Features

### Logs (the hourly capture)
The foundational unit of the app. A "log" is a short video or photo captured once per hour and sent to one or more specific friends, a group, or (optionally) posted publicly to a location via Places. Each log carries:
- A burned-in timestamp overlay (large, bold, rounded-font "2:00 PM" style stamp) — the same visual treatment from the camera viewfinder through to final playback, so a log carries one consistent time-stamp identity throughout its life.
- An optional caption, entered immediately after capture (not at send time), rendered in a smaller font directly beneath the time stamp.
- Optional stickers (emoji) and freehand drawing, positioned by the user and burned into the final media.
- An optional mute toggle for video logs (audio can be muted before sending, video-only — not applicable to photos).
- A hard landscape-only capture orientation, with camera controls redesigned around a full-bleed, borderless landscape viewfinder.

Camera details worth knowing: capture supports flipping between front and back cameras (including, critically, continuing to record through a camera flip mid-take rather than ending the clip — an architectural decision to record via raw sample-buffer capture and a custom asset writer rather than Apple's higher-level movie-file-output API, specifically because the simpler API can't survive a live camera swap without truncating the file). The camera is also designed to force landscape orientation even if the user's phone has the system-wide rotation lock enabled, since the capture experience is landscape-only by design.

### Pulse (the home feed)
Pulse is the home/inbox screen: a list of friends and groups, ordered by recency of interaction — specifically, whoever most recently sent you something (a log or a message) or whom you most recently reached out to surfaces at the top, in either direction. An unread indicator lights up specifically for incoming activity you haven't yet viewed (deliberately excluding your own outgoing sends from triggering it). A prominent "send your log for the hour" prompt sits at the top of Pulse, along with quick filters (All, Unread, Today, Streaks, Groups) and an "All Friends" entry point that shows everyone's latest clip for the current hour in one scrollable list, with hour-by-hour navigation (swipe or tap to step to the previous/next hour across your whole friend group at once).

### Friend-pairing / one-on-one viewing
Tapping into a specific friend from Pulse opens a paired, stacked view: their log for the current hour on top, your own log to that specific friend underneath, with reaction (emoji) and reply affordances overlaid on the video. This view is scoped per-conversation — critically, "your own log" here reflects what you actually sent to *that specific friend*, not just the most recent thing you filmed (an important distinction, since an earlier bug caused a log sent privately to one friend to visually appear to have gone to everyone, purely because the display logic wasn't properly scoped to the specific chat).

### Places (local discovery)
A public, location-tagged content layer, separate from the friends-only log-sharing flow. Users can post a video/photo publicly to a specific real-world location (a restaurant, park, landmark, etc.), and anyone can browse Places to see real user-submitted video from a spot before deciding to go — positioned as an authentic alternative to stock photography or paid advertising on typical map/review apps. Places supports likes, comments, view counts, bookmarking, and sharing a specific place directly to a friend via chat (which should let the recipient tap through to that place's real detail page, including its video highlights).

### Beacons (real-time meetup coordination)
A live, time-boxed "I'm here, come join" mechanic. A user can drop a Beacon at a location with a start time, capacity, description, and a public/friends-only visibility setting; friends (or the public, if opened up) can see who's hosting, how many spots remain, and join. Beacons are time-sensitive by nature — they're built to be treated as expired and effectively invisible a fixed window (currently 6 hours) after their start time, both in what the server returns and in local caching.

### Daily Recap (Daily Vlog)
An automatically assembled short highlight reel stitched together from a user's own hourly logs across a day, viewable and navigable clip-by-clip (not just day-by-day), with a "download to Photos" export that stitches the full day into one continuous video file.

### Chat / messaging
Real-time one-on-one and group messaging, built on the Stream Chat SDK (`stream-chat-swift` / `stream-chat-swiftui`) rather than a custom-built messaging backend — Stream handles message delivery, read state, and the underlying real-time infrastructure, while Ralli's own backend layers in custom features on top (e.g., a "reaction" mechanic where reacting to a friend's log posts a message into your chat with that friend showing the emoji reaction overlaid on a snapshot of the actual log being reacted to, rather than a plain text notification).

### Profile
A personal profile screen split into three concerns: a main profile view (showing "Highlights" — the user's own public Places posts, tappable to open a real player, plus basic stats), an edit-profile flow (name, handle, bio, avatar with crop support), and a settings screen (account management, notification preferences, and privacy/support links).

### Social graph
A mutual friend/follow system with request-and-accept semantics (not one-directional public following as the primary mechanic, though public content in Places can be viewed by anyone). Explicit product rules exist around this (e.g., you cannot follow/friend yourself — a real bug that had to be guarded against), and the friend graph underpins delivery scoping for logs, Pulse ordering, and chat channel membership.

### Notifications
Push notifications (via Firebase Cloud Messaging) cover: a friend sending you a log, a new chat message, friend request received/accepted, streak-lapse reminders (a nudge if you haven't posted in a while), and (in progress) a friend posting publicly to a location near you. Users have granular per-category notification preferences in Settings, stored per-account and checked server-side before any push is sent, defaulting to "on" for a new/unset user rather than silently suppressing notifications for anyone who hasn't explicitly configured preferences yet.

---

## 4. Technical Architecture

### Platform and language
Ralli is a **native iOS application**, written entirely in **Swift** using **SwiftUI** for the UI layer and **SwiftData** (Apple's modern successor to Core Data) for local, on-device persistence. There is no cross-platform framework (no React Native, Flutter, etc.) — this is a from-scratch native build. As of the current codebase snapshot: roughly **23,500 lines of Swift** for the client and **~3,000 lines of JavaScript** for the server (Cloud Functions).

### Backend: Firebase
The backend runs entirely on **Google Firebase**:
- **Firebase Authentication** handles email/password sign-in and account/session management, using Firebase's default persistent (keychain-backed) session storage — sessions are meant to last indefinitely without requiring re-login, refreshing access tokens silently in the background.
- **Cloud Firestore** is the primary database for everything server-side: user profiles, logs (the `logs` collection, with recipient-scoping fields), friend/follow relationships, chats, beacons, spots (places), likes/comments, and device-token records for push notifications. Firestore's security rules are configured defense-in-depth style: most collections are closed to direct client reads/writes entirely (`allow read, write: if false`), with essentially all mutations routed through server-side Cloud Functions callables instead of direct client Firestore access — meaning the client can't bypass business logic (like recipient scoping or block-list filtering) by writing to Firestore directly.
- **Cloud Functions** (Node.js, using the modern `firebase-functions/v2` `onCall` callable pattern, plus a handful of `onSchedule` scheduled functions and `onRequest` webhook endpoints) implement essentially all business logic: publishing a log, listing a friend's or the public's logs, managing the friend graph, beacon creation/join/listing, Places search and spot management, likes/comments/view-count tracking, sending push notifications, and receiving Stream Chat's webhook for message-triggered push notifications.
- **Cloud Storage** holds all uploaded media (video/photo logs, avatars, beacon cover photos where applicable).
- **Firebase Cloud Messaging (FCM)** delivers push notifications, built on top of standard APNs (Apple Push Notification service) device registration.

### Real-time chat: Stream Chat SDK
Rather than building custom real-time messaging infrastructure, Ralli integrates **Stream's Chat SDK** (`stream-chat-swift` and `stream-chat-swiftui`, plus a `stream-core-swift` shared dependency) for the actual message-sending/receiving/read-state layer. Ralli's own Cloud Functions mint Stream user tokens and manage channel membership server-side (never exposing the Stream API secret to the client), while custom features (log-reaction messages with an image overlay, for example) are built as a thin layer on top of Stream's primitives — custom message types with structured metadata (`extraData`) that the client interprets specially, alongside Stream's native message attachment support for images.

### Local persistence: SwiftData
The on-device data model is built with SwiftData `@Model` classes and `@Query`/`FetchDescriptor`-based fetching, with explicit `@Relationship` inverses connecting the core entities: `Friend` (a person, including yourself, flagged via `isMe`), `Clip` (a single log — video or photo, with author, capture time, caption, recipients, mute state, etc.), `Chat` (a conversation — 1:1 or group — with its own clips and messages), `Message` (a legacy local chat-message model, being phased out in favor of Stream's own message model for actual text chat), `SpotClip`/`Spot` (Places' public content and the locations they're tied to), and `Beacon` (a meetup). A synchronization layer (`LogSync`, `BeaconSync`, and related sync classes) is responsible for pulling server state down into the local SwiftData store and pushing local writes (new logs, new beacons, etc.) up to the server via the Cloud Functions callables, including a retry-pending mechanism for sends that fail while offline.

### Camera and media pipeline
Built on **AVFoundation** directly (not a third-party camera library): `AVCaptureSession` for the capture pipeline, with a modern `AVCaptureDevice.RotationCoordinator`-based approach to handling device rotation (rather than manually computing interface-orientation-to-rotation-angle mappings), explicit control over front-camera mirroring, and — notably — a custom recording architecture using `AVCaptureVideoDataOutput`/`AVCaptureAudioDataOutput` raw sample buffers written through a custom asset-writer wrapper, specifically chosen over the simpler `AVCaptureMovieFileOutput` API because the simpler API cannot survive a live camera-flip mid-recording without prematurely finalizing (ending) the video file. Post-capture editing (text, stickers, drawing) uses `AVMutableVideoComposition` and `AVVideoCompositionCoreAnimationTool` to burn user-placed overlays directly into the video's pixels at their exact chosen position before upload, rather than layering them as a separate, potentially-misaligned rendering pass at playback time.

### Design system
A centralized `Theme` module defines the entire visual language as adaptive, light/dark-aware color tokens (built on a custom `Color(light:dark:)` initializer) rather than hardcoded colors scattered through the UI — a single coral accent color, a small set of adaptive base/surface/text colors, and consistent typography (`.rounded` design system fonts) used for the app's signature "hour stamp" treatment on every log.

### Development workflow
The project is developed in Xcode, version-controlled with Git, hosted on GitHub. The team has used a feature-branch workflow (e.g., a `social-graph-phase-1` branch used for an extended stretch of feature work) alongside `main`, with an emphasis on eventually merging completed work back so that clean builds and archives reliably reflect the latest state.

---

## 5. Current Stage

As of this writing, Ralli is in **active beta development**, distributed via **TestFlight** ahead of a full App Store release. The core feature set (hourly logs, Pulse, Places, Beacons, Daily Recap, chat, notifications, friend graph) is built and functional, with an ongoing punch-list of polish items: performance optimization (log-load speed, message-send latency), UI consistency fixes (aspect-ratio handling across different feed screens, light/dark mode support), notification reliability, and a backlog of feature refinements (place-sharing to friends, beacon cover photos, likes/comments/view-count tracking) at varying stages of completion.

---

## 6. How Ralli Is Actually Being Built: an AI-Assisted Development Workflow

Ralli's development process is itself a notable part of the story — the app is being built by a single founder using AI coding agents as the primary implementation engine, in a tight, structured loop rather than an ad-hoc "ask the AI to build stuff" pattern. Worth documenting precisely, since it's a real, specific workflow rather than a vague "I used AI to help":

**The core loop.** The founder identifies a bug or a desired feature (often from personally using the app, or from screenshots of the actual UI showing something broken or off), and rather than describing it vaguely to a coding agent, the process runs through a research-first pipeline:

1. **Investigation before instruction.** Before any code is written, the actual codebase is read and traced — the real file, the real line numbers, the real function names — to find the *actual* root cause of a reported symptom, rather than guessing at a fix from the bug description alone. This step is treated as non-negotiable: multiple times during development, a bug reported by the founder was *not* where it initially seemed to be. A recurring, important example: a "sends to everyone instead of one friend" bug was reported and investigated repeatedly, with the send/delivery code re-verified correct each time — the actual root cause turned out to be a *display* bug (a friend-pairing screen showing the wrong cached clip), not a delivery bug at all, and was only found once the investigation stopped assuming the obvious explanation and re-traced the problem from scratch.
2. **Grounded, detailed prompt files, not one-line asks.** Once the real root cause is understood, a detailed markdown "prompt file" is written — citing exact file paths, exact line numbers, exact function names, and exact proposed code changes — and handed to Claude Code (Anthropic's agentic coding CLI tool) to implement. These aren't casual requests like "fix the camera bug"; they read more like an engineering design doc or a code review comment thread: here's the file, here's the line, here's why it's wrong, here's the specific fix, here's how to verify it worked. Dozens of these prompt files accumulated over the course of development, each named for the specific cluster of fixes it covers (e.g., a prompt covering a camera-preview rotation bug, another covering profile-picture cropping and video-viewer sizing, another covering push-notification delivery, etc.).
3. **Verification, not blind trust.** A recurring discipline in this workflow is *re-checking* whether a previously-written fix actually landed correctly in the code, before writing a new prompt — because AI coding agents (like any collaborator) don't always implement things exactly as specified, and because the founder has repeatedly caught cases where a fix was correctly written in the code but never actually reached the build being tested (see below). Verification is treated as a first-class step, not an afterthought — including, at times, spinning up dedicated investigation passes whose only job is to read the current state of specific files and report, in plain terms, whether a claimed fix is genuinely present, partially present, or entirely absent.
4. **Debugging the *process*, not just the app.** A meaningful share of the actual problem-solving in this workflow has been about the development pipeline itself, not just the app's code — for instance, discovering that a batch of fixes that were correctly written and even correctly committed to git were sitting on a feature branch (`social-graph-phase-1`) that was never merged into `main`, meaning a build compiled from `main` would never reflect any of that work no matter how many times it was rebuilt. Catching this kind of gap (a fix existing in the repository but not in the actual branch or build being tested) has been just as important to shipping progress as fixing the underlying app bugs.

**Why this workflow matters as a story, not just a process note:** it represents a specific, disciplined way of using AI agents to build production software as a solo or small-team founder — not "vibe coding" from vague prompts, but a rigorous investigate-then-instruct-then-verify loop that treats the AI coding agent as a capable but literal-minded collaborator who needs precise, code-grounded instructions and whose output needs to be checked against the real, running app rather than assumed correct. It's also a workflow that surfaces a genuinely underappreciated failure mode in AI-assisted development: the code can be entirely correct and the feature can still not work for the end user, because of a mundane software-engineering gap (an unmerged branch, a stale build, an uncommitted change) that has nothing to do with whether the AI wrote good code.

---

## 7. Suggested Framing for Essays / Written Content About Ralli

If you're using this document to brief an AI for writing essays, pitches, or articles about Ralli, useful angles include:
- **The authenticity/anti-algorithm thesis**: positioning Ralli against curated social media, in the lineage of BeReal but meaningfully differentiated by hourly (not daily) cadence and recipient-scoped (not broadcast) sharing.
- **The "close friends" thesis**: Ralli optimizes for small, real friend groups rather than public reach, follower counts, or algorithmic distribution — a bet that the future of social apps is smaller and more intentional, not bigger and more viral.
- **The multi-feature ecosystem thesis**: Ralli isn't just a camera app — it bundles hourly logging with local discovery (Places) and real-time coordination (Beacons), betting that "what my friends are doing right now" and "where should I go" and "let's meet up" are naturally connected problems for a friend-group-centric app to solve together.
- **The AI-native development story**: Ralli is being built through a disciplined, research-first AI-assisted workflow — investigate the real codebase, write precise engineering-grade prompts grounded in actual file/line detail, verify the result against the running app rather than trusting it blindly, and treat gaps in the development *process* itself (branches, builds, deploys) as seriously as gaps in the code. A compelling angle for essays specifically about building software with AI in 2025-2026: that the hard part isn't getting an AI to write code, it's building the surrounding discipline (investigation, precision, verification) that makes AI-written code actually reliable in production.
- **The engineering-craft angle**: a native (not cross-platform), from-scratch iOS app built with a deliberate, principled technical architecture — real-time chat via Stream rather than reinventing messaging infrastructure, careful attention to never degrading video quality/framing, and a security model where the client is never trusted to enforce its own business rules (all real logic lives server-side behind Cloud Functions).
