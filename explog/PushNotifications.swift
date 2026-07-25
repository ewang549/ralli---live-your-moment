import Foundation
import SwiftUI
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import Observation
import os

private let pushLog = Logger(subsystem: "com.ej.explog", category: "push")

/// Where a notification wants to take you.
///
/// Kept as a small enum rather than raw strings so the routing in `AppRouter`
/// can't drift from what the server sends — every payload type is named here.
enum PushDestination: Equatable {
    /// A specific 1-on-1 or group conversation, by Stream channel id.
    case thread(channelId: String)
    /// The friend requests inbox.
    case requests
    /// The capture screen (streak nudges).
    case capture
    /// Pulse, the default landing.
    case pulse

    /// Decodes the `type`/`channelId` pair the notification functions send.
    init(payload: [AnyHashable: Any]) {
        switch payload["type"] as? String {
        case "message":
            if let channelId = payload["channelId"] as? String, !channelId.isEmpty {
                self = .thread(channelId: channelId)
            } else {
                self = .pulse
            }
        case "friend_request":
            self = .requests
        case "friend_accepted":
            self = .pulse
        case "streak":
            self = .capture
        default:
            self = .pulse
        }
    }
}

/// APNs registration, FCM token bookkeeping, and permission priming.
///
/// The token lives at `users/{uid}/devices/{token}`. It's written when it's
/// minted and when the account changes, and deleted on sign-out — a token left
/// behind would keep delivering one person's notifications to a device that
/// somebody else is now signed in on.
@Observable
@MainActor
final class PushNotifications: NSObject {
    static let shared = PushNotifications()

    /// Set when a notification is tapped, for the router to consume.
    var pendingDestination: PushDestination?
    /// Current permission state, so onboarding knows whether to prime.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private var currentToken: String?

    private static let primedKey = "ralli.hasPrimedNotifications"

    /// Whether the explainer has already been shown. Persisted so it appears
    /// once per install, not once per launch.
    var hasPrimed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.primedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.primedKey) }
    }

    /// Show the explainer only when there's a decision left to make: a user who
    /// already allowed (or already refused) shouldn't be asked again.
    var shouldPrime: Bool {
        !hasPrimed && authorization == .notDetermined
    }

    // MARK: Setup

    /// Wires the delegates. Deliberately does *not* ask for permission — that's
    /// `requestAuthorization()`, called from onboarding after we've explained
    /// what the notifications are for. Prompting cold is how you get denied.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission, then registers with APNs if granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            pushLog.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Registers with APNs when permission already exists — e.g. on relaunch.
    func registerIfAuthorized() async {
        await refreshAuthorizationStatus()
        guard authorization == .authorized || authorization == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: Token bookkeeping

    /// Stores the FCM token against the signed-in account.
    func saveToken(_ token: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        currentToken = token
        do {
            try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("devices").document(token)
                .setData([
                    "token": token,
                    "platform": "ios",
                    "updatedAt": FieldValue.serverTimestamp(),
                ], merge: true)
            pushLog.info("saved device token for \(uid, privacy: .public)")
        } catch {
            pushLog.error("token save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-saves the current token under whoever is signed in now. Called after
    /// sign-in, since a token minted while signed out has nowhere to live.
    func syncTokenForCurrentUser() async {
        if let currentToken {
            await saveToken(currentToken)
        } else if let token = try? await Messaging.messaging().token() {
            await saveToken(token)
        }
    }

    /// Removes this device's token from the account being signed out of.
    ///
    /// Takes the uid explicitly: by the time sign-out finishes,
    /// `Auth.currentUser` is already nil and we'd have nothing to delete under.
    func clearToken(for uid: String) async {
        guard let token = currentToken else { return }
        do {
            try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("devices").document(token)
                .delete()
            pushLog.info("cleared device token for \(uid, privacy: .public)")
        } catch {
            pushLog.error("token clear failed: \(error.localizedDescription, privacy: .public)")
        }
        // Drop the FCM registration too, so this install stops being a target
        // until the next sign-in re-registers it.
        try? await Messaging.messaging().deleteToken()
        currentToken = nil
    }
}

// MARK: - Notification delegates

extension PushNotifications: UNUserNotificationCenterDelegate {
    /// Show notifications while the app is foregrounded — Ralli is a "what are
    /// your friends up to right now" app, so suppressing them in-app would hide
    /// exactly the thing the user opened the app for.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = response.notification.request.content.userInfo
        await MainActor.run {
            self.pendingDestination = PushDestination(payload: payload)
        }
    }
}

extension PushNotifications: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { await self.saveToken(fcmToken) }
    }
}
