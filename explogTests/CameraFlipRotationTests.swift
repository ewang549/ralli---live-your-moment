import Testing
import CoreGraphics
@testable import explog

/// Flipping the camera mid-take used to turn the rest of the clip upside down.
///
/// The swap carried the outgoing camera's rotation angle straight over to the
/// incoming one, on the theory that reusing one number kept the frames the same
/// shape for the file that was already open. It did — but the two cameras are
/// mounted with different sensor orientations, so the angle that is level for
/// one is a half turn off for the other, and every frame after the flip landed
/// inverted.
///
/// These pin the arithmetic that replaced it: keep the orientation the file
/// started at, correct for the mounting difference, and refuse the correction
/// outright if it would transpose the frame.
struct CameraFlipRotationTests {
    /// The ordinary case: phone held still, back camera level at 90°, front
    /// camera level at 270° for that same posture. The file keeps its
    /// orientation by taking the new camera's angle.
    @Test func adoptsIncomingCameraAngle() {
        let angle = CameraModel.swapRotationAngle(locked: 90, outgoingLive: 90, incomingLive: 270)
        #expect(angle == 270)
    }

    /// The reverse flip, back again.
    @Test func adoptsIncomingCameraAngleFlippingBack() {
        let angle = CameraModel.swapRotationAngle(locked: 270, outgoingLive: 270, incomingLive: 90)
        #expect(angle == 90)
    }

    /// Cameras that agree on where level is leave the angle alone.
    @Test func keepsAngleWhenCamerasAgree() {
        let angle = CameraModel.swapRotationAngle(locked: 180, outgoingLive: 180, incomingLive: 180)
        #expect(angle == 180)
    }

    /// A turn of the phone mid-take is deliberately never pushed at the
    /// connections, so the file is still being written at the angle it started
    /// at while the coordinator has moved on. The flip must correct for the
    /// mounting difference (here 180°) without also splicing in the turn: a take
    /// started at 0° stays at 180°, not at the incoming camera's live 90°.
    @Test func correctsMountingWithoutAdoptingAMidTakeTurn() {
        let angle = CameraModel.swapRotationAngle(locked: 0, outgoingLive: 270, incomingLive: 90)
        #expect(angle == 180)
    }

    /// The same, in the direction that would push the result past a full turn.
    @Test func normalizesPastAFullTurn() {
        let angle = CameraModel.swapRotationAngle(locked: 270, outgoingLive: 0, incomingLive: 180)
        #expect(angle == 90)
    }

    /// ...and the direction that would push it below zero.
    @Test func normalizesBelowZero() {
        let angle = CameraModel.swapRotationAngle(locked: 0, outgoingLive: 180, incomingLive: 0)
        #expect(angle == 180)
    }

    /// A quarter-turn correction would transpose width and height, and a movie's
    /// dimensions are fixed by its first frame. The open file keeps its angle
    /// rather than having the rest of itself rescaled.
    @Test func refusesACorrectionThatWouldTransposeTheFrame() {
        let angle = CameraModel.swapRotationAngle(locked: 0, outgoingLive: 0, incomingLive: 90)
        #expect(angle == 0)
    }

    /// The other quarter turn, refused for the same reason.
    @Test func refusesTheOppositeQuarterTurn() {
        let angle = CameraModel.swapRotationAngle(locked: 90, outgoingLive: 90, incomingLive: 0)
        #expect(angle == 90)
    }

    /// Every angle AVFoundation actually reports, in every pairing, comes back
    /// as one of the four — never something a connection would reject.
    @Test func alwaysReturnsASupportedAngle() {
        let angles: [CGFloat] = [0, 90, 180, 270]
        for locked in angles {
            for outgoing in angles {
                for incoming in angles {
                    let result = CameraModel.swapRotationAngle(locked: locked,
                                                               outgoingLive: outgoing,
                                                               incomingLive: incoming)
                    #expect(angles.contains(result))
                }
            }
        }
    }

    /// And never one that changes the shape of the frames going into the file.
    @Test func neverTransposesTheFrame() {
        let angles: [CGFloat] = [0, 90, 180, 270]
        for locked in angles {
            for outgoing in angles {
                for incoming in angles {
                    let result = CameraModel.swapRotationAngle(locked: locked,
                                                               outgoingLive: outgoing,
                                                               incomingLive: incoming)
                    #expect(result.truncatingRemainder(dividingBy: 180)
                            == locked.truncatingRemainder(dividingBy: 180))
                }
            }
        }
    }
}
