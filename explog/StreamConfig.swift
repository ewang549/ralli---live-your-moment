import Foundation

/// Stream Chat credentials. The API key is safe to ship; the API SECRET must
/// never appear anywhere in this app — tokens are minted server-side / via the
/// Stream CLI (`getstream token <user>`).
enum StreamConfig {
    static let apiKey = "msdyxmxmqf53"

    /// Fallback display identity for a launch with no signed-in account.
    static let userId = "ethan"
    static let userName = "Ethan"

    /// Deliberately empty.
    ///
    /// This used to hold a long-lived user JWT minted by `getstream token ethan`
    /// so the app could reach Stream without an account. A user token is a
    /// credential: committed to the repo it let anyone impersonate that Stream
    /// user until the API secret is rotated. Every signed-in path now goes
    /// through `StreamTokenProvider.fetchToken`, which mints a token bound to
    /// the real Firebase caller, so the fallback earned nothing.
    ///
    /// Empty = Stream messaging disabled; chat surfaces fall back to the local
    /// on-device store. To develop signed-out, put a short-lived token in a
    /// gitignored xcconfig — never here.
    static let userToken = ""

    static var isEnabled: Bool { !userToken.isEmpty }
}
