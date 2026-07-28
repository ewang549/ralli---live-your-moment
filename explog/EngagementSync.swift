import Foundation
import SwiftData
import FirebaseAuth
import Observation
import os

private let engagementLog = Logger(subsystem: "com.ej.explog", category: "engagement")

/// Likes, comments and view counts — the engagement layer over `logs/{id}`.
///
/// Sized like `BeaconSync` rather than `LogSync`: there's no media and no
/// materialisation pass, just three callables and the local rows they keep
/// honest. It exists because all of this used to be a pure SwiftData mutation —
/// `toggleLike()` flipped a boolean and incremented an integer on the device,
/// so a like or a comment was only ever visible to the person who made it.
///
/// Every action here is optimistic-then-reconciled, the same bargain
/// `FollowGraph`'s callers make: the UI moves on the same frame as the tap, and
/// the server's answer either confirms it or puts it back.
@Observable
@MainActor
final class EngagementSync {
    /// Last failure, for surfacing "couldn't reach the server".
    private(set) var lastError: String?

    /// Logs already counted as viewed this session.
    ///
    /// Scrolling a feed back and forth over one clip is one view, not ten. This
    /// is deliberately in memory and deliberately per-session: the alternative
    /// is a permanent per-viewer record on every log, which is a great deal of
    /// storage to answer a question nobody asks. A relaunch counting one more
    /// view is the acceptable side of that trade.
    private var countedViews: Set<String> = []

    /// Drops session state so a new sign-in doesn't inherit the previous
    /// account's "already counted" set.
    func clear() {
        countedViews.removeAll()
        lastError = nil
    }

    // MARK: Likes

