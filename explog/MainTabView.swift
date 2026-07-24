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
    /// The tab we were on when the phone was turned sideways. Turning back to
    /// portrait restores it, so a rotate-to-camera round trip lands you exactly
    /// where you left off. Nil whenever we're not in the landscape camera.
    var previousTab: MainTabView.Tab?
    /// State flag for the camera's orientation state machine. false = live
    /// recording screen (State 1: rotating to portrait exits the camera).
    /// true  = a photo/video has been captured and the Preview/Send screen is
    /// up (State 2: rotating to portrait must NOT dismiss — it just re-orients
    /// the send UI to vertical). Set by CameraCaptureView as media is captured
    /// or discarded.
    var isPreviewActive = false

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
        .environment(router)
        .fullScreenCover(isPresented: Bindable(router).showCapture) {
            CameraCaptureView(context: router.captureContext, router: router)
        }
        // Turning the phone sideways *is* the shortcut to the camera. Landscape
        // remembers the tab you were on, then raises the landscape camera with
        // that tab's duration cap. Turning back to portrait closes the camera
        // and restores the remembered tab — a clean, glitch-free round trip.
        .onChange(of: orientation.isLandscape) { _, landscape in
            if landscape {
                guard !router.showCapture else { return }
                router.previousTab = router.tab               // save active tab
                router.openCapture(router.contextForCurrentTab)
            } else {
                // Back to portrait — the state machine decides what happens:
                //   State 1 (isPreviewActive == false): still on the live
                //     camera with nothing captured → exit and restore the tab.
                //     Closing the cover fires CameraCaptureView.onDisappear,
                //     which does the actual tab restore + flag cleanup.
                //   State 2 (isPreviewActive == true): media is captured and
                //     the Preview/Send screen is up → do nothing, so the send
                //     flow survives the rotation and just re-orients to vertical.
                if router.showCapture && !router.isPreviewActive {
                    router.showCapture = false
                }
            }
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
            // Floating pill: surface with a light blur so it hovers over content
            // (including full-bleed media on Places), with one soft warm shadow.
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous).fill(Theme.glassTint)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.glassRimTop, lineWidth: 0.75)
                }
                .shadow(color: Color(hex: 0x14121E, alpha: 0.16), radius: 20, y: 8)
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
                    .fill(Theme.iris)
                    .frame(width: 52, height: 52)
                    .shadow(color: Theme.iris.opacity(0.4), radius: 14, y: 3)
                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.onIris)
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
                    // Only the active tab is lit iris; the rest stay muted so the
                    // accent never reads as five competing highlights.
                    .foregroundStyle(isActive ? Theme.iris : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Theme.iris : Theme.textSecondary.opacity(0.8))
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
