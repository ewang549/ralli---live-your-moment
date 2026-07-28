import SwiftUI
import SwiftData
import FirebaseAuth

// MARK: - View A: Niche Places feed
//
// The coral showcase. A snapping full-screen vertical media feed: the clip is
// the backdrop, edge to edge, and everything else floats over it as glass and
// coral — the right-hand action rail, the orb avatar with its coral ring, the
// follow chip, and the sequence scrubber marking your place in the spot's set.

/// Which slice of the reels feed is on screen: everyone's clips, or only the
/// highlights of accounts the current user follows.
enum PlacesFeed: String, CaseIterable, Identifiable {
    case main, following
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: "Public"
        case .following: "Following"
        }
    }
}

struct NichePlacesView: View {
    @Query(sort: \SpotClip.capturedAt, order: .reverse) private var clips: [SpotClip]
    @Environment(AppRouter.self) private var router
    @Environment(FollowGraph.self) private var followGraph
    @Environment(LogSync.self) private var logSync
    @Environment(\.modelContext) private var modelContext
    @State private var visibleClipID: UUID?
    @State private var feed: PlacesFeed = .main
    @State private var showBookmarks = false

    /// The Following feed: the Highlights of everyone this user follows, newest
    /// first — the same clips their public profile's Highlights grid shows,
    /// composed into one scroll.
    ///
    /// Matched by author name rather than uid because `SpotClip` carries a plain
    /// name, which is exactly what `PublicProfileSheet.highlights` matches on
    /// too. Both sides therefore agree on what counts as someone's highlight.
    private var followedNames: Set<String> { followGraph.followedNames }

