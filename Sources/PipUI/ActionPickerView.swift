import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import PipDomain
import PipActions

public enum PipUIError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public enum PipBuiltIn: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPause, previousTrack, nextTrack, mute, volumeDown, volumeUp
    case screenshot, notes, calendar

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .previousTrack: return "Previous track"
        case .nextTrack: return "Next track"
        case .mute: return "Mute / Unmute output"
        case .volumeDown: return "Volume down"
        case .volumeUp: return "Volume up"
        case .screenshot: return "Screenshot selection → clipboard"
        case .notes: return "Open Notes"
        case .calendar: return "Open Calendar"
        }
    }
    public var icon: String {
        switch self {
        case .playPause: return "playpause"
        case .previousTrack: return "backward.end"
        case .nextTrack: return "forward.end"
        case .mute: return "speaker.slash"
        case .volumeDown: return "speaker.minus"
        case .volumeUp: return "speaker.plus"
        case .screenshot: return "camera.viewfinder"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        }
    }
    public var consequence: String {
        switch self {
        case .playPause: return "Toggle the current media playback."
        case .previousTrack: return "Send the previous-track media control."
        case .nextTrack: return "Send the next-track media control."
        case .mute: return "Toggle the Mac’s output mute control."
        case .volumeDown: return "Lower output volume one step."
        case .volumeUp: return "Raise output volume one step."
        case .screenshot: return "Open selection capture. Select an area to copy."
        case .notes: return "Bring Apple Notes forward."
        case .calendar: return "Bring Apple Calendar forward."
        }
    }
}

public enum PipActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn, shortcut, application, url, keyboard, script
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .builtIn: return "Mac controls"
        case .shortcut: return "Apple Shortcuts"
        case .application: return "Open app"
        case .url: return "Open URL"
        case .keyboard: return "Keyboard shortcut"
        case .script: return "Shell script"
        }
    }
    public var icon: String {
        switch self {
        case .builtIn: return "slider.horizontal.3"
        case .shortcut: return "square.stack.3d.up"
        case .application: return "app"
        case .url: return "link"
        case .keyboard: return "keyboard"
        case .script: return "terminal"
        }
    }
}

/// UI-owned, version-independent assignment representation. It is deliberately
/// not encoded as ActionKind: that enum's cases and wire schema were not supplied.
public struct PipAction: Codable, Equatable, Sendable {
    public var kind: PipActionKind
    public var builtInControl: PipBuiltIn?
    public var name = ""
    public var bundleID = ""
    public var bookmark: Data?
    public var address = ""
    public var keyCode: UInt16?
    public var modifierMask: UInt64 = 0
    public var keyDisplay = ""
    public var script = ""
    public var directory = ""
    public var directoryBookmark: Data?
    public var timeout = 30.0

    public init(kind: PipActionKind) { self.kind = kind }
    public static func builtIn(_ value: PipBuiltIn) -> PipAction {
        var action = PipAction(kind: .builtIn)
        action.builtInControl = value
        return action
    }
    public var title: String {
        switch kind {
        case .builtIn: return builtInControl?.title ?? "Mac control"
        case .shortcut: return name.isEmpty ? "Run a Shortcut" : name
        case .application: return name.isEmpty ? "Open app" : "Open \(name)"
        case .url: return "Open URL"
        case .keyboard: return keyDisplay.isEmpty ? "Keyboard shortcut" : keyDisplay
        case .script: return name.isEmpty ? "Shell script" : name
        }
    }
    public var detail: String {
        switch kind {
        case .builtIn: return builtInControl?.consequence ?? ""
        case .shortcut: return "Apple Shortcut · exact name"
        case .application: return bundleID
        case .url: return URL(string: address)?.host ?? address
        case .keyboard: return "Send to the frontmost app"
        case .script: return "\(Int(timeout)) second timeout · /bin/zsh"
        }
    }
    public var icon: String { builtInControl?.icon ?? kind.icon }
    public var needsAccessibility: Bool {
        kind == .keyboard || (kind == .builtIn &&
            builtInControl != .notes && builtInControl != .calendar)
    }
    public func validate() throws {
        switch kind {
        case .builtIn:
            guard builtInControl != nil else { throw PipUIError.message("Choose a Mac control.") }
        case .shortcut:
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipUIError.message("Enter the Shortcut’s exact name.")
            }
        case .application:
            guard !bundleID.isEmpty else { throw PipUIError.message("Choose an application.") }
        case .url:
            guard let url = URL(string: address), let scheme = url.scheme, !scheme.isEmpty,
                  !address.contains(where: \.isWhitespace) else {
                throw PipUIError.message("Enter the full address, including its scheme, such as https://.")
            }
        case .keyboard:
            guard keyCode != nil, modifierMask != 0 else {
                throw PipUIError.message("Record a key with Command, Option, Control, or Shift.")
            }
        case .script:
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipUIError.message("Write a script before assigning it.")
            }
            guard (1...300).contains(timeout) else {
                throw PipUIError.message("Choose a timeout from 1 to 300 seconds.")
            }
        }
    }
}

