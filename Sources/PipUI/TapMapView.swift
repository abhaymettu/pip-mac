import SwiftUI
import AppKit
import PipDomain
import PipActions
import PipPersistence
import PipEngineAdapter

public enum PipSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct PipSlot: Hashable, Codable, Identifiable, Sendable {
    public let side: PipSide
    public let count: Int
    public var id: String { "\(side.rawValue)-\(count)" }
    public var countName: String { ["Single", "Double", "Triple"][count - 1] }
    public var title: String { "\(side.title) · \(countName)" }
    public var marks: String { String(repeating: "•", count: count) }

    public init(side: PipSide, count: Int) {
        precondition((1...3).contains(count))
        self.side = side
        self.count = count
    }

    public static let all = PipSide.allCases.flatMap { side in
        (1...3).map { PipSlot(side: side, count: $0) }
    }

    public var coreSlot: Slot? {
        guard let side = TapSide.allCases.first(where: {
            $0.rawValue.lowercased() == side.rawValue
        }), let count = TapCount(rawValue: count) else { return nil }
        return Slot(side: side, count: count)
    }

    public init?(_ gesture: Gesture) {
        guard let side = PipSide(rawValue: gesture.side.rawValue.lowercased()),
              (1...3).contains(gesture.count.rawValue) else { return nil }
        self.init(side: side, count: gesture.count.rawValue)
    }
}

public enum PipInput: String, Codable, CaseIterable, Identifiable {
    case chassis, trackpad
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var coreMode: InputMode? {
        if self == .chassis { return .chassisTaps }
        return InputMode.allCases.first {
            $0.rawValue.lowercased().contains("trackpad")
        }
    }
}

public struct PipSensitivity: Codable {
    public var overall = 0.5
    public var left = 0.5
    public var right = 0.5
    public var typingProtection = true
    public var swapSides = false
}

public struct PipUIConfiguration: Codable {
    public var input = PipInput.chassis
    public var assignments: [String: PipAction] = [:]
    public var clearedCoreSlots: Set<String> = []
    public var quietSound = true
    public var visualAcknowledgment = false
    public var sensitivity: [String: PipSensitivity] = [:]
    public init() {}
}

/// The supplied public surface omits ActionKind cases, Binding's initializer,
/// dispatcher construction, and engine stream/diagnostic members. These closures
/// are the explicit integration seam; no guessed enum cases or Codable schema.
///
/// The stock milestone app persists UI assignments separately and exposes Run.
/// Live listening stays unavailable until a host supplies the verified bridge.
@MainActor
public struct PipCoreBridge {
    public var describe: ((Binding) -> PipAction?)?
    public var assign: ((PipSlot, PipAction?) async throws -> Void)?
    public var run: ((Binding) async throws -> ActionResult)?
    public var setListening: ((Bool, PipInput) async throws -> Void)?
    public var applySensitivity: ((PipInput, PipSensitivity) async throws -> Void)?
    public var sensitivityExplanation: String?
    public var trackpadVerified = false

    public init() {}
}

public enum PipSourceSelection {
    case engine(EngineAdapter)
    case replay(ReplaySource)

    public func start() async {
        switch self {
        case .engine(let engine): await engine.start()
        case .replay(let replay): await replay.start()
        }
    }

    public func stop() async {
        switch self {
        case .engine(let engine): await engine.stop()
        case .replay(let replay): await replay.stop()
        }
    }
}

public struct PipDiagnostic: Identifiable {
    public let id = UUID()
    public let text: String
    public let timestamp: Date
    public let delay: TimeInterval?
}

@MainActor
public final class PipViewModel: ObservableObject {
    @Published public var preferences = PipUIConfiguration()
    @Published public private(set) var coreBindings: [String: Binding] = [:]
    @Published public private(set) var listening = false
    @Published public private(set) var pauseUntil: Date?
    @Published public private(set) var ready = false
    @Published public var error: String?
    @Published public private(set) var recentFailure: String?
    @Published public private(set) var lastResult = "No actions run yet"
    @Published public private(set) var running: Set<String> = []
    @Published public private(set) var recognizedSlot: PipSlot?
    @Published public private(set) var diagnostics: [PipDiagnostic] = []
    @Published public private(set) var envelope: [PipEnvelopePoint] = []
    @Published public private(set) var coreHistory: [FeedbackEntry] = []
    @Published public var testing = false {
        didSet { if !testing { alsoRunActions = false } }
    }
    @Published public var alsoRunActions = false
    @Published public private(set) var pulse = false