    private var visibleClips: [SpotClip] {
        switch feed {
        case .main: clips
        case .following:
            clips.filter { clip in
                // Same precedence the profile's Highlights grid uses: a real
                // author uid wins, name matching only covers seed clips.
                if !clip.authorUID.isEmpty { return followGraph.followedUIDs.contains(clip.authorUID) }
                return followedNames.contains(clip.authorName.lowercased())
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(visibleClips) { clip in
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

                    if visibleClips.isEmpty { emptyFollowingState }
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
        .onAppear { if visibleClipID == nil { visibleClipID = visibleClips.first?.id } }
        // Reconcile who's followed on the way in, so the Following tab reflects
        // follows made on another device (or before this tab first mounted).
        .task { await followGraph.refresh() }
        // Pull the real public feed. This is what makes Places show other
        // people's posts rather than only whatever is in the local store.
        .task { await logSync.syncPublicDown(context: modelContext) }
#if DEBUG
        // CLI screenshot hook, same family as EXPLOG_AUTO_OPEN elsewhere: the
        // Following slice is only reachable by tapping the header toggle.
        //   SIMCTL_CHILD_EXPLOG_AUTO_OPEN=following
        .task {
            guard ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] == "following" else { return }
            try? await Task.sleep(for: .seconds(1.2))
            feed = .following
        }
#endif
        .onChange(of: feed) { _, _ in visibleClipID = visibleClips.first?.id }
        .sheet(isPresented: $showBookmarks) { BookmarkedPlacesView() }
        // Deep link from a Highlights card on someone's public profile: land
        // on their exact clip regardless of which feed slice was last active,
        // since it might not be a friend's clip on the Following side.
        .onChange(of: router.focusedPlaceClipId) { _, target in focus(on: target) }
        .task(id: router.focusedPlaceClipId) { focus(on: router.focusedPlaceClipId) }
    }

    private func focus(on target: UUID?) {
        guard let target, clips.contains(where: { $0.id == target }) else { return }
        feed = .main
        withAnimation(.easeOut(duration: 0.2)) { visibleClipID = target }
        router.focusedPlaceClipId = nil
    }

    /// Following with nobody followed yet — a friendly prompt rather than a
    /// blank page. Also covers "followed people who haven't posted a highlight".
    private var emptyFollowingState: some View {
        VStack(spacing: 8) {
            Text("👀").font(.system(size: 44))
            Text(followGraph.following.isEmpty ? "Nobody followed yet" : "Nothing new here")
                .font(.headline)
                .foregroundStyle(.white)
            Text(followGraph.following.isEmpty
                 ? "Follow people to see their highlights here"
                 : "Highlights from the people you follow will show up here")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 500)
        .padding(.top, 120)
    }

    /// Floating header: the wordmark, the Public/Following feed toggle, and a
    /// bookmarks button in the trailing corner (replacing the old static
    /// "NEARBY NOW" pill, which didn't lead anywhere).
    private var topChrome: some View {
        HStack {
            RalliWordmark()
            Spacer()
            feedToggle
            Spacer()
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle().fill(.ultraThinMaterial)
                            .overlay { Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1) }
                    }
            }
            .accessibilityLabel("Bookmarked places")
        }
        // Horizontal margin matches the Pulse header (16) so the wordmark sits
        // at the exact same x-position tab to tab — no sideways shift on switch.
        .padding(.horizontal, 16)
        .padding(.top, 60)
        .padding(.bottom, 12)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// "Public | Following" — bold white marks the active side, the inactive
    /// side sits muted, switched with a tap. No pill background, matching the
    /// plain-text toggle style used in the reference layout.
    private var feedToggle: some View {
        HStack(spacing: 16) {
            ForEach(PlacesFeed.allCases) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { feed = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 15, weight: feed == option ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(feed == option ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PlacePage: View {
    let clip: SpotClip
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(FollowGraph.self) private var followGraph
    @Environment(EngagementSync.self) private var engagementSync
    @Query private var friends: [Friend]
    @State private var showComments = false
    @State private var showShare = false
    @State private var showDetail = false
    @State private var showProfile = false
    @State private var captionExpanded = false
    /// Optimistic override held only for the length of a follow round trip.
    /// `nil` means "read the graph", which is the real state — so the chip
    /// survives a relaunch and can't drift from the profile sheet's button.
    @State private var pendingFollow: Bool?
    @State private var followWorking = false

    /// Handle derived from the author's display name — the seeded feed has no
    /// real accounts behind it, so this is presentation only.
    private var handle: String {
        "@" + clip.authorName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    /// A roster match, when this author happens to already be a local friend
    /// — lets the tap open the real profile sheet instead of a name-only one.
    private var matchedFriend: Friend? {
        friends.first { !$0.isMe && $0.name.caseInsensitiveCompare(clip.authorName) == .orderedSame }
    }

    /// The account behind this clip. Public clips carry their author directly;
    /// falling back to a roster match keeps seed clips by an existing friend
    /// actionable. Empty means there's no real account to act on.
    private var authorUID: String {
        clip.authorUID.isEmpty ? (matchedFriend?.remoteUID ?? "") : clip.authorUID
    }

    /// The author's profile photo. The clip carries the copy the server
    /// denormalised onto it; a roster match is the fallback for a seed clip by
    /// someone who is already a friend.
    private var authorAvatarURL: URL? {
        if !clip.authorAvatarURL.isEmpty, let url = URL(string: clip.authorAvatarURL) {
            return url
        }
        return matchedFriend?.avatarRemotePhotoURL
    }

    /// The person's own avatar emoji for the placeholder — `clip.emoji` is the
    /// *clip's* vibe emoji, which is nobody's avatar.
    private var authorAvatarEmoji: String {
        if !clip.authorAvatarEmoji.isEmpty { return clip.authorAvatarEmoji }
        return matchedFriend?.emoji ?? clip.emoji
    }

    /// Following is only offered when there's someone real to follow — seed
    /// clips have no account, and a chip that can't do anything is worse than
    /// no chip.
    ///
    /// Your own public posts appear in this feed like anyone else's, so the
    /// author check has to exclude yourself as well. The server has always
    /// rejected a self-follow and `toggleFollow` swallows the failure, so the
    /// chip was never able to do anything here — it just sat there looking
    /// live. Same rule the profile sheet's Follow button already applies.
    private var canFollow: Bool {
        !authorUID.isEmpty && authorUID != Auth.auth().currentUser?.uid
    }

    private var isFollowing: Bool { pendingFollow ?? followGraph.isFollowing(authorUID) }

    /// Enough of a profile for the follow call and for the Following list to
    /// render this author before the next refresh replaces it with the
    /// server's copy.
    private var authorProfile: RemoteProfile {
        RemoteProfile(uid: authorUID,
                      handle: "",
                      handleDisplay: "",
                      name: clip.authorName,
                      avatarEmoji: authorAvatarEmoji,
                      city: "",
                      bio: "",
                      isPrivate: false,
                      // So the Following list renders this author's real photo
                      // straight away instead of an orb until the next refresh.
                      avatarURL: clip.authorAvatarURL)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The media is the backdrop; every control below floats over it.
            // Real upload when there is one, the stylized vibe when there isn't.
            //
            // `.fit` over black, the same treatment the post-capture review
            // uses: Ralli captures are landscape, so filling this portrait page
            // cropped a horizontal clip down to a vertical slice of itself.
            // Letterboxing shows what was actually filmed.
            ClipMediaView(spotClip: clip, isActive: isActive, contentMode: .fit)
                .background(Color.black)
                .ignoresSafeArea()
                // A view is counted when the clip is the one actually on
                // screen, not when its pane is built — a feed builds panes
                // either side of the visible one to make paging smooth, and
                // counting those would report views nobody had.
                .task(id: isActive) {
                    guard isActive else { return }
                    engagementSync.markViewed(logID: clip.remoteID)
                }

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
        .fullScreenCover(isPresented: $showProfile) {
            if let matchedFriend {
                PublicProfileSheet(friend: matchedFriend)
            } else {
                // `authorUID` is the clip's real author when it has one. It's
                // still empty for seed clips, which the sheet already handles
                // by hiding the action row rather than offering dead controls.
                PublicProfileSheet(uid: authorUID, name: clip.authorName,
                                   emoji: authorAvatarEmoji)
            }
        }
    }

    /// Follows or unfollows this clip's author through the same `FollowGraph`
    /// the profile sheet's Follow button uses, so the two can never disagree —
    /// and so the Following tab, which reads that graph, updates immediately.
    ///
    /// The override is cleared either way once the call settles: on success the
    /// graph already holds the new state, and on failure it was never changed,
    /// so dropping back to it *is* the rollback.
    private func toggleFollow() {
        guard canFollow, !followWorking else { return }
        let wasFollowing = isFollowing
        let profile = authorProfile

        withAnimation(.easeOut(duration: 0.18)) { pendingFollow = !wasFollowing }
        followWorking = true

        Task {
            defer { followWorking = false }
            do {
                _ = wasFollowing ? try await followGraph.unfollow(profile)
                                 : try await followGraph.follow(profile)
            } catch {
                // Nothing to undo — the graph is untouched when the call throws.
            }
            withAnimation(.easeOut(duration: 0.18)) { pendingFollow = nil }
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
                Button {
                    showProfile = true
                } label: {
                    HStack(spacing: 10) {
                        // Coral ring: this clip's author, lit against the media.
                        GlassOrbAvatar(emoji: authorAvatarEmoji, hue: clip.hueA,
                                       size: 42, isActive: true,
                                       photoURL: matchedFriend?.avatarPhotoURL,
                                       remotePhotoURL: authorAvatarURL)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(clip.authorName)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(handle) · \(clip.capturedAt.relativeHour)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if canFollow {
                    AccentChip(title: isFollowing ? "Following" : "Follow",
                             systemImage: isFollowing ? "checkmark" : "plus",
                             isFilled: isFollowing) {
                        toggleFollow()
                    }
                    .disabled(followWorking)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)

            Text(clip.label)
                .font(.logCaption)
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
                                .foregroundStyle(Theme.accent)
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
                    .foregroundStyle(Theme.accentSoft)
            }
            .buttonStyle(.plain)
        }
        // Capped so a long caption wraps rather than running under the rail.
        .frame(maxWidth: 280, alignment: .leading)
    }

    /// Hands the like to the server, which is what makes it visible to anyone
    /// else. `EngagementSync` does the optimistic flip and puts it back if the
    /// call fails, so the tap still lands on this frame.
    private func toggleLike() {
        Task { await engagementSync.toggleLike(clip, context: modelContext) }
    }
}

// MARK: - Comments bottom sheet

struct CommentsSheet: View {
    let clip: SpotClip

    @Environment(\.modelContext) private var modelContext
    @Environment(EngagementSync.self) private var engagementSync
    @State private var draft = ""
    /// True while a comment is on its way up, so the send button can't fire the
    /// same text twice.
    @State private var posting = false

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
                SendButton(enabled: !draft.isEmpty && !posting, action: post)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(GlassBackground())
        // Other people's comments only exist on the server, so the local copy
        // is a cache that has to be refreshed on open — otherwise this shows
        // nothing but what this device typed.
        .task { await engagementSync.loadComments(for: clip, context: modelContext) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    /// Sends the comment to the server, which is the only place it becomes
    /// anyone else's. The draft is cleared straight away and `EngagementSync`
    /// shows the comment optimistically, so the field empties on the same frame
    /// as the tap; a failure removes the row again rather than leaving a
    /// comment on screen that nobody else will ever load.
    private func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !posting else { return }
        draft = ""
        posting = true
        Task {
            await engagementSync.addComment(text, to: clip, context: modelContext)
            posting = false
        }
    }
}

// MARK: - Share sheet: friends, group chats, or post as a public beacon

struct SharePlaceSheet: View {
    let clip: SpotClip

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(BeaconSync.self) private var beaconSync
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @Query private var friends: [Friend]
    @State private var sentTo: Set<UUID> = []
    @State private var beaconPosted = false
    @State private var showPrivacyAlert = false
    /// A send that never left the device. Surfaced rather than swallowed —
    /// silently ticking "Sent" on a failure is the bug this whole path had.
    @State private var shareFailed = false

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
                                .foregroundStyle(beaconPosted ? .green : Theme.accent)
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
                                        .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
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
        .alert("Couldn't share this place", isPresented: $shareFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The message didn't send. Check your connection and try again.")
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
                    Task { await share(to: chat) }
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
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(14)
                    .background { GlassCard(cornerRadius: 14) { Color.clear } }
                }
                .disabled(sentTo.contains(chat.id))
            }
        }
    }

    /// Sends the place into the chat the friend actually reads.
    ///
    /// This used to be a bare SwiftData insert. That row is only ever drawn by
    /// `MessageBubble` inside the legacy `MessageThreadView`, and every
    /// signed-in session renders `StreamThreadView` instead — so the share
    /// showed "Sent" here and arrived nowhere. It goes over the same channel
    /// the thread itself opens now, exactly like a reaction does. The local
    /// insert survives as the fallback for a session with no Stream user,
    /// which is the only case that still renders the legacy thread.
    private func share(to chat: Chat) async {
        if StreamConfig.isEnabled {
            guard let spot = clip.spot,
                  await StreamThreadPoster.postSpotShare(spot, to: chat) else {
                shareFailed = true
                return
            }
            // A Stream message leaves no local `Message` row, so Pulse's
            // outgoing order has to be told about it here.
            chat.noteOutgoingMessage(at: .now)
            try? modelContext.save()
        } else {
            let message = Message(chat: chat, author: me,
                                  text: "check this spot out 👀",
                                  sharedSpotName: spotName)
            // Carry the real spot so the chat card can open its detail sheet.
            message.sharedSpot = clip.spot
            modelContext.insert(message)
            chat.messages.append(message)
            try? modelContext.save()
        }
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
        beacon.hostUID = me.remoteUID
        beacon.hostName = me.name
        beacon.hostEmoji = me.emoji
        beacon.hostAvatarURL = me.avatarURL
        modelContext.insert(beacon)
        try? modelContext.save()

        // Same local-first publish as the Beacons tab's create sheet — a beacon
        // started from a place is the same beacon, and leaving this path local
        // would mean nobody ever saw one posted from here.
        let context = modelContext
        let sync = beaconSync
        Task { await sync.publish(beacon, context: context) }

        beaconPosted = true
    }
}

// MARK: - Expandable detail: user-submitted notes + AI-generated summary

struct SpotDetailView: View {
    let spot: Spot
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    /// Optional for the same reason `ClipView`'s `EngagementSync` is: this
    /// sheet is also presented from the chat thread views (that's the
    /// shared-place flow), and a missing `@Observable` lookup is a hard crash
    /// rather than a nil. Without a router the strip simply isn't tappable,
    /// which is what it was before.
    @Environment(AppRouter.self) private var router: AppRouter?

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
                            .foregroundStyle(Theme.accent)
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
                                    // Thumbnails aren't the focus of this sheet,
                                    // so video stays paused — it still shows its
                                    // first frame rather than a placeholder.
                                    // Shaped by the clip and fitted, so even a
                                    // thumbnail shows the whole frame.
                                    //
                                    // Tapping one opens it in the Places feed
                                    // proper rather than in a player built just
                                    // for this sheet — same deep link a
                                    // Highlights card and the bookmarks rail
                                    // already use, so there is one way in.
                                    Button { open(clip) } label: {
                                        ClipMediaView(spotClip: clip, isActive: false,
                                                      contentMode: .fit)
                                            .frame(width: 120)
                                            .aspectRatio(clip.displayAspectRatio, contentMode: .fit)
                                            .background(Color.black)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                            .contentShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(PressScaleStyle())
                                    .disabled(router == nil)
                                    Text(clip.label)
                                        .font(.logCaption)
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
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.accent))
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

    /// Closes this sheet and hands the Places tab the clip to land on.
    ///
    /// The sheet has to go first: it is presented *over* the tab bar, so
    /// focusing a clip underneath it without dismissing would scroll a feed
    /// nobody can see. Driving the shared `focusedPlaceClipId` rather than
    /// opening another player here is what keeps one path into the feed —
    /// `UserProfileView.openHighlight` and the bookmarks rail already use it.
    private func open(_ clip: SpotClip) {
        guard let router else { return }
        router.tab = .places
        router.focusedPlaceClipId = clip.id
        dismiss()
    }
}
