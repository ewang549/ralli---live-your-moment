import SwiftUI
import SwiftData
import UIKit
import FirebaseCore
import FirebaseAuth
import FirebaseMessaging
import StreamChat
import StreamChatSwiftUI

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

    /// Force the interface into landscape and hold it there. The system rotates
    /// to whichever landscape edge matches how the phone is being held.
    @MainActor static func lockLandscape() { apply(.landscape) }

    /// Return to the app's default portrait and rotate upright, whatever posture
    /// the phone is in — this is what "restores portrait" on camera exit.
    @MainActor static func lockPortrait() { apply(.portrait) }

    @MainActor private static func apply(_ newMask: UIInterfaceOrientationMask) {
        // Update the reported mask FIRST so that when the system re-queries
        // supported orientations below it already sees the new policy.
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
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
        print("APNs registration failed: \(error)")
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
