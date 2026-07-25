import SwiftUI
import SwiftData
import UIKit

/// Find and add people — the "Add Friends" tab of `FriendHubView`.
///
/// Three ways in, in the order people actually use them: type a name or User
/// ID (prefix search over both), paste a 6-character friend code (exact), or
/// pick someone out of "People you may know". Every path lands on the same row,
/// with the same Add button and the same profile sheet behind it.
///
/// The lookups are real server calls, rate limited with a lockout — an
/// unthrottled directory endpoint is an enumeration oracle.
struct AddFriendContent: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph
    @Query private var friends: [Friend]

    @State private var query = ""
    @State private var state: LookupState = .idle
    @State private var searchTask: Task<Void, Never>?
    @State private var suggestions: [FirestoreService.SearchHit] = []
    @State private var loadingSuggestions = true
    /// Relationship per uid, so a row settles after its Add without refetching
    /// the whole result set.
    @State private var statuses: [String: FriendshipStatus] = [:]
    @State private var sending: String?
    @State private var actionError: String?
    @State private var openProfile: FirestoreService.SearchHit?
    @State private var codeCopied = false

    private enum LookupState: Equatable {
        case idle
        case searching
        case results([FirestoreService.SearchHit])
        case missing(String)
    }

    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 16) {
                searchField
                resultArea
                Spacer(minLength: 0)
                if let me, !me.friendCode.isEmpty {
                    myCodeCard(me)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .task { await loadSuggestions() }
#if DEBUG
        // CLI verification hook: SIMCTL_CHILD_EXPLOG_AUTO_ADD="<handle>"
        // looks the user up and taps Add, exercising the same lookup and
        // sendFriendRequest path the button does.
        .task {
            guard let handle = ProcessInfo.processInfo.environment["EXPLOG_AUTO_ADD"] else { return }
            query = handle
            await performLookup(handle)
            guard case .results(let hits) = state,
                  let first = hits.first,
                  status(of: first) == .none else { return }
            await add(first)
        }
#endif
        .fullScreenCover(item: $openProfile) { hit in
            PublicProfileSheet(uid: hit.profile.uid,
                               name: hit.profile.name,
                               emoji: hit.profile.avatarEmoji)
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                TextField("name, User ID, or code", text: $query)
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
                    .fill(Theme.sunken)
            }

            Text("Search by name or User ID, or paste a 6-character code.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        switch state {
        case .idle:
            suggestionsArea
        case .searching:
            Spacer().frame(height: 0)
        case .missing(let message):
            VStack(spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        case .results(let hits):
            resultList(hits, title: nil)
        }
    }

    /// "People you may know" fills the screen before anything is typed, so the
    /// blank state is a place to start rather than an empty box.
    @ViewBuilder
    private var suggestionsArea: some View {
        if loadingSuggestions {
            ProgressView().tint(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        } else if !suggestions.isEmpty {
            resultList(suggestions, title: "PEOPLE YOU MAY KNOW")
        }
    }

    private func resultList(_ hits: [FirestoreService.SearchHit], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(hits) { hit in
                        resultRow(hit)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultRow(_ hit: FirestoreService.SearchHit) -> some View {
        let profile = hit.profile
        return GlassCard(cornerRadius: 18) {
            HStack(spacing: 13) {
                Button {
                    openProfile = hit
                } label: {
                    HStack(spacing: 13) {
                        GlassOrbAvatar(emoji: profile.avatarEmoji, hue: 0.58, size: 46, isActive: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text(profile.atHandle)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            subtitle(for: hit)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                addControl(for: hit)
            }
            .padding(13)
        }
        // Long-press reaches the same Block/Report actions the profile sheet
        // offers, so a bad result never has to be opened to be dealt with.
        .safetyActions(for: .user(uid: profile.uid, name: profile.name))
    }

    @ViewBuilder
    private func subtitle(for hit: FirestoreService.SearchHit) -> some View {
        if hit.mutualCount > 0 {
            Text("\(hit.mutualCount) mutual friend\(hit.mutualCount == 1 ? "" : "s")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
        } else if !hit.profile.city.isEmpty {
            Text(hit.profile.city)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
    }

    /// One control, five states. Only `.none` and `.incoming` are tappable —
    /// once a request is out, the pill is a status, not a button, so there's
    /// nothing to double-send.
    @ViewBuilder
    private func addControl(for hit: FirestoreService.SearchHit) -> some View {
        switch status(of: hit) {
        case .none:
            actionPill(title: "Add", icon: "plus", busy: sending == hit.id) {
                await add(hit)
            }
        case .incoming:
            actionPill(title: "Accept", icon: "checkmark", busy: sending == hit.id) {
                await accept(hit)
            }
        case .requested:
            statusPill(title: "Requested", icon: "clock")
        case .friends:
            statusPill(title: "Friends", icon: "checkmark.circle.fill")
        case .blocked:
            statusPill(title: "Blocked", icon: "hand.raised.fill")
        }
    }

    private func actionPill(title: String,
                            icon: String,
                            busy: Bool,
                            action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().tint(Theme.onAccent).scaleEffect(0.7)
                } else {
                    Image(systemName: icon).font(.system(size: 12, weight: .bold))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(sending != nil)
        .accessibilityLabel(title)
    }

    /// Settled state — tinted rather than solid, so it reads as information.
    private func statusPill(title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.accentWash))
        .accessibilityLabel(title)
    }

    private func myCodeCard(_ me: Friend) -> some View {
        GlassCard(cornerRadius: 18) {
            VStack(spacing: 6) {
                Text("YOUR CODE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Text(me.friendCode)
                        .font(.system(size: 26, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Theme.accentGradient)
                    Button {
                        UIPasteboard.general.string = me.friendCode
                        withAnimation(.easeOut(duration: 0.15)) { codeCopied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation(.easeOut(duration: 0.2)) { codeCopied = false }
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(codeCopied ? Theme.mint : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(codeCopied ? "Copied" : "Copy your code")
                }
                Text(codeCopied ? "Copied to clipboard" : "Share this so friends can add you")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    // MARK: Actions

    /// The row's relationship: whatever we last resolved locally, else what the
    /// server shipped with the result.
    private func status(of hit: FirestoreService.SearchHit) -> FriendshipStatus {
        statuses[hit.id] ?? hit.friendship
    }

    private func add(_ hit: FirestoreService.SearchHit) async {
        await perform(hit) {
            try await friendGraph.send(to: hit.profile, context: modelContext)
        }
    }

    private func accept(_ hit: FirestoreService.SearchHit) async {
        await perform(hit) {
            try await friendGraph.accept(hit.profile, context: modelContext)
            return .friends
        }
    }

    /// Runs a graph mutation, moving that row's pill to whatever the server
    /// decided.
    private func perform(_ hit: FirestoreService.SearchHit,
                         _ work: @escaping () async throws -> FriendshipStatus) async {
        guard sending == nil else { return }
        sending = hit.id
        actionError = nil
        defer { sending = nil }
        do {
            let resolved = try await work()
            withAnimation(.easeOut(duration: 0.18)) { statuses[hit.id] = resolved }
        } catch let error as CallableFunctions.CallableError {
            actionError = error.message
        } catch {
            actionError = "Couldn't reach the server."
        }
    }

    // MARK: Lookup

    private func loadSuggestions() async {
        defer { loadingSuggestions = false }
        suggestions = (try? await FirestoreService.suggestedFriends()) ?? []
    }

    /// Debounced so we aren't calling the (rate limited) endpoint per keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
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
        guard trimmed.count >= 2 else { return }
        state = .searching
        searchTask = Task { await performLookup(trimmed) }
    }

    /// Prefix search first, then the exact endpoint.
    ///
    /// The order matters: friend codes are random strings, so they can't be
    /// prefix-matched and only `lookupUser` resolves them — but a name search
    /// is what people reach for far more often, so it goes first and the code
    /// path is the fallback.
    @MainActor
    private func performLookup(_ value: String) async {
        do {
            let hits = try await FirestoreService.searchUsers(value)
            guard !Task.isCancelled else { return }
            if !hits.isEmpty {
                actionError = nil
                state = .results(hits)
                return
            }
        } catch let error as CallableFunctions.CallableError {
            // A rate-limit lockout is worth surfacing rather than retrying
            // against a second endpoint that shares the same limiter.
            guard !Task.isCancelled else { return }
            state = .missing(error.message)
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .missing("Couldn't reach the server.")
            return
        }

        do {
            let result = try await FirestoreService.lookupUser(value)
            guard !Task.isCancelled else { return }
            actionError = nil
            state = .results([FirestoreService.SearchHit(profile: result.profile,
                                                         status: result.friendship.rawValue,
                                                         mutuals: nil)])
        } catch let error as CallableFunctions.CallableError {
            guard !Task.isCancelled else { return }
            state = .missing(error.message)
        } catch {
            guard !Task.isCancelled else { return }
            state = .missing("Couldn't reach the server.")
        }
    }
}
