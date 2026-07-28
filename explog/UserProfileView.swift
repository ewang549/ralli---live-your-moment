import SwiftUI
import SwiftData
import FirebaseAuth

// MARK: - Tab 1: Your profile — identity, stats, and everything you've filmed
//
// Editing lives in `EditProfileView`, account administration in `SettingsView`.

/// The Profile tab's landing screen.
///
/// This used to be one scrolling form that mixed three unrelated jobs: how you
/// present yourself, how your account is administered, and nothing at all about
/// what you'd actually posted. It's now a place you *land*: who you are, what
/// your logging adds up to, and everything you've filmed. Editing moved to
/// `EditProfileView` and account controls to `SettingsView`, each one tap away.
struct UserProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var friends: [Friend]
    @Query(sort: \SpotClip.capturedAt, order: .reverse) private var allSpotClips: [SpotClip]

    private var me: Friend? { friends.first { $0.isMe } }

    @State private var isRecovering = false
    @State private var recoveryError: String?
    @State private var showEditProfile = false
    @State private var showSettings = false
    /// The log whose Insights sheet is open.
    @State private var insightsClip: Clip?
    /// The log awaiting delete confirmation. Deleting media is not undoable,
    /// so it never happens straight off the menu.
    @State private var pendingDelete: Clip?
    /// The highlight currently open in the full-screen player.
    @State private var playingClip: Clip?

    var body: some View {
        ZStack {
            GlassBackground()
            content
        }
        .sheet(isPresented: $showEditProfile) {
            if let me { EditProfileView(me: me) }
        }
        .sheet(isPresented: $showSettings) {
            if let me { SettingsView(me: me) }
        }
        .sheet(item: $insightsClip) { clip in
            LogInsightsView(clip: clip)
        }
        // Your own Highlights play in place rather than redirecting to the
        // Places feed the way another account's grid does — this grid is
        // already yours, so there is nothing to go and browse.
        .fullScreenCover(item: $playingClip) { clip in
            HighlightPlayerView(clip: clip, author: me)
        }
        .confirmationDialog("Delete this log?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the video and its copy on the server. It can't be undone.")
        }
#if DEBUG
        // The account controls moved to Settings, so the CLI hooks that drive
        // them have to open Settings first. The hooks themselves live there.
        .task {
            let environment = ProcessInfo.processInfo.environment
            guard environment["EXPLOG_AUTO_ACCOUNT"] != nil
                    || environment["EXPLOG_AUTO_LOGOUT"] == "1" else { return }
            try? await Task.sleep(for: .seconds(1))
            showSettings = true
        }
