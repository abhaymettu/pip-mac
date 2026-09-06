import Foundation
import XCTest
@testable import PipPersistence
import PipDomain

final class PresetPackTests: XCTestCase {
    func testEverydayParsesAndCoversExactlySixSlots() throws {
        let pack = try PresetPack.everyday()
        XCTAssertEqual(pack.name, "Everyday")
        XCTAssertEqual(pack.version, 1)
        XCTAssertEqual(pack.bindings.count, 6)
        XCTAssertEqual(Set(pack.bindings.map(\.slot)), Set(Slot.all))
        try pack.validate()

        let placeholder = try XCTUnwrap(pack.bindings.first {
            $0.slot == Slot(side: .right, count: .triple)
        })
        XCTAssertFalse(placeholder.enabled)
        XCTAssertEqual(
            placeholder.action,
            .runShortcut(name: "REPLACE WITH EXACT SHORTCUT NAME")
        )
        XCTAssertTrue(placeholder.comment?.contains("exact name") == true)
    }

    func testDuplicateSlotsAreRejected() throws {
        let pack = try PresetPack.everyday()
        var bindings = pack.bindings
        bindings[5] = Binding(slot: bindings[0].slot, action: .toggleMute)
        XCTAssertThrowsError(try PresetPack(name: "Invalid", bindings: bindings))
    }

    func testConfigRoundTripAndAtomicReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let pack = try PresetPack.everyday()
        let initial = PipConfiguration(inputMode: .replay, bindings: pack.bindings)
        let store = try ConfigStore(fileURL: file, defaultConfiguration: initial)
        let replacement = PipConfiguration(
            inputMode: .trackpadFallback, bindings: pack.bindings
        )
        try await store.replace(with: replacement)

        let reopened = try ConfigStore(fileURL: file, defaultConfiguration: initial)
        let loaded = await reopened.configuration()
        XCTAssertEqual(loaded, replacement)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
    }

    func testExplicitSchemaOneMigration() throws {
        let pack = try PresetPack.everyday()
        let encoded = try JSONEncoder().encode(pack.bindings)
        var bindings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        for index in bindings.indices {
            var action = try XCTUnwrap(bindings[index]["action"] as? [String: Any])
            action.removeValue(forKey: "version")
            bindings[index]["action"] = action
        }
        let old = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "inputMode": "replay",
            "bindings": bindings
        ])
        let migrated = try ConfigStore.migrate(old)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)
        let configuration = try XCTUnwrap(root["configuration"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: configuration)
        let decoded = try JSONDecoder().decode(PipConfiguration.self, from: data)
        XCTAssertEqual(decoded.bindings, pack.bindings)
        XCTAssertEqual(decoded.inputMode, .replay)
    }

    func testFutureSchemaFailsClosed() {
        XCTAssertThrowsError(try ConfigStore.migrate(
            Data(#"{"schemaVersion":999}"#.utf8)
        ))
    }
}
