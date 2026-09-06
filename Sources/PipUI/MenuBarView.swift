import SwiftUI
import AppKit
import PipActions

private struct PipFeedbackKey: EnvironmentKey {
    static let defaultValue = FeedbackCoordinator()
}

public extension EnvironmentValues {
    var pipFeedback: FeedbackCoordinator {
        get { self[PipFeedbackKey.self] }
        set { self[PipFeedbackKey.self] = newValue }
    }
}

public struct PipMenuGlyph: View {
    public var paused: Bool
    public var failed: Bool

    public init(paused: Bool, failed: Bool) {
        self.paused = paused
        self.failed = failed
    }

    public var body: some View {
        Image(nsImage: Self.image(paused: paused, failed: failed))
            .accessibilityLabel(failed ? "Pip, action failure" : (paused ? "Pip, paused" : "Pip, listening"))
    }

    private static func image(paused: Bool, failed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 23, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 3, y: 5, width: 4, height: 9),
                xRadius: 2, yRadius: 2
            ).fill()
            NSBezierPath(ovalIn: NSRect(x: 9, y: 7, width: 4, height: 4)).fill()
            NSBezierPath(
                roundedRect: NSRect(x: 15, y: 4, width: 4, height: 9),
                xRadius: 2, yRadius: 2
            ).fill()
            if paused {
                NSColor.black.setStroke()
                let slash = NSBezierPath()
                slash.lineWidth = 1.6
                slash.move(to: NSPoint(x: 3, y: 2))
                slash.line(to: NSPoint(x: 19, y: 16))
                slash.stroke()
            }
            if failed {
                NSBezierPath(
                    roundedRect: NSRect(x: 21, y: 7, width: 1.5, height: 6),
                    xRadius: 0.7, yRadius: 0.7
                ).fill()
                NSBezierPath(ovalIn: NSRect(x: 21, y: 4, width: 1.5, height: 1.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

public struct MenuBarView: View {
    @EnvironmentObject private var model: PipViewModel
    @Environment(\.pipFeedback) private var feedback
    @Environment(\.openWindow) private var openWindow
    @State private var entries: [FeedbackEntry] = []

    public init() {}

    public var body: some View {
        Text(model.status)
        if let until = model.pauseUntil {
            Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        Button("Open Tap Map…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "tap-map")
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])

        if model.listening {
            Button("Pause for 10 minutes") { Task { await model.pause(minutes: 10) } }
        } else {
            Button("Resume") { Task { await model.setListening(true) } }
                .disabled(!model.canListen)
        }
        Menu("Input: \(model.input.title)") {
            ForEach(PipInput.allCases) { input in
                Button {
                    Task { await model.setInput(input) }
                } label: {
                    if model.input == input {
                        Label(input.title, systemImage: "checkmark")
                    } else {
                        Text(input.title)
                    }
                }
                .disabled(input == .trackpad && !model.bridge.trackpadVerified)
            }
        }

        if let failure = model.recentFailure {
            Divider()
            Text("Most recent failure")
            Text(failure)
        }

        Menu("Recent results") {
            if entries.isEmpty { Text("No core action results yet") }
            ForEach(Array(entries.suffix(5).reversed().enumerated()), id: \.offset) { _, entry in
                Text("\(statusLabel(for: entry)): \(entry.result.message)")
            }
        }
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "pip-settings")
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Quit Pip") {
            Task {
                await model.setListening(false)
                NSApplication.shared.terminate(nil)
            }
        }
        .keyboardShortcut("q", modifiers: .command)
        .task {
            await model.load()
            entries = await feedback.history()
            await model.refreshFeedback()
        }
    }

    private func statusLabel(for entry: FeedbackEntry) -> String {
        switch entry.result.status {
        case .completed: return "Done"
        case .launched: return "Opened"
        case .cancelled: return "Cancelled"
        case .unavailable: return "Unavailable"
        case .permissionRequired: return "Needs permission"
        case .busy: return "Busy"
        case .failed: return "Failed"
        }
    }
}

public struct PipSettingsView: View {
    @EnvironmentObject private var model: PipViewModel

    public init() {}

    public var body: some View {
        Form {
            Section("Listening") {
                LabeledContent("Status", value: model.status)
                Text("Pip doesn’t save what you type.")
                    .foregroundStyle(PipTheme.secondary)
                Button("Input Monitoring settings…") { PipPermissions.requestInput() }
                Button("Accessibility settings…") { PipPermissions.requestAccessibility() }
            }
            Section("Feedback") {
                Toggle("Quiet tap sound", isOn: $model.preferences.quietSound)
                    .disabled(true)
                Toggle("Visual acknowledgment", isOn: $model.preferences.visualAcknowledgment)
                    .disabled(true)
                Text("Feedback extras stay unavailable until the verified adapter and original tick asset are installed. Action results still appear in the map.")
                    .font(PipTheme.caption)
                    .foregroundStyle(PipTheme.secondary)
            }
            Section("This milestone") {
                Text("The map and explicit Run actions work without sensor access. The default source is a clearly labeled practice demo, not a hardware detector.")
                Text("UI assignments and first-run progress are stored in ui-state.json beside the core configuration. Existing core bindings remain intact.")
                    .font(PipTheme.caption)
                    .foregroundStyle(PipTheme.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(PipTheme.accent)
        .foregroundStyle(PipTheme.ink)
        .scrollContentBackground(.hidden)
        .background(PipTheme.canvas)
        .frame(width: 530, height: 480)
        .onDisappear { model.savePreferences() }
    }
}

