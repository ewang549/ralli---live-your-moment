import SwiftUI
import SwiftData

// MARK: - Tab 5: Beacons — friends/public activity feed with privacy guards

struct BeaconsFeedView: View {
    @Query private var beacons: [Beacon]
    @Query private var friends: [Friend]
    @Environment(AppRouter.self) private var router
    @Environment(BeaconSync.self) private var beaconSync
    @Environment(\.modelContext) private var modelContext

    // NEW: feed segmentation (friends vs public community).
    enum Segment: String, CaseIterable {
        case friends = "Friends"
        case publicFeed = "Public"
    }
    @State private var segment: Segment = .friends
    @State private var showMyActivities = false
    @State private var showCreate = false
    @State private var showPrivacyAlert = false
    @State private var debugDetail: Beacon?
    @State private var debugChat: Beacon?

    private var me: Friend? { friends.first { $0.isMe } }

    /// Friends and Public aren't opposites: a friend hosting a public beacon
    /// belongs in both. The Friends segment used to exclude anything marked
    /// public, so a friend's open invite never appeared there at all. It asks
    /// who's hosting instead — `host` only resolves for someone with a local
    /// `Friend` row, i.e. an actual friend (or you), so a stranger's public
    /// beacon still stays out of it.
    private var filtered: [Beacon] {
        beacons
            .filter { segment == .publicFeed ? $0.isPublic : $0.host != nil }
            .sorted { $0.startsAt < $1.startsAt }
    }

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 0) {
                header

                // Friends ↔ Public as a single segmented pill: the active segment
                // is coral-washed with its count in a small coral pill.
                // Counts read off the same rules `filtered` applies, or the
                // badge promises rows the segment won't show.
                BeaconSegments(segment: $segment,
                               friendsCount: beacons.filter { $0.host != nil }.count,
                               publicCount: beacons.filter { $0.isPublic }.count)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(filtered, id: \.id) { beacon in
                            BeaconFeedCard(beacon: beacon)
                        }
                        if filtered.isEmpty { emptyState }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 118)
                }
                .scrollIndicators(.hidden)
            }
        }
        .overlay(alignment: .top) { syncErrorBanner }
        // Both segments load together: the counts on the segmented control are
        // part of the first impression, so a public feed that only fills in
        // after you tap over to it reads as empty.
        .refreshable { await syncBeacons() }
        .task { await syncBeacons() }
        .sheet(isPresented: $showMyActivities) {
            MyActivitiesSheet()
        }
        .sheet(isPresented: $showCreate) {
            NewActivitySheet()
        }
        // Guard clause: creating a public activity requires a public profile.
        .alert("Public Profile Required", isPresented: $showPrivacyAlert) {
            Button("Go to Profile Settings") { router.tab = .profile }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You must set your profile to Public to create or join community activities.")
        }
#if DEBUG
        .sheet(item: $debugDetail) { ActivityDetailSheet(beacon: $0) }
        .sheet(item: $debugChat) { ActivityChatView(beacon: $0) }
        .task {
            try? await Task.sleep(for: .seconds(0.5))
            let publicBeacons = beacons.filter(\.isPublic).sorted { $0.startsAt < $1.startsAt }
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "joined": showMyActivities = true
            case "publicbeacons": segment = .publicFeed
            case "detail": segment = .publicFeed; debugDetail = publicBeacons.first
            case "activitychat": segment = .publicFeed; debugChat = publicBeacons.first
            case "newbeacon": showCreate = true
            default: break
            }
        }
#endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Beacons")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            // "My joined activities" shortcut.
            GlassCircleButton(icon: "ticket.fill", label: "My joined activities") {
                showMyActivities = true
            }
            // Create a public activity (privacy-guarded) — the primary action.
            GlassCircleButton(icon: "plus", label: "Create an activity", isProminent: true) {
                startCreate()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Warm empty state — a friendly nudge plus the one coral create action.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("📡").font(.system(size: 54))
            VStack(spacing: 5) {
                Text(segment == .friends ? "No friend beacons yet" : "Nothing public nearby yet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(segment == .friends
                     ? "Start one and your friends can join in."
                     : "Be the first to light one up in your area.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: startCreate) {
                Label("Start a beacon", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.3), radius: 12, y: 4))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.horizontal, 24)
    }

    /// Pulls both feeds and pushes anything created while offline.
    private func syncBeacons() async {
        await beaconSync.syncDown(context: modelContext)
        await beaconSync.syncPublicDown(context: modelContext)
        await beaconSync.publishPending(context: modelContext)
    }

    /// A beacon that didn't reach the server, or a refused RSVP, is otherwise
    /// invisible: the row is already on screen either way. This is the one place
    /// that says so.
    @ViewBuilder
    private var syncErrorBanner: some View {
        if let message = beaconSync.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    beaconSync.clearError()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.accent))
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Create a beacon, honoring the public-profile privacy guard.
    private func startCreate() {
        if me?.isPrivate == true {
            showPrivacyAlert = true
        } else {
            showCreate = true
        }
    }
}

