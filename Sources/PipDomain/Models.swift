import Foundation

public enum TapSide: String, Codable, CaseIterable, Sendable {
    case left, right
}

public enum TapCount: Int, Codable, CaseIterable, Sendable {
    case single = 1
    case double = 2
    case triple = 3
}

public struct Gesture: Codable, Hashable, Sendable {
    public let side: TapSide
    public let count: TapCount

    public init(side: TapSide, count: TapCount) {
        self.side = side
        self.count = count
    }
}

public struct Slot: Codable, Hashable, Sendable {
    public let side: TapSide
    public let count: TapCount

    public init(side: TapSide, count: TapCount) {
        self.side = side
        self.count = count
    }

    public init(_ gesture: Gesture) {
        self.init(side: gesture.side, count: gesture.count)
    }

    public static var all: [Slot] {
        TapSide.allCases.flatMap { side in
            TapCount.allCases.map { Slot(side: side, count: $0) }
        }
    }
}

/// Trackpad events must never masquerade as chassis events.
public enum InputMode: String, Codable, CaseIterable, Sendable {
    case chassisTaps
    case trackpadFallback
    case replay
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case command, option, control, shift
    }

    /// A macOS virtual key code, not a character or keyboard-layout guess.
    public let keyCode: UInt16
    public let modifiers: [Modifier]

    public init(keyCode: UInt16, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ActionValidationError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// Stable wire format: {"version":1,"type":"runShortcut","name":"Exact Name"}.
/// Payload fields are explicit; synthesized associated-enum Codable is not used.
public enum ActionKind: Equatable, Sendable, Codable {
    case playPause
    case previousTrack
    case nextTrack
    case volumeUp
    case volumeDown
    case toggleMute
    case screenshotInteractiveToClipboard
    case openApplication(bundleID: String)
    case openURL(String)
    case pressKeyboardShortcut(KeyboardShortcut)
    case runShortcut(name: String, input: String? = nil)
    case runShellScript(script: String)
    case pausePip(minutes: Int)

    private enum Keys: String, CodingKey {
        case version, type, bundleID, url, shortcut, name, input, script, minutes
    }

    private enum Tag: String, Codable {
        case playPause, previousTrack, nextTrack, volumeUp, volumeDown, toggleMute
        case screenshotInteractiveToClipboard
        case openApplication, openURL, pressKeyboardShortcut
        case runShortcut, runShellScript, pausePip
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "Unsupported ActionKind version \(version)."
            )
        }
        switch try c.decode(Tag.self, forKey: .type) {
        case .playPause: self = .playPause
        case .previousTrack: self = .previousTrack
        case .nextTrack: self = .nextTrack
        case .volumeUp: self = .volumeUp
        case .volumeDown: self = .volumeDown
        case .toggleMute: self = .toggleMute
        case .screenshotInteractiveToClipboard:
            self = .screenshotInteractiveToClipboard
        case .openApplication:
            self = .openApplication(bundleID: try c.decode(String.self, forKey: .bundleID))
        case .openURL:
            self = .openURL(try c.decode(String.self, forKey: .url))
        case .pressKeyboardShortcut:
            self = .pressKeyboardShortcut(
                try c.decode(KeyboardShortcut.self, forKey: .shortcut)
            )
        case .runShortcut:
            self = .runShortcut(
                name: try c.decode(String.self, forKey: .name),
                input: try c.decodeIfPresent(String.self, forKey: .input)
            )
        case .runShellScript:
            self = .runShellScript(script: try c.decode(String.self, forKey: .script))
        case .pausePip:
            self = .pausePip(minutes: try c.decode(Int.self, forKey: .minutes))
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(1, forKey: .version)
        let tag: Tag
        switch self {
        case .playPause: tag = .playPause
        case .previousTrack: tag = .previousTrack
        case .nextTrack: tag = .nextTrack
        case .volumeUp: tag = .volumeUp
        case .volumeDown: tag = .volumeDown
        case .toggleMute: tag = .toggleMute
        case .screenshotInteractiveToClipboard:
            tag = .screenshotInteractiveToClipboard
        case .openApplication(let bundleID):
            tag = .openApplication
            try c.encode(bundleID, forKey: .bundleID)
        case .openURL(let url):
            tag = .openURL
            try c.encode(url, forKey: .url)
        case .pressKeyboardShortcut(let shortcut):
            tag = .pressKeyboardShortcut
            try c.encode(shortcut, forKey: .shortcut)
        case .runShortcut(let name, let input):
            tag = .runShortcut
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(input, forKey: .input)
        case .runShellScript(let script):
            tag = .runShellScript
            try c.encode(script, forKey: .script)
        case .pausePip(let minutes):
            tag = .pausePip
            try c.encode(minutes, forKey: .minutes)
        }
        try c.encode(tag, forKey: .type)
    }

    public func validate() throws {
        switch self {
        case .openApplication(let bundleID):
            guard !bundleID.isEmpty, !bundleID.contains("\0") else {
                throw ActionValidationError.invalid("An application bundle ID is required.")
            }
        case .openURL(let text):
            guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty else {
                throw ActionValidationError.invalid("An absolute URL with a scheme is required.")
            }
        case .pressKeyboardShortcut(let shortcut):
            guard shortcut.keyCode <= 127,
                  Set(shortcut.modifiers).count == shortcut.modifiers.count else {
                throw ActionValidationError.invalid("Invalid key code or duplicate modifiers.")
            }
        case .runShortcut(let name, _):
            // Do not trim: leading and trailing spaces can be part of an exact name.
            guard !name.isEmpty, !name.contains("\0"), !name.contains(where: \.isNewline) else {
                throw ActionValidationError.invalid("A single-line, exact Shortcut name is required.")
            }
        case .runShellScript(let script):
            guard !script.isEmpty, !script.contains("\0") else {
                throw ActionValidationError.invalid("A nonempty shell script is required.")
            }
        case .pausePip(let minutes):
            guard (1...1440).contains(minutes) else {
                throw ActionValidationError.invalid("Pause must be between 1 and 1440 minutes.")
            }
        default:
            break
        }
    }
}