public enum PipPermissions {
    public static var inputAllowed: Bool { CGPreflightListenEventAccess() }
    public static var accessibilityAllowed: Bool { AXIsProcessTrusted() }

    @MainActor
    public static func requestInput() {
        // Verify the OS check against the vendored engine's actual event tap on-device.
        _ = CGRequestListenEventAccess()
        openPrivacy("Privacy_ListenEvent")
    }

    @MainActor
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }

    @MainActor
    private static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

public struct ActionPickerView: View {
    @EnvironmentObject private var model: PipViewModel
    @Environment(\.dismiss) private var dismiss
    public let slot: PipSlot

    @State private var search = ""
    @State private var selection: PipActionKind?
    @State private var draft: PipAction
    @State private var shortcutNames: [String] = []
    @State private var discoveryError: String?
    @State private var loading = false
    @State private var assigning = false
    @State private var issue: String?
    @State private var acknowledgeWarning = false

    public init(slot: PipSlot, initial: PipAction? = nil) {
        self.slot = slot
        _draft = State(initialValue: initial ?? PipAction(kind: .shortcut))
        _selection = State(initialValue: initial?.kind)
    }

    private var warning: String? {
        if draft.needsAccessibility && !PipPermissions.accessibilityAllowed {
            return "Accessibility isn’t allowed. This action can be assigned, but it won’t run until you allow it."
        }
        if draft.kind == .shortcut && !draft.name.isEmpty &&
            !shortcutNames.contains(draft.name) && !loading {
            return discoveryError == nil
                ? "“\(draft.name)” wasn’t found. Pip will use this exact name, never a similar one."
                : "Pip couldn’t verify this Shortcut. It will use only the exact name you entered."
        }
        if draft.kind == .application && !draft.bundleID.isEmpty &&
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: draft.bundleID) == nil {
            return "This application isn’t currently installed. Running this assignment may fail."
        }
        if draft.kind == .script {
            return "Scripts run with your account’s permissions. They can change or delete files. Only assign code you understand."
        }
        return nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("A useful little action.").font(PipTheme.title)
                Spacer()
                Text(slot.title).pipPill()
            }
            TextField("Search actions and Shortcuts", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search actions")

            HSplitView {
                ScrollView { catalog.padding(4) }
                    .frame(minWidth: 230, idealWidth: 260)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let selection {
                            Text(selection.title).font(PipTheme.heading)
                            fields
                        } else {
                            Label("Pick something useful from the list.", systemImage: "cursorarrow")
                                .foregroundStyle(PipTheme.secondary)
                        }
                        if let warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(PipTheme.error)
                            Toggle("Assign with this limitation", isOn: $acknowledgeWarning)
                        }
                        if let issue {
                            Label(issue, systemImage: "exclamationmark.circle")
                                .foregroundStyle(PipTheme.error)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 300)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if assigning { ProgressView().controlSize(.small) }
                Button("Assign to \(slot.title)") { assignDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || assigning ||
                              (warning != nil && !acknowledgeWarning))
            }
        }
        .padding(24)
        .frame(minWidth: 700, idealWidth: 760, minHeight: 520, idealHeight: 580)
        .background(PipTheme.canvas)
        .foregroundStyle(PipTheme.ink)
        .tint(PipTheme.accent)
        .task { await discover(refresh: false) }
        .onChange(of: draft) { _, _ in acknowledgeWarning = false }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Suggested")
            ForEach([PipBuiltIn.playPause, .mute, .notes].filter { matches($0.title) }) { item in
                builtInRow(item)
            }
            ForEach(recentActions, id: \.title) { action in
                row(action.title, icon: action.icon, detail: action.detail) {
                    choose(action)
                }
            }

            sectionHeading("Mac controls")
            ForEach(PipBuiltIn.allCases.filter { matches($0.title) }) { item in
                builtInRow(item)
            }

            sectionHeading("Apple Shortcuts")
            if loading { ProgressView("Looking for Shortcuts…").controlSize(.small) }
            if let discoveryError {
                Label(discoveryError, systemImage: "exclamationmark.circle")
                    .font(PipTheme.caption)
            } else if !loading && shortcutNames.isEmpty {
                Text("No Shortcuts found. Create one in Shortcuts, then refresh.")
                    .font(PipTheme.caption)
                    .foregroundStyle(PipTheme.secondary)
            }
            ForEach(shortcutNames.filter { matches($0) }, id: \.self) { name in
                row(name, icon: "square.stack.3d.up", detail: "Run this exact Shortcut") {
                    var action = PipAction(kind: .shortcut)
                    action.name = name
                    choose(action)
                }
            }
            HStack {
                Button("Refresh") { Task { await discover(refresh: true) } }
                    .disabled(loading)
                Button("Enter exact name…") { choose(PipAction(kind: .shortcut)) }
            }

            sectionHeading("Open app or URL")
            kindRow(.application, detail: "Bring an installed app forward.")
            kindRow(.url, detail: "Open a full address in its default app.")
            sectionHeading("Keyboard shortcut")
            kindRow(.keyboard, detail: "Send keys to the frontmost app.")
            Divider()
            sectionHeading("Advanced")
            kindRow(.script, detail: "Run code with your account’s permissions.")
        }
        .buttonStyle(.plain)
    }

    private var recentActions: [PipAction] {
        var seen = Set<String>()
        return model.preferences.assignments.values
            .sorted { $0.title < $1.title }
            .filter { $0.kind != .builtIn && matches($0.title) && seen.insert($0.title).inserted }
            .prefix(3).map { $0 }
    }

    private func matches(_ title: String) -> Bool {
        search.isEmpty || title.localizedCaseInsensitiveContains(search)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(PipTheme.cardLabel).accessibilityAddTraits(.isHeader)
    }

    private func row(
        _ title: String, icon: String, detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(PipTheme.body)
                    Text(detail).font(PipTheme.caption).foregroundStyle(PipTheme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func builtInRow(_ item: PipBuiltIn) -> some View {
        row(item.title, icon: item.icon, detail: item.consequence) {
            choose(.builtIn(item))
            // Low-friction built-ins assign immediately only when no capability
            // warning needs acknowledgment.
            if !draft.needsAccessibility || PipPermissions.accessibilityAllowed {
                assignDraft()
            }
        }
    }

    @ViewBuilder
    private func kindRow(_ kind: PipActionKind, detail: String) -> some View {
        if matches(kind.title) {
            row(kind.title, icon: kind.icon, detail: detail) {
                choose(PipAction(kind: kind))
            }
        }
    }

    private func choose(_ action: PipAction) {
        draft = action
        selection = action.kind
        acknowledgeWarning = false
        issue = nil
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .builtIn:
            Label(draft.title, systemImage: draft.icon).font(PipTheme.cardLabel)
            Text(draft.detail)
            if draft.needsAccessibility && !PipPermissions.accessibilityAllowed {
                Button("Allow Accessibility…") { PipPermissions.requestAccessibility() }
            }
        case .shortcut:
            TextField("Exact Shortcut name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Text("Capitalization and spacing are preserved. Pip won’t substitute another Shortcut.")
                .foregroundStyle(PipTheme.secondary)
            if !draft.name.isEmpty && shortcutNames.contains(draft.name) {
                Label("Found in Shortcuts", systemImage: "checkmark.circle")
            }
        case .application:
            Button("Choose application…") { chooseApplication() }
            Text(draft.name.isEmpty ? "No application selected" : draft.name)
            Text(draft.bundleID).font(PipTheme.mono).textSelection(.enabled)
            Text("Pip stores the bundle identifier and a file bookmark.")
                .foregroundStyle(PipTheme.secondary)
        case .url:
            TextField("https://example.com", text: $draft.address)
                .textFieldStyle(.roundedBorder)
            Text("Full address").font(PipTheme.cardLabel)
            Text(draft.address.isEmpty ? "Include a scheme, such as https://." : draft.address)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .keyboard:
            PipKeyRecorder(
                keyCode: $draft.keyCode,
                modifierMask: $draft.modifierMask,
                display: $draft.keyDisplay
            )
            .frame(height: 38)
            Text("Click the recorder, then press modifiers and a key. Escape cancels; Tab moves focus.")
                .foregroundStyle(PipTheme.secondary)
        case .script:
            TextField("Action name", text: $draft.name).textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.script)
                .font(PipTheme.mono)
                .frame(minHeight: 170)
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(PipTheme.border) }
                .accessibilityLabel("Shell script")
            Button("Choose working directory…") { chooseDirectory() }
            Text(draft.directory.isEmpty ? "Working directory: your home folder" : draft.directory)
                .font(PipTheme.caption)
                .textSelection(.enabled)
            HStack {
                Text("Timeout")
                TextField("Seconds", value: $draft.timeout, format: .number)
                    .frame(width: 65)
                Text("seconds · 1–300")
            }
            Text("Executed by /bin/zsh, not a login shell.")
                .font(PipTheme.mono)
        }
    }

    private func assignDraft() {
        do { try draft.validate() }
        catch { issue = error.localizedDescription; return }
        guard warning == nil || acknowledgeWarning else { return }
        assigning = true
        Task {
            defer { assigning = false }
            if await model.assign(draft, to: slot) { dismiss() }
            else { issue = model.error }
        }
    }

    private func discover(refresh: Bool) async {
        loading = true
        defer { loading = false }
        do {
            shortcutNames = Array(Set(try await model.discovery.list(refresh: refresh)))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            discoveryError = nil
        } catch {
            discoveryError = "Couldn’t read Shortcuts: \(error.localizedDescription)"
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        do {
            draft.bookmark = try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            draft.bundleID = identifier
            draft.name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        } catch { issue = error.localizedDescription }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            draft.directoryBookmark = try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            draft.directory = url.path
        } catch { issue = error.localizedDescription }
    }
}