// MARK: - Segmented Friends / Public control

/// A single sunken pill split into two segments; the active one is coral-washed
/// with its count in a small coral pill. Reads as one control, not two chips.
struct BeaconSegments: View {
    @Binding var segment: BeaconsFeedView.Segment
    let friendsCount: Int
    let publicCount: Int

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 4) {
            segmentButton(.friends, count: friendsCount)
            segmentButton(.publicFeed, count: publicCount)
        }
        .padding(4)
        .background(Capsule().fill(Theme.sunken))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentButton(_ option: BeaconsFeedView.Segment, count: Int) -> some View {
        let isActive = segment == option
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { segment = option }
        } label: {
            HStack(spacing: 6) {
                Text(option.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.accentPressed : Theme.textSecondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(isActive ? Theme.onAccent : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(isActive ? AnyShapeStyle(Theme.accent)
                                                    : AnyShapeStyle(Theme.textSecondary.opacity(0.16)))
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background {
                if isActive {
                    Capsule().fill(Theme.accentWash)
                        .matchedGeometryEffect(id: "seg", in: slide)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - When it actually happens

extension Beacon {
    /// The start time as a date and a clock time.
    ///
    /// The counterpart to `BeaconCountdownChip`, which is purely relative. A
    /// countdown answers "how soon", which is the urgency signal; it cannot
    /// answer "which evening is this" — and until this existed, nothing in the
    /// Beacons UI could, on the feed or on the detail sheet.
    ///
    /// Today and tomorrow are named rather than dated: most activities are
    /// imminent, and "Sat, Jul 26" for something three hours away is a date the
    /// reader has to convert before it means anything.
    var startsAtLabel: String {
        let calendar = Calendar.current
        let time = startsAt.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(startsAt) { return "Today · \(time)" }
        if calendar.isDateInTomorrow(startsAt) { return "Tomorrow · \(time)" }
        let day = startsAt.formatted(.dateTime.weekday(.abbreviated).month().day())
        return "\(day) · \(time)"
    }
}

// MARK: - Countdown chip

/// A live countdown pill for a beacon's start time. Sunken/glass by default; when
/// the activity starts soon (<30 min) or is live, the dot pulses and the chip
/// goes coral — the feed feels time-sensitive.
struct BeaconCountdownChip: View {
    let startsAt: Date
    /// `true` renders white-on-glass for legibility over the hero image.
    var overMedia: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = Self.state(start: startsAt, now: context.date)
            let hot = state.urgent
            HStack(spacing: 6) {
                GlowDot(size: 7, color: hot ? Theme.accent : (overMedia ? .white : Theme.textSecondary),
                        breathing: hot)
                Text(state.text)
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(hot ? Theme.onAccent
                                         : (overMedia ? .white : Theme.textPrimary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(hot ? AnyShapeStyle(Theme.accent)
                              : AnyShapeStyle(overMedia ? AnyShapeStyle(.ultraThinMaterial)
                                                        : AnyShapeStyle(Theme.sunken)))
                    .overlay {
                        if overMedia && !hot {
                            Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.75)
                        }
                    }
                    .shadow(color: hot ? Theme.accent.opacity(0.35) : .clear, radius: 8, y: 2)
            }
        }
    }

    static func state(start: Date, now: Date) -> (text: String, urgent: Bool, live: Bool) {
        let delta = start.timeIntervalSince(now)
        if delta <= 0 { return ("Live now", true, true) }
        let hours = Int(delta) / 3600
        let minutes = (Int(delta) % 3600) / 60
        let text: String
        if hours > 0 { text = "\(hours) hr \(minutes) min" }
        else if minutes > 0 { text = "\(minutes) min" }
        else { text = "under a min" }
        return (text, delta < 30 * 60, false)
    }
}

// MARK: - Activity card

struct BeaconFeedCard: View {
    let beacon: Beacon

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(BeaconSync.self) private var beaconSync
    @Query private var friends: [Friend]
    @State private var showDetail = false
    @State private var showPrivacyAlert = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var joined: Bool {
        guard let me else { return false }
        return beacon.hasJoined(me)
    }

    @State private var joinPulse = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 14) {
                hostRow
                if !beacon.note.isEmpty {
                    Text(beacon.note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineLimit(2)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    capacityMeter
                    Spacer(minLength: 4)
                    actions
                }
            }
            .padding(16)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(hex: 0x14121E, alpha: 0.07), radius: 18, y: 8)
        .shadow(color: Color(hex: 0x14121E, alpha: 0.05), radius: 1.5, y: 1)
        .sheet(isPresented: $showDetail) {
            ActivityDetailSheet(beacon: beacon)
        }
        // Guard clause: joining a PUBLIC activity requires a public profile.
        .alert("Public Profile Required", isPresented: $showPrivacyAlert) {
            Button("Go to Profile Settings") { router.tab = .profile }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You must set your profile to Public to create or join community activities.")
        }
    }

    /// Full-bleed hero banner: the place's vibe visual anchors the card, with the
    /// place name overlaid and the live countdown chip pinned top-leading.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let spot = beacon.spot {
                    VibeClipView(emoji: spot.emoji, label: spot.name,
                                 hueA: spot.hueA, hueB: spot.hueB, animate: false)
                } else {
                    Theme.accentGradient
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.12), .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text(beacon.spot?.name ?? "Community spot")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                    .lineLimit(1)
                // When it actually happens, with the name rather than in the
                // corner badge — the countdown chip up there says how soon, not
                // which day, and the day is what decides whether you can go.
                Label(beacon.startsAtLabel, systemImage: "calendar")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                    .lineLimit(1)
                if let spot = beacon.spot {
                    Text("\(spot.category) · \(spot.distanceMiles, specifier: "%.1f") mi away")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                } else {
                    Text("Open to everyone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(14)
        }
        .frame(height: 150)
        .overlay(alignment: .topLeading) {
            BeaconCountdownChip(startsAt: beacon.startsAt, overMedia: true)
                .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            if beacon.isFull {
                Text("Full")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accent))
                    .padding(12)
            }
        }
    }

    /// Who's behind the beacon: host orb (coral "new" ring) or a coral-wash group
    /// icon for community events, with a soft subtitle.
    private var hostRow: some View {
        HStack(spacing: 10) {
            if let host = beacon.host {
                // The "active" ring is painted *outside* the orb's own frame
                // (negative padding in `GlassOrbAvatar`), so the orb still
                // reports only 40×40 for layout and the ring's overflow lands
                // outside whatever the parent clips to. Reserving the overflow
                // here — rather than in `GlassOrbAvatar` — keeps every ringless
                // orb elsewhere sized exactly as before.
                GlassOrbAvatar(friend: host, size: 40, isActive: true)
                    .padding(40 * 0.08)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(beacon.isPublic ? "hosting · open to everyone" : "is heading out")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if !beacon.hostName.isEmpty {
                // A public beacon's host is usually someone the viewer isn't
                // friends with, so there's no local `Friend` row to draw from —
                // only the identity the server denormalised onto the beacon.
                RemoteHostOrb(emoji: beacon.hostEmoji, avatarURL: beacon.hostAvatarURL, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(beacon.hostName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(beacon.isPublic ? "hosting · open to everyone" : "is heading out")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ZStack {
                    Circle().fill(Theme.accentWash)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Community event")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("open to everyone")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
        }
    }

    /// Details (ghost) + Going (primary coral, filled + springy once confirmed).
    private var actions: some View {
        HStack(spacing: 10) {
            Button { showDetail = true } label: {
                Text("Details")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.sunken))
            }
            .buttonStyle(.plain)

            Button(action: confirmJoin) {
                HStack(spacing: 5) {
                    Image(systemName: joined ? "checkmark" : "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(joined ? "Going" : (beacon.isFull ? "Full" : "Join"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(joined ? Theme.onAccent : Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background {
                    Capsule().fill(joined ? AnyShapeStyle(Theme.accent)
                                          : AnyShapeStyle(Theme.accentWash))
                        .shadow(color: joined ? Theme.accent.opacity(0.3) : .clear, radius: 10, y: 3)
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(joinPulse ? 1.08 : 1)
            .disabled(!joined && beacon.isFull)
            .opacity(!joined && beacon.isFull ? 0.5 : 1)
        }
    }

    /// Who's in, and how close to full: overlapping attendee avatars, x/capacity,
    /// and a quiet coral capacity bar that runs hot as the last spots go.
    private var capacityMeter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: -10) {
                ForEach(beacon.attendees.prefix(4), id: \.id) { friend in
                    AvatarView(friend: friend, size: 28)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                }
                Text("\(beacon.joined.count)/\(beacon.capacity)")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(beacon.isFull ? Theme.accent : Theme.textSecondary)
                    .padding(.leading, 16)
            }
            GeometryReader { proxy in
                let fraction = min(1, Double(beacon.joined.count) / Double(max(beacon.capacity, 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textPrimary.opacity(0.1))
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(width: 112, height: 4)
        }
    }

    /// Springy confirm, then the actual RSVP.
    private func confirmJoin() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) { joinPulse = true }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.12)) { joinPulse = false }
        attemptJoin()
    }

    /// RSVP with the privacy guard applied to public activities.
    ///
    /// The guard is kept here so the user gets the "make your profile public"
    /// route rather than a bare error, but the server enforces it (and capacity,
    /// and the friends-only guest list) independently — this is UI, not the rule.
    private func attemptJoin() {
        guard let me else { return }
        if beacon.isPublic && me.isPrivate && !joined {
            showPrivacyAlert = true
            return
        }
        if joined {
            Task { await beaconSync.leave(beacon, as: me, context: modelContext) }
        } else if !beacon.isFull {
            Task { await beaconSync.join(beacon, as: me, context: modelContext) }
        }
    }
}

// MARK: - Activity detail sheet ("More Details")

struct ActivityDetailSheet: View {
    let beacon: Beacon

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(BeaconSync.self) private var beaconSync
    @Query private var friends: [Friend]
    @State private var profileFriend: Friend?
    @State private var showChat = false
    @State private var hostChat: Chat?
    @State private var showPrivacyAlert = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var attending: Bool {
        guard let me else { return false }
        return beacon.isAttending(me)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // When it happens, first thing on the page. This is the
                    // "more details" view and it used to be the one screen that
                    // never said when the activity was — you could read the
                    // venue, the address, the distance, the description and the
                    // whole guest list without learning the date.
                    //
                    // Outside the `spot` check below on purpose: a beacon with
                    // no place attached still happens at a time.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHEN")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 10) {
                            Label(beacon.startsAtLabel, systemImage: "calendar")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 8)
                            // The relative read stays alongside the absolute
                            // one: "in 20 min" and "Today · 3:00 PM" answer
                            // different questions.
                            BeaconCountdownChip(startsAt: beacon.startsAt)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { GlassCard(cornerRadius: 16) { Color.clear } }

                    // Location metadata: venue, address, distance, description.
                    if let spot = beacon.spot {
                        HStack(spacing: 12) {
                            VibeClipView(emoji: spot.emoji, label: spot.name,
                                         hueA: spot.hueA, hueB: spot.hueB, animate: false)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(spot.name)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(spot.distanceMiles, specifier: "%.1f") mi from you")
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        if !spot.address.isEmpty {
                            Label(spot.address, systemImage: "mappin.and.ellipse")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(beacon.note)
                            .font(.body)
                            .foregroundStyle(Theme.textPrimary)
                        VStack(alignment: .leading, spacing: 6) {
                            Label("About this spot", systemImage: "sparkles")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.accent)
                            Text(spot.aiInsight)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { GlassCard(cornerRadius: 16) { Color.clear } }
                    }

                    // Attendee roster — tap a card for their public profile sheet.
                    Text("WHO'S GOING (\(beacon.attendees.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(beacon.attendees, id: \.id) { friend in
                                Button {
                                    profileFriend = friend
                                } label: {
                                    VStack(spacing: 5) {
                                        // Same ring overflow as the header orb, and
                                        // the horizontal `ScrollView` clips to the
                                        // sizes its subviews report — so the host's
                                        // ring needs the room reserved here or the
                                        // scroll container cuts its edge off. Only
                                        // the host pays for it; the rest stay tight.
                                        let isHost = friend.id == beacon.host?.id
                                        GlassOrbAvatar(friend: friend, size: 52, isActive: isHost)
                                            .padding(isHost ? 52 * 0.08 : 0)
                                        Text(friend.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        if isHost {
                                            Text("host")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Primary CTA: activity group chat (attendees only).
                    Button {
                        if attending {
                            showChat = true
                        } else {
                            attemptJoin()
                        }
                    } label: {
                        Label(attending ? "Open activity group chat" : "Join to unlock group chat",
                              systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .padding(.top, 6)

                    // Secondary: direct message to a friend host.
                    if let host = beacon.host, host.isMe == false {
                        Button {
                            openHostChat(host)
                        } label: {
                            Label("Message \(host.name) directly", systemImage: "bubble.left.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(Theme.accent.opacity(0.15)))
                        }
                    }
                }
                .padding(20)
            }
            .background(GlassBackground())
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $profileFriend) { friend in
            PublicProfileSheet(friend: friend)
        }
        .sheet(isPresented: $showChat) {
            ActivityChatView(beacon: beacon)
        }
        .sheet(item: $hostChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .alert("Public Profile Required", isPresented: $showPrivacyAlert) {
            Button("Go to Profile Settings") {
                dismiss()
                router.tab = .profile
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You must set your profile to Public to create or join community activities.")
        }
    }

    /// Finds the existing 1-on-1 chat with the host, creating one if needed.
    private func openHostChat(_ host: Friend) {
        guard let me else { return }
        hostChat = Chat.dm(with: host, me: me, in: modelContext)
    }

    private func attemptJoin() {
        guard let me else { return }
        if beacon.isPublic && me.isPrivate {
            showPrivacyAlert = true
            return
        }
        if !beacon.isFull {
            Task { await beaconSync.join(beacon, as: me, context: modelContext) }
        }
    }
}

// MARK: - Activity group chat (scoped by activityId)

struct ActivityChatView: View {
    let beacon: Beacon

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var friends: [Friend]
    @Query private var messages: [Message]
    @State private var draft = ""

    init(beacon: Beacon) {
        self.beacon = beacon
        let key = beacon.activityKey
        // Live query bound to this activity's id.
        _messages = Query(filter: #Predicate<Message> { $0.activityId == key },
                          sort: \Message.sentAt)
    }

    private var me: Friend? { friends.first { $0.isMe } }
    private var canPost: Bool {
        guard let me else { return false }
        return beacon.isAttending(me)
    }

    var body: some View {
        NavigationStack {
            Group {
                if StreamConfig.isEnabled {
                    // Real multi-user messaging over Stream Chat.
                    StreamThreadView(channelId: beacon.streamChannelId,
                                     name: beacon.spot?.name ?? "Activity chat",
                                     memberIds: beacon.streamMemberIds)
                } else {
                    localThread
                }
            }
            .background(GlassBackground())
            .navigationTitle(beacon.spot?.name ?? "Activity chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(beacon.attendees.count) in chat")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var localThread: some View {
            VStack(spacing: 0) {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if messages.isEmpty {
                                Text("Say hi to the group 👋")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.top, 40)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: messages.count) {
                        if let last = messages.last {
                            withAnimation { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField(canPost ? "Message the group…" : "Join the activity to chat",
                              text: $draft)
                        .textFieldStyle(.plain)
                        .disabled(!canPost)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.baseRaised))
                        .foregroundStyle(Theme.textPrimary)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(draft.isEmpty || !canPost ? Theme.textSecondary : Theme.accent)
                    }
                    .disabled(draft.isEmpty || !canPost)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
    }

    private func send() {
        guard canPost else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = Message(chat: nil, author: me, text: text)
        message.activityId = beacon.activityKey
        modelContext.insert(message)
        try? modelContext.save()
        draft = ""
    }
}

// MARK: - "My joined activities" sheet

struct MyActivitiesSheet: View {
    @Query private var beacons: [Beacon]
    @Query private var friends: [Friend]

    private var me: Friend? { friends.first { $0.isMe } }
    private var mine: [Beacon] {
        guard let me else { return [] }
        return beacons.filter { $0.isAttending(me) }.sorted { $0.startsAt < $1.startsAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("My activities")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 20)

            if mine.isEmpty {
                VStack(spacing: 8) {
                    Text("🎟️").font(.system(size: 44))
                    Text("Nothing on the calendar — join a beacon to see it here")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(mine, id: \.id) { beacon in
                            HStack(spacing: 12) {
                                if let spot = beacon.spot {
                                    VibeClipView(emoji: spot.emoji, label: spot.name,
                                                 hueA: spot.hueA, hueB: spot.hueB, animate: false)
                                        .frame(width: 46, height: 46)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(beacon.spot?.name ?? "Activity")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(beacon.host?.id == me?.id
                                         ? "You're hosting"
                                         : "Starts \(beacon.startsAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Text("\(beacon.joined.count)/\(beacon.capacity)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                            }
                            .padding(12)
                            .background { GlassCard(cornerRadius: 14) { Color.clear } }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassBackground())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Create a new activity

struct NewActivitySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(BeaconSync.self) private var beaconSync
    @Query private var friends: [Friend]

    @State private var selectedSpot: Spot?
    @State private var showSpotSearch = false
    @State private var note = ""
    @State private var capacity = 8
    @State private var isPublic = true
    @State private var showPrivacyAlert = false
    /// When the plan actually happens. Defaults to two hours out — the same
    /// value this sheet used to hardcode into the `Beacon` initializer, so an
    /// untouched picker creates exactly the beacon it always did.
    @State private var startsAt: Date = .now.addingTimeInterval(3600 * 2)

    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        NavigationStack {
            Form {
                // Location search rather than a dropdown of local rows: `Spot`
                // only ever came from DEBUG seed data, so the old picker was
                // empty for every real account.
                Section("Where") {
                    Button {
                        showSpotSearch = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedSpot == nil ? "magnifyingglass" : "mappin.circle.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedSpot?.name ?? "Search for a place")
                                    .foregroundStyle(selectedSpot == nil ? Theme.textSecondary : Theme.textPrimary)
                                if let address = selectedSpot?.address, !address.isEmpty {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if selectedSpot != nil {
                                Text("Change")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                Section("Details") {
                    TextField("What's the plan?", text: $note, axis: .vertical)
                    // The server clamps `startsAt` into [now - 1h, now + 30d],
                    // so a past date would be silently pulled forward — the
                    // lower bound here keeps the picker honest about that.
                    DatePicker("Starts",
                               selection: $startsAt,
                               in: Date.now...,
                               displayedComponents: [.date, .hourAndMinute])
                        .tint(Theme.accent)
                    Stepper("Capacity: \(capacity)", value: $capacity, in: 2...50)
                    Toggle("Public activity", isOn: $isPublic)
                        .tint(Theme.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(GlassBackground())
            .navigationTitle("New beacon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }
                        .disabled(selectedSpot == nil || note.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showSpotSearch) {
            SpotSearchView { spot in selectedSpot = spot }
        }
        // Guard clause: posting a PUBLIC activity requires a public profile.
        .alert("Public Profile Required", isPresented: $showPrivacyAlert) {
            Button("Go to Profile Settings") {
                dismiss()
                router.tab = .profile
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You must set your profile to Public to create or join community activities.")
        }
    }

    private func post() {
        guard let me else { return }
        if isPublic && me.isPrivate {
            showPrivacyAlert = true
            return
        }
        let beacon = Beacon(spot: selectedSpot, host: me, note: note,
                            startsAt: startsAt, capacity: capacity)
        beacon.isPublic = isPublic
        beacon.hostUID = me.remoteUID
        beacon.hostName = me.name
        beacon.hostEmoji = me.emoji
        beacon.hostAvatarURL = me.avatarURL
        modelContext.insert(beacon)
        try? modelContext.save()

        // Local first, sync in the background — same bargain as sending a log.
        // Blocking the sheet on a round trip would make creating a plan feel
        // like a network operation, and the row is already on screen either way.
        let context = modelContext
        let sync = beaconSync
        Task { await sync.publish(beacon, context: context) }

        dismiss()
    }
}
