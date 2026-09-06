import Foundation
import PipDomain

/// Single-consumer stream of completed groups, not preliminary impulses.
public protocol GestureEventSource: Sendable {
    var events: AsyncStream<GestureEvent> { get }
    func start() async
    func stop() async
}

/// Kept separate from the sensor so replay and grouping tests need no hardware.
public protocol GestureGrouping: Sendable {
    var groupingGap: TimeInterval { get set }
    func reset()
    func registerImpulse(at: TimeInterval)
    func tick(now: TimeInterval) -> TapCount?
}

#if os(macOS)
/// The vendored class is actor-confined by EngineAdapter.
/// macOS-only build integration with the on-disk vendor needs device verification.
private final class VendoredGrouping: GestureGrouping, @unchecked Sendable {
    private let engine = GestureEngine()

    var groupingGap: TimeInterval {
        get { engine.groupingGap }
        set { engine.groupingGap = newValue }
    }

    func reset() {
        engine.reset()
    }

    func registerImpulse(at: TimeInterval) {
        engine.registerImpulse(at: at)
    }

    func tick(now: TimeInterval) -> TapCount? {
        guard let completed = engine.tick(now: now) else { return nil }
        return TapCount(rawValue: completed.tapCount)
    }
}
#endif

public actor EngineAdapter: GestureEventSource {
    public nonisolated let events: AsyncStream<GestureEvent>
    private let continuation: AsyncStream<GestureEvent>.Continuation
    private var grouping: any GestureGrouping
    private let inputMode: InputMode
    private let unattributedSide: TapSide
    private var firstSide: TapSide?
    private var lastTimestamp: TimeInterval?
    private var timer: Task<Void, Never>?
    private var running = false

    /// Ownership of grouping transfers to this actor; do not mutate it elsewhere.
    ///
    /// The supplied vendored interface has NO side information. Without a side hint,
    /// this adapter uses a fixed configured side (left by default), NOT a claim of
    /// reliable left/right sensing. A mixed-hint group uses its first impulse's side.
    /// Sensor capture, signal detection and trackpad capture are not enabled here.
    public init(
        grouping: any GestureGrouping,
        inputMode: InputMode = .chassisTaps,
        unattributedSide: TapSide = .left
    ) {
        let stream = AsyncStream<GestureEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        self.grouping = grouping
        self.inputMode = inputMode
        self.unattributedSide = unattributedSide
    }

    #if os(macOS)
    public init(
        groupingGap: TimeInterval = 0.3,
        inputMode: InputMode = .chassisTaps,
        unattributedSide: TapSide = .left
    ) {
        let stream = AsyncStream<GestureEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        let engine = VendoredGrouping()
        engine.groupingGap = groupingGap.isFinite && groupingGap > 0 ? groupingGap : 0.3
        self.grouping = engine
        self.inputMode = inputMode
        self.unattributedSide = unattributedSide
    }
    #endif

    deinit {
        timer?.cancel()
        continuation.finish()
    }

    public func start() {
        guard !running else { return }
        running = true
        grouping.reset()
        firstSide = nil
        lastTimestamp = nil
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000)
                } catch {
                    return
                }
                await self?.tick(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// Stopping discards a partial group; it does not invent a completed gesture.
    public func stop() {
        running = false
        timer?.cancel()
        timer = nil
        grouping.reset()
        firstSide = nil
        lastTimestamp = nil
    }

    /// Feed only detected impulses using the same monotonic clock as tick().
    public func registerImpulse(
        at timestamp: TimeInterval,
        sideHint: TapSide? = nil
    ) {
        guard running, timestamp.isFinite,
              lastTimestamp.map({ timestamp >= $0 }) ?? true else { return }
        // Complete an expired group before registering an impulse for a new group.
        publishCompleted(now: timestamp)
        if firstSide == nil { firstSide = sideHint ?? unattributedSide }
        grouping.registerImpulse(at: timestamp)
        lastTimestamp = timestamp
    }

    public func tick(now: TimeInterval) {
        guard running, now.isFinite,
              lastTimestamp.map({ now >= $0 }) ?? true else { return }
        publishCompleted(now: now)
    }

    private func publishCompleted(now: TimeInterval) {
        guard let count = grouping.tick(now: now) else { return }
        let side = firstSide ?? unattributedSide
        firstSide = nil
        continuation.yield(GestureEvent(
            gesture: Gesture(side: side, count: count),
            timestamp: now,
            inputMode: inputMode
        ))
    }
}

public struct ReplayStep: Sendable {
    /// Delay relative to the preceding step; event IDs/timestamps are preserved.
    public let delay: TimeInterval
    public let event: GestureEvent

    public init(delay: TimeInterval = 0, event: GestureEvent) {
        self.delay = delay
        self.event = event
    }
}

public actor ReplaySource: GestureEventSource {
    public nonisolated let events: AsyncStream<GestureEvent>
    private let continuation: AsyncStream<GestureEvent>.Continuation
    private let steps: [ReplayStep]
    private var playback: Task<Void, Never>?
    private var generation = UUID()

    public init(steps: [ReplayStep]) {
        let stream = AsyncStream<GestureEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        self.steps = steps
    }

    deinit {
        playback?.cancel()
        continuation.finish()
    }

    public func start() {
        guard playback == nil else { return }
        let token = UUID()
        generation = token
        playback = Task { [weak self, steps] in
            for step in steps {
                guard !Task.isCancelled else { return }
                if step.delay.isFinite, step.delay > 0 {
                    // Clamp before converting to nanoseconds to avoid overflow.
                    let seconds = min(step.delay, 86_400)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.emit(step.event, generation: token)
            }
            await self?.completed(generation: token)
        }
    }

    public func stop() {
        generation = UUID()
        playback?.cancel()
        playback = nil
    }

    /// Explicit end-of-input for finite demonstrations/tests. stop() is restartable.
    public func finish() {
        stop()
        continuation.finish()
    }

    private func emit(_ event: GestureEvent, generation token: UUID) {
        guard generation == token else { return }
        // Preserve the scripted group ID so duplicate-delivery tests remain possible,
        // but honestly identify every replay event as replay input.
        continuation.yield(GestureEvent(
            groupID: event.groupID,
            gesture: event.gesture,
            timestamp: event.timestamp,
            inputMode: .replay
        ))
    }

    private func completed(generation token: UUID) {
        guard generation == token else { return }
        playback = nil
    }
}
