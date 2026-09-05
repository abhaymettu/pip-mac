import Foundation

/// Groups impulses that land close together into single / double / triple bumps.
///
/// An impulse opens (or extends) a "burst". When no further impulse arrives for
/// `groupingGap`, the burst is finalized and classified by how many impulses it
/// held. `tick(now:)` must be called regularly (the sensor stream does this) so
/// the burst can close even when no new impulse arrives.
final class GestureEngine {
    /// Max quiet time after the last tap before a burst is considered complete.
    var groupingGap: TimeInterval = 0.42

    private var count = 0
    private var lastImpulseTime: TimeInterval = 0
    private var open = false

    /// Abandon any burst in progress (e.g. while typing is suppressing input).
    func reset() {
        open = false
        count = 0
    }

    /// Register an impulse at `time`.
    func registerImpulse(at time: TimeInterval) {
        if !open {
            open = true
            count = 0
        }
        count += 1
        lastImpulseTime = time
    }

    /// Close out a burst if it's been quiet long enough. Returns the gesture if
    /// one was just finalized.
    func tick(now: TimeInterval) -> BumpGesture? {
        guard open, now - lastImpulseTime >= groupingGap else { return nil }
        open = false
        switch count {
        case 1: return .single
        case 2: return .double
        default: return .triple   // 3+ collapses to triple
        }
    }
}
