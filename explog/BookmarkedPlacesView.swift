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
    @Environment(AppRouter.self) private var router

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
                //
                // The thumbnail is the tap target: the card used to render the
                // media and nothing else, so a bookmark could be removed but
                // never re-watched. The bookmark button sits above it in the
                // ZStack and keeps its own tap target.
                Button { open(clip) } label: {
                    ClipMediaView(spotClip: clip, isActive: false)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())

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

    /// Opens a saved clip in the Places feed itself rather than in a second
    /// player built just for this screen — the feed *is* the viewer, and it
    /// already knows how to land on one clip and autoplay it (the same deep
    /// link a Highlights card on a public profile uses).
    private func open(_ clip: SpotClip) {
        router.tab = .places
        router.focusedPlaceClipId = clip.id
        dismiss()
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
