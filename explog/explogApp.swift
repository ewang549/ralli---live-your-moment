import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAuth
import StreamChat
import StreamChatSwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    // Keep a strong reference — required by the Stream SDK.
    var streamChat: StreamChat?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

        // Initialize Stream Chat once at launch (key lives in StreamConfig).
        let config = ChatClientConfig(apiKey: .init(StreamConfig.apiKey))
        let chatClient = ChatClient(config: config)
        streamChat = StreamChat(chatClient: chatClient)

        connectStreamUser(chatClient)

        return true
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
        guard StreamConfig.isEnabled, let token = try? Token(rawValue: StreamConfig.userToken) else { return }
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