private struct PipKeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt16?
    @Binding var modifierMask: UInt64
    @Binding var display: String

    func makeNSView(context: Context) -> Recorder {
        let view = Recorder()
        view.bezelStyle = .rounded
        view.target = view
        view.action = #selector(Recorder.arm)
        return view
    }

    func updateNSView(_ view: Recorder, context: Context) {
        view.recordedTitle = display.isEmpty ? "Record keyboard shortcut…" : display
        if !view.recording { view.title = view.recordedTitle }
        view.onRecord = { code, flags, label in
            keyCode = code
            modifierMask = flags
            display = label
        }
    }

    final class Recorder: NSButton {
        var recording = false
        var recordedTitle = ""
        var onRecord: ((UInt16, UInt64, String) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        @objc func arm() {
            recording = true
            title = "Press a shortcut…"
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            title = recordedTitle
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 {
                recording = false
                title = recordedTitle
                return
            }
            if event.keyCode == 48 {
                recording = false
                title = recordedTitle
                window?.selectNextKeyView(self)
                return
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else {
                title = "Include a modifier key"
                return
            }
            var label = ""
            if flags.contains(.control) { label += "⌃" }
            if flags.contains(.option) { label += "⌥" }
            if flags.contains(.shift) { label += "⇧" }
            if flags.contains(.command) { label += "⌘" }
            label += event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            // Only this explicitly armed recorder reads a key label. No typing
            // suppression path retains characters or logs keyboard contents.
            onRecord?(event.keyCode, UInt64(flags.rawValue), label)
            recordedTitle = label
            title = label
            recording = false
        }
    }
}

/// Explicit Run fallback for UI-owned actions, not a replacement gesture router.
/// Core ActionDispatcher construction was not included in the supplied surface.
public actor PipUIActionExecutor {
    public init() {}

    public func execute(_ action: PipAction) async throws -> String {
        try action.validate()
        switch action.kind {
        case .application:
            let result = await WorkspaceOpener().openApplication(bundleID: action.bundleID)
            return try describe(result)
        case .url:
            guard let url = URL(string: action.address) else {
                throw PipUIError.message("The URL isn’t valid.")
            }
            return try describe(await WorkspaceOpener().openURL(url))
        case .shortcut:
            let outcome = try await process(
                "/usr/bin/shortcuts", ["run", action.name], directory: nil, timeout: 60
            )
            return outcome.isEmpty ? "Shortcut completed" : "Shortcut completed — \(outcome)"
        case .script:
            let directory = action.directory.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser
                : URL(fileURLWithPath: action.directory)
            let output = try await process(
                "/bin/zsh", ["-c", action.script], directory: directory, timeout: action.timeout
            )
            return output.isEmpty ? "Script completed" : "Script completed — \(output)"
        case .keyboard:
            guard let key = action.keyCode else { throw PipUIError.message("Record a key first.") }
            try await sendKey(key, flags: CGEventFlags(rawValue: action.modifierMask))
            return "Keyboard control sent"
        case .builtIn:
            guard let builtIn = action.builtInControl else {
                throw PipUIError.message("Choose a Mac control.")
            }
            switch builtIn {
            case .notes:
                return try describe(await WorkspaceOpener().openApplication(bundleID: "com.apple.Notes"))
            case .calendar:
                return try describe(await WorkspaceOpener().openApplication(bundleID: "com.apple.iCal"))
            case .screenshot:
                try await sendKey(21, flags: [.maskCommand, .maskShift, .maskControl])
                return "Selection capture opened"
            default:
                let code: Int
                switch builtIn {
                case .playPause: code = 16
                case .previousTrack: code = 20
                case .nextTrack: code = 19
                case .mute: code = 7
                case .volumeDown: code = 1
                case .volumeUp: code = 0
                default: throw PipUIError.message("This control isn’t available.")
                }
                try await sendMediaKey(code)
                return "Media control sent"
            }
        }
    }

    private func describe(_ result: ActionResult) throws -> String {
        // Status cases were not supplied. Preserve the core's own status wording.
        let status = result.status.rawValue
        if status.lowercased().contains("fail") || status.lowercased().contains("error") {
            throw PipUIError.message(result.message)
        }
        return "\(status): \(result.message)"
    }

    @MainActor
    private func sendKey(_ key: UInt16, flags: CGEventFlags) throws {
        guard PipPermissions.accessibilityAllowed else {
            throw PipUIError.message("Allow Accessibility to send keyboard controls.")
        }
        // Verify foreground-app delivery and keyboard-layout behavior on-device.
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            throw PipUIError.message("The keyboard event couldn’t be created.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @MainActor
    private func sendMediaKey(_ key: Int) throws {
        guard PipPermissions.accessibilityAllowed else {
            throw PipUIError.message("Allow Accessibility to send media controls.")
        }
        // Verify NX media-key behavior on Apple Silicon and the active media app.
        for state in [0xA, 0xB] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key << 16) | (state << 8),
                data2: -1
            )?.cgEvent else {
                throw PipUIError.message("The media control couldn’t be created.")
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func process(
        _ executable: String,
        _ arguments: [String],
        directory: URL?,
        timeout: TimeInterval
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            // Files avoid pipe deadlocks. Output is discarded after a bounded tail
            // is read; it is never added to a permanent diagnostics log.
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pip-run-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let stdoutURL = base.appendingPathComponent("stdout")
            let stderrURL = base.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout.close()
                try? stderr.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var timedOut = false
            var outputExceeded = false
            while process.isRunning {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    timedOut = true
                    break
                }
                let outSize = (try? FileManager.default.attributesOfItem(atPath: stdoutURL.path)[.size] as? NSNumber)?.intValue ?? 0
                let errSize = (try? FileManager.default.attributesOfItem(atPath: stderrURL.path)[.size] as? NSNumber)?.intValue ?? 0
                if outSize + errSize > 8 * 1024 * 1024 {
                    outputExceeded = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.15)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            if timedOut { throw PipUIError.message("The action timed out after \(Int(timeout)) seconds.") }
            if outputExceeded { throw PipUIError.message("The action stopped because it produced too much output.") }

            func tail(_ url: URL) throws -> String {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let length = try handle.seekToEnd()
                try handle.seek(toOffset: length > 4096 ? length - 4096 : 0)
                return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let errorText = try tail(stderrURL)
            guard process.terminationStatus == 0 else {
                throw PipUIError.message(errorText.isEmpty
                    ? "The action exited with status \(process.terminationStatus)."
                    : errorText)
            }
            return try tail(stdoutURL)
        }.value
    }
}
