import SwiftUI
import SwiftData
import MapKit
import CoreLocation

// MARK: - Local mirror

extension Spot {
    /// Creates or updates the local row for a server spot.
    ///
    /// Firestore is the source of truth for places; SwiftData stays the read
    /// model every screen renders, same split `LogSync` uses for clips. Matching
    /// on `remoteID` is what stops a place picked twice from becoming two rows.
    @MainActor
    @discardableResult
    static func mirror(_ remote: RemoteSpot, into context: ModelContext) -> Spot {
        let descriptor = FetchDescriptor<Spot>()
        let existing = ((try? context.fetch(descriptor)) ?? [])
            .first { $0.remoteID == remote.id }

        let spot: Spot
        if let existing {
            spot = existing
        } else {
            spot = Spot(name: remote.name,
                        category: remote.category,
                        summary: remote.summary,
                        aiInsight: "",
                        distanceMiles: 0,
                        emoji: remote.emoji.isEmpty ? "📍" : remote.emoji,
                        hueA: remote.hueA,
                        hueB: remote.hueB)
            context.insert(spot)
        }

        spot.remoteID = remote.id
        spot.name = remote.name
        spot.category = remote.category
        spot.summary = remote.summary
        spot.address = remote.address
        spot.latitude = remote.latitude
        spot.longitude = remote.longitude
        spot.hasCoordinate = true

        try? context.save()
        return spot
    }
}

// MARK: - Search model

