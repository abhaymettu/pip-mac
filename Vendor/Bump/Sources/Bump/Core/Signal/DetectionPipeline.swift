import Foundation

/// Owns the impulse detector + gesture engine and runs them together.
///
/// Intentionally **not** main-actor isolated: it's driven entirely from the
/// accelerometer's sensor thread. `threshold` may be written from the UI thread;
/// that's a benign race on a single Double (worst case: one sample uses the old
/// value). Keep all *reads* of detector/engine on the sensor thread.
final class DetectionPipeline {
    private let detector = ImpulseDetector()
    private let gestureEngine = GestureEngine()

    var threshold: Double {
        get { detector.threshold }
        set { detector.threshold = newValue }
    }

    /// Output of one sample step.
    struct Step {
        /// Current deviation magnitude (for the live waveform).
        var deviation: Double
        /// A gesture, if one just finalized.
        var gesture: BumpGesture?
    }

    private var decay: Double = 0

    /// Drop any in-progress burst (used while typing suppression is active).
    func reset() {
        gestureEngine.reset()
        decay = 0
    }

    func process(magnitude: Double, at time: TimeInterval) -> Step {
        if let spike = detector.process(magnitude: magnitude, at: time) {
            gestureEngine.registerImpulse(at: time)
            decay = spike
        } else {
            decay *= 0.6   // smooth trailing edge for a nicer trace
        }
        let gesture = gestureEngine.tick(now: time)
        return Step(deviation: decay, gesture: gesture)
    }
}
