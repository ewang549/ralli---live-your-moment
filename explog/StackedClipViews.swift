import SwiftUI
import SwiftData

// MARK: - Layout safety

/// Clamps a dimension derived from a `GeometryReader` so it can never be passed
/// to `.frame(width:height:)` as a negative, zero, or non-finite value — the
/// exact inputs that trigger SwiftUI's "invalid frame dimension" runtime error.
/// During a full-screen cover's present/dismiss transition `proxy.size` can
/// momentarily read 0, so every geometry-driven frame in this file routes
/// through this.
extension CGFloat {
    var safeDimension: CGFloat { (isFinite && self > 0) ? self : 1 }
}

/// One place that defines what a "video container" is, so every feed renders
/// clips in identically-proportioned cards (per the uniform-sizing rule).
enum VideoCard {
    /// Portrait 9:16 — the aspect every clip container is normalized to.
    static let aspectRatio: CGFloat = 9.0 / 16.0
    static let cornerRadius: CGFloat = 24
    /// How many equal cards the continuous group feed fits per screen height.
    static let groupVisibleCount: CGFloat = 3
}

// MARK: - Shared clip pane
//
// One full-bleed clip with its caption overlaid. This is the unit every stacked
// layout is built from, so captions, avatars and sync behave identically
// whether you're in a 1-on-1, a group, or the all-friends feed.

struct StackedClipPane: View {
    let clip: Clip?
    /// Name shown on the pane; nil hides the chip (used for "you").
    let authorName: String?
    let authorEmoji: String
    let authorHue: Double
    /// Label under the name, e.g. "you".
    var roleLabel: String?
    /// Extra space above the author chip so it clears the timestamp banner /
    /// status bar on whichever pane sits at the top of the screen.
    var headerTopPadding: CGFloat = 0
    /// The real friend behind this pane, when tapping the author should open
    /// their profile. Nil for "you" (nothing to view) and for placeholder panes.
    var authorFriend: Friend?
    /// Whose profile photo the orb draws.
    ///
    /// Separate from `authorFriend`, which is deliberately nil on your own
    /// pane so tapping it doesn't open your own profile sheet — your avatar
    /// still has to render there. Nil falls back to the emoji orb.
    var avatarSource: Friend?

    /// Which hour this pane is showing, when it sits on an hour axis.
    ///
    /// Only used for copy: it lets the empty state say *this hour* had nothing
    /// rather than implying the person has never logged at all. Nil on panes
    /// that always show the latest clip (the group feed).
    var viewingHour: Date?

    /// Steps the hour axis by `-1` or `+1`, from a tap on the pane's leading or
    /// trailing quarter. Nil leaves the pane with no scrub gesture at all.
    ///
    /// Handled inside the pane rather than by the caller as an `.overlay` so
    /// the layering is right by construction: the zones go above the media but
    /// below the author chip and the action rail, which would otherwise lose
    /// their taps to them. The rail sits in the trailing quarter on these
    /// feeds, so relying on the inert middle alone wouldn't be enough here.
    var onStepHour: ((Int) -> Void)?
    /// Jumps a whole day by `-1` or `+1`, from a horizontal swipe.
    ///
    /// The bigger sibling of `onStepHour`: a tap crawls the axis hour by hour
    /// and rolls over midnight on its own, a swipe skips the walk and lands on
    /// the start of the neighbouring day. Nil falls back to the hour step, so a
    /// pane that hasn't opted in behaves exactly as it did.
    var onSwipeDay: ((Int) -> Void)?
    /// False at the current hour, where there is nothing ahead to step into.
    var canStepHourForward: Bool = true

    /// How the media sits in the pane. `.fit` by default, and every caller
    /// wants it: a log is never cropped anywhere in the app, only ever shown
    /// smaller. The default used to be `.fill`, which meant a caller that
    /// simply forgot to pass anything silently cut the edges off the shot —
    /// including any sticker or doodle placed near them.
    var contentMode: ContentMode = .fit

    /// Whether this is the pane the viewer is actually on.
    ///
    /// Forwarded straight to `ClipView`, which pauses its player when this goes
    /// false. It used to be hardcoded `true` here, so in a paged feed every
    /// pane still resident in the lazy stack kept playing — swiping to the next
    /// friend mounted a *new* pane rather than reusing the old one, so nothing
    /// ever told the one you left to stop and its audio played on underneath.
    /// Defaults to true for the continuous feeds, where several cards on screen
    /// at once are all genuinely "on screen".
    var isActive: Bool = true

    @Environment(ClipSyncClock.self) private var clock
    @State private var showProfile = false

