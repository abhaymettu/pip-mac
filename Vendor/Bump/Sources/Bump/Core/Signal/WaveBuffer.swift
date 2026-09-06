import Foundation

/// A small lock-guarded ring buffer for the live waveform.
///
/// The sensor thread `push`es into it ~60×/sec; the UI reads `snapshot()` once
/// per display frame from a `TimelineView(.animation)`. Crucially this is **not**
/// `@Published` — it never triggers SwiftUI invalidations, so the ~60 Hz data
/// stream can't starve in-flight animations (the source of the old stutter).
final class WaveBuffer: @unchecked Sendable {
    private var values: [Double]
    private var lock = os_unfair_lock()
    let count: Int

    init(count: Int = 240) {
        self.count = count
        values = Array(repeating: 0, count: count)
    }

    /// Append one sample (call from the sensor thread).
    func push(_ v: Double) {
        os_unfair_lock_lock(&lock)
        values.removeFirst()
        values.append(v)
        os_unfair_lock_unlock(&lock)
    }

    /// Copy the current window (call from the render/main thread).
    func snapshot() -> [Double] {
        os_unfair_lock_lock(&lock)
        let copy = values
        os_unfair_lock_unlock(&lock)
        return copy
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        values = Array(repeating: 0, count: count)
        os_unfair_lock_unlock(&lock)
    }
}