/// Live place search, backed by MapKit for discovery and by Firestore for the
/// places Ralli already knows about.
///
/// Both lists matter: MapKit can find anywhere on earth but knows nothing about
/// Ralli, while the server knows exactly which places already have clips and
/// beacons on them. Picking either one settles on the same server record,
/// because `upsertSpot` derives a place's id from the place itself.
@MainActor
@Observable
final class SpotSearchModel: NSObject, MKLocalSearchCompleterDelegate, CLLocationManagerDelegate {
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            completer.queryFragment = query
            scheduleKnownSearch()
        }
    }

    /// Map suggestions for whatever is being typed.
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    /// Spots that already exist in Ralli and match the query.
    private(set) var knownSpots: [RemoteSpot] = []
    /// The place chosen but not yet confirmed — what the map preview shows.
    private(set) var pending: PendingSpot?
    private(set) var isResolving = false
    private(set) var errorMessage: String?

    private let completer = MKLocalSearchCompleter()
    private let locationManager = CLLocationManager()
    private var knownSearchTask: Task<Void, Never>?

    /// The most recent fix, kept so "use current location" can answer instantly
    /// when search biasing has already asked for one.
    private var lastFix: CLLocation?
    /// Everyone waiting on the next fix. A list rather than a single
    /// continuation because the delegate is the only place a fix arrives, and it
    /// has to be able to answer every caller that queued up behind it — and
    /// resume *all* of them on a failure or a refusal, or the button spins
    /// forever.
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []

    /// A place resolved to real coordinates, ready to confirm.
    struct PendingSpot: Equatable {
        var name: String
        var address: String
        var category: String
        var coordinate: CLLocationCoordinate2D
        /// Set when this came from a spot the server already had, so confirming
        /// doesn't need a round trip at all.
        var existing: RemoteSpot?

        static func == (lhs: PendingSpot, rhs: PendingSpot) -> Bool {
            lhs.name == rhs.name
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        // Points of interest and addresses both count as places worth logging.
        completer.resultTypes = [.pointOfInterest, .address]
        locationManager.delegate = self
    }

    /// Asks for location only to bias results toward where the user actually
    /// is. Search works without it, so a refusal costs relevance, not function.
    func startBiasingToCurrentArea() {
        guard locationManager.authorizationStatus == .notDetermined
                || locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways else { return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.requestLocation()
    }

    // MARK: Selection

    /// Resolves a map suggestion to coordinates, which the completer doesn't
    /// carry — that takes a second request.
    func select(_ completion: MKLocalSearchCompletion) {
        isResolving = true
        errorMessage = nil
        Task {
            defer { isResolving = false }
            let request = MKLocalSearch.Request(completion: completion)
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard let item = response.mapItems.first else {
                    errorMessage = "Couldn't locate that place."
                    return
                }
                pending = PendingSpot(name: item.name ?? completion.title,
                                      address: Self.address(for: item, fallback: completion.subtitle),
                                      category: item.pointOfInterestCategory?.rawValue ?? "",
                                      coordinate: item.placemark.coordinate,
                                      existing: nil)
            } catch {
                errorMessage = "Couldn't locate that place."
            }
        }
    }

    /// Resolves wherever the phone is standing into a place you can post,
    /// without typing anything.
    ///
    /// The location fix on its own is just a coordinate — a beacon needs a place
    /// with a name, so the fix is turned into a real `MKMapItem` before it
    /// becomes a `PendingSpot`. From there this is the ordinary flow: the same
    /// map confirmation covers it, and `confirm()` upserts it like any other.
    func useCurrentLocation() {
        guard !isResolving else { return }
        isResolving = true
        errorMessage = nil
        Task {
            defer { isResolving = false }
            guard let location = await currentFix() else {
                errorMessage = locationManager.authorizationStatus == .denied
                    || locationManager.authorizationStatus == .restricted
                    ? "Allow location access in Settings to use where you are."
                    : "Couldn't get your location. Try searching instead."
                return
            }
            guard let resolved = await Self.place(at: location) else {
                errorMessage = "Couldn't work out where you are. Try searching instead."
                return
            }
            pending = resolved
        }
    }

    /// The current fix, waiting for one if the manager hasn't produced it yet.
    ///
    /// Capped rather than open-ended: `requestLocation` can sit indefinitely
    /// indoors or on a simulator with no location set, and a button that spins
    /// forever is worse than one that says it couldn't.
    private func currentFix() async -> CLLocation? {
        // A fix from the last couple of minutes is still where you are, and
        // reusing it makes the common case — the biasing request already
        // answered — instant.
        if let lastFix, lastFix.timestamp.timeIntervalSinceNow > -120 { return lastFix }

        let status = locationManager.authorizationStatus
        guard status != .denied && status != .restricted else { return nil }
        if status == .notDetermined {
            // The delegate requests a fix once permission lands.
            locationManager.requestWhenInUseAuthorization()
        } else {
            locationManager.requestLocation()
        }

        let waited = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    self.fixWaiters.append(continuation)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // The timeout arm leaves a continuation parked; releasing it here keeps
        // a later fix from resuming a waiter this call has already abandoned.
        if waited == nil { deliverFix(nil) }
        return waited ?? lastFix
    }

    /// Resumes everyone waiting on a fix, and remembers it for the next caller.
    private func deliverFix(_ location: CLLocation?) {
        if let location { lastFix = location }
        let waiters = fixWaiters
        fixWaiters = []
        for waiter in waiters { waiter.resume(returning: location) }
    }

    /// Turns a coordinate into a named place.
    ///
    /// Points of interest first, because a POI carries the two things a spot
    /// wants and a coordinate doesn't: a real name and a category. Reverse
    /// geocoding is the fallback — standing in the middle of a park or on a
    /// residential street matches no POI, and an address is still a place worth
    /// logging.
    private static func place(at location: CLLocation) async -> PendingSpot? {
        let nearby = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 150)
        if let response = try? await MKLocalSearch(request: nearby).start(),
           let item = bestPlace(in: response.mapItems, near: location) {
            return PendingSpot(name: item.name ?? "Current location",
                               address: address(for: item, fallback: ""),
                               category: item.pointOfInterestCategory?.rawValue ?? "",
                               coordinate: item.placemark.coordinate,
                               existing: nil)
        }

        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return PendingSpot(name: item.name ?? "Current location",
                           address: address(for: item, fallback: ""),
                           category: item.pointOfInterestCategory?.rawValue ?? "",
                           coordinate: item.placemark.coordinate,
                           existing: nil)
    }

    /// Which of the nearby results is the place a person would say they're at.
    ///
    /// Neither the nearest nor simply the first. MapKit indexes a building's
    /// fittings alongside the building, and at the Ferry Building both the
    /// closest result and the top-ranked one are literally "Elevator". What
    /// separates those from the building is that they carry no
    /// `pointOfInterestCategory` — a real destination is categorised, a fitting
    /// inside one generally isn't. So: categorised places first, minus the
    /// categories that are still plumbing, in MapKit's own relevance order.
    private static func bestPlace(in items: [MKMapItem], near location: CLLocation) -> MKMapItem? {
        let named = items.filter { !($0.name ?? "").isEmpty }
        let places = named.filter { item in
            guard let category = item.pointOfInterestCategory else { return false }
            return !infrastructure.contains(category)
        }
        // Falls back through each narrowing, so somewhere with nothing but an
        // uncategorised result still resolves rather than dropping to a bare
        // address.
        return places.first ?? named.first ?? items.first
    }

    /// Categorised, but still part of a place rather than a place to be at.
    private static let infrastructure: Set<MKPointOfInterestCategory> = [
        .restroom, .parking, .mailbox, .atm, .evCharger, .publicTransport
    ]

    /// Picks a spot Ralli already has — no map resolution needed, it already
    /// carries its coordinates.
    func select(_ spot: RemoteSpot) {
        pending = PendingSpot(name: spot.name,
                              address: spot.address,
                              category: spot.category,
                              coordinate: CLLocationCoordinate2D(latitude: spot.latitude,
                                                                 longitude: spot.longitude),
                              existing: spot)
    }

    func clearPending() { pending = nil }

    /// Turns the pending place into a real server spot — or returns the
    /// existing one, if that's where it came from.
    func confirm() async throws -> RemoteSpot {
        guard let pending else {
            throw CallableFunctions.CallableError(status: "FAILED_PRECONDITION",
                                                  message: "Pick a place first.")
        }
        if let existing = pending.existing { return existing }
        return try await FirestoreService.upsertSpot(
            name: pending.name,
            latitude: pending.coordinate.latitude,
            longitude: pending.coordinate.longitude,
            category: pending.category,
            address: pending.address
        )
    }

    // MARK: Known spots

    /// Debounced, mirroring the handle-availability check in profile setup —
    /// this fires on every keystroke otherwise.
    private func scheduleKnownSearch() {
        knownSearchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            knownSpots = []
            return
        }
        knownSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await FirestoreService.searchSpots(term)) ?? []
            guard !Task.isCancelled, term == query.trimmingCharacters(in: .whitespaces) else { return }
            knownSpots = found
        }
    }

    private static func address(for item: MKMapItem, fallback: String) -> String {
        let placemark = item.placemark
        let parts = [placemark.thoroughfare, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
        return parts.isEmpty ? fallback : parts.joined(separator: ", ")
    }

    // MARK: Delegates

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.completer.region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 30_000,
                longitudinalMeters: 30_000
            )
            self.deliverFix(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Search still works without a fix, but anyone blocked on "use current
        // location" has to be told, or the button spins until the timeout.
        Task { @MainActor in self.deliverFix(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else {
            // A refusal is an answer: release the waiters rather than leaving
            // them for the timeout.
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                Task { @MainActor in self.deliverFix(nil) }
            }
            return
        }
        manager.requestLocation()
    }
}