    var body: some View {
        ZStack {
            // Backdrop for the letterbox bars when the media is fitted rather
            // than filled. Fully covered in the `.fill` case, so it costs the
            // full-bleed feeds nothing.
            Color.black

            if let clip {
                ClipView(clip: clip, isActive: isActive,
                         contentMode: contentMode, restartToken: clock.cycle)
                    // The clock synchronizes the stack by *value*, not by view
                    // identity: every pane gets the same cycle number and seeks
                    // its live player back to zero on the same tick.
                    //
                    // This used to live in `.id()`, which restarted the panes by
                    // destroying and rebuilding them. That resynced them, but it
                    // also threw away each player and reattached a new one only
                    // after an async asset load, so every cycle boundary blanked
                    // to black — the "black screen between loops". Identity is
                    // now the clip alone, so a pane is built once and kept.
                    .id(clip.id)
            } else {
                noClipPlaceholder
            }

            // Legibility scrim — captions sit over live video.
            ClipStampScrim()

            // The hour this log was filmed, burned across the middle of the
            // frame — the same banner the camera and the review screen show,
            // so a log carries one stamp from capture through to the feed.
            //
            // The caption rides directly beneath it, a size down, exactly as
            // `PostCaptureReview` composes the two: they are one stamp block,
            // not two overlays. It used to be bottom-pinned in the chrome stack
            // below, so a caption the user had watched sit under the time on
            // the review screen jumped to the far corner the moment the log was
            // sent and played back.
            if let clip {
                ClipStamp(date: clip.capturedAt, caption: clip.label)
            }

            // Hour scrubbing sits here in the stack: over the media and the
            // overlays above, under the author chip below.
            if let onStepHour {
                EdgeStepZones(onBack: { onStepHour(-1) },
                              onForward: { onStepHour(1) },
                              onSwipeBack: onSwipeDay.map { step in { step(-1) } },
                              onSwipeForward: onSwipeDay.map { step in { step(1) } },
                              canStepForward: canStepHourForward)
            }

            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.top, headerTopPadding)
                Spacer()
                // Reaction badges sit at the container's bottom-left — where a
                // friend's reactions land on their log. Pure readout, so left
                // hit-testable they'd swallow taps meant for the scrub zones;
                // the author chip above stays tappable.
                if let reactions = clip?.reactions, !reactions.isEmpty {
                    reactionBadges(reactions)
                        .allowsHitTesting(false)
                }
            }
            .padding(14)
        }
        .clipped()
        .contentShape(Rectangle())
        .fullScreenCover(isPresented: $showProfile) {
            if let authorFriend { PublicProfileSheet(friend: authorFriend) }
        }
    }

    /// De-duplicated reaction chips (emoji + count) pinned bottom-left.
    private func reactionBadges(_ reactions: [Reaction]) -> some View {
        // Group identical emoji so "❤️❤️🔥" reads as "❤️ 2  🔥 1".
        let counts = reactions.reduce(into: [String: Int]()) { $0[$1.emoji, default: 0] += 1 }
        return HStack(spacing: 6) {
            ForEach(counts.keys.sorted(), id: \.self) { emoji in
                HStack(spacing: 3) {
                    Text(emoji).font(.system(size: 15))
                    if let count = counts[emoji], count > 1 {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.5)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
        }
        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button {
                guard authorFriend != nil else { return }
                showProfile = true
            } label: {
                HStack(spacing: 9) {
                    // Coral ring marks the author who actually posted this slot.
                    GlassOrbAvatar(emoji: authorEmoji, hue: authorHue, size: 32,
                                   isActive: clip != nil,
                                   photoURL: avatarSource?.avatarPhotoURL,
                                   remotePhotoURL: avatarSource?.avatarRemotePhotoURL)
                    VStack(alignment: .leading, spacing: 1) {
                        if let authorName {
                            Text(authorName)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .shadow(color: .black.opacity(0.6), radius: 4)
                        }
                        if let roleLabel {
                            Text(roleLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(authorFriend == nil)

            // No hour pill here. The hour is already burned across the middle
            // of the frame by `HourOverlay` at 34pt — a second, smaller copy of
            // the same string in the corner was the same fact stated twice.
            Spacer()
        }
    }

    private var noClipPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.baseElevated, Theme.base],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Text(authorEmoji).font(.system(size: 34)).opacity(0.5)
                Text(emptyStateCopy)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// On an hour axis an empty slot means "nothing *this* hour", not "nothing
    /// ever" — and once you can scrub between hours, the old wording reads as
    /// the wrong claim about the person on almost every slot you land on.
    private var emptyStateCopy: String {
        guard let viewingHour else { return "no clip yet" }
        if Calendar.current.isDate(viewingHour, equalTo: .now, toGranularity: .hour) {
            return "nothing this hour yet"
        }
        return "nothing at \(viewingHour.formatted(.dateTime.hour()))"
    }
}

// MARK: - A. 1-on-1 stacked log detail with vertical paging

/// The friend's 2-second log on top (the larger card, carrying the reply +
/// reaction overlay), your own underneath (the smaller card), with the whole
/// pair paging vertically to the next friend.
///
/// The two cards are inset rounded panes rather than a flush split, and the
/// split is deliberately *not* 50/50 — the friend's log is the focus, so it
/// gets the taller container.
///
/// Two orthogonal navigation axes: swipe vertically to move between friends,
/// tap the leading or trailing edge to move the pair back or forward an hour. The
/// hour applies to *both* panes at once, so you're always comparing the same
/// slot of the same day rather than two unrelated "latest" clips.
struct FriendPairFeedView: View {
    let friends: [Friend]
    let me: Friend?
    /// Friend to open on first appearance.
    var startingFriend: Friend?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @State private var clock = ClipSyncClock()
    @State private var currentIndex: Int = 0
    /// The friend thread to open when Reply is tapped on a friend's card.
    @State private var replyChat: Chat?
    /// Which clock hour the pair is showing. The same type the Pulse feed uses,
    /// so "the hour you're on" means one thing across the app — including the
    /// clamp that stops it walking into the future.
    @State private var hourState = HourFeedState()

    private var viewingHour: Date { hourState.selectedHour }

    /// Moves the whole pair one hour, and restarts both panes together so the
    /// newly-loaded clips play in step rather than mid-cycle.
    private func stepHour(_ delta: Int) {
        let before = hourState.selectedHour
        withAnimation(.easeInOut(duration: 0.2)) { hourState.step(delta) }
        guard hourState.selectedHour != before else { return } // clamped at "now"
        clock.resync()
    }

    /// The swipe's move: a whole day in one gesture, keeping the hour you were
    /// reading so the same time of day is what you land on.
    private func stepDay(_ delta: Int) {
        let before = hourState.selectedHour
        withAnimation(.easeInOut(duration: 0.2)) { hourState.stepDay(delta) }
        guard hourState.selectedHour != before else { return } // clamped at "now"
        clock.resync()
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            GeometryReader { proxy in
                // Vertical paging over friends. `.scrollTargetBehavior(.paging)`
                // snaps a whole pair into place per swipe.
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                            // Only the page you're actually on plays. A paged
                            // scroll keeps neighbouring pages mounted, and
                            // every one of them used to be told it was active.
                            pairPage(for: friend, height: proxy.size.height,
                                     isActive: index == currentIndex)
                                .scrollTransition(.interactive.threshold(.visible(0.9))) { view, phase in
                                    view
                                        .opacity(phase.isIdentity ? 1 : 0.5)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.93)
                                }
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: Binding(
                    get: { currentIndex },
                    set: { newValue in
                        guard let newValue, newValue != currentIndex else { return }
                        currentIndex = newValue
                        // Restart the pair together rather than mid-cycle.
                        clock.resync()
                    }
                ))
            }
            .ignoresSafeArea()

            timestampBanner
        }
        .environment(clock)
        // Reply opens the very same thread engine used everywhere else.
        .sheet(item: $replyChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .task {
            if let startingFriend, let index = friends.firstIndex(where: { $0.id == startingFriend.id }) {
                currentIndex = index
            }
            clock.start()
        }
        .onDisappear { clock.stop() }
    }

    /// One page: the friend's card on top (with actions), yours below —
    /// identically sized per the uniform video-sizing rule.
    private func pairPage(for friend: Friend, height: CGFloat, isActive: Bool) -> some View {
        // Insets carve the pair out of the screen: the top inset clears the
        // floating timestamp banner, and the cards leave a margin all round.
        let topInset: CGFloat = 92
        let bottomInset: CGFloat = 22
        let gap: CGFloat = 10
        // Uniform sizing: both containers get exactly half the usable height,
        // so your clip and the friend's clip render at identical dimensions.
        // Clamped so a transient 0-height geometry pass can't emit a negative
        // frame ("invalid frame dimension").
        let usable = height - topInset - bottomInset - gap
        // The *ceiling* on a card, not its size. The card itself takes the
        // clip's shape (below) and simply never grows past half the usable
        // height, so the pair still splits the screen evenly.
        let cardHeight = (usable / 2).safeDimension
        // Both panes resolve against the same hour, so the pair is always the
        // same slot of the same day rather than two unrelated "latest" clips.
        let theirClip = friend.clip(forHourContaining: viewingHour)
        // Scoped to the thread with *this* friend, not to my whole history. See
        // `Chat.myClip(forHourContaining:)`. Read-only resolution on purpose —
        // `dmChat(with:)` creates the thread when it's missing, and doing that
        // here would insert an empty DM for every friend merely paged past.
        let myClip = existingDMChat(with: friend)?.myClip(forHourContaining: viewingHour)
        // One shape for both cards, so the pair stays a like-for-like
        // comparison — that uniformity is the point of this screen, and
        // shaping each card to its own clip would make the two halves
        // different sizes. Taken from whichever clip exists (theirs first,
        // since that's the pane the eye lands on), and the capture default
        // when the hour is empty on both sides.
        let pairRatio = (theirClip ?? myClip)?.displayAspectRatio ?? Clip.defaultAspectRatio

        return VStack(spacing: gap) {
            // Top — the friend's log, carrying the reaction + reply overlay.
            logCard {
                StackedClipPane(
                    clip: theirClip,
                    authorName: friend.name,
                    authorEmoji: friend.emoji,
                    authorHue: friend.hue,
                    roleLabel: friend.displayUserId.isEmpty ? nil : friend.displayUserId,
                    authorFriend: friend,
                    avatarSource: friend,
                    viewingHour: viewingHour,
                    onStepHour: stepHour,
                    onSwipeDay: stepDay,
                    canStepHourForward: !hourState.isAtCurrentHour,
                    contentMode: .fit,
                    isActive: isActive
                )
            }
            .aspectRatio(pairRatio, contentMode: .fit)
            // Centred on the trailing edge, not pinned to the bottom corner.
            // The card takes the clip's own shape now, so a bottom-corner
            // anchor moved with every clip's aspect ratio — on a landscape log
            // the rail rode up into a short card and bunched against the
            // reaction badges. The right edge's midpoint is the one place that
            // reads the same whatever shape the card resolves to.
            //
            // Applied before the half-height frame below, so the rail sits on
            // the *card's* edge rather than floating in the empty part of the
            // slot the card doesn't fill.
            .overlay(alignment: .trailing) {
                FriendLogActions(clip: theirClip, me: me,
                                 resolveChat: { dmChat(with: friend) }) {
                    replyChat = dmChat(with: friend)
                }
                .padding(.trailing, 14)
            }
            // Pinned to the *bottom* of its half, not centred in it. The frame
            // claims the full `cardHeight` whether or not the card fills it,
            // and a landscape clip's aspect-fit height falls far short of half
            // a portrait screen — so centring left a band of dead slot hanging
            // under this card and the same again over the next one, reading as
            // one huge gap even though `gap` never moved. Anchoring each card
            // to the edge nearest the other makes the visible separation
            // exactly `gap`, whatever shape the clips turn out to be.
            .frame(maxHeight: cardHeight, alignment: .bottom)

            // Bottom — your own log: the identical container.
            logCard {
                StackedClipPane(
                    clip: myClip,
                    authorName: me?.name ?? "You",
                    authorEmoji: me?.emoji ?? "🙂",
                    authorHue: me?.hue ?? 0.58,
                    roleLabel: "you",
                    avatarSource: me,
                    viewingHour: viewingHour,
                    onStepHour: stepHour,
                    onSwipeDay: stepDay,
                    canStepHourForward: !hourState.isAtCurrentHour,
                    contentMode: .fit,
                    isActive: isActive
                )
            }
            .aspectRatio(pairRatio, contentMode: .fit)
            // The mirror of the top card: pinned to the *top* of its half, so
            // the two cards meet across exactly `gap`.
            .frame(maxHeight: cardHeight, alignment: .top)
        }
        .padding(.horizontal, 12)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(height: height.safeDimension)
    }

    /// Rounded, hairline-ringed container shared by both panes.
    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }

    private func dmChat(with friend: Friend) -> Chat? {
        resolveDMChat(with: friend, me: me, chats: chats, context: modelContext)
    }

    /// The existing DM with `friend`, or nil.
    ///
    /// Deliberately never creates one, which is what makes it safe to call
    /// while the feed renders — unlike `dmChat(with:)`, whose whole job is
    /// create-or-reuse and which has to stay behind a button press.
    private func existingDMChat(with friend: Friend) -> Chat? {
        chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
    }

    /// Which hour the pair is showing, pinned above both panes.
    ///
    /// Reads the *viewed* hour rather than the wall clock: once the left/right
    /// zones can walk you back through the day, a banner stuck on "now" is the
    /// only thing on screen still claiming you're in the live hour. The live
    /// dot breathes only when you actually are.
    private var timestampBanner: some View {
        HStack(spacing: 10) {
            CloseButton(overMedia: true) { dismiss() }

            Spacer()

            // Floats over the screen's own background rather than over media,
            // so it follows the appearance instead of staying white-on-black.
            HStack(spacing: 7) {
                if hourState.isAtCurrentHour {
                    GlowDot(size: 7, breathing: true)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(viewingHour.hourOnlyClockTime)
                    .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                // The hour alone can't tell you which day you're on, and this is
                // the screen where tapping through midnight happens most: "11 PM"
                // → "12 AM" looks like nothing happened without the date beside it.
                Text("·")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                Text(hourState.dayLabel)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))

            Spacer()

            // Balances the leading button.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: viewingHour)
    }
}

// MARK: - Thread resolution

/// The 1-on-1 thread with `friend`, created if there isn't one yet.
///
/// The read-only lookup this replaces returned nil for a friend you'd accepted
/// but never messaged or sent a log to — they have no `Chat` row until
/// something makes one (see `Chat.dm`). That silently broke half of each action
/// on their card: a reaction still added its badge, but the broadcast into the
/// DM was skipped, and Reply opened nothing at all.
///
/// Call this from a button's action, never from `body`. Resolving it while
/// rendering would write a chat row for every friend merely scrolled past.
private func resolveDMChat(with friend: Friend, me: Friend?,
                           chats: [Chat], context: ModelContext) -> Chat? {
    guard let me else {
        // No local "me" row yet — fall back to a read-only lookup rather than
        // fabricating a thread with no sender in it.
        return chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
            ?? chats.first { $0.members.contains { $0.id == friend.id } }
    }
    return Chat.dm(with: friend, me: me, in: context)
}

// MARK: - Friend log action overlay (reply + emoji reaction)

/// The two vertically-stacked actions on the bottom-right of a friend's log
/// card: emoji reaction on top, reply beneath it (per the reference).
///
/// Reaction gestures are isolated so they never fight the paging swipe or a
/// tap: the button's own action opens the full picker, and a `.simultaneous`
/// long-press reveals the 5-emoji quick tray.
private struct FriendLogActions: View {
    let clip: Clip?
    let me: Friend?
    /// Thread this friend's log belongs to; a reaction is broadcast here so it
    /// also lands in the chat as a message. nil → badge-only (no thread).
    ///
    /// A closure rather than a value because resolving it can *create* the
    /// thread, and that must happen when the button is pressed — not while the
    /// feed renders. See `FriendPairFeedView.dmChat(with:)`.
    var resolveChat: () -> Chat?
    let onReply: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showQuickTray = false
    @State private var showEmojiPicker = false

    /// The 5 popular reactions in the quick tray.
    private let quickEmoji = ["❤️", "🔥", "😂", "😮", "👏"]

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Quick-reaction tray — revealed by long-pressing the react button.
            if showQuickTray {
                HStack(spacing: 14) {
                    ForEach(quickEmoji, id: \.self) { emoji in
                        Button { react(with: emoji) } label: {
                            Text(emoji).font(.system(size: 26))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                // Anchored where the rail now sits — the trailing edge — so the
                // tray grows out of the button that revealed it.
                .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }

            // Emoji reaction: tap → full picker, long-press → quick tray.
            actionButton(system: "face.smiling.inverse") {
                showEmojiPicker = true
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                    withAnimation(.spring(duration: 0.3)) { showQuickTray.toggle() }
                }
            )

            // Reply: opens the message thread with this friend.
            actionButton(system: "arrowshape.turn.up.left.fill", action: onReply)
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiReactionPicker { emoji in
                react(with: emoji)
                showEmojiPicker = false
            }
        }
    }

    private func actionButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(.black.opacity(0.4))
                        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func react(with emoji: String) {
        guard let clip else { return }
        let mine = Reaction(emoji: emoji, authorName: me?.name ?? "You")
        // Toggle: tapping the same reaction again removes it.
        withAnimation(.spring(duration: 0.3)) {
            if let index = clip.reactions.firstIndex(of: mine) {
                clip.reactions.remove(at: index)
            } else {
                clip.reactions.append(mine)
                // Broadcast the reaction into the chat thread — the same
                // reaction shows up as a message overlaying this clip's
                // preview. Only on add, so removing a reaction doesn't post.
                if let chat = resolveChat() {
                    if StreamConfig.isEnabled {
                        // The thread this lands in is a real Stream channel,
                        // and a local `Message` row is invisible to it: the
                        // reaction has to be an actual message on the channel
                        // or it reaches neither side's thread.
                        Task { await StreamThreadPoster.postReaction(emoji, to: clip, in: chat) }
                        // A Stream message leaves no local `Message` row, so
                        // Pulse's outgoing order has to be told about it here
                        // — the thread isn't open to notice it going out.
                        chat.noteOutgoingMessage(at: .now)
                    } else {
                        let message = Message.reaction(emoji, to: clip, from: me, in: chat)
                        modelContext.insert(message)
                        chat.messages.append(message)
                    }
                }
            }
        }
        try? modelContext.save()
        withAnimation(.spring(duration: 0.3)) { showQuickTray = false }
    }
}

// MARK: - Full emoji picker

/// A scrollable grid of reactions, presented when the emoji button is tapped.
/// Deliberately broad so "any emoji" is a reasonable claim without pulling in
/// a full system keyboard.
struct EmojiReactionPicker: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let emojis: [String] = [
        "❤️", "🔥", "😂", "😮", "👏", "🥰", "😍", "🤩", "😭", "🥺", "😅", "😎",
        "🙌", "👍", "👎", "🙏", "💯", "✨", "🎉", "😳", "🤔", "😴", "🤯", "😤",
        "🥳", "😱", "🫶", "💀", "👀", "😇", "🤗", "😆", "😉", "😜", "🤪", "😏",
    ]
    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            Text("React")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button { onPick(emoji) } label: {
                            Text(emoji).font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .background(GlassBackground())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - B. Group chat video feed

/// Every member's current 2-second clip in one continuous vertical scroll —
/// about three equal-sized cards to a screen, scrolling smoothly like a long
/// sheet (no page snapping). Every card is the same width, height, and aspect
/// ratio, so no member's clip renders larger than another's.
struct GroupClipFeedView: View {
    let chat: Chat

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()
    /// Thread to open when Reply is tapped — the group's own chat.
    @State private var replyChat: Chat?

    private var me: Friend? { chat.members.first { $0.isMe } }

    /// One clip per member, most recent first, skipping members with nothing.
    private var entries: [(friend: Friend, clip: Clip?)] {
        chat.members.map { member in
            (member, chat.sortedClips.first { $0.author?.id == member.id })
        }
        .sorted { ($0.clip?.capturedAt ?? .distantPast) > ($1.clip?.capturedAt ?? .distantPast) }
    }

    private let cardSpacing: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            GeometryReader { proxy in
                // Height that fits `groupVisibleCount` equal cards plus the gaps
                // between them. Clamped so a transient 0-height layout pass can
                // never emit a negative/zero frame.
                let count = VideoCard.groupVisibleCount
                let totalGaps = cardSpacing * (count - 1)
                let cardHeight = ((proxy.size.height - totalGaps) / count).safeDimension
                let cardWidth = (proxy.size.width - 24).safeDimension

                // Continuous scroll — no `.scrollTargetBehavior(.paging)`, so it
                // glides rather than snapping one clip at a time.
                ScrollView(.vertical) {
                    LazyVStack(spacing: cardSpacing) {
                        // Top spacer clears the floating title bar so the first
                        // card starts below it.
                        Color.clear.frame(height: 74)

                        ForEach(Array(entries.enumerated()), id: \.element.friend.id) { index, entry in
                            groupCard(entry: entry, width: cardWidth, height: cardHeight)
                                // Start pulling the next couple of cards' media
                                // while this one plays, so scrolling forward
                                // usually meets an already-cached file instead
                                // of a cold network load.
                                .onAppear { prefetchClips(after: index) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .ignoresSafeArea()

            header
        }
        .environment(clock)
        .sheet(item: $replyChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .task { clock.start() }
        .onDisappear { clock.stop() }
    }

    /// Warms the cache for the two cards after `index`.
    private func prefetchClips(after index: Int) {
        let all = entries
        for next in (index + 1)...(index + 2) where next < all.count {
            guard let url = all[next].clip?.remoteURL else { continue }
            VideoCache.shared.warm(url)
        }
    }

    /// One uniform member card. A friend's card carries the reaction + reply
    /// overlay; your own card doesn't (you don't react to yourself).
    @ViewBuilder
    private func groupCard(entry: (friend: Friend, clip: Clip?), width: CGFloat, height: CGFloat) -> some View {
        // The card is the clip's shape at this width, capped at the uniform
        // slot height so the feed still fits `groupVisibleCount` per screen.
        // `height` is a ceiling now rather than the size: forcing every card to
        // the same box is what produced bars that didn't line up with the
        // video's real edges.
        let cardRatio = entry.clip?.displayAspectRatio ?? Clip.defaultAspectRatio
        let cardHeight = min(height, (width / cardRatio).safeDimension).safeDimension
        logCard {
            StackedClipPane(
                clip: entry.clip,
                authorName: entry.friend.name,
                authorEmoji: entry.friend.emoji,
                authorHue: entry.friend.hue,
                roleLabel: entry.friend.isMe ? "you" : nil,
                authorFriend: entry.friend.isMe ? nil : entry.friend,
                avatarSource: entry.friend,
                contentMode: .fit
            )
        }
        .frame(width: width, height: cardHeight)
        // Trailing-centred, for the same reason as the 1-on-1 feed's rail: the
        // card's height is the clip's shape now, so a bottom corner is a
        // different place on every card.
        .overlay(alignment: .trailing) {
            if !entry.friend.isMe {
                // The group's own thread — it always exists, so there's
                // nothing to create here.
                FriendLogActions(clip: entry.clip, me: me, resolveChat: { chat }) {
                    replyChat = chat
                }
                .padding(.trailing, 12)
            }
        }
    }

    /// Rounded, hairline-ringed container — matches the 1-on-1 feed's card.
    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: VideoCard.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VideoCard.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }

    private var header: some View {
        HStack(spacing: 10) {
            CloseButton(overMedia: true) { dismiss() }
            Spacer()
            // Title chrome, over the screen background rather than over a card:
            // adaptive ink, or it vanishes into the canvas in light mode.
            VStack(spacing: 1) {
                Text(chat.displayName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(chat.members.count) members")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - C. All-friends hour feed

/// One hour of the day across the whole roster: every friend's log for the
/// hour you're standing in, stacked about four to a screen and scrolling
/// continuously — a long sheet of the hour rather than a deck of pages.
///
/// Two things make this different from the feeds above. The vertical axis is
/// not paged: `.scrollTargetBehavior(.paging)` is deliberately absent so the
/// list unrolls rather than snapping one friend at a time. And the horizontal
/// axis is the hour, shared by every row at once — tapping either side of any
/// row moves the entire roster to the adjacent hour, so you are always reading
/// one slice of time across everybody rather than each person's own latest.
struct AllFriendsFeedView: View {
    let friends: [Friend]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @State private var clock = ClipSyncClock()
    /// The friend thread to open when Reply is tapped on a card.
    @State private var replyChat: Chat?
    /// The hour every row resolves against. One value for the whole screen —
    /// this is what makes a tap shift everybody together — and the same type
    /// the Pulse feed and the paired feed use, so the clamp at "now" and the
    /// meaning of "the hour you're on" are shared rather than reimplemented.
    @State private var hourState = HourFeedState()

    private var viewingHour: Date { hourState.selectedHour }

    private var me: Friend? { friends.first { $0.isMe } }

    private static let rowSpacing: CGFloat = 10

    /// The whole roster, in a stable order.
    ///
    /// Everyone is listed whether or not they logged this hour: an empty slot
    /// is information — it says nobody was around at 4pm — and dropping those
    /// rows would leave the feed silently shorter on quiet hours. Sorted by
    /// name rather than by recency for the same reason the hour is shared: with
    /// a recency sort the rows would reshuffle under your thumb every time you
    /// scrubbed, and the same person would never be in the same place twice.
    private var entries: [Friend] {
        friends
            .filter { !$0.isMe }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Moves every row an hour, and restarts the visible clips together so the
    /// newly-resolved hour plays in step instead of mid-cycle.
    private func stepHour(_ delta: Int) {
        let before = hourState.selectedHour
        withAnimation(.easeInOut(duration: 0.2)) { hourState.step(delta) }
        guard hourState.selectedHour != before else { return } // clamped at "now"
        clock.resync()
    }

    /// The swipe's move, as on the paired feed: a whole day at once, carrying
    /// the current hour across rather than restarting at midnight.
    private func stepDay(_ delta: Int) {
        let before = hourState.selectedHour
        withAnimation(.easeInOut(duration: 0.2)) { hourState.stepDay(delta) }
        guard hourState.selectedHour != before else { return } // clamped at "now"
        clock.resync()
    }

    var body: some View {
        GeometryReader { proxy in
            // The list's own horizontal padding, taken off here so a row knows
            // the width it actually gets to size its card against.
            let rowWidth = (proxy.size.width - 24).safeDimension
            // The row *is* the capture's shape rather than a fraction of the
            // screen's height. Both were uniform, but a screen fraction has no
            // relationship to what `.fit` actually draws, so every row carried a
            // black band above and below the video. At the landscape ratio the
            // clip fills the box exactly and there's nothing left for
            // `StackedClipPane`'s backdrop to show through.
            let rowHeight = (rowWidth / Clip.defaultAspectRatio).safeDimension

            // A plain scroll view: no paging behavior and no scroll position
            // binding, so it glides continuously. The rows keep
            // `StackedClipPane`'s identity-by-clip rule, which is what stops a
            // scroll from tearing down and rebuilding live players.
            ScrollView(.vertical) {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, friend in
                        row(for: friend, width: rowWidth, height: rowHeight)
                            // See `GroupClipFeedView.prefetchClips`.
                            .onAppear { prefetchClips(after: index) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            // The title bar reserves its own space rather than the list
            // guessing at it. A fixed top spacer had to encode both the header
            // height and the device's safe-area inset, and got the first row
            // tucked underneath the title on any phone where that guess was
            // short — which was all of them.
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .background(Theme.base.ignoresSafeArea())
        .environment(clock)
        .sheet(item: $replyChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .task { clock.start() }
        .onDisappear { clock.stop() }
    }

    /// Warms the cache for the two rows after `index`, resolved against the
    /// hour currently on screen.
    private func prefetchClips(after index: Int) {
        let all = entries
        for next in (index + 1)...(index + 2) where next < all.count {
            guard let url = all[next].clip(forHourContaining: viewingHour)?.remoteURL else { continue }
            VideoCache.shared.warm(url)
        }
    }

    /// One friend's slot for the viewed hour.
    ///
    /// The scrub zones live inside the row rather than as one overlay across
    /// the screen: a full-screen tap target sits above the scroll view and
    /// swallows the drag that scrolls it. Per-row zones all drive the same
    /// `viewingHour`, so the behaviour is the screen-wide one either way.
    @ViewBuilder
    private func row(for friend: Friend, width: CGFloat, height: CGFloat) -> some View {
        let clip = friend.clip(forHourContaining: viewingHour)
        // Every row is the same `width × height` box, populated or not — and
        // that box is the landscape capture ratio (see `body`), so uniform and
        // borderless are not in tension here the way they first looked.
        //
        // Sizing each row to its own clip instead does remove the bars, but
        // friends' clips aren't all the same shape, so the list becomes a ragged
        // column of differently-sized cards — much louder than a thin bar, on a
        // screen that's a scan down a list of people. Rows that stay put read as
        // one list. Anything that isn't the usual landscape shape letterboxes
        // inside the box via the `.fit` content mode below.

        Group {
            if let clip {
                StackedClipPane(
                    clip: clip,
                    authorName: friend.name,
                    authorEmoji: friend.emoji,
                    authorHue: friend.hue,
                    roleLabel: friend.displayUserId.isEmpty ? nil : friend.displayUserId,
                    authorFriend: friend,
                    avatarSource: friend,
                    viewingHour: viewingHour,
                    onStepHour: stepHour,
                    onSwipeDay: stepDay,
                    canStepHourForward: !hourState.isAtCurrentHour,
                    // Captures are landscape; filling a short wide row would
                    // crop away most of the shot, so it letterboxes instead —
                    // the same treatment post-capture and Places use.
                    contentMode: .fit
                )
                .frame(width: width.safeDimension, height: height.safeDimension)
            } else {
                emptySlot(for: friend)
                    .frame(width: width.safeDimension, height: height.safeDimension)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VideoCard.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VideoCard.cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        // React and reply, exactly as the 1-on-1 and group feeds carry them.
        // Only where there's a log to act on — the actions are inert without
        // one, and an empty slot is meant to stay plain.
        .overlay(alignment: .trailing) {
            if clip != nil {
                FriendLogActions(clip: clip, me: me,
                                 resolveChat: { dmChat(with: friend) }) {
                    replyChat = dmChat(with: friend)
                }
                .padding(.trailing, 10)
            }
        }
    }

    /// A friend who logged nothing this hour: a bare slot carrying just their
    /// name and the hour it stands in for.
    ///
    /// Deliberately not `StackedClipPane`'s emoji empty state. That one is
    /// decorative, and decoration repeated down a quarter-height list reads as
    /// content — a wall of illustrated cards implying everyone posted. A flat
    /// unadorned surface reads as absence, which is what this is.
    ///
    /// It draws a surface rather than the flat `Color.black` it used to: there
    /// is no video here for black to be the stage of, so in light mode a row of
    /// these was a column of black holes punched through the canvas.
    private func emptySlot(for friend: Friend) -> some View {
        ZStack {
            Theme.baseElevated

            EdgeStepZones(onBack: { stepHour(-1) },
                          onForward: { stepHour(1) },
                          onSwipeBack: { stepDay(-1) },
                          onSwipeForward: { stepDay(1) },
                          canStepForward: !hourState.isAtCurrentHour)

            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("nothing at \(hourState.hourLabel)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        }
    }

    /// Title bar, carrying which hour the whole feed is showing.
    private var header: some View {
        HStack(spacing: 10) {
            CloseButton(overMedia: true) { dismiss() }
            Spacer()
            // See `GroupClipFeedView.header` — same chrome, same reason.
            VStack(spacing: 1) {
                Text("All friends")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    if !hourState.isAtCurrentHour {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9, weight: .bold))
                    }
                    // The day is named even while live, so it's a constant rather
                    // than something that only appears once you've already tapped
                    // your way off today without noticing.
                    Text(hourState.isAtCurrentHour
                         ? "this hour · \(hourState.dayLabel)"
                         : "\(hourState.hourLabel) · \(hourState.dayLabel)")
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.numericText())
                }
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.2), value: viewingHour)
    }

    private func dmChat(with friend: Friend) -> Chat? {
        resolveDMChat(with: friend, me: me, chats: chats, context: modelContext)
    }
}
