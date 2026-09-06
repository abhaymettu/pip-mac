import Foundation
import XCTest
@testable import PipDomain

final class GestureRouterTests: XCTestCase {
    private func event(
        id: UUID = UUID(),
        side: TapSide = .left,
        count: TapCount = .single,
        mode: InputMode = .chassisTaps
    ) -> GestureEvent {
        GestureEvent(
            groupID: id,
            gesture: Gesture(side: side, count: count),
            timestamp: 10,
            inputMode: mode
        )
    }

    func testRoutesAllSixSlots() async {
        let bindings = Slot.all.map { Binding(slot: $0, action: .playPause) }
        let router = GestureRouter(store: InMemoryBindingStore(bindings: bindings))
        for binding in bindings {
            let routed = await router.route(event(
                side: binding.slot.side, count: binding.slot.count
            ))
            XCTAssertEqual(routed?.binding, binding)
        }
    }

    func testConcurrentDuplicateGroupIsAcceptedOnlyOnce() async {
        let binding = Binding(slot: Slot(side: .left, count: .single), action: .playPause)
        let router = GestureRouter(store: InMemoryBindingStore(bindings: [binding]))
        let input = event()
        async let first = router.route(input)
        async let second = router.route(input)
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
    }

    func testAcceptedBindingIsSnapshot() async throws {
        let id = UUID()
        let slot = Slot(side: .left, count: .single)
        let original = Binding(id: id, slot: slot, action: .playPause)
        let store = InMemoryBindingStore(bindings: [original])
        let router = GestureRouter(store: store)
        let routed = await router.route(event())
        let accepted = try XCTUnwrap(routed)

        await store.set(Binding(id: id, slot: slot, action: .nextTrack))
        XCTAssertEqual(accepted.binding.action, .playPause)
        let next = await router.route(event())
        XCTAssertEqual(next?.binding.action, .nextTrack)
    }

    func testDisabledMissingAndWrongModeAreRejected() async {
        let slot = Slot(side: .left, count: .single)
        let store = InMemoryBindingStore(bindings: [
            Binding(slot: slot, action: .playPause, enabled: false)
        ])
        let router = GestureRouter(store: store)
        let disabled = await router.route(event())
        let missing = await router.route(event(side: .right))
        XCTAssertNil(disabled)
        XCTAssertNil(missing)

        await store.set(Binding(slot: slot, action: .playPause))
        let trackpad = await router.route(event(mode: .trackpadFallback))
        XCTAssertNil(trackpad)
    }

    func testPauseAndResumeDoNotReplayRejectedGroup() async throws {
        let store = InMemoryBindingStore(bindings: [
            Binding(slot: Slot(side: .left, count: .single), action: .playPause)
        ])
        let control = PipControl()
        let router = GestureRouter(store: store, control: control)
        try await control.pause(minutes: 5)
        let input = event()
        let paused = await router.route(input)
        XCTAssertNil(paused)
        await control.resume()
        let duplicate = await router.route(input)
        let fresh = await router.route(event())
        XCTAssertNil(duplicate)
        XCTAssertNotNil(fresh)
    }

    func testTaggedActionRoundTripsAndRejectsFutureVersion() throws {
        let actions: [ActionKind] = [
            .playPause, .previousTrack, .nextTrack, .volumeUp, .volumeDown,
            .toggleMute, .screenshotInteractiveToClipboard,
            .openApplication(bundleID: "com.apple.TextEdit"),
            .openURL("https://example.com"),
            .pressKeyboardShortcut(KeyboardShortcut(keyCode: 8, modifiers: [.command])),
            .runShortcut(name: " Exact Name ", input: "literal\n$HOME"),
            .runShellScript(script: "printf '%s' hello"),
            .pausePip(minutes: 10)
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["version"] as? Int, 1)
            XCTAssertNotNil(object["type"] as? String)
            XCTAssertEqual(try JSONDecoder().decode(ActionKind.self, from: data), action)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            ActionKind.self,
            from: Data(#"{"version":99,"type":"playPause"}"#.utf8)
        ))
    }
}
