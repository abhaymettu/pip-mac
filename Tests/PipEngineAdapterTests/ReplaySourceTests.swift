import Foundation
import XCTest
@testable import PipEngineAdapter
import PipDomain

private final class ScriptedGrouping: GestureGrouping, @unchecked Sendable {
    var groupingGap: TimeInterval = 0.3
    private var impulses: [TimeInterval] = []

    // Tests transfer exclusive ownership to EngineAdapter.
    func reset() {
        impulses.removeAll()
    }

    func registerImpulse(at: TimeInterval) {
        impulses.append(at)
    }

    func tick(now: TimeInterval) -> TapCount? {
        guard let last = impulses.last, now - last >= groupingGap else { return nil }
        let count = min(3, impulses.count)
        impulses.removeAll()
        return TapCount(rawValue: count)
    }
}

final class ReplaySourceTests: XCTestCase {
    func testReplayPreservesGroupIdentityAndLabelsItsMode() async {
        let event = GestureEvent(
            gesture: Gesture(side: .right, count: .double),
            timestamp: 12,
            inputMode: .chassisTaps
        )
        let source = ReplaySource(steps: [
            ReplayStep(event: event),
            ReplayStep(event: event)
        ])
        var iterator = source.events.makeAsyncIterator()
        await source.start()
        let first = await iterator.next()
        let duplicate = await iterator.next()
        XCTAssertEqual(first?.groupID, event.groupID)
        XCTAssertEqual(duplicate?.groupID, event.groupID)
        XCTAssertEqual(first?.inputMode, .replay)
        XCTAssertEqual(first?.gesture, event.gesture)
        await source.finish()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testAdapterPublishesOnlyCompletedGroupWithFirstSideHint() async {
        let source = EngineAdapter(grouping: ScriptedGrouping())
        var iterator = source.events.makeAsyncIterator()
        await source.start()

        // Place this synthetic sequence ahead of the live timer's clock so timer
        // ticks cannot interfere with deterministic manual tick advancement.
        let start = ProcessInfo.processInfo.systemUptime + 60
        await source.registerImpulse(at: start, sideHint: .right)
        await source.registerImpulse(at: start + 0.1, sideHint: .left)
        await source.tick(now: start + 0.2)
        await source.tick(now: start + 0.5)

        let event = await iterator.next()
        XCTAssertEqual(event?.gesture, Gesture(side: .right, count: .double))
        XCTAssertEqual(event?.timestamp, start + 0.5)
        XCTAssertEqual(event?.inputMode, .chassisTaps)
        await source.stop()
    }
}