    /// Toggles a like, flipping the local row first and reconciling with the
    /// server's count.
    ///
    /// The rollback matters more than it looks: without it a like that failed
    /// on the network stays lit forever, which reads exactly like a like that
    /// worked, and the user has no way to tell the difference.
    func toggleLike(_ clip: SpotClip, context: ModelContext) async {
        guard Auth.auth().currentUser != nil else { return }
        guard !clip.remoteID.isEmpty else {
            // Seed and device-only clips have nothing on the server to like.
            // Keeping the local flip is the honest behaviour here: there is no
            // audience for this row either way.
            clip.likedByMe.toggle()
            clip.likeCount = max(0, clip.likeCount + (clip.likedByMe ? 1 : -1))
            try? context.save()
            return
        }

        let wasLiked = clip.likedByMe
        let previousCount = clip.likeCount

        clip.likedByMe.toggle()
        clip.likeCount = max(0, previousCount + (clip.likedByMe ? 1 : -1))
        try? context.save()

        do {
            let result = try await CallableFunctions.call("toggleLikeLog",
                                                          data: ["logId": clip.remoteID],
                                                          as: LikeResult.self)
            clip.likedByMe = result.liked
            clip.likeCount = max(0, result.likeCount)
            try? context.save()
            lastError = nil
        } catch {
            clip.likedByMe = wasLiked
            clip.likeCount = previousCount
            try? context.save()
            lastError = message(for: error)
            engagementLog.error("like failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Comments

    /// Replaces a clip's local comments with the server's copy.
    ///
    /// A whole-list replace rather than a merge: the server is the only place
    /// comments actually live now, so anything local that isn't in the response
    /// is either already deleted or was never sent.
    func loadComments(for clip: SpotClip, context: ModelContext) async {
        guard Auth.auth().currentUser != nil, !clip.remoteID.isEmpty else { return }

        do {
            let response = try await CallableFunctions.call("listComments",
                                                            data: ["logId": clip.remoteID,
                                                                   "limit": 200],
                                                            as: CommentsResponse.self)
            guard !Task.isCancelled else { return }
            clip.comments = response.comments.map(\.local)
            try? context.save()
            lastError = nil
        } catch {
            lastError = message(for: error)
            engagementLog.error("load comments failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Posts a comment, showing it immediately and reconciling with the
    /// server's stored copy.
    ///
    /// - Returns: true when the comment reached the server.
    @discardableResult
    func addComment(_ text: String, to clip: SpotClip, context: ModelContext) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Auth.auth().currentUser != nil else { return false }
        guard !clip.remoteID.isEmpty else { return false }

        // Shown straight away under whatever name the local profile knows; the
        // server's copy replaces it below with the identity it actually stored.
        let pending = ClipComment(authorUID: Auth.auth().currentUser?.uid ?? "",
                                  authorName: localName(in: context),
                                  text: trimmed,
                                  sentAt: .now)
        clip.comments.append(pending)
        try? context.save()

        do {
            let response = try await CallableFunctions.call("addComment",
                                                            data: ["logId": clip.remoteID,
                                                                   "text": trimmed],
                                                            as: AddCommentResponse.self)
            // Swap the optimistic row for the stored one rather than appending
            // beside it — matched on the placeholder's empty `remoteID`, which
            // is the only thing that distinguishes it.
            if let index = clip.comments.lastIndex(where: { $0.remoteID.isEmpty && $0.text == trimmed }) {
                clip.comments[index] = response.comment.local
            } else {
                clip.comments.append(response.comment.local)
            }
            try? context.save()
            lastError = nil
            return true
        } catch {
            if let index = clip.comments.lastIndex(where: { $0.remoteID.isEmpty && $0.text == trimmed }) {
                clip.comments.remove(at: index)
            }
            try? context.save()
            lastError = message(for: error)
            engagementLog.error("comment failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Views

    /// Counts one view of a log, at most once per session.
    ///
    /// Fire-and-forget on purpose: this is called from a feed as clips scroll
    /// past, and nothing on screen waits for it. The server drops the author's
    /// own views, so watching your own log back never inflates its count.
    func markViewed(logID: String) {
        guard !logID.isEmpty, Auth.auth().currentUser != nil else { return }
        guard countedViews.insert(logID).inserted else { return }

        Task { [weak self] in
            do {
                _ = try await CallableFunctions.call("viewLog",
                                                     data: ["logId": logID],
                                                     as: ViewResult.self)
            } catch {
                // Let it be retried later in the session: a view that failed on
                // a dropped connection shouldn't be permanently swallowed.
                self?.countedViews.remove(logID)
                engagementLog.error("view failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pulls one log's counters and caches them on the local clip.
    ///
    /// Needed because your own logs never come back through `listFriendLogs` —
    /// that queries your friends' logs, not yours — so this is the only route
    /// by which an author learns their own view count.
    func refreshStats(for clip: Clip, context: ModelContext) async {
        guard Auth.auth().currentUser != nil, !clip.remoteID.isEmpty else { return }

        do {
            let stats = try await CallableFunctions.call("logStats",
                                                          data: ["logId": clip.remoteID],
                                                          as: LogStats.self)
            guard !Task.isCancelled else { return }
            clip.viewCount = max(0, stats.viewCount)
            try? context.save()
            lastError = nil
        } catch {
            lastError = message(for: error)
            engagementLog.error("stats failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    private func localName(in context: ModelContext) -> String {
        let me = ((try? context.fetch(FetchDescriptor<Friend>())) ?? []).first { $0.isMe }
        return me?.name ?? "You"
    }

    private func message(for error: Error) -> String {
        (error as? CallableFunctions.CallableError)?.message ?? "Couldn't reach the server."
    }

    // MARK: Wire types

    private struct LikeResult: Decodable {
        let liked: Bool
        let likeCount: Int
    }

    private struct ViewResult: Decodable {
        let viewCount: Int
    }

    private struct LogStats: Decodable {
        let likeCount: Int
        let commentCount: Int
        let viewCount: Int
    }

    private struct CommentsResponse: Decodable {
        let comments: [RemoteComment]
    }

    private struct AddCommentResponse: Decodable {
        let comment: RemoteComment
    }

    struct RemoteComment: Decodable {
        let id: String
        let authorUid: String
        let authorName: String
        let authorAvatarEmoji: String
        let authorAvatarURL: String
        let text: String
        let sentAt: Double

        var local: ClipComment {
            ClipComment(remoteID: id,
                        authorUID: authorUid,
                        authorName: authorName,
                        authorAvatarEmoji: authorAvatarEmoji,
                        authorAvatarURL: authorAvatarURL,
                        text: text,
                        sentAt: Date(timeIntervalSince1970: sentAt / 1000))
        }
    }
}
