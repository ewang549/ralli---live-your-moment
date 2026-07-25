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
    /// Set by a "friend request" notification; Pulse presents the inbox.
    var showRequestsInbox = false
    /// Set by a "message" notification; Pulse opens that Stream channel.
    var openThreadChannelId: String?
    /// Set when a Highlights card is tapped on someone's public profile;
    /// Places scrolls to and focuses this exact clip once it's the active tab.
    var focusedPlaceClipId: UUID?
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
    /// The real friend graph (accepted friends + pending requests both ways).
    /// Owned here so it survives tab switches and every surface sees one copy.
    @State private var friendGraph = FriendGraph()
    /// Log upload/download. Owned alongside the graph for the same reason.
    @State private var logSync = LogSync()
    /// The follow graph (one-directional, separate from friendships). Owned
    /// here too so the Places Following tab and every public-profile sheet
    /// read and write the same copy.
    @State private var followGraph = FollowGraph()
    /// Beacon publish/sync. Owned here for the same reason as the two above:
    /// the feed, the create sheet and the detail sheet all act on one copy.
    @State private var beaconSync = BeaconSync()
    /// Push registration + the destination of a tapped notification.
    @State private var push = PushNotifications.shared
    @State private var showNotificationPrimer = false
    /// Injected by AuthGateView; seeding depends on *resolved* auth.
    @Environment(AuthSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRetryingSends = false

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
        // Sends are fire-and-forget so the composer can dismiss instantly.
        // This is the other half of that bargain: the one place a send that
        // died on the network becomes visible after the fact. App-wide rather
        // than on one screen, because the capture flow can dismiss you onto
        // any tab.
        .overlay(alignment: .top) { sendFailureBanner }
        .animation(.spring(response: 0.32, dampingFraction: 0.86),
                   value: logSync.lastPublishError)
        .environment(router)
        .environment(friendGraph)
        .environment(logSync)
        .environment(followGraph)
        .environment(beaconSync)
        // Notification priming, once, on the first run that reaches the app.
        //
        // Deliberately here and not at the end of onboarding: the auth gate can
        // swap ProfileSetupView out from under itself the moment the profile
        // resolves, which silently ate a sheet presented there — and a primer
        // that sometimes doesn't appear is a permission that never gets asked
        // for. MainTabView is the first screen that's stable.
        .sheet(isPresented: $showNotificationPrimer) {
            NotificationPrimerView { push.hasPrimed = true }
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: Bindable(router).showCapture) {
            CameraCaptureView(context: router.captureContext, router: router, logSync: logSync)
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

            // Before any network work: the primer doesn't depend on it, and
            // sitting behind a slow sync is how it ends up never appearing.
            await push.refreshAuthorizationStatus()
            if push.shouldPrime { showNotificationPrimer = true }

            SeedData.seedIfNeeded(context: modelContext, session: session)
            // Clear DMs left behind by un-friending before the fix that deletes
            // them alongside the friend — otherwise they linger as "Just me".
            Chat.pruneOrphanedDMs(in: modelContext)
            // Real friendships land after seeding, so a real account's roster
            // reflects the server even in a DEBUG build with demo data forced.
            await friendGraph.refresh(context: modelContext)
            // Friends' logs need the roster to exist first — a log whose author
            // has no local row is dropped — so this follows the graph refresh.
            await logSync.syncDown(context: modelContext)
            // Catch up anything captured while offline.
            await logSync.publishPending(context: modelContext)
            // Who we follow — the Following tab under Places is built from it.
            await followGraph.refresh()
#if DEBUG
            // CLI verification hook: SIMCTL_CHILD_EXPLOG_AUTO_POST="caption"
            // captures a synthetic photo log and sends it through the real
            // upload + publishLog path. The simulator has no camera, so this is
            // the only way to exercise content sync end to end from the CLI.
            if let caption = ProcessInfo.processInfo.environment["EXPLOG_AUTO_POST"] {
                await postSyntheticLog(caption: caption)
            }

            // CLI screenshot hooks: SIMCTL_CHILD_EXPLOG_AUTO_OPEN=profile|places|beacons|capture
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "profile": router.tab = .profile
            case "places", "discover", "following": router.tab = .places
            case "beacons", "joined", "detail", "activitychat", "publicbeacons", "newbeacon": router.tab = .beacons
            case "capture": router.openCapture(.pulse)
            default: break
            }
#endif
        }
        // Deep links from a tapped notification. Consumed here rather than in
        // the gate so routing only happens once the app is actually signed in
        // and the tabs exist to route to.
        .onChange(of: push.pendingDestination) { _, destination in
            guard let destination else { return }
            open(destination)
            push.pendingDestination = nil
        }
        .task(id: push.pendingDestination) {
            // Covers a cold launch from a notification, where the destination
            // is already set before this view is listening for changes.
            if let destination = push.pendingDestination {
                open(destination)
                push.pendingDestination = nil
            }
        }
        // Coming back to the app is the most likely moment for connectivity to
        // have returned, so it's the cheapest place to recover a failed send
        // before the user has to notice anything broke.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await logSync.publishPending(context: modelContext) }
        }
        .onDisappear { orientation.stop() }
    }

    // MARK: Failed sends

    /// "That didn't send", with a way to fix it.
    ///
    /// Retrying is just `publishPending` — the same catch-up the app runs at
    /// launch and on foreground — so the button asks for automatic recovery to
    /// happen now rather than being a second, separate send path.
    @ViewBuilder
    private var sendFailureBanner: some View {
        if let message = logSync.lastPublishError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.amber)

                VStack(alignment: .leading, spacing: 1) {
                    Text(message)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(logSync.failedPublishCount > 1
                         ? "\(logSync.failedPublishCount) logs are still on this device."
                         : "It's still on this device.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 0)

                Button {
                    retryFailedSends()
                } label: {
                    Group {
                        if isRetryingSends {
                            ProgressView().tint(Theme.onAccent).scaleEffect(0.7)
                        } else {
                            Text("Retry").font(.caption.weight(.bold))
                        }
                    }
                    .foregroundStyle(Theme.onAccent)
                    .frame(minWidth: 46)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent))
                }
                .disabled(isRetryingSends)

                Button {
                    logSync.clearPublishError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background { GlassCard(cornerRadius: 14) { Color.clear } }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func retryFailedSends() {
        guard !isRetryingSends else { return }
        isRetryingSends = true
        Task {
            await logSync.publishPending(context: modelContext)
            isRetryingSends = false
        }
    }

    /// Routes a tapped notification to the screen it's about.
    private func open(_ destination: PushDestination) {
        switch destination {
        case .pulse:
            router.tab = .pulse
        case .requests:
            router.tab = .pulse
            router.showRequestsInbox = true
        case .capture:
            router.tab = .pulse
            router.openCapture(.pulse)
        case .thread(let channelId):
            router.tab = .pulse
            router.openThreadChannelId = channelId
        }
    }

#if DEBUG
    /// One-shot: `.task` re-runs whenever this view is remounted (every stage
    /// change through the auth gate does it), and without this the hook posts a
    /// fresh log each time.
    @MainActor
    private static var didAutoPost = false

    /// Writes a real image file, wraps it in a `Clip` authored by the signed-in
    /// user, and publishes it — the same path `SendToFriendsView` takes after a
    /// capture, minus the camera.
    private func postSyntheticLog(caption: String) async {
        guard !Self.didAutoPost else { return }
        Self.didAutoPost = true

        let friends = (try? modelContext.fetch(FetchDescriptor<Friend>())) ?? []
        guard let me = friends.first(where: \.isMe) else { return }

        let size = CGSize(width: 900, height: 1600)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 1.0, green: 0.35, blue: 0.37, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = caption as NSString
            text.draw(at: CGPoint(x: 60, y: 720), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.white,
            ])
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }

        let fileName = "\(UUID().uuidString).jpg"
        let url = URL.documentsDirectory.appending(path: fileName)
        try? data.write(to: url)

        let clip = Clip(author: me, chat: nil, capturedAt: .now, kind: .photo,
                        assetFileName: fileName, label: caption, emoji: "✨",
                        hueA: 0.02, hueB: 0.08)
        modelContext.insert(clip)
        try? modelContext.save()

        await logSync.publish(clip, context: modelContext)
    }
#endif

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
                    .fill(Theme.accent)
                    .frame(width: 52, height: 52)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 3)
                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
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
                    // Only the active tab is lit coral; the rest stay muted so the
                    // accent never reads as five competing highlights.
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary.opacity(0.8))
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