public struct Binding: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let slot: Slot
    public let action: ActionKind
    public let enabled: Bool
    public let comment: String?

    public init(
        id: UUID = UUID(),
        slot: Slot,
        action: ActionKind,
        enabled: Bool = true,
        comment: String? = nil
    ) {
        self.id = id
        self.slot = slot
        self.action = action
        self.enabled = enabled
        self.comment = comment
    }
}

public struct PipConfiguration: Codable, Equatable, Sendable {
    public let inputMode: InputMode
    public let bindings: [Binding]

    public init(inputMode: InputMode, bindings: [Binding]) {
        self.inputMode = inputMode
        self.bindings = bindings
    }
}

public struct ActionResult: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case completed, launched, cancelled, unavailable
        case permissionRequired, busy, failed
    }

    public let status: Status
    public let message: String
    public let exitStatus: Int32?
    public let stdoutTail: String
    public let stderrTail: String

    public init(
        _ status: Status,
        message: String = "",
        exitStatus: Int32? = nil,
        stdoutTail: String = "",
        stderrTail: String = ""
    ) {
        self.status = status
        self.message = message
        self.exitStatus = exitStatus
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

/// Sources emit this only after a complete single/double/triple group.
/// timestamp is monotonic uptime in seconds, not a wall-clock Date.
public struct GestureEvent: Equatable, Sendable, Identifiable {
    public let groupID: UUID
    public let gesture: Gesture
    public let timestamp: TimeInterval
    public let inputMode: InputMode

    public var id: UUID { groupID }

    public init(
        groupID: UUID = UUID(),
        gesture: Gesture,
        timestamp: TimeInterval,
        inputMode: InputMode
    ) {
        self.groupID = groupID
        self.gesture = gesture
        self.timestamp = timestamp
        self.inputMode = inputMode
    }
}

/// The binding is a value snapshot. Executors must not re-read the binding store.
public struct RoutedGesture: Equatable, Sendable {
    public let event: GestureEvent
    public let binding: Binding

    public init(event: GestureEvent, binding: Binding) {
        self.event = event
        self.binding = binding
    }
}
