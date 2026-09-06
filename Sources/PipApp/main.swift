import Foundation
import PipDomain
import PipActions
import PipPersistence
import PipEngineAdapter

#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

// macOS-only bootstrap menu bar UI; AppKit lifecycle requires device verification.
// Hardware and trackpad capture are intentionally not advertised as active.
@MainActor
final class BootstrapModel: ObservableObject {
    @Published var status = "Replay mode · sensor capture not active"
    private var replayTask: Task<Void, Never>?

    func replay() {
        guard replayTask == nil else { return }
        replayTask = Task {
            defer { replayTask = nil }
            do {
                let preset = try PresetPack.everyday()
                let store = InMemoryBindingStore(bindings: preset.bindings)
                let control = PipControl(inputMode: .replay)
                let router = GestureRouter(store: store, control: control)
                let dispatcher = ActionDispatcher(control: control)
                let source = ReplaySource(steps: [
                    ReplayStep(event: GestureEvent(
                        gesture: Gesture(side: .left, count: .single),
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        inputMode: .replay
                    ))
                ])
                var iterator = source.events.makeAsyncIterator()
                await source.start()
                if let event = await iterator.next(),
                   let accepted = await router.route(event) {
                    let result = await dispatcher.dispatch(accepted)
                    status = "\(result.status.rawValue): \(result.message)"
                }
                await source.finish()
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

@main
struct PipApplication: App {
    @StateObject private var model = BootstrapModel()

    var body: some Scene {
        MenuBarExtra("Pip", systemImage: "hand.tap") {
            Text(model.status)
            Button("Replay left single tap") { model.replay() }
            Divider()
            Button("Quit Pip") { NSApplication.shared.terminate(nil) }
        }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
#else
@main
enum PipApplication {
    static func main() async {
        do {
            let preset = try PresetPack.everyday()
            let store = InMemoryBindingStore(bindings: preset.bindings)
            let router = GestureRouter(
                store: store,
                control: PipControl(inputMode: .replay)
            )
            let source = ReplaySource(steps: [
                ReplayStep(event: GestureEvent(
                    gesture: Gesture(side: .left, count: .single),
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    inputMode: .replay
                ))
            ])
            var iterator = source.events.makeAsyncIterator()
            await source.start()
            if let event = await iterator.next(),
               let accepted = await router.route(event) {
                print("Replay accepted: \(accepted.binding.slot.side.rawValue) single tap.")
                print("The menu bar and OS actions require macOS.")
            }
            await source.finish()
        } catch {
            print("Pip failed: \(error.localizedDescription)")
        }
    }
}
#endif