#endif
    }

    @ViewBuilder
    private var content: some View {
        if let me {
            profileBody(for: me)
        } else {
            // No local "me" row. Normally AuthGateView caches it from Firestore
            // on launch; if that hasn't happened (offline, or the cache was
            // wiped mid-session) show a real state with a way out instead of a
            // spinner that never resolves.
            missingProfileState
        }
    }

    // MARK: - Landing

    private func profileBody(for me: Friend) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleBar
                identityHeader(for: me)
                actionButtons
                statsSection(for: me)
                highlightsSection(for: me)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
    }

    private var titleBar: some View {
        HStack {
            Text("Profile")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            RalliWordmark(size: 22)
        }
        .padding(.top, 12)
    }

    private func identityHeader(for me: Friend) -> some View {
        VStack(spacing: 8) {
            GlassOrbAvatar(friend: me, size: 104, isActive: true)
            Text(me.name.isEmpty ? "You" : me.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if !me.displayUserId.isEmpty {
                Text(me.displayUserId)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !me.city.isEmpty {
                Label("\(me.city)\(me.age > 0 ? " · \(me.age)" : "")",
                      systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !me.bio.isEmpty {
                Text(me.bio)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            if me.isPrivate {
                Label("Private profile", systemImage: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background { Capsule().fill(Theme.sunken) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button { showEditProfile = true } label: {
                Label("Edit profile", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background { Capsule().fill(Theme.accentGradient) }
            }
            .buttonStyle(PressScaleStyle())

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46)
                    .background {
                        Circle().fill(Theme.accentWash)
                            .overlay { Circle().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1) }
                    }
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Stats
    //
    // Every tile here is a real count off the local model. Two things the brief
    // asked for aren't in this list, both for the same reason:
    //
    //   • "Distance travelled" needs a location history per log, and there
    //     isn't one — a `Clip` records no coordinate, and `Spot` only carries
    //     one for places that came from location search. So it's scoped down to
    //     the number of distinct places you've posted from, which is a real
    //     figure derived from real rows rather than an invented mileage.
    //   • "Total hours logged" would be a sum of clip durations, which nothing
    //     stores. "Logs sent" is the count of hourly logs, which is the same
    //     idea measured in something the app actually has.

    private func statsSection(for me: Friend) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BY THE NUMBERS")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 10) {
                statTile("figure.wave", "\(me.joinedBeacons.count)", "experiences")
                statTile("mappin.and.ellipse", "\(distinctPlaces(for: me))", "places")
                statTile("paperplane.fill", "\(me.clips.count)", "logs sent")
                statTile("flame.fill", "\(bestStreak(for: me))", "best streak")
                statTile("person.2.fill", "\(friendCount)", "friends")
                statTile("video.fill", "\(highlights(for: me).count)", "on your grid")
            }
        }
    }

    private func statTile(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(size: 20, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background { GlassCard(cornerRadius: 14) { Color.clear } }
    }

    private var friendCount: Int {
        friends.filter { !$0.isMe }.count
    }

    /// Longest run going in any of your 1-on-1 threads.
    ///
    /// Deliberately the max rather than `Friend.streakCount`, which returns
    /// whichever DM happens to come first in the relationship — fine as a row
    /// detail next to a specific person, meaningless as a headline number
    /// about you.
    private func bestStreak(for me: Friend) -> Int {
        me.chats.filter { !$0.isGroup }.map(\.streak).max() ?? 0
    }

    /// Distinct places you've posted from.
    ///
    /// Matched on account id where there is one, falling back to display name
    /// for seed and legacy rows — the same rule `PublicProfileSheet` uses,
    /// because `SpotClip` carries a plain author name rather than a `Friend`.
    private func distinctPlaces(for me: Friend) -> Int {
        let mine = allSpotClips.filter { clip in
            if !clip.authorUID.isEmpty {
                return !me.remoteUID.isEmpty && clip.authorUID == me.remoteUID
            }
            return !me.name.isEmpty
                && clip.authorName.caseInsensitiveCompare(me.name) == .orderedSame
        }
        return Set(mine.compactMap { $0.spot?.id }).count
    }

    // MARK: - Highlights

    /// What you've posted publicly to a place, newest first.
    ///
    /// `intendedSpotID` is the test rather than `kind`: it's set only by
    /// `PublicPlacePostView.post()` and stays empty for every friends-only
    /// send. Filtering on media kind instead put every hourly log you ever
    /// filmed on your public grid — a private send to one friend is not a
    /// highlight, and this screen is the public face of the account.
    private func highlights(for me: Friend) -> [Clip] {
        me.clips
            .filter { !$0.intendedSpotID.isEmpty }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    @ViewBuilder
    private func highlightsSection(for me: Friend) -> some View {
        let clips = highlights(for: me)

        VStack(alignment: .leading, spacing: 10) {
            Text("HIGHLIGHTS")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)

            if clips.isEmpty {
                VStack(spacing: 6) {
                    Text("🎬").font(.system(size: 40))
                    Text("Nothing posted publicly yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Posts to a place will show up here.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background { GlassCard(cornerRadius: 16) { Color.clear } }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(clips) { clip in
                        highlightCell(clip)
                    }
                }
            }
        }
    }

    /// One posted log, with its own overflow menu pinned bottom-right.
    private func highlightCell(_ clip: Clip) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // The tile takes the clip's own shape and fits inside it, so the
            // whole frame survives — including a sticker or a doodle placed
            // near an edge, which a fixed-ratio fill used to cut off.
            Color.black
            ClipMediaView(kind: clip.kind,
                          localURL: clip.assetURL,
                          remoteURL: clip.remoteURL,
                          emoji: clip.emoji,
                          label: clip.label,
                          hueA: clip.hueA,
                          hueB: clip.hueB,
                          // Still frames, not a grid of running players.
                          isActive: false,
                          contentMode: .fit)
                .aspectRatio(clip.displayAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                // The tap target is the media rather than the whole tile, so
                // it can't compete with the overflow menu sitting on top of
                // it — Insights and Delete keep their own taps.
                .contentShape(Rectangle())
                .onTapGesture { playingClip = clip }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(clip.label.isEmpty ? "Play log" : "Play \(clip.label)")

            // A failed send is the one thing worth surfacing on the tile
            // itself — it's the difference between "posted" and "still sitting
            // on this phone", and nothing else on this screen would say so.
            if clip.sendState == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Theme.accent))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }

            overflowMenu(for: clip)
                .padding(8)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func overflowMenu(for clip: Clip) -> some View {
        Menu {
            Button { insightsClip = clip } label: {
                Label("Insights", systemImage: "chart.bar")
            }
            Button(role: .destructive) { pendingDelete = clip } label: {
                Label("Delete video", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                // Blur rather than a flat black disc: this sits directly on
                // video, where a solid fill reads as a sticker pasted over the
                // frame. The material picks up what's behind it, so the control
                // belongs to the tile instead of covering it.
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .environment(\.colorScheme, .dark)
        }
        .accessibilityLabel("More options")
    }

    /// Server copy first, then the file, then the row.
    ///
    /// The server call is best-effort and deliberately not awaited before the
    /// local delete: the user asked for this log to be gone, and leaving it on
    /// their own grid because the network was down would be the wrong answer.
    /// An unpublished log has nothing on the server to remove.
    private func delete(_ clip: Clip) {
        if clip.isPublished {
            let remoteID = clip.remoteID
            Task { try? await FirestoreService.deleteLog(id: remoteID) }
            // The Places feed reads a *different* model: publishing to a place
            // writes a `SpotClip` mirror alongside this `Clip`, and dropping
            // only the `Clip` left that mirror rendering in Places, Niche and
            // Bookmarks forever. `LogSync.materialisePublic` prunes these too,
            // which covers a delete made on another device — this is just the
            // immediate half, so the row goes on the same tap.
            deleteSpotMirror(remoteID: remoteID)
        }
        if let assetURL = clip.assetURL {
            try? FileManager.default.removeItem(at: assetURL)
        }
        // The chat's `clips` array holds it too; dropping the row without this
        // leaves the thread pointing at a deleted model.
        clip.chat?.clips.removeAll { $0.id == clip.id }
        modelContext.delete(clip)
        try? modelContext.save()
    }

    /// Drops the Places-feed row that shares this log's server id.
    ///
    /// Keyed on `remoteID` because that is the only thing the two models have
    /// in common — they're separate `@Model` types with their own local ids,
    /// and the mirror is stamped with the log's server id as soon as the
    /// publish returns (see `PublicPlacePostView.post`). An empty id can't
    /// identify anything, so it's refused rather than matching every
    /// never-published row at once.
    private func deleteSpotMirror(remoteID: String) {
        guard !remoteID.isEmpty else { return }
        let mirrors = (try? modelContext.fetch(
            FetchDescriptor<SpotClip>(predicate: #Predicate { $0.remoteID == remoteID })
        )) ?? []
        mirrors.forEach { modelContext.delete($0) }
    }

    // MARK: - Recovery

    private var missingProfileState: some View {
        VStack(spacing: 14) {
            Text("👤").font(.system(size: 52))
            Text("Profile not loaded")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(recoveryError ?? "Your profile lives on the server and hasn't been cached on this device yet.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                reloadProfile()
            } label: {
                if isRecovering {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    Text("Reload profile").font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.accent))
            .disabled(isRecovering)

#if DEBUG
            // Dev-only: demo content is gated off real accounts, so this is how
            // you get the fake roster back while signed in.
            Button {
                SeedData.seed(context: modelContext)
            } label: {
                Label("Load demo data", systemImage: "wand.and.stars")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 6)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pulls the profile from Firestore and rebuilds the local `isMe` row.
    private func reloadProfile() {
        isRecovering = true
        recoveryError = nil
        Task { @MainActor in
            do {
                if let profile = try await FirestoreService.currentProfile() {
                    FirestoreService.cacheLocally(profile, context: modelContext)
                } else {
                    recoveryError = "No profile found for this account."
                }
            } catch {
                recoveryError = error.localizedDescription
            }
            isRecovering = false
        }
    }
}

/// Simple wrapping chip selector for interest tags.
struct FlowChips: View {
    let options: [String]
    @Binding var selection: [String]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 82), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { tag in
                let isOn = selection.contains(tag)
                Button {
                    if isOn {
                        selection.removeAll { $0 == tag }
                    } else {
                        selection.append(tag)
                    }
                } label: {
                    Text(tag)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOn ? Theme.onAccent : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            Capsule()
                                .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.sunken))
                        }
                }
            }
        }
    }
}

// MARK: - Public profile sheet (attendee cards, search results, avatars)

/// One profile sheet for every entry point.
///
/// Opens from a local `Friend` (attendee cards, Pulse rows) or from a bare uid
/// (search results, suggestions). When the account is a real one it loads the
/// server's view — handle, city, bio, mutual count, and the relationship — and
/// offers the matching action: Add / Requested / Accept / Message / Unblock,
/// with Report and Block always one tap away in the overflow.
///
/// Demo rows have no `remoteUID`, so they render exactly as they always did
/// from local data with no network call and no actions.
struct PublicProfileSheet: View {
    /// Local row, when there is one. Supplies interests and the avatar hue,
    /// neither of which the public projection carries.
    private let friend: Friend?
    private let uid: String
    private let fallbackName: String
    private let fallbackEmoji: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph
    @Environment(FollowGraph.self) private var followGraph
    @Environment(AppRouter.self) private var router
    @Query private var friends: [Friend]
    @Query(sort: \SpotClip.capturedAt, order: .reverse) private var allSpotClips: [SpotClip]

    @State private var remote: RemoteProfile?
    @State private var status: FriendshipStatus = .none
    @State private var mutuals = 0
    @State private var isFollowing = false
    @State private var followerCount = 0
    @State private var followWorking = false
    @State private var loading = false
    @State private var working = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var openChat: Chat?
    @State private var safety = SafetyPresentation()

    init(friend: Friend) {
        self.friend = friend
        self.uid = friend.remoteUID
        self.fallbackName = friend.name
        self.fallbackEmoji = friend.emoji
    }

    /// Entry point for search results and suggestions, where all we have is an
    /// account id and whatever the row was already showing.
    init(uid: String, name: String, emoji: String = "🙂") {
        self.friend = nil
        self.uid = uid
        self.fallbackName = name
        self.fallbackEmoji = emoji
    }

    private var isRemote: Bool { !uid.isEmpty }

    /// This sheet is showing the signed-in user their own account.
    ///
    /// Reachable without going through the Profile tab — finding yourself in
    /// search, or tapping your own name on a public feed, opens this sheet for
    /// your own uid with no local "me" `Friend` row resolved. Nothing stopped
    /// the relationship actions from firing there, so you could follow (and
    /// then unfollow) yourself.
    private var isMe: Bool {
        isRemote && uid == Auth.auth().currentUser?.uid
    }

    private var displayName: String { remote?.name ?? fallbackName }

    /// This account's profile photo as held on the server. Empty-string URLs
    /// come back from profiles that never set one.
    private var remoteAvatarURL: URL? {
        guard let raw = remote?.avatarURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
    private var isPrivate: Bool { remote?.isPrivate ?? friend?.isPrivate ?? false }
    /// A private account shows nothing beyond its name until you're friends.
    private var detailsHidden: Bool { isPrivate && status != .friends }

    /// This person's place clips — casual video/photo posts, not a follower-style
    /// grid. Matched by name, the same signal Places itself uses to tell a
    /// friend's clip from a stranger's (`SpotClip` carries a plain author name
    /// rather than a `Friend` relationship).
    private var highlights: [SpotClip] {
        allSpotClips.filter { clip in
            // A clip that carries a real author is matched on it and nothing
            // else, so two accounts sharing a display name can't inherit each
            // other's highlights. Name matching is the fallback for seed and
            // legacy clips, which have no account behind them at all.
            if !clip.authorUID.isEmpty { return clip.authorUID == uid }
            return clip.authorName.caseInsensitiveCompare(displayName) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: 13) {
                        header
                        if let loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 30)
                                .multilineTextAlignment(.center)
                        } else if detailsHidden {
                            privateNotice
                        } else {
                            details
                        }
                        // No relationship actions on your own account: follow,
                        // add friend, message and block are all things you do
                        // to somebody else.
                        if isRemote && !isMe { actionRow }
                        if !detailsHidden && !highlights.isEmpty { highlightsSection }
                        Spacer(minLength: 20)
                    }
                    .padding(.top, 22)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Prominent, always-present way out — this is a full-screen
                // cover, not a sheet, so there's no swipe-down to fall back on.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.sunken))
                    }
                    .accessibilityLabel("Close")
                }
                // Same reasoning as `actionRow`: reporting or blocking
                // yourself isn't a thing.
                if isRemote && !isMe {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            SafetyMenuItems(
                                target: .user(uid: uid, name: displayName),
                                presentation: safety
                            )
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: Binding(get: { safety.reporting }, set: { safety.reporting = $0 })) { target in
            ReportSheet(target: target) { dismiss() }
        }
        .confirmationDialog(
            "Block \(displayName)?",
            isPresented: Binding(get: { safety.blocking != nil },
                                 set: { if !$0 { safety.blocking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await blockThem() } }
            Button("Cancel", role: .cancel) { safety.blocking = nil }
        } message: {
            Text("They won't be able to message you or see your logs, and you won't see theirs. Your friendship and any pending requests are removed.")
        }
        .fullScreenCover(item: $openChat) { chat in
            NavigationStack {
                ChatDetailView(chat: chat) { openChat = nil }
            }
            // Same as Pulse's quick chat: presented as a cover, so the swipe
            // back has to be supplied rather than inherited.
            .swipeRightToDismiss { openChat = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // A local row's own photo wins; otherwise fall back to whatever the
            // server holds for this account, and to the emoji orb if it holds
            // nothing.
            GlassOrbAvatar(emoji: remote?.avatarEmoji ?? friend?.emoji ?? fallbackEmoji,
                           hue: friend?.hue ?? 0.58, size: 84, isActive: false,
                           photoURL: friend?.avatarPhotoURL,
                           // The local row's own copy of the photo covers the
                           // window before the profile finishes loading —
                           // otherwise opening a friend you have a photo for
                           // showed the emoji orb until the network came back.
                           remotePhotoURL: remoteAvatarURL ?? friend?.avatarRemotePhotoURL)
            Text(displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if let remote, !remote.handle.isEmpty {
                Text(remote.atHandle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            // Followers — the one count this profile carries, and only for a
            // real account. It's what the Follow button below acts on, so
            // hiding it would leave that button with nothing to move.
            if isRemote {
                Text("\(followerCount) follower\(followerCount == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            if loading {
                ProgressView().tint(Theme.textSecondary).scaleEffect(0.7)
            }
        }
    }

    private var privateNotice: some View {
        VStack(spacing: 6) {
            Label("Private profile", systemImage: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("This member keeps their details hidden.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var details: some View {
        let city = remote?.city ?? friend?.city ?? ""
        let bio = remote?.bio ?? friend?.bio ?? ""
        let age = friend?.age ?? 0

        if !city.isEmpty {
            Label("\(city)\(age > 0 ? " · \(age)" : "")", systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }

        // Mutuals are the strongest "do I know this person?" signal, so they sit
        // above the bio rather than buried under it.
        if mutuals > 0 {
            Label("\(mutuals) mutual friend\(mutuals == 1 ? "" : "s")",
                  systemImage: "person.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background { Capsule().fill(Theme.accentWash) }
        }

        if !bio.isEmpty {
            Text(bio)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }

        if let friend, !friend.interests.isEmpty {
            HStack(spacing: 6) {
                ForEach(friend.interests, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background { Capsule().fill(Theme.sunken) }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// A quiet grid of this person's place clips — no like counts or captions
    /// up front, just what they've been up to. Tapping one hands the whole
    /// screen over to Places, focused on that exact clip.
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlights")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(highlights) { clip in
                    Button { openHighlight(clip) } label: {
                        HighlightThumbnail(clip: clip)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// Tears this profile down, switches the active tab to Places, and hands
    /// it the clip to scroll to and autoplay.
    private func openHighlight(_ clip: SpotClip) {
        router.tab = .places
        router.focusedPlaceClipId = clip.id
        dismiss()
    }

    /// The context action. One primary control per state, matching what the
    /// server says the relationship is rather than what the caller assumed.
    @ViewBuilder
    private var actionRow: some View {
        VStack(spacing: 8) {
            // Follow sits above the friendship action: it's the lighter of the
            // two commitments and the one that's always available, whatever
            // the friendship state happens to be.
            followButton

            switch status {
            case .none:
                primaryButton("Add friend", icon: "plus") {
                    try await friendGraph.send(to: profileForActions, context: modelContext)
                }
            case .incoming:
                primaryButton("Accept request", icon: "checkmark") {
                    try await friendGraph.accept(profileForActions, context: modelContext)
                    return .friends
                }
            case .requested:
                settledPill("Requested", icon: "clock")
            case .friends:
                messageButton
                settledPill("Friends", icon: "checkmark.circle.fill")
            case .blocked:
                primaryButton("Unblock", icon: "hand.raised.slash") {
                    try await friendGraph.unblock(profileForActions, context: modelContext)
                    return FriendshipStatus.none
                }
            }

            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 30)
    }

    /// Follow / Following — outlined while the offer is open, filling in once
    /// taken, the same way Beacons' "Going" confirms.
    ///
    /// Deliberately the inverse of `primaryButton`'s grammar: Follow stacks
    /// directly above "Add friend", and only one coral fill may sit in that
    /// stack by default. Add friend keeps it — it's the more consequential
    /// action, since a mutual friendship is what unlocks messaging.
    private var followButton: some View {
        Button(action: toggleFollow) {
            HStack(spacing: 6) {
                Image(systemName: isFollowing ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                Text(isFollowing ? "Following" : "Follow")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(isFollowing ? Theme.onAccent : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                if isFollowing {
                    Capsule().fill(Theme.accentGradient)
                } else {
                    Capsule().fill(Theme.accentWash)
                        .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: 1.5) }
                }
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(followWorking)
        .accessibilityLabel(isFollowing ? "Following \(displayName)" : "Follow \(displayName)")
    }

    /// Flips the button and the count on the spot, then reconciles with the
    /// server — and puts both back exactly as they were if the call fails.
    private func toggleFollow() {
        // Guarded here as well as by hiding the button: this is the one place
        // the follow actually happens, and a future entry point that forgets
        // the `isMe` check shouldn't be able to make you your own follower.
        guard isRemote, !isMe, !followWorking else { return }
        let wasFollowing = isFollowing
        let previousCount = followerCount
        let profile = profileForActions

        withAnimation(.easeOut(duration: 0.18)) {
            isFollowing = !wasFollowing
            followerCount = max(0, previousCount + (wasFollowing ? -1 : 1))
        }
        followWorking = true
        actionError = nil

        Task {
            defer { followWorking = false }
            do {
                let result = wasFollowing ? try await followGraph.unfollow(profile)
                                          : try await followGraph.follow(profile)
                withAnimation(.easeOut(duration: 0.18)) {
                    isFollowing = result.following
                    followerCount = result.followerCount
                }
            } catch {
                withAnimation(.easeOut(duration: 0.18)) {
                    isFollowing = wasFollowing
                    followerCount = previousCount
                }
                if let callable = error as? CallableFunctions.CallableError {
                    actionError = callable.message
                } else {
                    actionError = "Couldn't reach the server."
                }
            }
        }
    }

    private var messageButton: some View {
        Button {
            openChat = chatWithThem()
        } label: {
            Label("Message", systemImage: "bubble.left.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background { Capsule().fill(Theme.accentGradient) }
        }
        .buttonStyle(PressScaleStyle())
    }

    private func primaryButton(_ title: String,
                               icon: String,
                               action: @escaping () async throws -> FriendshipStatus) -> some View {
        Button {
            Task { await perform(action) }
        } label: {
            HStack(spacing: 6) {
                if working {
                    ProgressView().tint(Theme.onAccent).scaleEffect(0.75)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background { Capsule().fill(Theme.accentGradient) }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(working)
    }

    private func settledPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background { Capsule().fill(Theme.accentWash) }
    }

    // MARK: Data

    /// The profile the graph actions operate on. Prefers the server's copy and
    /// falls back to what the row already had, so an action still works if the
    /// profile load failed.
    private var profileForActions: RemoteProfile {
        remote ?? RemoteProfile(uid: uid,
                                handle: "",
                                handleDisplay: "",
                                name: fallbackName,
                                avatarEmoji: fallbackEmoji,
                                city: "",
                                bio: "",
                                isPrivate: false)
    }

    private func load() async {
        guard isRemote, remote == nil else { return }
        loading = true
        defer { loading = false }
        // Seed from what the graph already knows so the button doesn't flash
        // "Follow" for someone this user is plainly already following.
        isFollowing = followGraph.isFollowing(uid)
        do {
            let loaded = try await FirestoreService.publicProfile(uid: uid)
            remote = loaded.profile
            status = loaded.friendship
            mutuals = loaded.mutualCount
            isFollowing = loaded.isFollowing
            followerCount = loaded.profile.followers
        } catch let error as CallableFunctions.CallableError {
            loadError = error.message
        } catch {
            loadError = "Couldn't load this profile."
        }
    }

    private func perform(_ work: @escaping () async throws -> FriendshipStatus) async {
        guard !working else { return }
        working = true
        actionError = nil
        defer { working = false }
        do {
            let resolved = try await work()
            withAnimation(.easeOut(duration: 0.18)) { status = resolved }
        } catch let error as CallableFunctions.CallableError {
            actionError = error.message
        } catch {
            actionError = "Couldn't reach the server."
        }
    }

    private func blockThem() async {
        safety.blocking = nil
        working = true
        defer { working = false }
        try? await friendGraph.block(profileForActions, context: modelContext)
        dismiss()
    }

    /// The DM with this account, creating one if this is the first message.
    private func chatWithThem() -> Chat? {
        guard let them = friend ?? friends.first(where: { $0.remoteUID == uid }),
              let me = friends.first(where: { $0.isMe }) else { return nil }
        return Chat.dm(with: them, me: me, in: modelContext)
    }
}

/// One rounded card in a profile's Highlights grid — the clip's own gradient
/// and emoji, plus a caption clipped to a single line. No like/view counts;
/// this is a scrapbook, not a leaderboard.
private struct HighlightThumbnail: View {
    let clip: SpotClip

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.clipGradient(hueA: clip.hueA, hueB: clip.hueB)
            Text(clip.emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if !clip.label.isEmpty {
                Text(clip.label)
                    .font(.logCaption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        LinearGradient(colors: [.black.opacity(0.55), .clear],
                                       startPoint: .bottom, endPoint: .top)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Highlight player

/// A single one of your own logs, full screen and playing.
///
/// The other-profile grid redirects into the Places feed instead (see
/// `PublicProfileSheet.openHighlight`), which is the right move for browsing
/// someone else's public posts — you land in the feed those posts live in. On
/// your own profile there is nothing to go and browse: you tapped a specific
/// log, so this plays that log and nothing else.
///
/// Built on `StackedClipPane` so a highlight looks exactly like it does
/// everywhere else — same caption placement, same hour banner, same reaction
/// badges. The pane reads its playhead from a `ClipSyncClock`, which the
/// stacked feeds own per-feed; with one clip there is nothing to synchronize
/// *with*, but the clock still drives the loop, so this owns one of its own.
private struct HighlightPlayerView: View {
    let clip: Clip
    /// Only used for the avatar orb — the pane deliberately shows no name
    /// chip for your own log, the same as your pane in the paired feed.
    let author: Friend?

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StackedClipPane(clip: clip,
                            authorName: nil,
                            authorEmoji: author?.emoji ?? "✨",
                            authorHue: author?.hue ?? 0.58,
                            roleLabel: "you",
                            headerTopPadding: 44,
                            avatarSource: author,
                            contentMode: .fit)
                .environment(clock)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            CloseButton(overMedia: true) { dismiss() }
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }
}
