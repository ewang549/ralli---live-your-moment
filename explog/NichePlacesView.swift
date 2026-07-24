import SwiftUI
import SwiftData

// MARK: - View A: Niche Places feed
//
// The iris showcase. A snapping full-screen vertical media feed: the clip is
// the backdrop, edge to edge, and everything else floats over it as glass and
// iris — the right-hand action rail, the orb avatar with its iris ring, the
// follow chip, and the sequence scrubber marking your place in the spot's set.

struct NichePlacesView: View {
    @Query(sort: \SpotClip.capturedAt, order: .reverse) private var clips: [SpotClip]
    @State private var visibleClipID: UUID?

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(clips) { clip in
                        PlacePage(clip: clip, isActive: visibleClipID == clip.id)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            // The current clip is full and sharp; the one being
                            // swiped away eases back and dims, so the page change
                            // reads as a smooth settle rather than a hard cut.
                            .scrollTransition(.interactive.threshold(.visible(0.9))) { view, phase in
                                view
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.92)
                            }
                            .id(clip.id)
                    }
                }
                .scrollTargetLayout()
            }
            // One item per swipe — the feed always settles on a whole clip.
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleClipID)
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) { topChrome }
        }
        .ignoresSafeArea()
        .background(Color.black)
        // Places is the immersive media tab — it stays dark whatever the system
        // theme, so the glass chrome floats over full-bleed video correctly.
        .preferredColorScheme(.dark)
        .onAppear { if visibleClipID == nil { visibleClipID = clips.first?.id } }
    }

    /// Floating header: just the wordmark and the live "nearby" pill. The
    /// per-spot sequence scrubber that used to sit under the logo has been
    /// removed so the media feed anchors straight below the Ralli header.
    private var topChrome: some View {
        HStack {
            RalliWordmark(size: 24)
            Spacer()
            HStack(spacing: 6) {
                GlowDot(size: 7, breathing: true)
                Text("NEARBY NOW")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .kerning(1.1)
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay { Capsule().strokeBorder(Theme.iris.opacity(0.35), lineWidth: 1) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 60)
        .padding(.bottom, 12)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

private struct PlacePage: View {
    let clip: SpotClip
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var showComments = false
    @State private var showShare = false
    @State private var showDetail = false
    @State private var captionExpanded = false
    @State private var isFollowing = false

    /// Handle derived from the author's display name — the seeded feed has no
    /// real accounts behind it, so this is presentation only.
    private var handle: String {
        "@" + clip.authorName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The media is the backdrop; every control below floats over it.
            VibeClipView(emoji: clip.emoji, label: clip.label,
                         hueA: clip.hueA, hueB: clip.hueB, animate: isActive)
                .ignoresSafeArea()

            // Keeps the glass and the caption legible over bright footage.
            LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.72)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                attribution
                Spacer(minLength: 0)
                actionRail
            }
            .padding(.horizontal, 16)
            // Clears the floating nav pill, which hovers over this content.
            .padding(.bottom, 146)
        }
        .sheet(isPresented: $showComments) { CommentsSheet(clip: clip) }
        .sheet(isPresented: $showShare) { SharePlaceSheet(clip: clip) }
        .sheet(isPresented: $showDetail) {
            if let spot = clip.spot { SpotDetailView(spot: spot) }
        }
    }

    // MARK: Right-hand rail

    private var actionRail: some View {
        VStack(spacing: 18) {
            RailButton(icon: "heart", activeIcon: "heart.fill",
                           count: clip.likeCount, isActive: clip.likedByMe,
                           activeTint: Theme.coral) {
                toggleLike()
            }
            RailButton(icon: "bubble.right", activeIcon: "bubble.right.fill",
                           count: clip.comments.count) {
                showComments = true
            }
            RailButton(icon: "paperplane", activeIcon: "paperplane.fill") {
                showShare = true
            }
            RailButton(icon: "bookmark", activeIcon: "bookmark.fill",
                           isActive: clip.savedByMe) {
                clip.savedByMe.toggle()
                try? modelContext.save()
            }
        }
    }

    // MARK: Bottom-left attribution

    private var attribution: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // Iris ring: this clip's author, lit against the media.
                GlassOrbAvatar(emoji: clip.emoji, hue: clip.hueA, size: 42, isActive: true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.authorName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(handle) · \(clip.capturedAt.relativeHour)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }

                AccentChip(title: isFollowing ? "Following" : "Follow",
                         systemImage: isFollowing ? "checkmark" : "plus",
                         isFilled: isFollowing) {
                    isFollowing.toggle()
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

            Text(clip.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(captionExpanded ? 6 : 1)

            if let spot = clip.spot {
                Button {
                    showDetail = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.iris)
                            Text(spot.name)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text("· \(spot.distanceMiles, specifier: "%.1f") mi")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if captionExpanded {
                            Text(spot.summary)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        GlassCard(cornerRadius: 14) { Color.clear }
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.easeOut(duration: 0.22)) { captionExpanded.toggle() }
            } label: {
                Text(captionExpanded ? "See less" : "See more")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.irisSoft)
            }
            .buttonStyle(.plain)
        }
        // Capped so a long caption wraps rather than running under the rail.
        .frame(maxWidth: 280, alignment: .leading)
    }

    private func toggleLike() {
        clip.likedByMe.toggle()
        clip.likeCount += clip.likedByMe ? 1 : -1
        try? modelContext.save()
    }
}

