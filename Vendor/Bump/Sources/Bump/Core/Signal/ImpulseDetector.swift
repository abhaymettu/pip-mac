import Foundation

/// Turns a stream of raw acceleration magnitudes (in g) into discrete "impulse"
/// events that correspond to sharp physical taps.
///
/// Strategy: track a slow-moving baseline (gravity / posture) with an EMA, then
/// look for spikes in the *deviation* from that baseline.
///
/// The tricky part is that one physical tap **rings** — the chassis/desk keeps
/// bouncing for ~100–200 ms, producing several decaying spikes. A fixed
/// threshold mis-counts those bounces (worse at high sensitivity). So after a
/// hit we disarm and only re-arm once the signal has decayed to a fraction of
/// *that hit's own peak*. Bounces are always smaller than the peak, so they're
/// ignored no matter how low the threshold is; a genuine second bump makes a
/// fresh full-size spike that re-fires.
final class ImpulseDetector {
    /// Deviation (in g) a spike must exceed to count. Driven by the sensitivity
    /// slider; smaller = more sensitive.
    var threshold: Double

    /// Hard floor on spacing between impulses (also covers the rising edge).
    var refractory: TimeInterval = 0.10

    /// Must decay below this fraction of the hit's peak before re-arming.
    var reArmRatio: Double = 0.30

    private var baseline: Double = 1.0          // resting ~1g
    private let baselineAlpha = 0.02            // slow tracker
    private var lastImpulse: TimeInterval = -1
    private var armed = true
    private var peak: Double = 0                // peak deviation of the current tap

    init(threshold: Double = 0.08) {
        self.threshold = threshold
    }

    /// Feed one sample. Returns the spike strength (deviation in g) if this
    /// sample triggered an impulse, otherwise nil.
    func process(magnitude: Double, at time: TimeInterval) -> Double? {
        let deviation = abs(magnitude - baseline)

        // Only let the baseline drift while things are quiet, so taps and their
        // ring don't pull it around.
        if armed && deviation < threshold * 0.5 {
            baseline += baselineAlpha * (magnitude - baseline)
        }

        if !armed {
            // Inside a tap (and its ring): follow the true peak and wait for the
            // signal to settle before allowing the next impulse.
            peak = max(peak, deviation)
            if time - lastImpulse >= refractory && deviation < peak * reArmRatio {
                armed = true
            }
            return nil
        }

        guard deviation >= threshold, time - lastImpulse >= refractory else { return nil }

        lastImpulse = time
        peak = deviation
        armed = false
        return deviation
    }
}
