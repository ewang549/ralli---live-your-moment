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
        .background(Theme.background.ignoresSafeArea())
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

    private var tabBar: some View {
        HStack {
            // Tab 1: Profile
            tabButton(icon: "person.crop.circle", title: "Profile", target: .profile)
            // Tab 2: Pulse
            tabButton(icon: "clock.fill", title: "Pulse", target: .pulse)

            // Tab 3: Camera — center action button.
            Button {
                router.openCapture(router.contextForCurrentTab)
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 58, height: 58)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 12, y: 4)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .offset(y: -14)
            .accessibilityLabel("Capture a log")

            // Tab 4: Places
            tabButton(icon: "map.fill", title: "Places", target: .places)
            // Tab 5: Beacons
            tabButton(icon: "light.beacon.max.fill", title: "Beacons", target: .beacons)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Theme.background.opacity(0.6))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(icon: String, title: String, target: Tab) -> some View {
        Button {
            router.tab = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(router.tab == target ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    MainTabView()
        .environment(AuthSession())
        .modelContainer(for: Friend.self, inMemory: true)
}
