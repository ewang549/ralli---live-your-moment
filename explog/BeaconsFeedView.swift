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
        VStack(spacing: 0) {
            header

            // Friends ↔ Public segmented control.
            Picker("Feed", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

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
                .padding(.bottom, 100)
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
        HStack(spacing: 12) {
            Text("Beacons")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            // NEW: "My joined activities" shortcut.
            Button {
                showMyActivities = true
            } label: {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(9)
                    .background(Circle().fill(Theme.surface))
            }
            .accessibilityLabel("My joined activities")
            // NEW: create a public activity (privacy-guarded).
            Button {
                if me?.isPrivate == true {
                    showPrivacyAlert = true
                } else {
                    showCreate = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(9)
                    .background(Circle().fill(Theme.accent))
            }
            .accessibilityLabel("Create an activity")
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
                    AvatarView(friend: host, size: 38)
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
                        Circle().fill(Theme.surfaceLight)
                        Image(systemName: "person.3.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(width: 38, height: 38)
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
                Text(beacon.startsAt, style: .relative)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
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
                Text("\(beacon.joined.count)/\(beacon.capacity) going")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                // NEW: "More Details" opens the activity detail sheet.
                Button {
                    showDetail = true
                } label: {
                    Text("More Details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                Button {
                    attemptJoin()
                } label: {
                    Text(joined ? "Going ✓" : "Join")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(joined ? Theme.accent : .black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(joined ? Theme.accent.opacity(0.2) : Theme.accent))
                }
                .disabled(!joined && beacon.isFull)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surface))
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
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surfaceLight))
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
                                        AvatarView(friend: friend, size: 52)
                                        Text(friend.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                        if friend.id == beacon.host?.id {
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
                            .foregroundStyle(.black)
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
            .background(Theme.background.ignoresSafeArea())
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
            .background(Theme.background.ignoresSafeArea())
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
                        .background(Capsule().fill(Theme.surfaceLight))
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
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceLight))
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
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
                        .tint(Theme.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
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
