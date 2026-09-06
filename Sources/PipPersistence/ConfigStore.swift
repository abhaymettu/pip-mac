import Foundation
import PipDomain

public enum ConfigStoreError: Error, LocalizedError {
    case malformed(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason): return "Invalid Pip configuration: \(reason)"
        case .unsupportedVersion(let version):
            return "Unsupported Pip configuration version \(version)."
        }
    }
}

public actor ConfigStore: BindingStore {
    public static let currentSchemaVersion = 2

    private struct Envelope: Codable {
        let schemaVersion: Int
        let configuration: PipConfiguration
    }

    private let fileURL: URL
    private var current: PipConfiguration

    public init(fileURL: URL, defaultConfiguration: PipConfiguration) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let original = try Data(contentsOf: fileURL)
            let migrated = try Self.migrate(original)
            let envelope = try JSONDecoder().decode(Envelope.self, from: migrated)
            guard envelope.schemaVersion == Self.currentSchemaVersion else {
                throw ConfigStoreError.unsupportedVersion(envelope.schemaVersion)
            }
            try PresetPack.validateBindings(envelope.configuration.bindings)
            current = envelope.configuration
            if original != migrated {
                try Self.write(current, to: fileURL)
            }
        } else {
            try PresetPack.validateBindings(defaultConfiguration.bindings)
            current = defaultConfiguration
            try Self.write(defaultConfiguration, to: fileURL)
        }
    }

    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("Pip", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func binding(for slot: Slot) -> Binding? {
        current.bindings.first { $0.slot == slot }
    }

    public func configuration() -> PipConfiguration {
        current
    }

    public func replace(with configuration: PipConfiguration) throws {
        try PresetPack.validateBindings(configuration.bindings)
        // Persist first: a failed write does not silently change the active snapshot.
        try Self.write(configuration, to: fileURL)
        current = configuration
    }

    private static func write(_ configuration: PipConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(
            schemaVersion: currentSchemaVersion,
            configuration: configuration
        ))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    /// Schema 1 was a root {schemaVersion,inputMode,bindings} object with explicit
    /// action tags but no action.version. Schema 2 wraps configuration and versions
    /// every action. Unknown/newer versions fail closed; corrupt data is not replaced.
    public static func migrate(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["schemaVersion"] as? Int else {
            throw ConfigStoreError.malformed("Missing schemaVersion.")
        }
        switch version {
        case currentSchemaVersion:
            return data
        case 1:
            guard let mode = root["inputMode"] as? String,
                  var bindings = root["bindings"] as? [[String: Any]] else {
                throw ConfigStoreError.malformed("Schema 1 requires inputMode and bindings.")
            }
            for index in bindings.indices {
                guard var action = bindings[index]["action"] as? [String: Any],
                      action["type"] is String else {
                    throw ConfigStoreError.malformed("Schema 1 action requires an explicit type.")
                }
                if action["version"] == nil { action["version"] = 1 }
                bindings[index]["action"] = action
                if bindings[index]["enabled"] == nil { bindings[index]["enabled"] = true }
            }
            root = [
                "schemaVersion": currentSchemaVersion,
                "configuration": ["inputMode": mode, "bindings": bindings]
            ]
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        default:
            throw ConfigStoreError.unsupportedVersion(version)
        }
    }
}
