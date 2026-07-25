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
    @State private var label: String

    /// `initialLabel` seeds the caption from any text added on the review screen.
    init(media: CapturedMedia, initialLabel: String = "", logSync: LogSync, onSent: @escaping () -> Void) {
        self.media = media
        self.logSync = logSync
        self.onSent = onSent
        _label = State(initialValue: initialLabel)
    }

    @State private var emoji = "✨"
    @State private var hueA = Double.random(in: 0...1)

    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LogPreviewCard(media: media, label: label, emoji: emoji, hueA: hueA)

                if media.kind == .vibe {
                    VibeEmojiComposer(emoji: $emoji, hueA: $hueA)
                }

                TextField("What are you up to?", text: $label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.baseRaised))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

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
        let finalLabel = label.isEmpty ? "right now" : label
        let calendar = Calendar.current
        var created: [Clip] = []
        for chat in chats where selected.contains(chat.id) {
            // Streak bumps on the first log of the day to that chat.
            let loggedTodayAlready = chat.clips.contains {
                $0.author?.isMe == true && calendar.isDateInToday($0.capturedAt)
            }
            let clip = Clip(author: me, chat: chat, capturedAt: .now, kind: media.kind,
                            assetFileName: media.assetFileName, label: finalLabel, emoji: emoji,
                            hueA: hueA, hueB: (hueA + 0.15).truncatingRemainder(dividingBy: 1))
            modelContext.insert(clip)
            created.append(clip)
            chat.clips.append(clip)
            chat.lastSentAt = .now
            if !loggedTodayAlready { chat.streak += 1 }
        }
        try? modelContext.save()

        // The clip is already on screen and in the cache; sharing it is a
        // background concern. Dismiss first so a slow upload never holds up the
        // capture flow, and publish the media once.
        //
        // Only the first copy is published: sending the same capture to three
        // chats is one log to your friends, not three.
        if let first = created.first {
            Task { await logSync.publish(first, context: modelContext) }
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

    @State private var emoji = "✨"
    @State private var hueA = Double.random(in: 0...1)

    /// `initialName` seeds the name from any text added on the review screen.
    init(media: CapturedMedia, initialName: String = "", logSync: LogSync, onSent: @escaping () -> Void) {
        self.media = media
        self.logSync = logSync
        self.onSent = onSent
        _name = State(initialValue: initialName)
    }

    private var me: Friend? { friends.first { $0.isMe } }

    /// A placed post needs somewhere to land — the Places feed is organised by
    /// place, and an unplaced post has no home.
    private var canPost: Bool { spot?.remoteID.isEmpty == false }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LogPreviewCard(media: media, label: name, emoji: emoji, hueA: hueA)

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
                }
                .disabled(!canPost)
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
        guard let spot, !spot.remoteID.isEmpty else { return }
        let finalLabel = name.isEmpty ? "right now" : name
        let hueB = (hueA + 0.15).truncatingRemainder(dividingBy: 1)

        let clip = Clip(author: me, chat: nil, capturedAt: .now, kind: media.kind,
                        assetFileName: media.assetFileName, label: finalLabel, emoji: emoji,
                        hueA: hueA, hueB: hueB)
        // Recorded for both audiences: the place is where this was filmed, and
        // that stays true whoever ends up seeing it.
        clip.intendedSpotID = spot.remoteID
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

/// The capture, previewed at the top of whichever share screen you're on.
private struct LogPreviewCard: View {
    let media: CapturedMedia
    let label: String
    let emoji: String
    let hueA: Double

    var body: some View {
        preview
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 20)
            .padding(.top, 8)
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
            ClipView(clip: clip)
        }
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
