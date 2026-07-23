import SwiftUI
import SwiftData

// MARK: - Tab 5: Beacons — friends/public activity feed with privacy guards

struct BeaconsFeedView: View {
    @Query private var beacons: [Beacon]
    @Query private var friends: [Friend]
    @Environment(AppRouter.self) private var router

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

    private var filtered: [Beacon] {
        beacons
            .filter { segment == .publicFeed ? $0.isPublic : !$0.isPublic }
            .sorted { $0.startsAt < $1.startsAt }
    }

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 0) {
                header

                // Friends ↔ Public, as gold filter chips rather than a system
                // segmented control, which can't be tinted to match the rest.
                HStack(spacing: 8) {
                    ForEach(Segment.allCases, id: \.self) { option in
                        FilterChip(title: option.rawValue,
                                   count: beacons.filter {
                                       option == .publicFeed ? $0.isPublic : !$0.isPublic
                                   }.count,
                                   isActive: segment == option) {
                            withAnimation(.easeOut(duration: 0.18)) { segment = option }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(filtered, id: \.id) { beacon in
                            BeaconFeedCard(beacon: beacon)
                        }
                        if filtered.isEmpty {
                            VStack(spacing: 8) {
                                Text("📡").font(.system(size: 50))
                                Text(segment == .friends
                                     ? "No friend beacons right now"
                                     : "No public activities nearby yet")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.top, 60)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 118)
                }
                .scrollIndicators(.hidden)
            }
        }
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
            case "detail": segment = .publicFeed; debugDetail = publicBeacons.first
            case "activitychat": segment = .publicFeed; debugChat = publicBeacons.first
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
            GlassCircleButton(icon: "plus", label: "Create an activity", isGold: true) {
                if me?.isPrivate == true {
                    showPrivacyAlert = true
                } else {
                    showCreate = true
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Activity card

struct BeaconFeedCard: View {
    let beacon: Beacon

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Query private var friends: [Friend]
    @State private var showDetail = false
    @State private var showPrivacyAlert = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var joined: Bool {
        guard let me else { return false }
        return beacon.hasJoined(me)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let host = beacon.host {
                    // Gold ring on the host's orb — they're the live signal here.
                    GlassOrbAvatar(friend: host, size: 40, isActive: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(beacon.isPublic ? "hosting a public activity" : "is heading out")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                            .overlay { Circle().strokeBorder(Theme.gold.opacity(0.35), lineWidth: 1) }
                        Image(systemName: "person.3.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.gold)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Community event")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("open to everyone")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                HStack(spacing: 5) {
                    GlowDot(size: 7, breathing: true)
                    Text(beacon.startsAt, style: .relative)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.gold)
                }
            }

            if let spot = beacon.spot {
                HStack(spacing: 10) {
                    VibeClipView(emoji: spot.emoji, label: spot.name,
                                 hueA: spot.hueA, hueB: spot.hueB, animate: false)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(spot.category) · \(spot.distanceMiles, specifier: "%.1f") mi")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            Text(beacon.note)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary.opacity(0.9))

            HStack(spacing: 10) {
                capacityMeter
                Spacer(minLength: 4)
                // "More Details" opens the activity detail sheet.
                GoldChip(title: "Details", systemImage: "info.circle") {
                    showDetail = true
                }
                // Filled gold once you're in — RSVP state reads at a glance.
                GoldChip(title: joined ? "Going" : (beacon.isFull ? "Full" : "Join"),
                         systemImage: joined ? "checkmark" : nil,
                         isFilled: joined) {
                    attemptJoin()
                }
                .disabled(!joined && beacon.isFull)
                .opacity(!joined && beacon.isFull ? 0.45 : 1)
            }
        }
        .padding(16)
        .background {
            GlassCard(cornerRadius: 20) { Color.clear }
        }
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

    /// Who's in, and how close to full: attendee orbs plus a gold fill bar that
    /// runs hot as the last spots go.
    private var capacityMeter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: -8) {
                ForEach(beacon.attendees.prefix(4), id: \.id) { friend in
                    GlassOrbAvatar(friend: friend, size: 24)
                }
                Text("\(beacon.joined.count)/\(beacon.capacity)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(beacon.isFull ? Theme.gold : Theme.textSecondary)
                    .padding(.leading, 14)
            }
            GeometryReader { proxy in
                let fraction = min(1, Double(beacon.joined.count) / Double(max(beacon.capacity, 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textPrimary.opacity(0.12))
                    Capsule()
                        .fill(Theme.goldSheen)
                        .frame(width: proxy.size.width * fraction)
                        .shadow(color: Theme.goldGlow.opacity(0.5), radius: 5)
                }
            }
            .frame(width: 96, height: 3)
        }
    }

    /// RSVP with the privacy guard applied to public activities.
    private func attemptJoin() {
        guard let me else { return }
        if beacon.isPublic && me.isPrivate && !joined {
            showPrivacyAlert = true
            return
        }
        if joined {
            beacon.joined.removeAll { $0.id == me.id }
        } else if !beacon.isFull {
            beacon.joined.append(me)
        }
        try? modelContext.save()
    }
}

// MARK: - Activity detail sheet ("More Details")

struct ActivityDetailSheet: View {
    let beacon: Beacon

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Query private var friends: [Friend]
    @Query private var chats: [Chat]
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
                                    .foregroundStyle(Theme.gold)
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
                                .foregroundStyle(Theme.gold)
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
                                        GlassOrbAvatar(friend: friend, size: 52, isActive: friend.id == beacon.host?.id)
                                        Text(friend.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        if friend.id == beacon.host?.id {
                                            Text("host")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Theme.gold)
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
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.gold))
                    }
                    .padding(.top, 6)

                    // Secondary: direct message to a friend host.
                    if let host = beacon.host, host.isMe == false {
                        Button {
                            openHostChat(host)
                        } label: {
                            Label("Message \(host.name) directly", systemImage: "bubble.left.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.gold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(Theme.gold.opacity(0.15)))
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
        .sheet(item: $profileFriend) { friend in
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
        .preferredColorScheme(.dark)
    }

    /// Finds the existing 1-on-1 chat with the host, creating one if needed.
    private func openHostChat(_ host: Friend) {
        guard let me else { return }
        if let existing = chats.first(where: { chat in
            !chat.isGroup && chat.members.contains { $0.id == host.id }
        }) {
            hostChat = existing
        } else {
            let chat = Chat(isGroup: false, members: [me, host])
            modelContext.insert(chat)
            try? modelContext.save()
            hostChat = chat
        }
    }

    private func attemptJoin() {
        guard let me else { return }
        if beacon.isPublic && me.isPrivate {
            showPrivacyAlert = true
            return
        }
        if !beacon.isFull {
            beacon.joined.append(me)
            try? modelContext.save()
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
        .preferredColorScheme(.dark)
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
                            .foregroundStyle(draft.isEmpty || !canPost ? Theme.textSecondary : Theme.gold)
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
                                    .foregroundStyle(Theme.gold)
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
        .preferredColorScheme(.dark)
    }
}

// MARK: - Create a new activity

struct NewActivitySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Query(sort: \Spot.distanceMiles) private var spots: [Spot]
    @Query private var friends: [Friend]

    @State private var selectedSpot: Spot?
    @State private var note = ""
    @State private var capacity = 8
    @State private var isPublic = true
    @State private var showPrivacyAlert = false

    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    Picker("Spot", selection: $selectedSpot) {
                        Text("Pick a spot").tag(Spot?.none)
                        ForEach(spots, id: \.id) { spot in
                            Text(spot.name).tag(Spot?.some(spot))
                        }
                    }
                }
                Section("Details") {
                    TextField("What's the plan?", text: $note, axis: .vertical)
                    Stepper("Capacity: \(capacity)", value: $capacity, in: 2...50)
                    Toggle("Public activity", isOn: $isPublic)
                        .tint(Theme.gold)
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
        .preferredColorScheme(.dark)
    }

    private func post() {
        guard let me else { return }
        if isPublic && me.isPrivate {
            showPrivacyAlert = true
            return
        }
        let beacon = Beacon(spot: selectedSpot, host: me, note: note,
                            startsAt: .now.addingTimeInterval(3600 * 2), capacity: capacity)
        beacon.isPublic = isPublic
        modelContext.insert(beacon)
        try? modelContext.save()
        dismiss()
    }
}
