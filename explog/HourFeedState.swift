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
    var dayLabel: String {
        if calendar.isDateInToday(selectedHour) { return "today" }
        if calendar.isDateInYesterday(selectedHour) { return "yesterday" }
        return selectedHour.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    /// Whether `date` falls inside the hour the feed is currently showing.
    func containsHour(of date: Date) -> Bool {
        Self.floorToHour(date, calendar: calendar) == selectedHour
    }

    private static func floorToHour(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }
}
