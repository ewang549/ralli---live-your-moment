import Foundation
import MapKit

// MARK: - Readable place categories
//
// `Spot.category` holds MapKit's raw enum value — "MKPOICategoryLandmark" — for
// the same reason clip kinds are stored as their raw case: the stored value is
// the machine's, and the screen's job is to translate it. Nothing translated it
// until now, so the raw token went straight onto the card.
//
// Formatting happens at render time rather than at write time on purpose.
// Spots created before this existed are already sitting in Firestore with raw
// strings, and a display-side lookup fixes those without a migration.

extension MKPointOfInterestCategory {
    /// "Restaurant", "EV Charger", "National Park" — what a person calls this.
    var displayName: String { POICategoryLabel.display(rawValue) }
}

enum POICategoryLabel {
    /// Turns a stored MapKit category into something readable.
    ///
    /// Empty in, empty out: a spot picked from an address rather than a point of
    /// interest has no category at all, and the callers already elide the
    /// separator around an empty label.
    static func display(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if let known = names[MKPointOfInterestCategory(rawValue: raw)] { return known }
        // Anything MapKit adds after this table was written still reads
        // sensibly, rather than falling back to the raw token this whole file
        // exists to stop showing.
        return humanized(raw)
    }

    /// Keyed on the typed constants rather than on hand-written
    /// `"MKPOICategoryX"` strings, so the raw values come from the SDK and can't
    /// drift out of sync with a typo here.
    private static let names: [MKPointOfInterestCategory: String] = [
        .airport: "Airport",
        .amusementPark: "Amusement Park",
        .animalService: "Animal Service",
        .aquarium: "Aquarium",
        .atm: "ATM",
        .automotiveRepair: "Auto Repair",
        .bakery: "Bakery",
        .bank: "Bank",
        .baseball: "Baseball",
        .basketball: "Basketball",
        .beach: "Beach",
        .beauty: "Beauty",
        .bowling: "Bowling",
        .brewery: "Brewery",
        .cafe: "Café",
        .campground: "Campground",
        .carRental: "Car Rental",
        .castle: "Castle",
        .conventionCenter: "Convention Center",
        .distillery: "Distillery",
        .evCharger: "EV Charger",
        .fairground: "Fairground",
        .fireStation: "Fire Station",
        .fishing: "Fishing",
        .fitnessCenter: "Gym",
        .foodMarket: "Food Market",
        .fortress: "Fortress",
        .gasStation: "Gas Station",
        .goKart: "Go-Kart Track",
        .golf: "Golf",
        .hiking: "Hiking",
        .hospital: "Hospital",
        .hotel: "Hotel",
        .kayaking: "Kayaking",
        .landmark: "Landmark",
        .laundry: "Laundry",
        .library: "Library",
        .mailbox: "Mailbox",
        .marina: "Marina",
        .miniGolf: "Mini Golf",
        .movieTheater: "Movie Theater",
        .museum: "Museum",
        .musicVenue: "Music Venue",
        .nationalMonument: "National Monument",
        .nationalPark: "National Park",
        .nightlife: "Nightlife",
        .park: "Park",
        .parking: "Parking",
        .pharmacy: "Pharmacy",
        .planetarium: "Planetarium",
        .police: "Police",
        .postOffice: "Post Office",
        .publicTransport: "Transit",
        .restaurant: "Restaurant",
        .restroom: "Restroom",
        .rockClimbing: "Rock Climbing",
        .rvPark: "RV Park",
        .school: "School",
        .skatePark: "Skate Park",
        .skating: "Skating",
        .skiing: "Skiing",
        .soccer: "Soccer",
        .spa: "Spa",
        .stadium: "Stadium",
        .store: "Store",
        .surfing: "Surfing",
        .swimming: "Swimming",
        .tennis: "Tennis",
        .theater: "Theater",
        .university: "University",
        .volleyball: "Volleyball",
        .winery: "Winery",
        .zoo: "Zoo"
    ]

    /// Last resort: drop the prefix and break the remaining camel case into
    /// words. "MKPOICategorySomethingNew" → "Something New".
    ///
    /// Runs of capitals stay welded together so an acronym survives — "EVCharger"
    /// becomes "EV Charger", not "E V Charger".
    private static func humanized(_ raw: String) -> String {
        let stem = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        guard !stem.isEmpty else { return raw }

        var words: [String] = []
        var current = ""
        var previousWasUpper = false

        for character in stem {
            let isUpper = character.isUppercase
            // A capital starts a new word unless it's continuing an acronym.
            if isUpper && !previousWasUpper && !current.isEmpty {
                words.append(current)
                current = ""
            }
            // The tail of an acronym belongs to the word it introduces:
            // "EVCharger" splits at the C, leaving "EV" and "Charger".
            if !isUpper && previousWasUpper && current.count > 1 {
                words.append(String(current.dropLast()))
                current = String(current.suffix(1))
            }
            current.append(character)
            previousWasUpper = isUpper
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    private static let prefix = "MKPOICategory"
}
