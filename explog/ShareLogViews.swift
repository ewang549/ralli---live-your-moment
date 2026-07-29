import SwiftUI
import SwiftData

// The two things a finished capture can become, one screen each.
//
// The choice used to live *inside* one screen, behind a segmented control, so
// every send went through a picker before you could say who it was for. It's
// decided a screen earlier now — on the post-capture review — which is why
// these are two views rather than two branches: `PostCaptureReview` presents
// whichever one the user actually asked for, and neither carries the other's
// controls.

// MARK: - Friends

/// Friends-only share: pick who gets this log.
///
/// Each chat allows one log per clock hour (you choose when to log — you just
/// can't send twice to the same chat within the same hour; see
/// `Chat.cooldownRemaining`).
struct SendToFriendsView: View {
    let media: CapturedMedia
    let onSent: () -> Void
    /// Passed in explicitly rather than read from `@Environment` — this view is
    /// presented via a `.sheet` nested inside `CameraCaptureView`'s own
    /// `.fullScreenCover`, and a fullScreenCover's content does not reliably
    /// inherit an @Observable injected on the presenting view. A missing lookup
    /// there is a hard crash (see the same note on `CameraCaptureView.router`).
    let logSync: LogSync

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @Query private var friends: [Friend]

    /// One row in the "Send to" list.
    ///
    /// People come from the friend roster rather than from existing `Chat`
    /// rows: a chat is created the first time you actually message or send to
    /// someone, so listing chats meant a friend you'd just accepted — but never
    /// opened a thread with — simply wasn't offered here. Their DM is created
    /// on selection instead. Crews have no roster to derive from, so they're
    /// listed as the chats they already are.
    private enum Audience: Identifiable {
        case friend(Friend)
        case group(Chat)

        var id: UUID {
            switch self {
            case .friend(let friend): friend.id
            case .group(let chat): chat.id
            }
        }
    }

    @State private var selected: Set<UUID> = []

    /// The caption typed on the review screen. A plain `let`, not `@State`:
    /// this screen shows it and does not edit it. Captioning lives on
    /// `PostCaptureReview`, where the text sits under the hour stamp over the
    /// actual shot — so what you type is composed against the frame it will be
    /// read on. Back returns there to change it.
    let label: String
    /// The capture's real shape, so the preview is the log's shape rather than
    /// a fixed box that letterboxes it. See `Clip.videoAspectRatio`.
    let aspectRatio: Double
    /// Carried onto the clip so the recipient's player honours it.
    let isMuted: Bool

    init(media: CapturedMedia, initialLabel: String = "", aspectRatio: Double = 0,
         isMuted: Bool = false, logSync: LogSync, onSent: @escaping () -> Void) {
        self.media = media
        self.label = initialLabel
        self.aspectRatio = aspectRatio
        self.isMuted = isMuted
        self.logSync = logSync
        self.onSent = onSent
    }

    @State private var emoji = "✨"
    @State private var hueA = Double.random(in: 0...1)

    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Exactly what gets sent: the media at its own shape, with the
                // hour stamp and caption drawn over it the way every feed will
                // draw them. Read-only on purpose — this screen answers "who
                // gets this", and showing an editable field here is what let
                // the caption be one thing while composing and another by the
                // time it went out.
                LogPreviewCard(media: media, label: label, emoji: emoji, hueA: hueA,
                               aspectRatio: aspectRatio, isMuted: isMuted)

                if media.kind == .vibe {
                    VibeEmojiComposer(emoji: $emoji, hueA: $hueA)
                }

                List {
                    Section("Send to") {
                        ForEach(audiences) { audience in
                            let chat = existingChat(for: audience)
                            AudienceRow(name: name(of: audience),
                                        streak: chat?.streak ?? 0,
                                        chat: chat,
                                        isSelected: chat.map { selected.contains($0.id) } ?? false) {
                                toggle(audience)
                            }
                        }
                    }
                    .listRowBackground(Theme.baseElevated)
                }
                .scrollContentBackground(.hidden)

