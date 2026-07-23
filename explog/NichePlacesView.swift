import SwiftUI
import SwiftData

// MARK: - View A: Niche Places feed
// Reels-style full-screen vertical stream of place clips. Right edge carries the
// interaction rail (like / comment / share), bottom overlay carries the location
// caption which expands into the detail sheet.

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
                            .id(clip.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleClipID)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .onAppear { if visibleClipID == nil { visibleClipID = clips.first?.id } }
    }
}

private struct PlacePage: View {
    let clip: SpotClip
    let isActive: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var showComments = false
    @State private var showShare = false
    @State private var showDetail = false

    var body: some View {
        ZStack {
            VibeClipView(emoji: clip.emoji, label: clip.label,
                         hueA: clip.hueA, hueB: clip.hueB, animate: isActive)
                .ignoresSafeArea()

            // Right-edge interaction rail (like / comment / share).
            VStack(spacing: 22) {
                Spacer()
                railButton(icon: clip.likedByMe ? "heart.fill" : "heart",
                           tint: clip.likedByMe ? Theme.accent : .white,
                           count: clip.likeCount) {
                    toggleLike()
                }
                railButton(icon: "bubble.right.fill", tint: .white, count: clip.comments.count) {
                    showComments = true
                }
                railButton(icon: "paperplane.fill", tint: .white, count: nil) {
                    showShare = true
                }
                Spacer().frame(height: 140)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 14)

            // Bottom caption: location, distance, summary → tap expands detail sheet.
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(clip.authorName) · \(clip.capturedAt.relativeHour)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(clip.label)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    if let spot = clip.spot {
                        Button {
                            showDetail = true
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                    Text(spot.name)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text("· \(spot.distanceMiles, specifier: "%.1f") mi")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                Text(spot.summary)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("more")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.trailing, 80)
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                )
            }
        }
        .sheet(isPresented: $showComments) {
            CommentsSheet(clip: clip)
        }
        .sheet(isPresented: $showShare) {
            SharePlaceSheet(clip: clip)
        }
        .sheet(isPresented: $showDetail) {
            if let spot = clip.spot {
                SpotDetailView(spot: spot)
            }
        }
    }

    private func railButton(icon: String, tint: Color, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .shadow(radius: 4)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.surfaceLight))
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(post)
                Button(action: post) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(draft.isEmpty ? Theme.textSecondary : Theme.accent)
                }
                .disabled(draft.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.surface)
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
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Theme.surfaceLight)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
                                )
                        )
                    }
                    .disabled(beaconPosted || clip.spot == nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Theme.surface)
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
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceLight))
                }
                .disabled(sentTo.contains(chat.id))
            }
        }
    }

    private func share(to chat: Chat) {
        let message = Message(chat: chat, author: me,
                              text: "check this spot out 👀",
                              sharedSpotName: spotName)
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
                            note: "found this on Explog — who's in?",
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
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))

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
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
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
