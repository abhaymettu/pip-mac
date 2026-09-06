import SwiftUI
import AppKit
import PipUI
import PipDomain
import PipActions
import PipPersistence
import PipEngineAdapter

@MainActor
final class PipApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct PipApplication: App {
    @NSApplicationDelegateAdaptor(PipApplicationDelegate.self) private var delegate
    @StateObject private var model: PipViewModel
    private let feedback: FeedbackCoordinator

    init() {
        let feedback = FeedbackCoordinator(historyLimit: 100)
        self.feedback = feedback

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Pip", isDirectory: true)

        let configuration = PipConfiguration(inputMode: .chassisTaps, bindings: [])

        // ConfigStore has no first-run flag in the supplied API. Keep UI progress
        // in a sibling file; never add undocumented fields to PipConfiguration.
        //
        // EngineAdapter constructors and GestureEventSource subscriptions were
        // omitted. Select a replay lifecycle honestly instead of guessing them.
        // An embedding host can supply .engine(adapter) and PipCoreBridge after
        // verifying permission requirements, Option gating, and pre-dispatch interception.
        let source = PipSourceSelection.replay(ReplaySource(steps: []))
        let viewModel: PipViewModel

        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true
            )
            let store = try ConfigStore(
                fileURL: support.appendingPathComponent("configuration.json"),
                defaultConfiguration: configuration
            )
            viewModel = PipViewModel(
                bindingStore: store,
                configStore: store,
                preferencesURL: support.appendingPathComponent("ui-state.json"),
                feedback: feedback,
                source: source
            )
        } catch {
            viewModel = PipViewModel(
                bindingStore: InMemoryBindingStore(bindings: []),
                configStore: nil,
                preferencesURL: support.appendingPathComponent("ui-state.json"),
                feedback: feedback,
                source: source
            )
            viewModel.error = "Pip couldn’t open its configuration. Existing files haven’t been replaced. \(error.localizedDescription)"
        }
        _model = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        Window("Tap Map", id: "tap-map") {
            PipLaunchView()
                .environmentObject(model)
                .environment(\.pipFeedback, feedback)
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)

        Window("Pip Settings", id: "pip-settings") {
            PipSettingsView()
                .environmentObject(model)
                .environment(\.pipFeedback, feedback)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environment(\.pipFeedback, feedback)
        } label: {
            PipStatusLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct PipLaunchView: View {
    @EnvironmentObject private var model: PipViewModel
    @State private var loaded = false

    var body: some View {
        TapMapView()
            .task {
                guard !loaded else { return }
                loaded = true
                await model.load()
            }
    }
}

private struct PipStatusLabel: View {
    @EnvironmentObject private var model: PipViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compressed = false

    var body: some View {
        PipMenuGlyph(paused: !model.listening, failed: model.recentFailure != nil)
            .scaleEffect(x: reduceMotion ? 1 : (compressed ? 0.9 : 1), y: 1)
            .opacity(reduceMotion && compressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.1), value: compressed)
            .task(id: model.pulse) {
                compressed = true
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                compressed = false
            }
    }
}

