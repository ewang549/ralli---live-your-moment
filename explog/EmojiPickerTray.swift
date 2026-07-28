import SwiftUI

/// The sticker tray: the whole emoji range, by category, with search.
///
/// Replaces a fixed seven-column grid of fourteen emoji. At full range a flat
/// grid is unusable — hence the category tabs and the search field, which are
/// what make "every emoji" navigable rather than merely present.
struct EmojiPickerTray: View {
    /// The emoji the user picked. The tray does not dismiss itself; the caller
    /// owns presentation (and `dropSticker` already closes it).
    let onPick: (String) -> Void

    @State private var categoryIndex = 0
    @State private var query = ""

    private var categories: [EmojiCatalog.Category] { EmojiCatalog.categories }

    /// Search results when there's a query, otherwise the selected category.
    /// Search deliberately spans the whole catalog rather than the current tab —
    /// searching inside one category means knowing which category a thing is
    /// in, which is the problem search exists to avoid.
    private var visible: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return categories.indices.contains(categoryIndex)
                ? categories[categoryIndex].emoji : []
        }
        return EmojiCatalog.search(trimmed)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)

    var body: some View {
        VStack(spacing: 10) {
            Capsule().fill(Theme.textTertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            searchField

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                categoryTabs
            }

            grid
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            TextField("", text: $query,
                      prompt: Text("Search emoji").foregroundColor(.white.opacity(0.5)))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .tint(Theme.coral)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Capsule().fill(.white.opacity(0.12)))
        .padding(.horizontal, 18)
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories.indices, id: \.self) { index in
                    let isActive = index == categoryIndex
                    Button {
                        categoryIndex = index
                    } label: {
                        Image(systemName: categories[index].symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isActive ? Theme.onCoral : .white.opacity(0.8))
                            .frame(width: 38, height: 34)
                            .background {
                                if isActive {
                                    Capsule().fill(Theme.coral)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(categories[index].name)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    @ViewBuilder
    private var grid: some View {
        if visible.isEmpty {
            Text("No emoji found")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 260)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visible, id: \.self) { emoji in
                        Button { onPick(emoji) } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            // Tall enough to browse, short enough to leave the shot visible
            // behind the tray while picking.
            .frame(height: 260)
            // Restart at the top when the tab or the query changes, so a new
            // list never opens scrolled into the middle of itself.
            .id(scrollIdentity)
        }
    }

    private var scrollIdentity: String {
        "\(categoryIndex)-\(query.trimmingCharacters(in: .whitespaces).isEmpty ? "browse" : query)"
    }
}
