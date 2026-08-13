import Foundation
import Observation

/// Single source of truth for the hour the Pulse feed is showing.
///
/// Every card in `PulseFeedView` reads this from the environment, so an edge tap
/// anywhere in the feed re-times *all* friends at once instead of scrubbing one card.
@Observable
final class HourFeedState {
    /// Always normalized to the top of the hour (e.g. 3:00 PM), never a loose timestamp.
    private(set) var selectedHour: Date

    private let calendar = Calendar.current

    init(reference: Date = .now) {
        selectedHour = Self.floorToHour(reference, calendar: Calendar.current)
    }

    // MARK: - Navigation

    /// Moves the whole feed by `delta` hours. Forward motion stops at the current
    /// hour — there is nothing to show in the future.
    func step(_ delta: Int) {
        guard let candidate = calendar.date(byAdding: .hour, value: delta, to: selectedHour) else { return }
        selectedHour = min(candidate, Self.floorToHour(.now, calendar: calendar))
    }

    /// Jumps a whole day forward/back while keeping the hour-of-day exactly
    /// where it was — swipe forward from 3 PM lands on 3 PM the next day, not
    /// midnight.
    ///
    /// The swipe gesture's move, distinct from the other two: `jump(toDay:)`
    /// goes to an arbitrary specific day the calendar picker names rather than
    /// stepping relative to the current one, and `step(_:)` walks the axis an
    /// hour at a time. This one is the shortcut — a whole day in one gesture,
    /// landing at the same time of day you were already reading.
    func stepDay(_ delta: Int) {
        guard let target = calendar.date(byAdding: .day, value: delta, to: selectedHour) else { return }
        // Same clamp as `jump(toDay:)`: swiping forward from an hour later than
        // right now would otherwise land on an hour that hasn't happened.
        selectedHour = min(target, Self.floorToHour(.now, calendar: calendar))
    }

    func jump(toDay day: Date) {
        // Preserve the hour-of-day while switching days (calendar picker entry point).
        let hour = calendar.component(.hour, from: selectedHour)
        let start = calendar.startOfDay(for: day)
        guard let target = calendar.date(byAdding: .hour, value: hour, to: start) else { return }
        selectedHour = min(target, Self.floorToHour(.now, calendar: calendar))
    }

    func resetToNow() {
        selectedHour = Self.floorToHour(.now, calendar: calendar)
    }

    // MARK: - Derived state

    /// True when the feed is live — used to disable the "forward" edge tap.
    var isAtCurrentHour: Bool {
        selectedHour >= Self.floorToHour(.now, calendar: calendar)
    }

    /// "3:00 PM" — the badge text.
    var hourLabel: String {
        selectedHour.formatted(.dateTime.hour().minute())
    }

    /// "today" / "yesterday" / "Mon, Jul 20" — the badge subtitle.
    var dayLabel: String { selectedHour.dayLabel }

    /// Whether `date` falls inside the hour the feed is currently showing.
    func containsHour(of date: Date) -> Bool {
        Self.floorToHour(date, calendar: calendar) == selectedHour
    }

    private static func floorToHour(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }
}