// MARK: - Comments bottom sheet

struct CommentsSheet: View {
    let clip: SpotClip

    @Environment(\.modelContext) private var modelContext
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("\(clip.comments.count) comment\(clip.comments.count == 1 ? "" : "s")")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(clip.comments.sorted { $0.sentAt < $1.sentAt }, id: \.self) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(comment.authorName)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(comment.sentAt.relativeHour)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Text(comment.text)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    if clip.comments.isEmpty {
                        Text("Be the first to comment")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                TextField("Add a comment…", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay { Capsule().strokeBorder(Theme.glassRimTop.opacity(0.35), lineWidth: 1) }
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(post)
                SendButton(enabled: !draft.isEmpty, action: post)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(GlassBackground())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        clip.comments.append(ClipComment(authorName: "Ethan", text: text, sentAt: .now))
        try? modelContext.save()
        draft = ""
    }
}

// MARK: - Share sheet: friends, group chats, or post as a public beacon

struct SharePlaceSheet: View {
    let clip: SpotClip

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @Query private var friends: [Friend]
    @State private var sentTo: Set<UUID> = []
    @State private var beaconPosted = false
    @State private var showPrivacyAlert = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var spotName: String { clip.spot?.name ?? clip.label }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Share \(spotName)")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 20)

                // Destination 1: individual friends (1-on-1 chats).
                section(title: "FRIENDS", items: chats.filter { !$0.isGroup })

                // Destination 2: group chats.
                section(title: "GROUPS", items: chats.filter(\.isGroup))

                // Destination 3: post publicly as a beacon.
                VStack(alignment: .leading, spacing: 8) {
                    Text("PUBLIC")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        postBeacon()
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(beaconPosted ? .green : Theme.iris)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(beaconPosted ? "Beacon posted" : "Post as public beacon")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Broadcast \"join me\" to nearby people")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if beaconPosted {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                        .padding(14)
                        .background {
                            GlassCard(cornerRadius: 14) { Color.clear }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Theme.iris.opacity(0.45), lineWidth: 1)
                                }
                        }
                    }
                    .disabled(beaconPosted || clip.spot == nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(GlassBackground())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Guard clause: posting a public beacon requires a public profile.
        .alert("Public Profile Required", isPresented: $showPrivacyAlert) {
            Button("Go to Profile Settings") {
                dismiss()
                router.tab = .profile
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You must set your profile to Public to create or join community activities.")
        }
        .preferredColorScheme(.dark)
    }

    private func section(title: String, items: [Chat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(items) { chat in
                Button {
                    share(to: chat)
                } label: {
                    HStack {
                        Text(chat.displayName)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if sentTo.contains(chat.id) {
                            Label("Sent", systemImage: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "paperplane")
                                .foregroundStyle(Theme.iris)
                        }
                    }
                    .padding(14)
                    .background { GlassCard(cornerRadius: 14) { Color.clear } }
                }
                .disabled(sentTo.contains(chat.id))
            }
        }
    }

    private func share(to chat: Chat) {
        let message = Message(chat: chat, author: me,
                              text: "check this spot out 👀",
                              sharedSpotName: spotName)
        // Carry the real spot so the chat card can open its detail sheet.
        message.sharedSpot = clip.spot
        modelContext.insert(message)
        chat.messages.append(message)
        try? modelContext.save()
        sentTo.insert(chat.id)
    }

    private func postBeacon() {
        guard let spot = clip.spot, let me else { return }
        // Business rule: private profiles cannot post public beacons.
        if me.isPrivate {
            showPrivacyAlert = true
            return
        }
        let beacon = Beacon(spot: spot, host: me,
                            note: "found this on Ralli — who's in?",
                            startsAt: .now.addingTimeInterval(3600 * 2),
                            capacity: 10)
        beacon.isPublic = true
        modelContext.insert(beacon)
        try? modelContext.save()
        beaconPosted = true
    }
}

// MARK: - Expandable detail: user-submitted notes + AI-generated summary

struct SpotDetailView: View {
    let spot: Spot
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(spot.emoji).font(.system(size: 44))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.name)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(spot.category) · \(spot.distanceMiles, specifier: "%.1f") mi away")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Text(spot.summary)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Insight", systemImage: "sparkles")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.iris)
                        Text(spot.aiInsight)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        Text("Generated from \(max(spot.perspectives.count, 2)) visitor clips + public info")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.baseElevated))

                    Text("VISITOR NOTES")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(spot.perspectives.sorted { $0.capturedAt > $1.capturedAt }, id: \.id) { clip in
                                VStack(alignment: .leading, spacing: 4) {
                                    VibeClipView(emoji: clip.emoji, label: clip.label,
                                                 hueA: clip.hueA, hueB: clip.hueB)
                                        .frame(width: 120, height: 180)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    Text(clip.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(clip.authorName) · \(clip.capturedAt.relativeHour)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .frame(width: 120)
                            }
                        }
                    }

                    Button {
                        showShare = true
                    } label: {
                        Label("Share this spot", systemImage: "paperplane.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.onIris)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.iris))
                    }
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .background(GlassBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let clip = spot.perspectives.first {
                SharePlaceSheet(clip: clip)
            }
        }
        .preferredColorScheme(.dark)
    }
}
