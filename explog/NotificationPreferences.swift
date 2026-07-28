import Foundation
import SwiftData

/// What Ralli is allowed to buzz your phone about.
///
/// One case per thing the backend actually sends. The raw value is the key
/// written into `users/{uid}.notificationPrefs` and the same key every
/// `notify()` call site on the server passes as its `prefKey`, so adding a
/// category here means adding it in exactly one place there.
///
/// Absent means on. That matters: every account that predates this feature has
/// no `notificationPrefs` field at all, and reading a missing key as "off"
/// would silently stop notifying every existing user.
enum NotificationCategory: String, CaseIterable, Identifiable {
    /// A friend sent you a log.
    case logReceived
    /// A new chat message.
    case chatMessages
    /// Friend requests, sent and accepted.
    case friendRequests
    /// A friend posted publicly at a place.
    case friendPostedLocation
    /// The nudge to log this hour.
    case hourlyReminder
    /// The evening warning that a streak is about to lapse.
    case streakReminder
    /// Someone joined a beacon you're hosting.
    case beaconActivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logReceived: "Logs sent to you"
        case .chatMessages: "Messages"
        case .friendRequests: "Friend requests"
        case .friendPostedLocation: "Friends posting places"
        case .hourlyReminder: "Hourly reminders"
        case .streakReminder: "Streak reminders"
        case .beaconActivity: "Beacon activity"
        }
    }

    var detail: String {
        switch self {
        case .logReceived: "When a friend sends a log your way."
        case .chatMessages: "New messages in your chats."
        case .friendRequests: "When someone adds you, and when they accept."
        case .friendPostedLocation: "When a friend posts publicly at a place."
        case .hourlyReminder: "A nudge to log, once an hour during the day."
        case .streakReminder: "An evening heads-up before a streak breaks."
        case .beaconActivity: "When someone joins a beacon you're hosting."
        }
    }
}

extension Friend {
    /// Whether `category` is switched on. On by default, including for every
    /// account written before preferences existed.
    func wantsNotification(_ category: NotificationCategory) -> Bool {
        notificationPrefs[category.rawValue] ?? true
    }

    func setNotification(_ category: NotificationCategory, enabled: Bool) {
        notificationPrefs[category.rawValue] = enabled
    }

    /// The full set, spelled out, for writing to `users/{uid}`.
    ///
    /// Every category is sent rather than only the ones that differ from the
    /// default: the server reads one map and a partial write would leave stale
    /// keys behind from a previous version of this list.
    var notificationPrefsPayload: [String: Bool] {
        Dictionary(uniqueKeysWithValues: NotificationCategory.allCases.map {
            ($0.rawValue, wantsNotification($0))
        })
    }
}
