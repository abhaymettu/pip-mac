import Foundation
import PipDomain

public enum ShortcutDiscoveryError: Error, LocalizedError, Sendable {
    case commandFailed(ActionResult)
    case invalidUTF8
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let result):
            return "Shortcut discovery failed: \(result.message)"
        case .invalidUTF8:
            return "shortcuts list did not return valid UTF-8."
        case .outputTooLarge:
            return "Shortcut discovery output exceeded the capture limit; no partial list was used."
        }
    }
}

public actor ShortcutDiscovery {
    private let factory: any ProcessFactory
    private var cachedNames: [String]?

    public init(factory: any ProcessFactory = FoundationProcessFactory()) {
        self.factory = factory
    }

    public static var listRequest: ProcessRequest {
        ProcessRequest(
            executable: "/usr/bin/shortcuts",
            arguments: ["list"],
            timeout: 30,
            tailLimit: 8 * 1024 * 1024
        )
    }

    public func invalidateCache() {
        cachedNames = nil
    }

    public func refresh() async throws -> [String] {
        try await list(refresh: true)
    }

    public func list(refresh: Bool = false) async throws -> [String] {
        if !refresh, let cachedNames { return cachedNames }

        let outcome = await factory.makeProcess().run(Self.listRequest)
        let result = outcome.actionResult
        guard result.status == .completed else {
            throw ShortcutDiscoveryError.commandFailed(result)
        }
        guard !outcome.stdoutTruncated else {
            throw ShortcutDiscoveryError.outputTooLarge
        }
        guard let text = String(data: outcome.stdout, encoding: .utf8) else {
            throw ShortcutDiscoveryError.invalidUTF8
        }
        let names = Self.parseList(text)
        cachedNames = names
        return names
    }

    /// Remove only line terminators. Spaces, tabs, punctuation and case survive.
    public static func parseList(_ text: String) -> [String] {
        let names = text.split(whereSeparator: \.isNewline).map(String.init)
        return names.sorted {
            let comparison = $0.localizedStandardCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }
}
