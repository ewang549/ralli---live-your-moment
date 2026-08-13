import Testing
import Foundation
@testable import explog

/// Tap and swipe used to be the same move.
///
/// `EdgeStepZones` wired both gestures to one pair of closures, so every screen
/// that used it had exactly one way to travel. The rule now is two: a tap steps
/// one hour and crosses midnight on its own, a swipe skips a whole day and keeps
/// the hour it left from.
///
/// These pin the arithmetic behind that split — the part that has a right answer
/// regardless of what the gesture recognizer does with a touch.
@MainActor
struct HourAxisSteppingTests {
    /// A given hour of a day far enough in the past that the "no future" clamp
    /// never fires, so each test measures only the step it made.
    private func state(hour: Int, daysAgo: Int = 3) -> HourFeedState {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo,
                                to: calendar.startOfDay(for: .now))!
        return HourFeedState(reference: calendar.date(byAdding: .hour, value: hour, to: day)!)
    }

    /// Which day, as the local midnight it belongs to.
    ///
    /// Deliberately not `ordinality(of: .day, in: .era, …)`, which counts days
    /// in UTC — every one of these assertions is about what happens either side
    /// of *local* midnight, and in a negative-offset zone the two disagree by a
    /// day for the exact hours under test.
    private func components(_ state: HourFeedState) -> (day: Date, hour: Int) {
        let calendar = Calendar.current
        return (calendar.startOfDay(for: state.selectedHour),
                calendar.component(.hour, from: state.selectedHour))
    }

    private func day(_ start: Date, plus delta: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: delta, to: start)!
    }

    @Test("A tap walks the clock and rolls into the next day at midnight")
    func tapRollsForwardPastMidnight() {
        let hourState = state(hour: 12)
        let startDay = components(hourState).day

        // 12pm → 11pm: eleven steps, still the same day.
        for _ in 0..<11 { hourState.step(1) }
        #expect(components(hourState).hour == 23)
        #expect(components(hourState).day == startDay)

        // The twelfth is the one that crosses. Nothing stops at the boundary.
        hourState.step(1)
        #expect(components(hourState).hour == 0)
        #expect(components(hourState).day == day(startDay, plus: 1))

        hourState.step(1)
        #expect(components(hourState).hour == 1)
        #expect(components(hourState).day == day(startDay, plus: 1))
    }

    @Test("A tap rolls backwards past midnight the same way")
    func tapRollsBackPastMidnight() {
        let hourState = state(hour: 0)
        let startDay = components(hourState).day

        hourState.step(-1)
        #expect(components(hourState).hour == 23)
        #expect(components(hourState).day == day(startDay, plus: -1))
    }

    @Test("A swipe lands on the same hour of the adjacent day, not midnight")
    func swipeKeepsHourOfDay() {
        for hour in [0, 7, 12, 23] {
            let hourState = state(hour: hour)
            let startDay = components(hourState).day

            hourState.stepDay(1)
            #expect(components(hourState).hour == hour)
            #expect(components(hourState).day == day(startDay, plus: 1))

            hourState.stepDay(-1)
            #expect(components(hourState).hour == hour)
            #expect(components(hourState).day == startDay)
        }
    }

    /// `stepDay(_:)` and `jump(toDay:)` now agree about the hour; what separates
    /// them is that one steps relative to where you are and the other is handed
    /// a specific day by the calendar picker.
    @Test("The calendar jump still preserves the hour of day")
    func calendarJumpKeepsHour() {
        let calendar = Calendar.current
        let hourState = state(hour: 15)
        let target = calendar.date(byAdding: .day, value: -1, to: hourState.selectedHour)!

        hourState.jump(toDay: target)
        #expect(components(hourState).hour == 15)
    }

    @Test("Neither move walks into the future")
    func clampedAtNow() {
        let hourState = HourFeedState(reference: .now)
        hourState.step(5)
        #expect(hourState.isAtCurrentHour)

        // This hour tomorrow is ahead of now, so the swipe clamps to the live
        // hour rather than jumping into a day that hasn't happened.
        hourState.stepDay(1)
        #expect(hourState.isAtCurrentHour)
    }
}

