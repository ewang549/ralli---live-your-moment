import SwiftUI
import SwiftData

/// The requests inbox: who wants to be your friend, and who you're still
/// waiting on — the "Friend Requests" tab of `FriendHubView`.
///
/// Incoming requests lead — they're the ones with something for the user to
/// decide — and outgoing sit underneath as a quieter "still pending" list.
struct FriendRequestsContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph

    /// uid currently being acted on, so only that row shows a spinner.
    @State private var busyUID: String?
    @State private var actionError: String?
    @State private var openProfile: RemoteProfile?

    var body: some View {
        ZStack {
            GlassBackground()

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let actionError {
                        Text(actionError)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    if !friendGraph.incoming.isEmpty {
                        sectionHeader("REQUESTS", count: friendGraph.incoming.count)
                        ForEach(friendGraph.incoming) { profile in
                            requestRow(profile) {
                                HStack(spacing: 8) {
                                    pill("Decline", uid: profile.uid, prominent: false) {
                                        try await friendGraph.decline(profile, context: modelContext)
                                    }
                                    pill("Accept", uid: profile.uid, prominent: true) {
                                        try await friendGraph.accept(profile, context: modelContext)
                                    }
                                }
                            }
                        }
                    }

                    if !friendGraph.outgoing.isEmpty {
                        sectionHeader("SENT", count: friendGraph.outgoing.count)
                            .padding(.top, friendGraph.incoming.isEmpty ? 0 : 12)
                        ForEach(friendGraph.outgoing) { profile in
                            requestRow(profile) {
                                pill("Cancel", uid: profile.uid, prominent: false) {
                                    try await friendGraph.cancel(profile, context: modelContext)
                                }
                            }
                        }
                    }

                    if friendGraph.incoming.isEmpty && friendGraph.outgoing.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .scrollIndicators(.hidden)
            .refreshable { await friendGraph.refresh(context: modelContext) }
        }
        .task { await friendGraph.refresh(context: modelContext) }
#if DEBUG
        // CLI verification hook: SIMCTL_CHILD_EXPLOG_AUTO_ACCEPT=1 accepts the
        // first pending request, driving the same callable the Accept pill does.
        .task {
            guard ProcessInfo.processInfo.environment["EXPLOG_AUTO_ACCEPT"] == "1" else { return }
            await friendGraph.refresh(context: modelContext)
            guard let first = friendGraph.incoming.first else { return }
            await run(first.uid) {
                try await friendGraph.accept(first, context: modelContext)
            }
        }
#endif
        .fullScreenCover(item: $openProfile) { profile in
            PublicProfileSheet(uid: profile.uid, name: profile.name, emoji: profile.avatarEmoji)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.accent)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func requestRow<Actions: View>(_ profile: RemoteProfile,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        GlassCard(cornerRadius: 18) {
            HStack(spacing: 12) {
                Button { openProfile = profile } label: {
                    HStack(spacing: 12) {
                        GlassOrbAvatar(profile: profile, size: 46)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(profile.atHandle)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 6)

                if busyUID == profile.uid {
                    ProgressView().tint(Theme.accent).scaleEffect(0.8)
                } else {
                    actions()
                }
            }
            .padding(12)
        }
    }

    private func pill(_ title: String,
                      uid: String,
                      prominent: Bool,
                      action: @escaping () async throws -> Void) -> some View {
        Button {
            Task { await run(uid, action) }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(prominent ? AnyShapeStyle(Theme.accent)
                                             : AnyShapeStyle(Theme.sunken))
                }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🤝").font(.system(size: 44))
            Text("No requests")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("When someone adds you, they'll show up here.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 90)
    }

    /// Serialises row actions and keeps the spinner on the row being acted on.
    private func run(_ uid: String, _ work: @escaping () async throws -> Void) async {
        guard busyUID == nil else { return }
        busyUID = uid
        actionError = nil
        do {
            try await work()
        } catch let error as CallableFunctions.CallableError {
            actionError = error.message
        } catch {
            actionError = "Couldn't reach the server."
        }
        busyUID = nil
    }
}
