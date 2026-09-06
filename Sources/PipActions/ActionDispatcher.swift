import Foundation
import PipDomain
#if canImport(AppKit)
import AppKit
#endif

/// Implementations own permission probes and return permissionRequired when needed.
/// This is the intentional OS boundary for media keys, volume, mute and synthetic
/// keyboard events; those facilities require on-device verification.
public protocol SystemActionExecuting: Sendable {
    func execute(_ action: ActionKind) async -> ActionResult
}

public protocol ApplicationOpening: Sendable {
    func openURL(_ url: URL) async -> ActionResult
    func openApplication(bundleID: String) async -> ActionResult
}

public struct WorkspaceOpener: ApplicationOpening {
    public init() {}

    public func openURL(_ url: URL) async -> ActionResult {
        #if canImport(AppKit)
        // macOS-only: Launch Services dispatch must be verified on-device.
        return await MainActor.run {
            NSWorkspace.shared.open(url)
                ? ActionResult(.launched, message: "URL handed to its application.")
                : ActionResult(.failed, message: "No application accepted this URL.")
        }
        #else
        return ActionResult(.unavailable, message: "Opening URLs requires macOS.")
        #endif
    }

    public func openApplication(bundleID: String) async -> ActionResult {
        #if canImport(AppKit)
        // macOS-only: application discovery and launch require on-device verification.
        return await Self.launchApplication(bundleID: bundleID)
        #else
        return ActionResult(.unavailable, message: "Opening applications requires macOS.")
        #endif
    }

    #if canImport(AppKit)
    @MainActor
    private static func launchApplication(bundleID: String) async -> ActionResult {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            return ActionResult(.unavailable, message: "Application not installed: \(bundleID)")
        }

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { application, error in
                if let error {
                    continuation.resume(returning: ActionResult(
                        .failed, message: error.localizedDescription
                    ))
                } else if application != nil {
                    continuation.resume(returning: ActionResult(
                        .launched, message: "Application launched."
                    ))
                } else {
                    continuation.resume(returning: ActionResult(
                        .failed, message: "Launch Services returned no application."
                    ))
                }
            }
        }
    }
    #endif
}

public struct FeedbackEntry: Equatable, Sendable {
    public let groupID: UUID
    public let bindingID: UUID
    public let result: ActionResult

    public init(groupID: UUID, bindingID: UUID, result: ActionResult) {
        self.groupID = groupID
        self.bindingID = bindingID
        self.result = result
    }
}

public protocol FeedbackCoordinating: Sendable {
    func report(_ result: ActionResult, for gesture: RoutedGesture) async
}

/// UI can consume updates without depending on executor implementations.
/// Every update carries a textual status/message, not just a color.
public actor FeedbackCoordinator: FeedbackCoordinating {
    public nonisolated let updates: AsyncStream<FeedbackEntry>
    private let continuation: AsyncStream<FeedbackEntry>.Continuation
    private let historyLimit: Int
    private var entries: [FeedbackEntry] = []

    public init(historyLimit: Int = 100) {
        let stream = AsyncStream<FeedbackEntry>.makeStream(bufferingPolicy: .bufferingNewest(100))
        updates = stream.stream
        continuation = stream.continuation
        self.historyLimit = max(1, historyLimit)
    }

    deinit {
        continuation.finish()
    }

    public func report(_ result: ActionResult, for gesture: RoutedGesture) {
        let entry = FeedbackEntry(
            groupID: gesture.event.groupID,
            bindingID: gesture.binding.id,
            result: result
        )
        entries.append(entry)
        if entries.count > historyLimit {
            entries.removeFirst(entries.count - historyLimit)
        }
        continuation.yield(entry)
    }

    public func history() -> [FeedbackEntry] {
        entries
    }
}

public actor ActionDispatcher {
    private let runner: ShortcutRunner
    private let opener: any ApplicationOpening
    private let systemExecutor: (any SystemActionExecuting)?
    private let control: PipControl
    private let feedback: any FeedbackCoordinating
    private let limiter: ActionConcurrencyLimiter

    public init(
        control: PipControl,
        feedback: any FeedbackCoordinating = FeedbackCoordinator(),
        factory: any ProcessFactory = FoundationProcessFactory(),
        opener: any ApplicationOpening = WorkspaceOpener(),
        systemExecutor: (any SystemActionExecuting)? = nil,
        limiter: ActionConcurrencyLimiter = ActionConcurrencyLimiter()
    ) {
        self.control = control
        self.feedback = feedback
        self.opener = opener
        self.systemExecutor = systemExecutor
        self.limiter = limiter
        self.runner = ShortcutRunner(factory: factory, limiter: limiter)
    }

    @discardableResult
    public func dispatch(_ gesture: RoutedGesture) async -> ActionResult {
        let result: ActionResult
        do {
            try gesture.binding.action.validate()
            result = await execute(gesture.binding)
        } catch {
            result = ActionResult(.failed, message: error.localizedDescription)
        }
        await feedback.report(result, for: gesture)
        return result
    }

    private func execute(_ binding: Binding) async -> ActionResult {
        if Task.isCancelled { return ActionResult(.cancelled, message: "Cancelled.") }

        switch binding.action {
        case .runShortcut(let name, let input):
            return await runner.run(
                bindingID: binding.id, exactName: name, literalInput: input
            )
        case .runShellScript(let script):
            #if os(macOS)
            // Deliberately a shell ONLY for the explicitly selected shell-script action.
            // macOS-only: zsh environment and user-script behavior need device testing.
            return await runner.runProcess(
                bindingID: binding.id,
                request: ProcessRequest(executable: "/bin/zsh", arguments: ["-c", script])
            )
            #else
            return ActionResult(.unavailable, message: "Pip shell actions require macOS zsh.")
            #endif
        case .screenshotInteractiveToClipboard:
            #if os(macOS)
            // macOS-only: interactive capture/Screen Recording policy needs device testing.
            return await runner.runProcess(
                bindingID: binding.id,
                request: ProcessRequest(
                    executable: "/usr/sbin/screencapture", arguments: ["-i", "-c"]
                )
            )
            #else
            return ActionResult(.unavailable, message: "Screenshot capture requires macOS.")
            #endif
        case .pausePip(let minutes):
            // Control actions are immediate and remain available when two jobs run.
            do {
                try await control.pause(minutes: minutes)
                return ActionResult(.completed, message: "Pip paused for \(minutes) minutes.")
            } catch {
                return ActionResult(.failed, message: error.localizedDescription)
            }
        default:
            // Also bound asynchronous OS implementations, not just external processes.
            if let rejection = await limiter.acquire(bindingID: binding.id) {
                return rejection
            }
            let result = await executeOSAction(binding.action)
            await limiter.release(bindingID: binding.id)
            return result
        }
    }

    private func executeOSAction(_ action: ActionKind) async -> ActionResult {
        switch action {
        case .openURL(let text):
            guard let url = URL(string: text) else {
                return ActionResult(.failed, message: "Invalid URL.")
            }
            return await opener.openURL(url)
        case .openApplication(let bundleID):
            return await opener.openApplication(bundleID: bundleID)
        case .playPause, .previousTrack, .nextTrack,
             .volumeUp, .volumeDown, .toggleMute, .pressKeyboardShortcut:
            guard let systemExecutor else {
                return ActionResult(
                    .unavailable,
                    message: "This build has no verified media/keyboard system executor installed."
                )
            }
            return await systemExecutor.execute(action)
        default:
            return ActionResult(.failed, message: "Action reached an incompatible executor.")
        }
    }
}
