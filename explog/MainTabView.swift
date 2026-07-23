import SwiftUI
import SwiftData

/// Shared navigation state: lets any view (e.g. the privacy guard alert)
/// programmatically switch tabs or open capture.
@Observable
final class AppRouter {
    var tab: MainTabView.Tab = .pulse
    var showCapture = false
    /// Which surface opened the camera — decides the max clip length (2s vs 5s).
    var captureContext: CaptureContext = .pulse

    /// Opens capture with the recording cap that fits the surface asking for it.
    func openCapture(_ context: CaptureContext) {
        captureContext = context
        showCapture = true
    }

    /// The cap implied by the tab you're standing on when you raise the camera.
    var contextForCurrentTab: CaptureContext {
        switch tab {
        case .places, .beacons: .place
        case .profile, .pulse: .pulse
        }
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var router = AppRouter()
    @State private var orientation = OrientationObserver()
    /// Injected by AuthGateView; seeding depends on *resolved* auth.
    @Environment(AuthSession.self) private var session

    // Five surfaces, left to right: Profile · Pulse · Camera · Places · Beacons.
    enum Tab { case profile, pulse, places, beacons }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch router.tab {
                case .profile: UserProfileView()
                case .pulse: PulseHomeView()
                case .places: NichePlacesView()
                case .beacons: BeaconsFeedView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
        }
        .background(GlassBackground())
        .preferredColorScheme(.dark)
        .environment(router)
        .fullScreenCover(isPresented: Bindable(router).showCapture) {
            CameraCaptureView(context: router.captureContext)
        }
        // Turning the phone sideways *is* the shortcut to the camera: landscape
        // raises capture with the current tab's duration cap. Returning to
        // portrait leaves it up — you dismiss it yourself, as with any capture.
        .onChange(of: orientation.isLandscape) { _, landscape in
            guard landscape, !router.showCapture else { return }
            router.openCapture(router.contextForCurrentTab)
        }
        .task {
            orientation.start()
            SeedData.seedIfNeeded(context: modelContext, session: session)
#if DEBUG
            // CLI screenshot hooks: SIMCTL_CHILD_EXPLOG_AUTO_OPEN=profile|places|beacons|capture
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "profile": router.tab = .profile
            case "places", "discover": router.tab = .places
            case "beacons", "joined", "detail", "activitychat": router.tab = .beacons
            case "capture": router.openCapture(.pulse)
            default: break
            }
#endif
        }
        .onDisappear { orientation.stop() }
    }

    /// A floating glass pill rather than a docked bar: it hovers over whatever
    /// the tab is showing (including full-bleed media on Places), so the content
    /// runs edge to edge and the nav refracts what's behind it.
    private var tabBar: some View {
        HStack(spacing: 0) {
            // Tab 1: Profile
            tabButton(icon: "person.crop.circle", title: "Profile", target: .profile)
            // Tab 2: Pulse
            tabButton(icon: "clock.fill", title: "Pulse", target: .pulse)

            // Tab 3: Camera — center action, the one solid-metal element.
            captureButton

            // Tab 4: Places
            tabButton(icon: "map.fill", title: "Places", target: .places)
            // Tab 5: Beacons
            tabButton(icon: "light.beacon.max.fill", title: "Beacons", target: .beacons)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    // Inner sheen — light gathers along the top of the pill.
                    Capsule(style: .continuous).fill(
                        LinearGradient(colors: [Theme.glassTint, .clear, .black.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
                .overlay {
                    Capsule(style: .continuous).strokeBorder(
                        LinearGradient(colors: [Theme.glassRimTop, .white.opacity(0.05), Theme.glassRimBottom],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.55), radius: 20, y: 8)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var captureButton: some View {
        Button {
            router.openCapture(router.contextForCurrentTab)
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.goldSheen)
                    .frame(width: 52, height: 52)
                    .shadow(color: Theme.goldGlow.opacity(0.6), radius: 16, y: 3)
                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture a log")
    }

    private func tabButton(icon: String, title: String, target: Tab) -> some View {
        let isActive = router.tab == target
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { router.tab = target }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    // Only the active tab is lit; the rest stay muted so the
                    // gold never reads as five competing highlights.
                    .foregroundStyle(isActive ? AnyShapeStyle(Theme.goldSheen)
                                              : AnyShapeStyle(Theme.textSecondary))
                    .shadow(color: isActive ? Theme.goldGlow.opacity(0.7) : .clear, radius: 10)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Theme.gold : Theme.textSecondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MainTabView()
        .environment(AuthSession())
        .modelContainer(for: Friend.self, inMemory: true)
}