// MARK: - View

/// Type a place, see live suggestions, confirm it on a map.
///
/// Replaces the old local-only `Spot` dropdown, which was empty for every real
/// account — `Spot` rows only ever came from DEBUG seed data, so a signed-in
/// user had nothing to pick. Confirming here creates a server-backed spot, so
/// the place is immediately findable by anyone else.
struct SpotSearchView: View {
    /// Handed the confirmed spot, already mirrored into the local store.
    let onPicked: (Spot) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var model = SpotSearchModel()
    @State private var confirming = false
    @State private var confirmError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                VStack(spacing: 14) {
                    GlassField(placeholder: "Search for a place",
                               text: Binding(get: { model.query },
                                             set: { model.query = $0 }),
                               systemImage: "magnifyingglass")
                        .focused($searchFocused)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                    if let pending = model.pending {
                        confirmation(for: pending)
                    } else {
                        results
                    }
                }
            }
            .navigationTitle("Pick a spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            searchFocused = true
            model.startBiasingToCurrentArea()
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // First, and above both result sections: the whole point is that
                // it's reachable before you've typed anything, and the most
                // common answer to "where are you" is "here".
                row(title: "Use current location",
                    subtitle: "Find the place you're standing in",
                    icon: "location.fill",
                    tint: Theme.accent) {
                    model.useCurrentLocation()
                }
                .padding(.top, 4)

                if !model.knownSpots.isEmpty {
                    sectionHeader("Already on Ralli")
                    ForEach(model.knownSpots) { spot in
                        row(title: spot.name,
                            subtitle: spot.clipCount == 1 ? "1 clip" : "\(spot.clipCount) clips",
                            icon: "mappin.circle.fill",
                            tint: Theme.accent) {
                            model.select(spot)
                        }
                    }
                }

                if !model.suggestions.isEmpty {
                    sectionHeader("Places")
                    ForEach(model.suggestions, id: \.self) { suggestion in
                        row(title: suggestion.title,
                            subtitle: suggestion.subtitle,
                            icon: "magnifyingglass",
                            tint: Theme.textSecondary) {
                            model.select(suggestion)
                        }
                    }
                }

                if model.isResolving {
                    ProgressView().tint(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }

                if model.query.isEmpty {
                    emptyPrompt
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 8) {
            Text("🗺️").font(.system(size: 40))
            Text("Where are you?")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Use your current location, or type a place name to find it on the map.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 8)
    }

    private func row(title: String, subtitle: String, icon: String,
                     tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 14).fill(Theme.surface) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: Map confirmation

    private func confirmation(for pending: SpotSearchModel.PendingSpot) -> some View {
        VStack(spacing: 14) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: pending.coordinate,
                latitudinalMeters: 600,
                longitudinalMeters: 600
            ))) {
                Marker(pending.name, coordinate: pending.coordinate)
                    .tint(Theme.accent)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text(pending.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                if !pending.address.isEmpty {
                    Text(pending.address)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            if let confirmError {
                Text(confirmError)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Button(action: confirm) {
                HStack(spacing: 6) {
                    if confirming {
                        ProgressView().tint(Theme.onAccent).scaleEffect(0.75)
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    }
                    Text("Use this place").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background { Capsule().fill(Theme.accentGradient) }
            }
            .buttonStyle(PressScaleStyle())
            .disabled(confirming)
            .padding(.horizontal, 24)

            Button("Pick somewhere else") { model.clearPending() }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Spacer(minLength: 0)
        }
    }

    private func confirm() {
        guard !confirming else { return }
        confirming = true
        confirmError = nil
        Task {
            defer { confirming = false }
            do {
                let remote = try await model.confirm()
                let local = Spot.mirror(remote, into: modelContext)
                onPicked(local)
                dismiss()
            } catch let error as CallableFunctions.CallableError {
                confirmError = error.message
            } catch {
                confirmError = "Couldn't save that place."
            }
        }
    }
}
