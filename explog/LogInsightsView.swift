import SwiftUI
import SwiftData

// MARK: - Insights for one of your own logs
//
// What this screen can honestly say.
//
// Views are real now: `viewLog` counts one view per account per log, excluding
// the author's own, and `logStats` fetches the total for this log specifically
// — your own logs never come back through `listFriendLogs`, which queries your
// friends' logs rather than yours, so this screen has to ask for them directly.
//
// Delivery and reach are real for the same reason they always were: whether the
// media actually reached Storage, who it was addressed to, and where it was
// posted all come off fields the sync layer genuinely maintains.
//
// Likes and comments are deliberately *not* here. They have a real backend now,
// but it's scoped to public place posts (`SpotClip`), and this screen shows a
// `Clip` — which for a friends-only log has no likes to report. Showing a zero
// would be inventing a number, which is what the note at the bottom exists to
// avoid. Saves are still not tracked anywhere.

struct LogInsightsView: View {
    let clip: Clip

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(EngagementSync.self) private var engagementSync
    @Query private var spots: [Spot]

    /// The place a public post was filed under, when it was one.
    private var publicSpot: Spot? {
        guard !clip.intendedSpotID.isEmpty else { return nil }
        return spots.first { $0.remoteID == clip.intendedSpotID }
    }

    private var deliveryLabel: String {
        switch clip.sendState {
        case .published: "Delivered"
        case .pending: "Still uploading"
        case .failed: "Failed to send"
        }
    }

    private var deliveryIcon: String {
        switch clip.sendState {
        case .published: "checkmark.circle.fill"
        case .pending: "arrow.up.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var deliveryTint: Color {
        switch clip.sendState {
        case .published: Theme.mint
        case .pending: Theme.textSecondary
        case .failed: Theme.accent
        }
    }

    /// Who this was addressed to.
    ///
    /// An empty recipient list is not "nobody" — it's what an unaddressed log
    /// has always meant, namely every friend you have.
    private var audienceLabel: String {
        if let publicSpot { return "Public · \(publicSpot.name)" }
        if !clip.intendedSpotID.isEmpty { return "Public post" }
        let count = clip.intendedRecipientUIDs.count
        return count > 0 ? "\(count) friend\(count == 1 ? "" : "s")" : "All friends"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        preview

                        section("DELIVERY") {
                            row(deliveryIcon, "Status", deliveryLabel, tint: deliveryTint)
                            row("icloud", "Media on server",
                                clip.isPublished ? "Yes" : "Not yet")
                        }

                        section("REACH") {
                            row("person.2.fill", "Sent to", audienceLabel)
                            // Only meaningful once the log is on the server —
                            // an unpublished capture has had no audience at
                            // all, and a zero there would read as "nobody
                            // watched" rather than "nobody could".
                            if clip.isPublished {
                                row("eye.fill", "Views", "\(clip.viewCount)")
                            }
                            if let publicSpot, !publicSpot.category.isEmpty {
                                row("mappin.and.ellipse", "Place category",
                                    POICategoryLabel.display(publicSpot.category))
                            }
                        }

                        section("CAPTURE") {
                            row("clock", "Logged at",
                                clip.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            row(clip.kind == .video ? "video.fill" : "photo.fill", "Type",
                                clip.kind == .video ? "Video" : "Photo")
                            if !clip.label.isEmpty {
                                row("text.quote", "Caption", clip.label)
                            }
                        }

                        notTrackedNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            // The counter lives on the server and changes without this device
            // doing anything, so it's fetched on open rather than trusted from
            // the last time this row was written.
            .task { await engagementSync.refreshStats(for: clip, context: modelContext) }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var preview: some View {
        ClipView(clip: clip, isActive: false, contentMode: .fit)
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The honest footnote. Without it this screen reads as "your log got no
    /// engagement", which is a claim the app has no way to make.
    private var notTrackedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not measured yet", systemImage: "info.circle")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            Text("Likes and comments are only recorded on public place posts, and saves aren't recorded at all — so there are no numbers to show for them here. This is everything Ralli tracks for this log today.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { GlassCard(cornerRadius: 14) { Color.clear } }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 4)
                .background { GlassCard(cornerRadius: 14) { Color.clear } }
        }
    }

    private func row(_ icon: String, _ label: String, _ value: String,
                     tint: Color = Theme.textPrimary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
