import SwiftUI
import SwiftData

/// End-of-day vlog: the user's clips from today, auto-stitched into a sequential reel.
struct MontageView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allClips: [Clip]
    @Query private var friends: [Friend]

    @State private var index = 0

    private var todaysClips: [Clip] {
        guard let me = friends.first(where: { $0.isMe }) else { return [] }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return allClips
            .filter { $0.author?.id == me.id && $0.capturedAt >= startOfDay }
            .sorted { $0.capturedAt < $1.capturedAt } // chronological, like a vlog
    }

    var body: some View {
        ZStack {
            Theme.base.ignoresSafeArea()

            if todaysClips.isEmpty {
                VStack(spacing: 10) {
                    Text("🎬").font(.system(size: 60))
                    Text("Capture a log to start today's vlog")
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                let clip = todaysClips[min(index, todaysClips.count - 1)]
                // `.fit` over the black base: the recap shows the whole frame,
                // the same as every other surface.
                ClipView(clip: clip, isActive: true, contentMode: .fit)
                    .id(clip.id)
                    .transition(.opacity)
                    .ignoresSafeArea()

                VStack {
                    // Story-style progress
                    HStack(spacing: 4) {
                        ForEach(0..<todaysClips.count, id: \.self) { i in
                            Capsule()
                                .fill(i <= index ? Theme.accent : .white.opacity(0.3))
                                .frame(height: 3)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 54)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Today's vlog")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Spacer()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.label)
                                .font(.logCaption)
                                .foregroundStyle(.white)
                            Text(clip.capturedAt.hourOnlyClockTime)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 50)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .task(id: index) {
            guard todaysClips.count > 1 else { return }
            try? await Task.sleep(for: .seconds(clipDuration))
            advance()
        }
        .preferredColorScheme(.dark)
    }

    private func advance() {
        guard !todaysClips.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            index = (index + 1) % todaysClips.count
        }
    }
}