                Button {
                    send()
                } label: {
                    Text(selected.isEmpty ? "Pick at least one chat" : "Send to \(selected.count) chat\(selected.count == 1 ? "" : "s")")
                        .font(.headline)
                        .foregroundStyle(selected.isEmpty ? Theme.textSecondary : Theme.onCoral)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(selected.isEmpty ? Theme.sunken : Theme.coral))
                }
                .disabled(selected.isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(GlassBackground())
            .navigationTitle("Send log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
        }
    }

    // MARK: Audience

    /// Everyone you can send to: the roster first, then crews.
    private var audiences: [Audience] {
        let people = friends
            .filter { !$0.isMe }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return people.map(Audience.friend) + chats.filter(\.isGroup).map(Audience.group)
    }

    private func name(of audience: Audience) -> String {
        switch audience {
        case .friend(let friend): friend.name
        case .group(let chat): chat.displayName
        }
    }

    /// Read-only lookup — a row renders its streak and cooldown from the chat
    /// when there is one, and must not bring one into existence just to draw a
    /// list. The DM is created when the row is actually selected.
    private func existingChat(for audience: Audience) -> Chat? {
        switch audience {
        case .group(let chat): chat
        case .friend(let friend): chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
        }
    }

    private func toggle(_ audience: Audience) {
        let chat: Chat?
        switch audience {
        case .group(let group): chat = group
        case .friend(let friend): chat = me.map { Chat.dm(with: friend, me: $0, in: modelContext) }
        }
        guard let chat, chat.cooldownRemaining <= 0 else { return }
        if selected.contains(chat.id) {
            selected.remove(chat.id)
        } else {
            selected.insert(chat.id)
        }
    }

    private func send() {
        // An untyped caption stays empty — every surface that draws one already
        // skips the overlay for an empty string, so there is nothing to fill in.
        let finalLabel = label
        let calendar = Calendar.current
        var created: [Clip] = []
        /// Everyone the published copy is actually addressed to, gathered as the
        /// chats are walked. Without this the server only learned that you
        /// posted, never who for, and handed the log to every friend you have.
        var recipients: Set<String> = []
        for chat in chats where selected.contains(chat.id) {
            // Streak bumps on the first log of the day to that chat.
            let loggedTodayAlready = chat.clips.contains {
                $0.author?.isMe == true && calendar.isDateInToday($0.capturedAt)
            }
            let clip = Clip(author: me, chat: chat, capturedAt: .now, kind: media.kind,
                            assetFileName: media.assetFileName, label: finalLabel, emoji: emoji,
                            hueA: hueA, hueB: (hueA + 0.15).truncatingRemainder(dividingBy: 1))
            // Both measured on the review screen: the shape every surface sizes
            // its container to, and whether the recipient hears this.
            clip.videoAspectRatio = aspectRatio
            clip.isMuted = isMuted
            modelContext.insert(clip)
            created.append(clip)
            chat.clips.append(clip)
            chat.lastSentAt = .now
            if !loggedTodayAlready { chat.streak += 1 }
            // A DM's one other member, or every member of a crew. Demo rows
            // have no uid and contribute nothing — there's no account on the
            // server for them to reach.
            for member in chat.members where !member.isMe && !member.remoteUID.isEmpty {
                recipients.insert(member.remoteUID)
            }
        }
        try? modelContext.save()

        // The clip is already on screen and in the cache; sharing it is a
        // background concern. Dismiss first so a slow upload never holds up the
        // capture flow, and publish the media once.
        //
        // Only the first copy is published: sending the same capture to three
        // chats is one log to your friends, not three. It carries the union of
        // every selected chat's members, so one upload still reaches exactly
        // the people who were picked and nobody else.
        if let first = created.first {
            let addressed = Array(recipients)
            // Recorded on the clip as well as passed here, so a retry after a
            // failed upload goes to the same people rather than reverting to
            // the whole roster (see `Clip.intendedRecipientUIDs`).
            first.intendedRecipientUIDs = addressed
            try? modelContext.save()

            // A selection that resolves to no real account — a roster of demo
            // rows only — has nobody on the server to receive it. Publishing
            // anyway would mean an unaddressed log, which the server still
            // reads as "all your friends": the exact leak this scoping closes.
            // The capture stays local, the same as it does with no network.
            if !addressed.isEmpty {
                Task { await logSync.publish(first, context: modelContext, recipientUids: addressed) }
            }
        }

        dismiss()
        onSent()
    }
}

