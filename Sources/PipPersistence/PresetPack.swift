import Foundation
import PipDomain

public enum PresetError: Error, Equatable, LocalizedError {
    case missingResource
    case unsupportedVersion(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource: return "The bundled Everyday preset is missing."
        case .unsupportedVersion(let version): return "Unsupported preset version \(version)."
        case .invalid(let message): return "Invalid preset: \(message)"
        }
    }
}

public struct PresetPack: Codable, Equatable, Sendable {
    public let version: Int
    public let name: String
    public let bindings: [Binding]

    public init(version: Int = 1, name: String, bindings: [Binding]) throws {
        self.version = version
        self.name = name
        self.bindings = bindings
        try validate()
    }

    public func validate() throws {
        guard version == 1 else { throw PresetError.unsupportedVersion(version) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PresetError.invalid("A display name is required.")
        }
        try Self.validateBindings(bindings)
    }

    public static func validateBindings(_ bindings: [Binding]) throws {
        guard bindings.count == Slot.all.count,
              Set(bindings.map(\.slot)) == Set(Slot.all) else {
            throw PresetError.invalid("Exactly one binding is required for each of the six slots.")
        }
        guard Set(bindings.map(\.id)).count == bindings.count else {
            throw PresetError.invalid("Binding IDs must be unique.")
        }
        for binding in bindings {
            try binding.action.validate()
        }
    }

    public static func load(data: Data) throws -> PresetPack {
        let pack = try JSONDecoder().decode(PresetPack.self, from: data)
        try pack.validate()
        return pack
    }

    public static func everyday() throws -> PresetPack {
        guard let url = Bundle.module.url(
            forResource: "everyday", withExtension: "json", subdirectory: "Presets"
        ) else {
            throw PresetError.missingResource
        }
        return try load(data: Data(contentsOf: url))
    }

    /// Installing a preset uses fresh binding identities so an old running action
    /// cannot accidentally claim the concurrency identity of a newly installed slot.
    public func configuration(inputMode: InputMode) -> PipConfiguration {
        PipConfiguration(
            inputMode: inputMode,
            bindings: bindings.map {
                Binding(
                    slot: $0.slot,
                    action: $0.action,
                    enabled: $0.enabled,
                    comment: $0.comment
                )
            }
        )
    }
}
