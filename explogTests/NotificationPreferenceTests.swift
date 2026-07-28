import Testing
import Foundation
@testable import explog

/// The one thing about notification preferences that can fail silently and
/// badly: an account that predates them going dark.
///
/// Every existing user has no `notificationPrefs` at all, on the device or on
/// the server. If a missing key ever reads as "off", every one of them stops
/// getting notifications and nothing in the app looks wrong. Both ends encode
/// "absent means on" — the server in `notificationsAllowed`, the client here.
@MainActor
struct NotificationPreferenceTests {

    private func makeMe() -> Friend {
        Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
    }

    @Test func anAccountWithNoPreferencesWantsEverything() {
        let me = makeMe()
        #expect(me.notificationPrefs.isEmpty)
        for category in NotificationCategory.allCases {
            #expect(me.wantsNotification(category), "\(category.rawValue) should default to on")
        }
    }

    @Test func turningOneOffLeavesTheRestAlone() {
        let me = makeMe()
        me.setNotification(.chatMessages, enabled: false)

        #expect(!me.wantsNotification(.chatMessages))
        for category in NotificationCategory.allCases where category != .chatMessages {
            #expect(me.wantsNotification(category))
        }
    }

    @Test func togglingBackOnRestoresIt() {
        let me = makeMe()
        me.setNotification(.hourlyReminder, enabled: false)
        me.setNotification(.hourlyReminder, enabled: true)
        #expect(me.wantsNotification(.hourlyReminder))
    }

    /// The whole map is written every time, not just the changed key — a
    /// partial write would leave keys behind from an older version of the list.
    @Test func theSyncedPayloadSpellsOutEveryCategory() {
        let me = makeMe()
        me.setNotification(.beaconActivity, enabled: false)

        let payload = me.notificationPrefsPayload
        #expect(payload.count == NotificationCategory.allCases.count)
        #expect(payload["beaconActivity"] == false)
        #expect(payload["chatMessages"] == true)
        for category in NotificationCategory.allCases {
            #expect(payload[category.rawValue] != nil)
        }
    }

    /// Keys are the wire format shared with `functions/index.js`, where each
    /// `notify()` call site passes one as `prefKey`. Renaming a case silently
    /// detaches a switch from the notification it is supposed to control, so
    /// they are pinned here.
    @Test func categoryKeysMatchTheServerContract() {
        #expect(Set(NotificationCategory.allCases.map(\.rawValue)) == [
            "logReceived",
            "chatMessages",
            "friendRequests",
            "friendPostedLocation",
            "hourlyReminder",
            "streakReminder",
            "beaconActivity",
        ])
    }
}
