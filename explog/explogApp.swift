import SwiftUI
import SwiftData
import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseMessaging
import StreamChat
import StreamChatSwiftUI
import os

/// Matches `PushNotifications.swift`'s logger, so APNs registration and the FCM
/// token save that follows it read as one story under `category: push` rather
/// than the failure landing somewhere the other half of the flow isn't.
private let pushLog = Logger(subsystem: "com.ej.explog", category: "push")

/// Interface-orientation policy changes and the geometry updates that carry
/// them out. A declined rotation is otherwise completely silent — it looks
/// exactly like "nothing happened" from the outside — so this is the only
/// signal there is when the system refuses to turn the interface.
private let orientationLog = Logger(subsystem: "com.ej.explog", category: "orientation")

/// Runtime-switchable interface-orientation policy.
///
/// The app ships iPhone-portrait-only (see `INFOPLIST_KEY_UISupportedInterface`
/// `Orientations_iPhone` in the project settings), but video in Ralli is always
/// shot horizontally — so the camera capture screen forces the interface into
/// landscape and locks it there. `AppDelegate` reports the current mask from
/// `application(_:supportedInterfaceOrientationsFor:)`; the helpers below flip
/// it and ask the active window scene to re-evaluate and physically rotate.
enum InterfaceOrientationLock {
    /// Orientations the app currently permits. Read on the main thread by the
    /// app delegate; mutated only through `lockLandscape()` / `lockPortrait()`.
    static var mask: UIInterfaceOrientationMask = .portrait

    /// Force the interface into landscape and hold it there, on the single edge
    /// that matches how the phone is physically being held.
    ///
    /// Deliberately *one* orientation rather than `.landscape`, which is both
    /// edges at once. With the phone's rotation lock engaged, the system only
    /// reliably overrides the lock for an app that permits exactly one
    /// orientation — there is nothing left to choose. Permit both and choosing
    /// between them needs the same automatic-rotation machinery Control Centre's
    /// lock disables, so the geometry request below can simply be declined and
    /// the camera comes up running but stuck in portrait.
    ///
    /// Reading the edge from the *device* keeps the rotation-lock-off case right
    /// too: a hard-coded edge would show the UI upside down for anyone who turns
    /// the phone the other way.
    @MainActor static func lockLandscape() { apply(landscapeMask()) }

    /// Return to the app's default portrait and rotate upright, whatever posture
    /// the phone is in — this is what "restores portrait" on camera exit.
    @MainActor static func lockPortrait() { apply(.portrait) }