// MARK: - Public place post

/// Post this log at a place: give it a name, say where it was, and choose who
/// can see it.
///
/// Its own screen rather than a branch of the friends picker — posting
/// somewhere public is a different act with different inputs, and burying it
/// behind a segmented control meant every send paid for the choice.
struct PublicPlacePostView: View {
    let media: CapturedMedia
    let onSent: () -> Void
    /// Same reasoning as `SendToFriendsView.logSync`.
    let logSync: LogSync

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var friends: [Friend]

    /// Who can see a placed log.
    ///
    /// Both choices pin the log to the place — that's the point of this screen.
    /// What differs is reach: `everyone` also mirrors it onto the place's public
    /// feed, `friends` keeps it to the people who already follow you.
    private enum PostAudience: String, CaseIterable, Identifiable {
        case everyone, friends
        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyone: "Public"
            case .friends: "Friends only"
            }
        }

        var footnote: String {
            switch self {
            case .everyone: "Anyone on Ralli can see this on the place's feed."
            case .friends: "Only your friends see this — it won't appear on the place's public feed."
            }
        }
    }

    @State private var name: String
    @State private var spot: Spot?
    @State private var audience: PostAudience = .everyone
    @State private var showSpotSearch = false

    /// True from the instant Post is tapped. `dismiss()` doesn't take the
    /// button off screen until SwiftUI gets round to it, so without this a
    /// fast second tap ran `post()` again and wrote a second clip.
    @State private var isSending = false

    /// Identifies the capture this composer is posting, not the clip row it
    /// writes — so if a double tap does slip through, both attempts carry the
    /// same key and the server keeps one log.
    @State private var requestID = UUID().uuidString

    @State private var emoji = "✨"
    @State private var hueA = Double.random(in: 0...1)

    /// See `SendToFriendsView` — same two fields, same reasons.
    let aspectRatio: Double
    let isMuted: Bool

    /// `initialName` seeds the name from the caption typed on the review
    /// screen. Editable here, unlike the friends picker's caption: a place
    /// post's name is a different thing from a log's caption — it titles the
    /// post on the place's feed — so this screen is where it belongs.
    init(media: CapturedMedia, initialName: String = "", aspectRatio: Double = 0,
         isMuted: Bool = false, logSync: LogSync, onSent: @escaping () -> Void) {
        self.media = media
        self.aspectRatio = aspectRatio
        self.isMuted = isMuted
        self.logSync = logSync
        self.onSent = onSent
        _name = State(initialValue: initialName)
    }

    private var me: Friend? { friends.first { $0.isMe } }

    /// A placed post needs somewhere to land — the Places feed is organised by
    /// place, and an unplaced post has no home.
    private var canPost: Bool { spot?.remoteID.isEmpty == false }

    /// What the button actually obeys: having a place is necessary, but a send
    /// already on its way is the other reason not to start another one.
    private var canTapPost: Bool { canPost && !isSending }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LogPreviewCard(media: media, label: name, emoji: emoji, hueA: hueA,
                               aspectRatio: aspectRatio, isMuted: isMuted)

                if media.kind == .vibe {
                    VibeEmojiComposer(emoji: $emoji, hueA: $hueA)
                }

                VStack(spacing: 14) {
                    field("Name") {
                        TextField("Give this log a name", text: $name)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Theme.baseRaised))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    field("Location") { locationPicker }

                    field("Audience") {
                        Picker("Audience", selection: $audience) {
                            ForEach(PostAudience.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Text(audience.footnote)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer(minLength: 0)

                Button {
                    post()
                } label: {
                    Text(canPost ? "Post to \(spot?.name ?? "")" : "Pick a place first")
                        .font(.headline)
                        .foregroundStyle(canPost ? Theme.onCoral : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(canPost ? Theme.coral : Theme.sunken))
                        .opacity(isSending ? 0.6 : 1)
                }
                .disabled(!canTapPost)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(GlassBackground())
            .navigationTitle("Post to a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
            }
            .sheet(isPresented: $showSpotSearch) {
                SpotSearchView { spot = $0 }
            }
        }
    }

    /// A labelled row, so the three inputs read as the three fields they are.
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private var locationPicker: some View {
        Button {
            showSpotSearch = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: spot == nil ? "magnifyingglass" : "mappin.circle.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot?.name ?? "Pick a place")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(spot == nil ? Theme.textSecondary : Theme.textPrimary)
                    if let address = spot?.address, !address.isEmpty {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if spot != nil {
                    Text("Change")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background { RoundedRectangle(cornerRadius: 14).fill(Theme.baseElevated) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Writes the post locally, then publishes it.
    ///
    /// The author's own `Clip` is always written, so the capture survives a
    /// failed upload exactly as a friends-only log does. A `SpotClip` — the
    /// local mirror of the Places feed — is written only for a public post, so
    /// a friends-only one can't turn up on a feed it was explicitly kept off.
    /// The `SpotClip` is stamped with the server's log id afterwards so the next
    /// public sync updates that row instead of adding a duplicate.
    private func post() {
        guard !isSending, let spot, !spot.remoteID.isEmpty else { return }
        // Closes the door before anything else runs: `.disabled` only takes
        // effect on the next SwiftUI update, this takes effect now.
        isSending = true
        // Same as a friends-only log: no caption means no caption.
        let finalLabel = name
        let hueB = (hueA + 0.15).truncatingRemainder(dividingBy: 1)

        let clip = Clip(author: me, chat: nil, capturedAt: .now, kind: media.kind,
                        assetFileName: media.assetFileName, label: finalLabel, emoji: emoji,
                        hueA: hueA, hueB: hueB)
        // Recorded for both audiences: the place is where this was filmed, and
        // that stays true whoever ends up seeing it.
        clip.intendedSpotID = spot.remoteID
        // Keyed to the capture, not to this row — see `requestID`.
        clip.clientRequestID = requestID
        clip.videoAspectRatio = aspectRatio
        clip.isMuted = isMuted
        modelContext.insert(clip)

        var spotClip: SpotClip?
        if audience == .everyone {
            let mirror = SpotClip(spot: spot,
                                  authorName: me?.name ?? "You",
                                  authorUID: me?.remoteUID ?? "",
                                  label: finalLabel,
                                  emoji: emoji,
                                  hueA: hueA,
                                  hueB: hueB,
                                  capturedAt: .now,
                                  // Without these the Places card had no idea
                                  // the post carried real media and always drew
                                  // the emoji placeholder.
                                  kind: media.kind,
                                  assetFileName: media.assetFileName)
            // Your own post shows your own photo straight away, rather than
            // waiting for the public feed to sync your own log back to you.
            mirror.authorAvatarURL = me?.avatarURL ?? ""
            mirror.authorAvatarEmoji = me?.emoji ?? ""
            // Same measurement as the `Clip` above, so the Places feed sizes
            // its cards to the real shape rather than guessing.
            mirror.videoAspectRatio = aspectRatio
            modelContext.insert(mirror)
            spotClip = mirror
        }
        try? modelContext.save()

        let wireAudience: LogSync.Audience = audience == .everyone
            ? .publicAt(spotID: spot.remoteID)
            : .friends

        Task {
            await logSync.publish(clip, context: modelContext, audience: wireAudience)
            if let spotClip {
                spotClip.remoteID = clip.remoteID
                spotClip.remoteURLString = clip.remoteURLString
                try? modelContext.save()
            }
        }

        dismiss()
        onSent()
    }
}

// MARK: - Shared composer pieces

/// The log exactly as it will be sent, previewed at the top of whichever share
/// screen you're on: the media whole, at its own shape, with the hour stamp and
/// caption over it.
///
/// Read-only by design. This is a confirmation of what the review screen
/// composed, not a second place to compose it — the caption is drawn here in
/// the same type the feeds use, so what you see is what lands.
private struct LogPreviewCard: View {
    let media: CapturedMedia
    let label: String
    let emoji: String
    let hueA: Double
    /// The capture's measured width ÷ height. 0 when it couldn't be read, in
    /// which case the card falls back to the landscape capture shape.
    var aspectRatio: Double = 0
    var isMuted: Bool = false

    private var ratio: Double {
        aspectRatio > 0 ? aspectRatio : Clip.defaultAspectRatio
    }

    var body: some View {
        preview
            // Shaped by the media rather than pinned to a fixed height, so the
            // card *is* the log's shape and there are no bars that don't line
            // up with the frame's real edges.
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(stampBlock)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }

    /// The hour banner with the caption beneath it — the same two-line block,
    /// in the same order and type, that `PostCaptureReview` composes against.
    private var stampBlock: some View {
        VStack(spacing: 6) {
            HourOverlay(date: .now)
            if !label.isEmpty {
                Text(label)
                    .font(.logCaptionCompact)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
                    .padding(.horizontal, 20)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var preview: some View {
        switch media.kind {
        case .vibe:
            VibeClipView(emoji: emoji, label: label, hueA: hueA,
                         hueB: (hueA + 0.15).truncatingRemainder(dividingBy: 1))
        case .video, .photo:
            let clip = Clip(author: nil, chat: nil, capturedAt: .now, kind: media.kind,
                            assetFileName: media.assetFileName, label: label, emoji: emoji,
                            hueA: hueA, hueB: hueA)
            // `.fit` inside a card already cut to the media's own ratio, so the
            // frame is shown whole with nothing to letterbox against.
            ClipView(clip: muted(clip), contentMode: .fit)
        }
    }

    /// The preview honours the mute toggle, so silencing a log is audible (or
    /// rather, inaudible) before it is sent rather than only on arrival.
    private func muted(_ clip: Clip) -> Clip {
        clip.isMuted = isMuted
        return clip
    }
}

/// Emoji + hue picker, shown only for a composed "vibe" clip — the one kind of
/// log with no real media behind it to look at.
private struct VibeEmojiComposer: View {
    @Binding var emoji: String
    @Binding var hueA: Double

    private let emojiOptions = ["✨", "💻", "☕️", "🏃", "🎧", "🌳", "🍜", "🌆", "📚", "🎮"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(emojiOptions, id: \.self) { option in
                    Button {
                        emoji = option
                        hueA = Double.random(in: 0...1)
                    } label: {
                        Text(option)
                            .font(.system(size: 26))
                            .padding(8)
                            .background(
                                Circle().fill(emoji == option ? Theme.coralWash : Theme.baseRaised)
                            )
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 14)
    }
}

private struct AudienceRow: View {
    let name: String
    let streak: Int
    /// Nil until this destination has been sent to or messaged — a friend with
    /// no thread yet has nothing to be on cooldown for, and is always sendable.
    let chat: Chat?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = chat?.cooldownRemaining ?? 0
            let locked = remaining > 0
            Button(action: onTap) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .foregroundStyle(locked ? Theme.textSecondary : Theme.textPrimary)
                        if locked {
                            Text("next log in \(cooldownString(remaining))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        } else if streak > 0 {
                            Text("🔥 \(streak)")
                                .font(.caption)
                                .foregroundStyle(Theme.coral)
                        }
                    }
                    Spacer()
                    if locked {
                        Image(systemName: "hourglass")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Theme.coral : Theme.textSecondary)
                    }
                }
            }
            .disabled(locked)
        }
    }
}
