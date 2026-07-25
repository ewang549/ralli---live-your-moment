import SwiftUI

/// Add & manage friends — one sheet, two tabs.
///
/// Reached from the people+ button in the Pulse header (replacing the old
/// separate add-friend sheet and requests bell): "Add Friends" carries the
/// search bar, add-by-code, and your own shareable code; "Friend Requests"
/// carries the incoming/outgoing inbox. Both tabs reuse the exact same
/// content and logic those two screens always had — only the chrome around
/// them changed.
struct FriendHubView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case add, requests
        var id: String { rawValue }
        var title: String {
            switch self {
            case .add: "Add Friends"
            case .requests: "Requests"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(FriendGraph.self) private var friendGraph
    @State private var tab: Tab

    init(initialTab: Tab = .add) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                VStack(spacing: 14) {
                    tabPicker
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                    Group {
                        switch tab {
                        case .add: AddFriendContent()
                        case .requests: FriendRequestsContent()
                        }
                    }
                }
            }
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { option in
                FilterChip(title: option.title,
                           count: option == .requests ? friendGraph.pendingCount : 0,
                           isActive: tab == option) {
                    withAnimation(.easeOut(duration: 0.18)) { tab = option }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