    /// The one landscape edge matching the phone's current posture.
    ///
    /// `UIDeviceOrientation` and `UIInterfaceOrientation` name their landscapes
    /// from opposite ends — a device held `.landscapeLeft` puts the interface in
    /// `.landscapeRight` — so the two cases cross over here.
    ///
    /// Anything that isn't a landscape (`.portrait`, `.faceUp` on a table,
    /// `.unknown` before the sensor has reported) falls back to `.landscapeRight`
    /// rather than to a both-edge mask, since an ambiguous mask is the thing
    /// this whole function exists to avoid. The camera's controls reflow by
    /// orientation, not by edge, so either edge is equally right when the phone
    /// isn't telling us which one it's on.
    @MainActor private static func landscapeMask() -> UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: .landscapeRight
        }
    }

    @MainActor private static func apply(_ newMask: UIInterfaceOrientationMask) {
        // Update the reported mask FIRST so that when the system re-queries
        // supported orientations below it already sees the new policy.
        mask = newMask
        // Logged on the way in, not only on failure. The error handler below is
        // silent in the success case, which makes "no output at all" mean three
        // different things at once: the policy change never happened, it
        // happened but found no scene to ask, or it was asked and accepted.
        // Under a hardware rotation lock those are the exact possibilities that
        // need telling apart, and only this line separates them.
        orientationLog.notice(
            "apply(mask: \(newMask.rawValue, privacy: .public)) device=\(UIDevice.current.orientation.rawValue, privacy: .public)"
        )
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            orientationLog.error("no foreground-active window scene; geometry update not requested")
            return
        }
        // The handler only runs on failure. Swallowing it was how the declined
        // rotation under a hardware rotation lock stayed invisible for so long.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
            orientationLog.error(
                "requestGeometryUpdate(mask: \(newMask.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        // Where the interface actually ended up, once it has had time to turn.
        // An accepted request that nonetheless leaves the interface where it was
        // is indistinguishable from a working rotation in the log otherwise, and
        // that difference is the whole question under a rotation lock.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            orientationLog.notice(
                "settled interface=\(scene.interfaceOrientation.rawValue, privacy: .public) for mask=\(newMask.rawValue, privacy: .public)"
            )
        }
        // Nudge the system to re-read `supportedInterfaceOrientationsFor`, so it
        // doesn't immediately snap the interface back toward the old mask.
        //
        // Every controller up the presentation chain, not just the root: the
        // camera comes up in a full-screen cover, and iOS asks the *presented*
        // controller what it supports. Telling only the root to re-check left
        // the cover still reporting the previous mask, which is how the
        // viewfinder could come up vertical despite the lock being set.
        for controller in presentationChain(from: scene.keyWindow?.rootViewController) {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// A view controller and everything it has presented, root-most first.
    @MainActor private static func presentationChain(
        from root: UIViewController?
    ) -> [UIViewController] {
        var chain: [UIViewController] = []
        var next = root
        while let controller = next {
            chain.append(controller)
            next = controller.presentedViewController
        }
        return chain
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    // Keep a strong reference — required by the Stream SDK.
    var streamChat: StreamChat?

    /// The whole app is portrait except while the camera capture screen is up,
    /// which flips `InterfaceOrientationLock.mask` to landscape.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        InterfaceOrientationLock.mask
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

        // Initialize Stream Chat once at launch (key lives in StreamConfig).
        let config = ChatClientConfig(apiKey: .init(StreamConfig.apiKey))
        let chatClient = ChatClient(config: config)
        streamChat = StreamChat(chatClient: chatClient)

        // Ralli's own message kinds — currently a shared place — have to be
        // declared before the first message list is built, or the SDK draws
        // them as the plain text they fall back to.
        //
        // Strictly after `StreamChat(chatClient:)`: assigning through this key
        // path reads it first, and the getter asserts if the SDK hasn't been
        // initialised yet. Setting it a line earlier is a launch crash.
        InjectedValues[\.utils] = Utils(messageTypeResolver: RalliMessageTypeResolver())

        connectStreamUser(chatClient)

        // Delegates only — the permission prompt is deliberately deferred to
        // onboarding, which explains what the notifications are for first.
        Task { @MainActor in
            PushNotifications.shared.start()
            await PushNotifications.shared.registerIfAuthorized()
        }

        return true
    }

    /// Hands the APNs token to Firebase Messaging, which exchanges it for the
    /// FCM token the backend actually sends to.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Logged rather than printed: this is the one signal that push is dead
        // on this device, and it has to be findable in a device log filtered by
        // subsystem. A bare `print` only reaches an attached Xcode console,
        // which is exactly the situation you aren't in when a real build on a
        // real phone silently never receives anything.
        pushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Firebase-signed-in users get a backend-minted token (Stream user is
    /// created quietly server-side); otherwise fall back to the dev token.
    private func connectStreamUser(_ chatClient: ChatClient) {
        if let firebaseUser = Auth.auth().currentUser {
            Task { @MainActor in
                do {
                    let credentials = try await StreamTokenProvider.fetchToken(for: firebaseUser)
                    let token = try Token(rawValue: credentials.token)
                    chatClient.connectUser(
                        userInfo: .init(id: credentials.userId,
                                        name: firebaseUser.displayName ?? StreamConfig.userName),
                        token: token
                    ) { error in
                        if let error { print("Stream connect failed: \(error)") }
                    }
                } catch {
                    print("Stream token fetch failed: \(error)")
                    connectWithDevToken(chatClient)
                }
            }
        } else {
            connectWithDevToken(chatClient)
        }
    }

    private func connectWithDevToken(_ chatClient: ChatClient) {
        // `hasDevToken`, not `isEnabled` — `isEnabled` now reports whether a
        // user is already connected, which is exactly the state this function
        // exists to get out of.
        guard StreamConfig.hasDevToken, let token = try? Token(rawValue: StreamConfig.userToken) else { return }
        chatClient.connectUser(
            userInfo: .init(id: StreamConfig.userId, name: StreamConfig.userName),
            token: token
        ) { error in
            if let error { print("Stream connect failed: \(error)") }
        }
    }
}

@main
struct explogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Friend.self,
            Chat.self,
            Clip.self,
            Message.self,
            Spot.self,
            SpotClip.self,
            Beacon.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            AuthGateView()
        }
        .modelContainer(sharedModelContainer)
    }
}