    public let feedback: FeedbackCoordinator
    public let control: PipControl
    public let discovery: ShortcutDiscovery
    public let bridge: PipCoreBridge
    public let source: PipSourceSelection

    private let bindingStore: any BindingStore
    private let configStore: ConfigStore?
    private let preferencesURL: URL
    private let executor = PipUIActionExecutor()
    private var resumeTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var lastAcknowledgment = Date.distantPast

    public init(
        bindingStore: any BindingStore,
        configStore: ConfigStore?,
        preferencesURL: URL,
        feedback: FeedbackCoordinator,
        control: PipControl = PipControl(),
        discovery: ShortcutDiscovery = ShortcutDiscovery(),
        source: PipSourceSelection = .replay(ReplaySource(steps: [])),
        bridge: PipCoreBridge = PipCoreBridge()
    ) {
        self.bindingStore = bindingStore
        self.configStore = configStore
        self.preferencesURL = preferencesURL
        self.feedback = feedback
        self.control = control
        self.discovery = discovery
        self.source = source
        self.bridge = bridge
    }

    public var input: PipInput { preferences.input }
    public var canListen: Bool { bridge.setListening != nil }
    public var status: String {
        if !canListen { return "Paused · demo build" }
        if !PipPermissions.inputAllowed { return "Permission needed" }
        return listening ? "Listening" : "Paused"
    }