/// A tap crossing midnight is invisible in the hour alone — "11 PM" becoming
/// "12 AM" looks like any other step — so every log screen names the day too.
/// These pin the wording, and that it actually changes on the step that crosses.
@MainActor
struct DayLabelTests {
    private let calendar = Calendar.current

    private func daysAgo(_ delta: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -delta,
                                to: calendar.startOfDay(for: .now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    @Test("Recent days are named, older ones carry a real date")
    func wording() {
        #expect(daysAgo(0, hour: 9).dayLabel == "today")
        #expect(daysAgo(1, hour: 9).dayLabel == "yesterday")

        // Anything older is a date rather than an unhelpful "3 days ago".
        let older = daysAgo(5, hour: 9)
        #expect(older.dayLabel == older.formatted(.dateTime.weekday(.abbreviated).month().day()))
    }

    /// The regression this whole change is about: the label has to move on the
    /// step that crosses midnight, not one step later.
    @Test("Stepping an hour past midnight flips the day label")
    func labelFollowsTheStepAcrossMidnight() {
        let hourState = HourFeedState(reference: daysAgo(1, hour: 23))
        #expect(hourState.dayLabel == "yesterday")

        hourState.step(1)
        #expect(hourState.dayLabel == "today")

        hourState.step(-1)
        #expect(hourState.dayLabel == "yesterday")
    }

    /// Both the feeds and the recap read the same formatter, so a tweak to one
    /// screen's wording can't leave the others saying something different.
    @Test("The feed badge and a bare date agree on the wording")
    func oneSourceOfTruth() {
        for delta in 0...6 {
            let moment = daysAgo(delta, hour: 14)
            #expect(HourFeedState(reference: moment).dayLabel == moment.dayLabel)
        }
    }
}

/// The recap screen walks hours too, but it holds a list of clips rather than a
/// clock — and its own send cooldown is per chat, so one hour can hold two
/// clips. These pin the grouping that makes a tap there cost the same as a tap
/// on the other two feeds.
struct RecapHourGroupingTests {
    /// The same one-pass bucketing `DayRecapPage.hourGroups` does, over plain
    /// dates: the property itself needs a SwiftData `Clip` graph, and what's
    /// worth pinning is the arithmetic, not the model plumbing.
    private func group(_ dates: [Date]) -> [[Date]] {
        let calendar = Calendar.current
        var groups: [[Date]] = []
        for date in dates.sorted() {
            if let previous = groups.last?.last,
               calendar.isDate(previous, equalTo: date, toGranularity: .hour) {
                groups[groups.count - 1].append(date)
            } else {
                groups.append([date])
            }
        }
        return groups
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: .now)
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
    }

    @Test("Two clips sent in the same hour are one step, not two")
    func sameHourCollapses() {
        // 9:05 and 9:40 are two logs to two different friends inside one hour.
        let groups = group([at(9, 5), at(9, 40), at(14, 0)])
        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 1)
    }

    @Test("A step lands on the first clip of the hour it enters")
    func landsOnFirstOfGroup() {
        let clips = [at(9, 5), at(9, 40), at(14, 0)]
        let groups = group(clips)
        // The index into the flat clip list is everything in the earlier groups.
        let firstOfSecondGroup = groups[..<1].reduce(0) { $0 + $1.count }
        #expect(firstOfSecondGroup == 2)
        #expect(clips[firstOfSecondGroup] == at(14, 0))
    }

    @Test("Hours with nothing in them are not steps")
    func emptyHoursAreSkipped() {
        // 9am, then nothing until 6pm: two hour-groups, not ten.
        #expect(group([at(9, 0), at(18, 0)]).count == 2)
    }

