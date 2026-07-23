import SwiftUI
import SwiftData

/// Add a friend by their unique User ID.
///
/// The lookup is a real server call (`lookupUser`), which resolves either a
/// handle or a friend code and is rate limited with a lockout — an unthrottled
/// ID lookup is a directory-enumeration oracle.
struct AddFriendView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var friends: [Friend]

    @State private var query = ""
    @State private var state: LookupState = .idle
    @State private var searchTask: Task<Void, Never>?

    private enum LookupState: Equatable {
        case idle
        case searching
        case found(RemoteProfile)
        case missing(String)
    }

    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                VStack(spacing: 18) {
                    searchField
                    resultArea
                    Spacer()
                    if let me, !me.friendCode.isEmpty {
                        myCodeCard(me)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .navigationTitle("Add friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text("@")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.gold)
                TextField("their User ID", text: $query)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { search() }
                    .onChange(of: query) { _, _ in scheduleSearch() }

                if state == .searching {
                    ProgressView().tint(Theme.textSecondary).scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.glassRimTop.opacity(0.4), lineWidth: 1)
                    }
            }

            Text("Type a friend's User ID or their 6-character code.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        switch state {
        case .idle, .searching:
            EmptyView()
        case .missing(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        case .found(let profile):
            resultCard(profile)
        }
    }

    private func resultCard(_ profile: RemoteProfile) -> some View {
        GlassCard(cornerRadius: 20) {
            HStack(spacing: 13) {
                GlassOrbAvatar(emoji: profile.avatarEmoji, hue: 0.58, size: 52, isActive: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(profile.atHandle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if !profile.city.isEmpty {
                        Text(profile.city)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    }
                }
                Spacer()
            }
            .padding(13)
        }
    }

    private func myCodeCard(_ me: Friend) -> some View {
        GlassCard(cornerRadius: 18) {
            VStack(spacing: 6) {
                Text("YOUR CODE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                Text(me.friendCode)
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Theme.goldSheen)
                Text("Share this so friends can add you")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    // MARK: Lookup

    /// Debounced so we aren't calling the (rate limited) endpoint per keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            state = .idle
            return
        }
        state = .searching
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await performLookup(trimmed)
        }
    }

    private func search() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return }
        state = .searching
        searchTask = Task { await performLookup(trimmed) }
    }

    @MainActor
    private func performLookup(_ value: String) async {
        do {
            let profile = try await FirestoreService.lookupUser(value)
            guard !Task.isCancelled else { return }
            state = .found(profile)
        } catch let error as CallableFunctions.CallableError {
            guard !Task.isCancelled else { return }
            state = .missing(error.message)
        } catch {
            guard !Task.isCancelled else { return }
            state = .missing("Couldn't reach the server.")
        }
    }
}
