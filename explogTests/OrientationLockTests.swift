import Testing
import UIKit
@testable import explog

/// The camera is landscape-only, and it has to stay landscape even when the
/// user has the physical rotation lock switched on. Overriding that lock works
/// only if the reported mask genuinely *excludes* portrait — a mask that merely
/// adds landscape alongside portrait leaves the system free to keep the
/// interface upright, which is indistinguishable from the lock not working.
///
/// These pin that down. They don't (and can't) prove behaviour against the
/// hardware switch — that needs a physical device — but they do catch the one
/// mistake that would silently disable the override.
@MainActor
struct OrientationLockTests {
    /// Restores the default so these can't leak into other tests in the process.
    private func withRestoredMask(_ body: () -> Void) {
        let original = InterfaceOrientationLock.mask
        defer { InterfaceOrientationLock.mask = original }
        body()
    }

    @Test func landscapeLockExcludesPortrait() {
        withRestoredMask {
            InterfaceOrientationLock.lockLandscape()
            let mask = InterfaceOrientationLock.mask
            #expect(!mask.contains(.portrait))
            #expect(!mask.contains(.portraitUpsideDown))
            // Exactly one edge, not both: the system only reliably overrides
            // the hardware rotation lock when there is nothing left for it to
            // choose between. See `lockLandscape()`. Which edge depends on how
            // the phone is being held, so this pins the count, not the value.
            #expect(mask.contains(.landscapeLeft) != mask.contains(.landscapeRight))
        }
    }

    @Test func portraitLockExcludesLandscape() {
        withRestoredMask {
            InterfaceOrientationLock.lockPortrait()
            let mask = InterfaceOrientationLock.mask
            #expect(mask.contains(.portrait))
            #expect(!mask.contains(.landscapeLeft))
            #expect(!mask.contains(.landscapeRight))
        }
    }

    /// The mask has to be updated *before* the scene is asked to re-evaluate,
    /// or the system re-reads the old policy and snaps straight back. `apply`
    /// returns early when there's no foreground scene (as in a unit test), so
    /// reaching this assertion at all proves the write happens first.
    @Test func maskIsSetEvenWithoutAnActiveScene() {
        withRestoredMask {
            InterfaceOrientationLock.mask = .portrait
            InterfaceOrientationLock.lockLandscape()
            #expect(InterfaceOrientationLock.mask != .portrait)
            #expect(!InterfaceOrientationLock.mask.contains(.portrait))
        }
    }
}
