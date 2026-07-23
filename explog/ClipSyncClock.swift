import SwiftUI
import Observation

/// Shared playhead for every stacked clip on screen.
///
/// The stacked layouts show several 2-second clips at once — yours on top, a
/// friend's below, or a whole group in a column. Left alone, each player starts
/// whenever its view happens to appear, so the stack drifts out of phase within
/// seconds and the "same moment, different people" idea falls apart.
///
/// This publishes one cycle counter that ticks every `clipDuration`. Every clip
/// view keys its player off `cycle`, so they all restart on the same tick and
/// stay locked together no matter when they were added to the hierarchy.
@Observable
@MainActor
final class ClipSyncClock {
    /// Increments once per clip length. Views use it as a restart key.
    private(set) var cycle: Int = 0
    /// When the current cycle began — lets a late-joining view seek into it.
    private(set) var cycleStartedAt: Date = .now

    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Seconds elapsed in the current cycle (0..<clipDuration).
    var elapsedInCycle: TimeInterval {
        max(0, Date.now.timeIntervalSince(cycleStartedAt))
    }

    func start() {
        guard ticker == nil else { return }
        cycleStartedAt = .now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(clipDuration))
                guard let self, !Task.isCancelled else { return }
                self.cycle &+= 1
                self.cycleStartedAt = .now
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Restarts the cycle immediately — used when a feed changes page so the
    /// newly visible pair begins together rather than mid-cycle.
    func resync() {
        cycle &+= 1
        cycleStartedAt = .now
    }
}
