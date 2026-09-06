import SwiftUI
import AppKit
import ServiceManagement
import PipDomain
import PipEngineAdapter

/// Illustrative practice, not calibration evidence.
///
/// ReplaySource exposes start/stop but no subscription signature in the supplied
/// API. The source lifecycle is real; the visible demo uses an explicit local
/// clock, rather than inventing a stream member or pretending these are samples.
@MainActor
public final class PipPracticeDemo: ObservableObject {
    @Published public private(set) var completed = 0
    @Published public private(set) var side = PipSide.left
    @Published public private(set) var compressed = false
    @Published public private(set) var annotation = "Illustrative replay · no sensor data"
    @Published public private(set) var points: [PipEnvelopePoint] = []
    @Published public private(set) var playing = false

    private let source = ReplaySource(steps: [])
    private var task: Task<Void, Never>?

    public init() {}

    public func play() {
        stop()
        completed = 0
        playing = true
        task = Task {
            await source.start()
            defer { playing = false }
            for index in 0..<8 {
                do { try await Task.sleep(for: .seconds(1.3)) }
                catch { return }
                side = index < 3 || index == 6 ? .left : .right
                let count = index < 6 ? 1 : (index == 6 ? 2 : 3)

                // Envelope generation is off-main. A real adapter must use
                // two seconds of min/max bins at <=30 fps, not raw samples.
                points = await Task.detached {
                    (0..<100).map { sample in
                        let baseline = 0.018 * sin(Double(sample) * 1.7)
                        let impulse = (0..<count).map { tap -> Double in
                            let distance = Double(sample - (45 + tap * 12))
                            return 0.86 * exp(-distance * distance / 2.5)
                        }.max() ?? 0
                        return PipEnvelopePoint(
                            id: sample, low: baseline - impulse * 0.6,
                            high: baseline + impulse
                        )
                    }
                }.value
                compressed = true
                completed = index + 1
                annotation = index < 6
                    ? "\(side.title) tap. Got it. · Demo"
                    : "\(side.title) · \(count == 2 ? "Double" : "Triple") · Demo"
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                compressed = false
            }
            await source.finish()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        playing = false
        compressed = false
        Task { await source.stop() }
    }
}

public struct OnboardingView: View {
    @EnvironmentObject private var model: PipViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @StateObject private var demo = PipPracticeDemo()

    @State private var step = 0
    @State private var typedSentence = ""
    @State private var inputAllowed = PipPermissions.inputAllowed
    @State private var accessibilityAllowed = PipPermissions.accessibilityAllowed
    @State private var restartNeeded = false
    @State private var preset = PipPreset.everyday
    @State private var presetApplied = false
    @State private var choosingShortcut = false
    @State private var busy = false
    @State private var launchAtLogin = false
    @State private var sensitivity = false
    @State private var message: String?
    @State private var setupStarted = false