    public func load() async {
        guard !ready else { return }
        do {
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                preferences = try JSONDecoder().decode(
                    PipUIConfiguration.self,
                    from: Data(contentsOf: preferencesURL)
                )
            }
            if let configStore {
                let configuration = await configStore.configuration()
                preferences.input = configuration.inputMode == .chassisTaps ? .chassis : .trackpad
            }
        } catch {
            self.error = "Pip couldn’t read its settings: \(error.localizedDescription)"
        }
        await refreshBindings()
        // Pause before any source starts. Setup never dispatches actions.
        try? await control.pause(minutes: 24 * 60)
        ready = true
    }

    public func refreshBindings() async {
        var next: [String: Binding] = [:]
        for slot in PipSlot.all {
            if let key = slot.coreSlot, let binding = await bindingStore.binding(for: key) {
                next[slot.id] = binding
            }
        }
        coreBindings = next
    }

    @discardableResult
    public func savePreferences() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: preferencesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: preferencesURL, options: .atomic)
            return true
        } catch {
            self.error = "Pip couldn’t save your changes: \(error.localizedDescription)"
            return false
        }
    }

    public func action(for slot: PipSlot) -> PipAction? {
        if let action = preferences.assignments[slot.id] { return action }
        guard !preferences.clearedCoreSlots.contains(slot.id),
              let binding = coreBindings[slot.id] else { return nil }
        return bridge.describe?(binding)
    }

    public func unresolvedBinding(for slot: PipSlot) -> Binding? {
        guard preferences.assignments[slot.id] == nil,
              !preferences.clearedCoreSlots.contains(slot.id),
              let binding = coreBindings[slot.id],
              bridge.describe?(binding) == nil else { return nil }
        return binding
    }

    public func assign(_ action: PipAction?, to slot: PipSlot) async -> Bool {
        let previous = preferences
        do {
            if let action { try action.validate() }
            if let assign = bridge.assign {
                try await assign(slot, action)
            }
            preferences.assignments[slot.id] = action
            preferences.clearedCoreSlots.insert(slot.id)
            guard savePreferences() else {
                preferences = previous
                return false
            }
            await refreshBindings()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func setInput(_ input: PipInput) async {
        guard input != .trackpad || bridge.trackpadVerified else {
            error = "Trackpad input isn’t available yet. Pip needs verified Option-tap regions before it can leave ordinary pointer use untouched."
            return
        }
        await setListening(false)
        do {
            guard let mode = input.coreMode else {
                throw PipUIError.message("This input mode isn’t available in the installed engine.")
            }
            if let configStore {
                let current = await configStore.configuration()
                try await configStore.replace(with: PipConfiguration(
                    inputMode: mode, bindings: current.bindings
                ))
            }
            preferences.input = input
            await control.setInputMode(mode)
            savePreferences()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func setListening(_ enabled: Bool) async {
        resumeTask?.cancel()
        pauseUntil = nil
        if enabled {
            guard let setListening = bridge.setListening else {
                error = "Live listening isn’t connected in this UI build. You can build your map, run actions explicitly, and watch the practice demo."
                return
            }
            guard PipPermissions.inputAllowed else {
                error = "Allow Input Monitoring before listening."
                return
            }
            do {
                try await setListening(true, input)
                await control.resume()
                await source.start()
                listening = true
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            listening = false
            try? await control.pause(minutes: 24 * 60)
            await source.stop()
            do { try await bridge.setListening?(false, input) }
            catch { self.error = error.localizedDescription }
        }
    }

    public func pause(minutes: Int) async {
        await setListening(false)
        do {
            try await control.pause(minutes: minutes)
            pauseUntil = Date().addingTimeInterval(Double(minutes) * 60)
            resumeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Double(minutes) * 60)) }
                catch { return }
                guard let self else { return }
                await self.setListening(true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A verified engine adapter calls this BEFORE routing/dispatching the gesture.
    /// It returns whether ordinary action routing is permitted.
    public func intercept(
        _ event: GestureEvent,
        dispatchDelay: TimeInterval? = nil
    ) -> Bool {
        guard let slot = PipSlot(event.gesture) else { return false }
        recognizedSlot = slot
        addDiagnostic(slot.title, delay: dispatchDelay)
        recognitionTask?.cancel()
        recognitionTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            recognizedSlot = nil
        }
        if testing && !alsoRunActions { return false }
        guard listening else { return false }

        // Exactly one acknowledgment for each grouped event, never per impulse.
        if Date().timeIntervalSince(lastAcknowledgment) > 0.12 {
            lastAcknowledgment = Date()
            pulse.toggle()
        }
        return true
    }

    /// Feed already downsampled min/max bins, at no more than 30 Hz.
    /// Raw sensor processing belongs in the engine, not on the main actor.
    public func receiveEnvelope(_ points: [PipEnvelopePoint]) {
        envelope = Array(points.suffix(120))
    }

    public func addDiagnostic(_ text: String, delay: TimeInterval? = nil) {
        diagnostics.append(PipDiagnostic(text: text, timestamp: Date(), delay: delay))
        diagnostics = Array(diagnostics.suffix(40))
    }

    public func run(_ slot: PipSlot) async {
        guard !running.contains(slot.id), running.count < 2 else {
            error = "Two actions are already running. Give them a moment."
            return
        }
        running.insert(slot.id)
        defer { running.remove(slot.id) }

        do {
            let message: String
            if let action = action(for: slot) {
                message = try await executor.execute(action)
            } else if let binding = unresolvedBinding(for: slot) {
                guard binding.enabled else {
                    throw PipUIError.message("This binding is disabled.")
                }
                guard let run = bridge.run else {
                    throw PipUIError.message("This core action needs the dispatcher bridge before it can run here.")
                }
                let result = try await run(binding)
                message = "\(result.status.rawValue): \(result.message)"
            } else {
                return
            }
            lastResult = "\(slot.title) — \(message)"
        } catch {
            recentFailure = error.localizedDescription
            lastResult = "\(slot.title) — Failed: \(error.localizedDescription)"
        }
    }

    public func refreshFeedback() async {
        coreHistory = await feedback.history()
        if let failure = coreHistory.last(where: {
            let status = $0.result.status.rawValue.lowercased()
            return status.contains("fail") || status.contains("error") || status.contains("timeout")
        }) {
            recentFailure = failure.result.message
        }
    }

    public func applyPreset(_ preset: PipPreset) async -> Bool {
        // Keep the previous UI map if any write fails. A host bridge should supply
        // a transactional preset operation if it also writes core bindings.
        let previous = preferences
        for slot in PipSlot.all {
            let action = preset.action(for: slot)
            if !(await assign(action, to: slot)) {
                preferences = previous
                savePreferences()
                return false
            }
        }
        return true
    }
}

public enum PipPreset: String, CaseIterable, Identifiable {
    case everyday = "Everyday"
    case quiet = "Quiet desk"
    case canvas = "Shortcut canvas"
    public var id: String { rawValue }

    public func action(for slot: PipSlot) -> PipAction? {
        let index = (slot.side == .left ? 0 : 3) + slot.count - 1
        switch self {
        case .everyday:
            return PipAction.builtIn([
                .playPause, .previousTrack, .nextTrack,
                .mute, .screenshot, .notes
            ][index])
        case .quiet:
            return PipAction.builtIn([
                .playPause, .volumeDown, .volumeUp,
                .mute, .calendar, .notes
            ][index])
        case .canvas:
            return nil
        }
    }
}

public struct TapMapView: View {
    @EnvironmentObject private var model: PipViewModel
    @State private var picking: PipSlot?
    @State private var sensitivity = false
    @State private var presets = false
    @State private var selectedPreset = PipPreset.everyday
    @State private var showDiagnostics = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    PipMacBook(activeSide: model.recognizedSlot?.side)
                    HStack(alignment: .top, spacing: 16) {
                        column(.left)
                        column(.right)
                    }
                    if model.testing { testPanel }
                    if !model.canListen {
                        Label(
                            "Demo build: live detection is paused. Run buttons execute real actions.",
                            systemImage: "info.circle"
                        )
                        .font(PipTheme.caption)
                        .foregroundStyle(PipTheme.secondary)
                    }
                    if let error = model.error {
                        HStack(alignment: .top) {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(PipTheme.error)
                            Spacer()
                            Button("Dismiss") { model.error = nil }
                        }
                        .font(PipTheme.body)
                        .pipCard()
                    }
                }
                .padding(PipTheme.pagePadding)
            }
            Divider()
            utilityStrip
        }
        .font(PipTheme.body)
        .foregroundStyle(PipTheme.ink)
        .background(PipTheme.canvas)
        .tint(PipTheme.accent)
        .frame(minWidth: 700, minHeight: 520)
        .sheet(item: $picking) { slot in
            ActionPickerView(slot: slot, initial: model.action(for: slot))
                .environmentObject(model)
        }
        .sheet(isPresented: $sensitivity) {
            PipSensitivityView().environmentObject(model)
        }
        .sheet(isPresented: $presets) { presetSheet }
        .task {
            await model.load()
            while !Task.isCancelled {
                await model.refreshFeedback()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            Text("Pip").font(PipTheme.title)
            Picker("Input", selection: Binding(
                get: { model.input },
                set: { value in Task { await model.setInput(value) } }
            )) {
                Text("Chassis").tag(PipInput.chassis)
                Text("Trackpad").tag(PipInput.trackpad)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()
            Toggle(isOn: Binding(
                get: { model.listening },
                set: { value in Task { await model.setListening(value) } }
            )) {
                Label(model.status, systemImage: model.listening ? "ear" : "pause.circle")
            }
            .toggleStyle(.switch)
            .accessibilityHint("Pause or resume gesture detection")
        }
        .padding(.horizontal, PipTheme.pagePadding)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private func column(_ side: PipSide) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(side.title) side")
                .font(PipTheme.heading)
                .accessibilityAddTraits(.isHeader)
            ForEach(1...3, id: \.self) { count in
                card(PipSlot(side: side, count: count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func card(_ slot: PipSlot) -> some View {
        let action = model.action(for: slot)
        let unresolved = model.unresolvedBinding(for: slot)
        let title = action?.title ?? (unresolved == nil ? "Assign an action" : "Core action")
        let enabled = unresolved?.enabled ?? true

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("\(slot.marks)  \(slot.countName)").font(PipTheme.cardLabel)
                Spacer()
                if model.recognizedSlot == slot {
                    Label("Recognized", systemImage: "checkmark")
                        .font(PipTheme.caption)
                }
                if model.running.contains(slot.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("Action running")
                }
            }
            Button {
                picking = slot
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: action?.icon ?? (unresolved == nil ? "plus.circle" : "gearshape"))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(PipTheme.cardLabel)
                        Text(action?.detail ?? (unresolved == nil
                             ? "Choose something useful"
                             : "Existing binding · \(enabled ? "Enabled" : "Disabled")"))
                            .font(PipTheme.caption)
                            .foregroundStyle(PipTheme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(slot.title), \(title), \(enabled ? "enabled" : "disabled")")
            .accessibilityHint("Change this action")

            HStack {
                Button {
                    Task { await model.run(slot) }
                } label: {
                    Label("Run", systemImage: "play")
                }
                .help("Run this action without a physical tap")
                .disabled((action == nil && unresolved == nil) || !enabled
                          || model.running.contains(slot.id))
                Spacer()
                Menu {
                    Button("Change…") { picking = slot }
                    Menu("Duplicate to…") {
                        ForEach(PipSlot.all.filter { $0 != slot }) { destination in
                            Button(destination.title) {
                                Task { _ = await model.assign(action, to: destination) }
                            }
                            .disabled(action == nil)
                        }
                    }
                    Button("Clear", role: .destructive) {
                        Task { _ = await model.assign(nil, to: slot) }
                    }
                    .disabled(action == nil && unresolved == nil)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More options for \(slot.title)")
            }
            .controlSize(.small)
        }
        .pipCard(emphasized: model.recognizedSlot == slot)
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Test taps", systemImage: "waveform.path")
                    .font(PipTheme.cardLabel)
                Spacer()
                Toggle("Also run actions", isOn: $model.alsoRunActions)
                    .disabled(!model.canListen)
                Button("Done") { model.testing = false }
            }
            Text(model.canListen
                 ? "Recognized gestures highlight their card. Actions stay off unless you opt in."
                 : "Live diagnostic events aren’t connected in this build.")
                .foregroundStyle(PipTheme.secondary)
            if model.alsoRunActions {
                Label("Assigned actions, including scripts, can run during this session.",
                      systemImage: "exclamationmark.triangle")
            }
            PipWaveform(points: model.envelope)
            DisclosureGroup("Event details", isExpanded: $showDiagnostics) {
                ForEach(model.diagnostics.suffix(8).reversed()) { entry in
                    HStack {
                        Text(entry.text)
                        Spacer()
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                        if let delay = entry.delay {
                            Text("\(Int(delay * 1000)) ms dispatch delay")
                        }
                    }
                    .font(PipTheme.mono)
                }
                if model.diagnostics.isEmpty { Text("No diagnostic events yet.") }
            }
        }
        .pipCard()
    }

    private var utilityStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Sensitivity…") { sensitivity = true }
                Button(model.testing ? "Stop testing" : "Test taps") {
                    model.alsoRunActions = false
                    model.testing.toggle()
                }
                Button("Presets…") { presets = true }
            }
            Label(model.lastResult, systemImage: model.lastResult.contains("Failed:") ? "exclamationmark.circle" : "checkmark.circle")
                .font(PipTheme.caption)
                .textSelection(.enabled)
                .accessibilityLabel("Last action result: \(model.lastResult)")
        }
        .padding(16)
    }

    private var presetSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Start with a good map.").font(PipTheme.title)
            Picker("Preset", selection: $selectedPreset) {
                ForEach(PipPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            PipPresetPreview(preset: selectedPreset)
            Text("Applying a preset replaces the six current assignments.")
                .foregroundStyle(PipTheme.secondary)
            HStack {
                Button("Cancel") { presets = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use \(selectedPreset.rawValue)") {
                    Task {
                        if await model.applyPreset(selectedPreset) {
                            presets = false
                            if selectedPreset == .canvas {
                                picking = PipSlot(side: .right, count: 3)
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 570)
        .background(PipTheme.canvas)
    }
}

public struct PipPresetPreview: View {
    public let preset: PipPreset
    public init(preset: PipPreset) { self.preset = preset }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            ForEach(PipSlot.all) { slot in
                GridRow {
                    Text(slot.title).foregroundStyle(PipTheme.secondary)
                    Text(preset.action(for: slot)?.title
                         ?? (slot.side == .right && slot.count == 3
                             ? "Choose a Shortcut…" : "Unassigned"))
                }
            }
        }
        .font(PipTheme.body)
        .pipCard()
    }
}

public struct PipSensitivityView: View {
    @EnvironmentObject private var model: PipViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = PipSensitivity()
    @State private var tuneEachSide = false
    @State private var applying = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A gentle touch. A little room.").font(PipTheme.title)
            Text(model.bridge.sensitivityExplanation
                 ?? "Sensitivity is unavailable until the engine exposes its supported parameter range. Your detector defaults haven’t been changed.")
                .foregroundStyle(PipTheme.secondary)

            VStack {
                Slider(value: $settings.overall, in: 0...1) {
                    Text("Tap sensitivity")
                }
                HStack {
                    Text("Firmer taps")
                    Spacer()
                    Text("Lighter taps")
                }
            }
            DisclosureGroup("Tune each side", isExpanded: $tuneEachSide) {
                Slider(value: $settings.left, in: 0...1) { Text("Left side") }
                Slider(value: $settings.right, in: 0...1) { Text("Right side") }
            }
            Toggle("Typing protection", isOn: $settings.typingProtection)
            if !settings.typingProtection {
                Label("Typing may trigger actions with protection off.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(PipTheme.error)
            }
            Toggle("Swap sides", isOn: $settings.swapSides)
            PipWaveform(points: model.envelope)

            HStack {
                Button("Restore defaults") { settings = PipSensitivity() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        applying = true
                        defer { applying = false }
                        do {
                            if let apply = model.bridge.applySensitivity {
                                try await apply(model.input, settings)
                                model.preferences.sensitivity[model.input.rawValue] = settings
                                if model.savePreferences() { dismiss() }
                            }
                        } catch { model.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.bridge.applySensitivity == nil || applying)
            }
        }
        .padding(24)
        .frame(width: 590)
        .background(PipTheme.canvas)
        .onAppear {
            settings = model.preferences.sensitivity[model.input.rawValue] ?? PipSensitivity()
        }
        // Without a bounded engine transformation these controls must not pretend
        // that a cosmetic percentage adjusts detection.
        .disabled(applying)
    }
}


