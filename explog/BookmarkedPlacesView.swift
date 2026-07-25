import SwiftUI
import SwiftData

/// Every place clip you've bookmarked from the Places reels feed.
///
/// Backed by `SpotClip.savedByMe`, which the reels rail's bookmark rail button
/// already toggles and persists — this view is just a saved-only read of that
/// same field, so nothing new needs to sync.
struct BookmarkedPlacesView: View {
    @Query(sort: \SpotClip.capturedAt, order: .reverse) private var clips: [SpotClip]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private var saved: [SpotClip] { clips.filter(\.savedByMe) }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                if saved.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(saved) { clip in
                                card(clip)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func card(_ clip: SpotClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Same media ladder as the Places feed — a saved card showing
                // the emoji placeholder for a clip with real media reads as a
                // different (missing) post than the one that was bookmarked.
                ClipMediaView(spotClip: clip, isActive: false)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    clip.savedByMe = false
                    try? modelContext.save()
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.coral)
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.5)))
                }
                .padding(8)
                .accessibilityLabel("Remove bookmark")
            }

            Text(clip.spot?.name ?? clip.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(clip.authorName)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🔖").font(.system(size: 44))
            Text("No bookmarks yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Tap the bookmark icon on a place clip to save it here")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