    /// The same nearest-hour search `DayRecapPage.startIndex(ofGroupNearest:)`
    /// does, over plain dates for the reason `group(_:)` is reimplemented here.
    private func landing(_ dates: [Date], nearest hour: Int) -> Int {
        let calendar = Calendar.current
        var landing = 0
        var bestDistance = Int.max
        var offset = 0
        for bucket in group(dates) {
            if let first = bucket.first {
                let distance = abs(calendar.component(.hour, from: first) - hour)
                if distance < bestDistance {
                    bestDistance = distance
                    landing = offset
                }
            }
            offset += bucket.count
        }
        return landing
    }

    /// A swipe carries the hour across, so the day it lands on has to answer
    /// "which clip is 3 PM here" — and usually doesn't have one at that hour.
    @Test("A day swipe lands on the clip nearest the hour it left from")
    func swipeLandsNearestTheCarriedHour() {
        let clips = [at(8, 0), at(15, 30), at(21, 0)]

        // Exactly on an hour that exists.
        #expect(landing(clips, nearest: 15) == 1)
        // Nothing at 4 PM, and 3:30 PM is closer than 9 PM.
        #expect(landing(clips, nearest: 16) == 1)
        // Earlier than anything logged: the first clip, not a fallback to zero
        // by accident — 8 AM really is nearest.
        #expect(landing(clips, nearest: 5) == 0)
        // Later than anything logged.
        #expect(landing(clips, nearest: 23) == 2)
    }

    /// The landing is an index into the flat clip list, so an hour holding two
    /// clips has to shift everything after it — the same offset arithmetic a
    /// tap uses.
    @Test("The nearest-hour landing counts clips, not hours")
    func landingIndexesTheFlatList() {
        // 9:05 and 9:40 are one hour but two clips.
        let clips = [at(9, 5), at(9, 40), at(14, 0)]
        #expect(landing(clips, nearest: 9) == 0)
        #expect(landing(clips, nearest: 14) == 2)
    }

    /// A day with nothing on it can't strand the swipe on an index that isn't
    /// there.
    @Test("An empty day lands at zero")
    func emptyDayLandsAtZero() {
        #expect(landing([], nearest: 15) == 0)
    }
}

/// The category shown on a place card was MapKit's raw token —
/// "MKPOICategoryLandmark" — because nothing ever translated it.
struct POICategoryLabelTests {
    @Test("Raw MapKit categories read as words")
    func knownCategories() {
        #expect(POICategoryLabel.display("MKPOICategoryLandmark") == "Landmark")
        #expect(POICategoryLabel.display("MKPOICategoryRestaurant") == "Restaurant")
        #expect(POICategoryLabel.display("MKPOICategoryNationalPark") == "National Park")
    }

    /// Acronyms are the reason the table is keyed on the SDK's own constants
    /// rather than split mechanically — "ATM" is not "A T M".
    @Test("Acronyms stay whole")
    func acronyms() {
        #expect(POICategoryLabel.display("MKPOICategoryATM") == "ATM")
        #expect(POICategoryLabel.display("MKPOICategoryEVCharger") == "EV Charger")
        #expect(POICategoryLabel.display("MKPOICategoryRVPark") == "RV Park")
    }

    /// A spot picked from a street address rather than a point of interest has
    /// no category, and the cards elide the separator around an empty label.
    @Test("No category stays empty rather than becoming a placeholder")
    func emptyStaysEmpty() {
        #expect(POICategoryLabel.display("") == "")
    }

    /// Whatever MapKit adds after this table was written still has to read as
    /// words — the fallback is what stops a future category regressing to the
    /// raw token this whole thing exists to hide.
    @Test("Unknown categories fall back to split camel case")
    func unknownCategories() {
        #expect(POICategoryLabel.display("MKPOICategorySomethingNew") == "Something New")
        #expect(POICategoryLabel.display("MKPOICategoryXYZLounge") == "XYZ Lounge")
    }
}
