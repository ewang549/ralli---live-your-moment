import SwiftUI
import SwiftData

// MARK: - Edit Profile
//
// Everything that answers "how do I present myself": the photo, the name, the
// details under it, the tags, and whether any of it is visible to people who
// aren't friends. Account administration — the address you sign in with, the
// session, the account itself — lives in Settings instead, because those are
// things you *do to the account* rather than things other people see.

struct EditProfileView: View {
    @Bindable var me: Friend

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let interestOptions = ["surf", "climb", "hike", "food", "music", "photo", "code", "games"]

    /// Debounces pushing edited fields to Firestore — they are bound straight
    /// to SwiftData, so they change on every keystroke.
    @State private var profileSyncTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        avatarPicker
                        privacyToggle
                        identityFields
                        bioField
                        guidelinesWarning
                        interestChips
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        // Every edited field mirrors to Firestore, so search and other people's
        // view of this account stay in step with what's on screen here.
        .onChange(of: me.name) { scheduleProfileSync() }
        .onChange(of: me.city) { scheduleProfileSync() }
        .onChange(of: me.bio) { scheduleProfileSync() }
        .onChange(of: me.isPrivate) {
            try? modelContext.save()
            scheduleProfileSync()
        }
        // A pending debounce would otherwise be cancelled by this view going
        // away, losing the last few characters typed before Done.
        .onDisappear {
            try? modelContext.save()
            flushProfileSync()
        }
    }

    // MARK: Pieces

    /// One large, centred photo. Ralli uses real photos now, so there's no
    /// emoji picker beside it — the emoji orb survives only as the fallback
    /// fill inside `GlassOrbAvatar` when nothing has been chosen yet.
    private var avatarPicker: some View {
        AvatarPhotoButton(onPicked: { fileName in
            me.avatarPhotoFileName = fileName
            try? modelContext.save()
            uploadAvatar(fileName: fileName)
        }) {
            ZStack(alignment: .bottomTrailing) {
                GlassOrbAvatar(friend: me, size: 112, isActive: true)
                AvatarPhotoBadge().offset(x: 2, y: 2)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Change profile photo")
    }

    /// Public/private — the switch that gates every community feature.
    private var privacyToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { !me.isPrivate },
                                 set: { me.isPrivate = !$0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(me.isPrivate ? "Private profile" : "Public profile")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(me.isPrivate
                         ? "Hidden from community feeds. Public activities are locked."
                         : "Visible in community feeds. You can host and join public activities.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
        }
        .padding(14)
        .background {
            GlassCard(cornerRadius: 16) { Color.clear }
                // A public profile carries a coral edge — the setting is
                // legible without reading the label.
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(me.isPrivate ? Color.clear : Theme.accent.opacity(0.5),
                                      lineWidth: 1)
                }
        }
    }

    private var identityFields: some View {
        VStack(spacing: 10) {
            ProfileFieldRow(label: "Full name", text: $me.name)
            ProfileFieldRow(label: "City", text: $me.city)
            HStack {
                Text("Age")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Stepper("\(me.age)", value: $me.age, in: 13...120)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background { GlassCard(cornerRadius: 12) { Color.clear } }
        }
    }

    private var bioField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BIO")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Say something about yourself…", text: $me.bio, axis: .vertical)
                .lineLimit(2...4)
                .padding(12)
                .background { GlassCard(cornerRadius: 12) { Color.clear } }
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var interestChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INTERESTS")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            FlowChips(options: interestOptions, selection: $me.interests)
        }
    }

    // MARK: Sync

    /// Pushes a newly picked photo to Storage and records its URL on the
    /// profile. Best-effort, mirroring `LogSync.publish`: the photo is already
    /// on disk and already showing, so a failed upload must not undo the pick.
    private func uploadAvatar(fileName: String) {
        let localURL = URL.documentsDirectory.appending(path: fileName)
        Task { try? await FirestoreService.uploadAvatarPhoto(at: localURL) }
    }

    private var softFields: [String: Any] {
        ["name": me.name, "city": me.city, "bio": me.bio, "isPrivate": me.isPrivate]
    }

    /// Whether anything on this screen would be published as objectionable.
    ///
    /// These three fields are the app's one piece of user-authored text that
    /// never passes through a Cloud Function — `updateSoftFields` writes them
    /// straight to Firestore under the `onlySoftProfileFields` rule — so this
    /// check is the only thing standing between them and every other user.
    private var violatingField: String? {
        if ContentFilter.isObjectionable(me.name) { return "name" }
        if ContentFilter.isObjectionable(me.bio) { return "bio" }
        if ContentFilter.isObjectionable(me.city) { return "city" }
        return nil
    }

    @ViewBuilder
    private var guidelinesWarning: some View {
        if let violatingField {
            Label("Your \(violatingField) breaks Ralli's community guidelines and won't be saved. "
                  + "Ralli has zero tolerance for objectionable content.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scheduleProfileSync() {
        // Nothing leaves the device while a field is in violation. The edit
        // stays visible locally so it can be corrected rather than being
        // reverted under the person typing; it just never becomes public.
        guard violatingField == nil else {
            profileSyncTask?.cancel()
            return
        }
        let fields = softFields
        profileSyncTask?.cancel()
        profileSyncTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? await FirestoreService.updateSoftFields(fields)
        }
    }

    /// Sends the current values immediately, without the debounce — for when
    /// the screen is closing and there may be no later chance.
    private func flushProfileSync() {
        guard violatingField == nil else {
            profileSyncTask?.cancel()
            return
        }
        let fields = softFields
        profileSyncTask?.cancel()
        Task { try? await FirestoreService.updateSoftFields(fields) }
    }
}

// MARK: - Shared field row

/// A labelled text row on a glass card. Shared by Edit Profile and Settings so
/// the two screens don't drift into looking like different apps.
struct ProfileFieldRow: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            TextField(label, text: $text)
                .keyboardType(keyboard)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background { GlassCard(cornerRadius: 12) { Color.clear } }
    }
}