    private let labels = [
        "Meet Pip", "Permissions", "Practice",
        "Typing protection", "Your map", "Ready"
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    demo.stop()
                    step = max(0, step - 1)
                    persistProgress()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(step == 0 || busy)
                Spacer()
                Text("Step \(step + 1) of 6 · \(labels[step])")
                    .foregroundStyle(PipTheme.secondary)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    screen
                    if let message {
                        Label(message, systemImage: "info.circle")
                            .font(PipTheme.body)
                            .foregroundStyle(PipTheme.secondary)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(PipTheme.error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            Divider()
            footer.padding(24)
        }
        .font(PipTheme.body)
        .foregroundStyle(PipTheme.ink)
        .background(PipTheme.canvas)
        .tint(PipTheme.accent)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 500, idealHeight: 560)
        .task {
            await model.load()
            guard !setupStarted else { return }
            setupStarted = true
            step = min(max(model.preferences.onboardingStep, 0), 5)
            await model.beginSetup()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .task(id: step) {
            guard step == 1 else { return }
            while !Task.isCancelled {
                recheckPermissions()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if step == 1 { recheckPermissions() }
        }
        .onDisappear {
            demo.stop()
            typedSentence = ""
            Task { await model.endSetup(startListening: false) }
        }
        .sheet(isPresented: $choosingShortcut) {
            ActionPickerView(slot: PipSlot(side: .right, count: 3),
                             initial: PipAction(kind: .shortcut))
                .environmentObject(model)
        }
        .sheet(isPresented: $sensitivity) {
            PipSensitivityView().environmentObject(model)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch step {
        case 0:
            title("Meet your Mac’s new little trick.")
            PipMacBook()
            Text("Tap either side of your MacBook to do something useful.\nStart gently. Pip listens for a tap—not a knock.")
            if !model.canListen {
                Label("Pip couldn’t probe the sensor in this build.", systemImage: "exclamationmark.circle")
                    .pipCard()
                Text("That doesn’t mean your Mac is unsupported. The live engine bridge still needs to be connected.")
                    .foregroundStyle(PipTheme.secondary)
                HStack {
                    Button("Retry") {
                        message = "The live engine bridge is still unavailable. You can try the illustrated demo or build a map without listening."
                    }
                    DisclosureGroup("Diagnostics") {
                        Text("No sensor-open or diagnostic subscription API was supplied to this UI target. No hardware support claim has been made.")
                            .font(PipTheme.mono)
                            .textSelection(.enabled)
                    }
                }
            }
            Button("Set up trackpad gestures instead") {
                Task { await model.setInput(.trackpad) }
            }
            Text("Trackpad mode requires verified hit regions and Option held while tapping. Ordinary clicks aren’t a substitute.")
                .font(PipTheme.caption)
                .foregroundStyle(PipTheme.secondary)

        case 1:
            title("Give Pip permission to listen.")
            permissionRow(
                "Input Monitoring",
                purpose: "Helps Pip avoid reacting while you type and supports trackpad input.",
                allowed: inputAllowed
            ) {
                PipPermissions.requestInput()
                recheckPermissions()
            }
            permissionRow(
                "Accessibility",
                purpose: "Lets Pip send keyboard controls to your Mac and other apps.",
                allowed: accessibilityAllowed
            ) {
                PipPermissions.requestAccessibility()
                recheckPermissions()
            }
            Text("Pip doesn’t save what you type. Input activity is used only to suppress accidental gestures.")
                .foregroundStyle(PipTheme.secondary)
            Text("These are macOS permission checks. Listening remains paused until the actual engine confirms it can start.")
                .font(PipTheme.caption)
            if restartNeeded {
                Label("Restart needed", systemImage: "arrow.clockwise")
                Button("Quit and reopen Pip") { reopen() }
            }
            DisclosureGroup("Changed a permission, but Pip still can’t listen?") {
                Text("Some event taps need a fresh process after a permission change. Save your progress and reopen Pip.")
                Button("Mark restart needed") { restartNeeded = true }
            }

        case 2:
            title("Tap here.")
            PipMacBook(activeSide: demo.side, compressed: demo.compressed)
            PipWaveform(points: demo.points, annotation: demo.annotation)
            Text(demo.completed < 3
                 ? "Rest your MacBook on a steady surface.\nGive the left edge one gentle tap."
                 : "Now try the right edge. Start gently.")
            HStack(spacing: 12) {
                ForEach(0..<6) { index in
                    Image(systemName: demo.completed > index ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(PipTheme.accent)
                        .accessibilityLabel("\(index < 3 ? "Left" : "Right") practice tap \(index % 3 + 1), \(demo.completed > index ? "shown in demo" : "not shown")")
                }
                Spacer()
                Button(demo.playing ? "Stop demo" : "Play practice demo") {
                    if demo.playing { demo.stop() } else { demo.play() }
                }
            }
            Text("After singles, try one double tap and one triple tap.\nPip waits a short beat to tell one tap from two or three.")
            Label("Illustrative replay. No actions run and no sensitivity is learned.",
                  systemImage: "play.rectangle")
                .font(PipTheme.caption)
            Text("Real calibration keeps the engine’s side classifier and grouping interval. If the evidence is weak: “Let’s try a firmer tap.”")
                .font(PipTheme.caption)
                .foregroundStyle(PipTheme.secondary)
            Button("Swap left and right") {
                message = "Side swapping is available with the verified sensor calibration bridge. The demo doesn’t change your detector."
            }

        case 3:
            title("Try it while you type.")
            Text("Type this: A small tap. A useful little trick.")
            TextField("Type here — this stays in this window", text: $typedSentence)
                .textFieldStyle(.roundedBorder)
                .onSubmit { typedSentence = "" }
            Label(
                model.canListen ? "Typing protection on" : "Typing protection · not yet verified",
                systemImage: "shield.lefthalf.filled"
            )
            .pipPill()
            PipWaveform(points: model.envelope)
            Text("Then stop typing and try a tap. Pip should notice the tap, not the sentence.")
            Text("Desk bumps and some typing patterns can still get through. If that happens, choose firmer taps and recalibrate.")
                .foregroundStyle(PipTheme.secondary)
            if !model.canListen {
                Text("This demo can’t prove suppression or recovery. Keep listening paused until you’ve tried both on your Mac.")
                    .font(PipTheme.caption)
            }
            Button("Adjust sensitivity…") { sensitivity = true }

        case 4:
            title("Start with a good map.")
            Picker("Preset pack", selection: $preset) {
                ForEach(PipPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: preset) { _, _ in presetApplied = false }
            PipPresetPreview(preset: preset)
            if preset == .canvas {
                Text("An empty starting point, not six automations you don’t own.")
                Button("Choose a Shortcut for Right · Triple…") {
                    Task {
                        if !presetApplied {
                            presetApplied = await model.applyPreset(.canvas)
                        }
                        if presetApplied { choosingShortcut = true }
                    }
                }
                if let action = model.action(for: PipSlot(side: .right, count: 3)) {
                    Label(action.title, systemImage: action.icon)
                }
            } else {
                Text("Singles stay reversible and low-stakes. You can change any binding in the Tap Map.")
                    .foregroundStyle(PipTheme.secondary)
            }

        default:
            title("You’re set.")
            HStack {
                PipMenuGlyph(paused: true, failed: false)
                    .frame(width: 28, height: 20)
                Text("Look for these little contact marks in your menu bar.")
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PipSlot.all) { slot in
                    HStack {
                        Text(slot.title).frame(width: 110, alignment: .leading)
                        Text(model.action(for: slot)?.title ?? "Assign an action")
                        Spacer()
                    }
                }
            }
            .pipCard()
            Toggle("Launch Pip at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        // Verify SMAppService with a signed .app bundle, not swift run.
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        message = "Login launch couldn’t be changed: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Quiet tap sound", isOn: $model.preferences.quietSound)
                .disabled(true)
            Text("Sound is reserved for the verified feedback adapter. This source-only milestone has no bundled, speaker-tested tick asset.")
                .font(PipTheme.caption)
                .foregroundStyle(PipTheme.secondary)
            if !model.canListen {
                Label("Your map is ready. Listening will stay paused in this demo build.",
                      systemImage: "pause.circle")
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(PipTheme.title).accessibilityAddTraits(.isHeader)
    }

    private func permissionRow(
        _ name: String, purpose: String, allowed: Bool,
        request: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: allowed ? "checkmark.circle" : "lock.circle")
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(PipTheme.cardLabel)
                Text(purpose).foregroundStyle(PipTheme.secondary)
                Text(allowed ? "Allowed" : "Not allowed").font(PipTheme.caption)
            }
            Spacer()
            Button(allowed ? "Open Settings…" : "Allow…", action: request)
        }
        .pipCard()
    }

    private var footer: some View {
        HStack {
            if step == 1 {
                Button("Set up without listening") {
                    Task {
                        model.preferences.completedOnboarding = true
                        model.preferences.onboardingStep = 4
                        guard model.savePreferences() else { return }
                        await finish(startListening: false)
                    }
                }
            } else {
                Text("Actions stay off during setup.")
                    .font(PipTheme.caption)
                    .foregroundStyle(PipTheme.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(primaryTitle) {
                Task { await next() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(busy || (step == 4 && preset == .canvas &&
                model.action(for: PipSlot(side: .right, count: 3))?.kind != .shortcut))
        }
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "Try a tap"
        case 2: return "Continue"
        case 3: return model.canListen ? "That feels right" : "Continue with listening paused"
        case 4: return "Use this map"
        case 5: return model.canListen ? "Start listening" : "Open Tap Map"
        default: return "Continue"
        }
    }

    private func next() async {
        busy = true
        defer { busy = false }
        if step == 4 && !presetApplied {
            guard await model.applyPreset(preset) else { return }
            presetApplied = true
        }
        if step == 5 {
            model.preferences.completedOnboarding = true
            guard model.savePreferences() else { return }
            await finish(startListening: model.canListen)
            return
        }
        demo.stop()
        if step == 3 { typedSentence = "" }
        step += 1
        message = nil
        persistProgress()
    }

    private func persistProgress() {
        model.preferences.onboardingStep = step
        model.savePreferences()
    }

    private func recheckPermissions() {
        inputAllowed = PipPermissions.inputAllowed
        accessibilityAllowed = PipPermissions.accessibilityAllowed
    }

    private func finish(startListening: Bool) async {
        demo.stop()
        typedSentence = ""
        await model.endSetup(startListening: startListening)
        openWindow(id: "tap-map")
        dismiss()
    }

    private func reopen() {
        persistProgress()
        guard model.savePreferences() else { return }
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            message = "Quit Pip, then launch it again from your development command. Your progress is saved."
            return
        }
        // Verify relaunch handoff and TCC restart behavior in the signed app.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { message = error.localizedDescription }
                else { NSApplication.shared.terminate(nil) }
            }
        }
    }
}
