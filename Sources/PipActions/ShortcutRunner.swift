import Foundation
import PipDomain
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessRequest: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval
    public let tailLimit: Int

    public init(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 300,
        tailLimit: Int = 64 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.tailLimit = tailLimit
    }
}

public struct ProcessOutcome: Equatable, Sendable {
    public enum Termination: Equatable, Sendable {
        case exited
        case timedOut
        case cancelled
        case launchFailed(String)
    }

    public let termination: Termination
    public let exitStatus: Int32?
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public init(
        termination: Termination = .exited,
        exitStatus: Int32? = 0,
        stdout: Data = Data(),
        stderr: Data = Data(),
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.termination = termination
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    public var actionResult: ActionResult {
        let status: ActionResult.Status
        let message: String
        switch termination {
        case .cancelled:
            status = .cancelled
            message = "Cancelled."
        case .timedOut:
            status = .failed
            message = "The action exceeded its time limit."
        case .launchFailed(let reason):
            status = .failed
            message = "Could not launch the process: \(reason)"
        case .exited:
            // Output text is diagnostic only; do not infer success from its wording.
            if exitStatus == 0 {
                status = .completed
                message = "Completed."
            } else {
                status = .failed
                message = exitStatus.map { "Process exited with status \($0)." }
                    ?? "Process ended without an exit status."
            }
        }
        return ActionResult(
            status,
            message: message,
            exitStatus: exitStatus,
            stdoutTail: String(decoding: stdout, as: UTF8.self),
            stderrTail: String(decoding: stderr, as: UTF8.self)
        )
    }
}

public protocol RunningProcess: Sendable {
    func run(_ request: ProcessRequest) async -> ProcessOutcome
}

public protocol ProcessFactory: Sendable {
    func makeProcess() -> any RunningProcess
}

public struct FoundationProcessFactory: ProcessFactory {
    public init() {}

    public func makeProcess() -> any RunningProcess {
        FoundationRunningProcess()
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct ByteTail {
    let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false

    mutating func append(_ bytes: UnsafeRawBufferPointer, count: Int) {
        guard count > 0 else { return }
        data.append(bytes.bindMemory(to: UInt8.self).baseAddress!, count: count)
        if data.count > limit {
            data.removeFirst(data.count - limit)
            truncated = true
        }
    }
}

private struct FoundationRunningProcess: RunningProcess {
    func run(_ request: ProcessRequest) async -> ProcessOutcome {
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled { cancellation.cancel() }
            return await Task.detached(priority: .utility) {
                Self.execute(request, cancellation: cancellation)
            }.value
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// All Process operations and pipe reads occur on a worker, never the main thread.
    /// POSIX pipe draining is supported on Darwin/Linux; macOS CLI behavior needs
    /// on-device verification. Termination covers the direct process, not its descendants.
    private static func execute(
        _ request: ProcessRequest,
        cancellation: CancellationFlag
    ) -> ProcessOutcome {
        guard request.timeout.isFinite, request.timeout > 0, request.tailLimit > 0 else {
            return ProcessOutcome(
                termination: .launchFailed("Invalid timeout or capture limit."),
                exitStatus: nil
            )
        }
        if cancellation.isCancelled {
            return ProcessOutcome(termination: .cancelled, exitStatus: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        }

        let outFD = outputHandle.fileDescriptor
        let errFD = errorHandle.fileDescriptor
        guard makeNonblocking(outFD), makeNonblocking(errFD) else {
            return ProcessOutcome(
                termination: .launchFailed("Could not configure nonblocking pipes."),
                exitStatus: nil
            )
        }

        do {
            try process.run()
        } catch {
            return ProcessOutcome(
                termination: .launchFailed(error.localizedDescription),
                exitStatus: nil
            )
        }
        // The parent must not keep an extra writer open.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        var stdout = ByteTail(limit: request.tailLimit)
        var stderr = ByteTail(limit: request.tailLimit)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var stopReason: ProcessOutcome.Termination?
        var terminationSentAt: TimeInterval?
        var sentKill = false

        while process.isRunning {
            // Bounded work per pipe prevents one noisy stream starving the other
            // or preventing timeout/cancellation checks.
            drain(outFD, into: &stdout)
            drain(errFD, into: &stderr)

            let now = ProcessInfo.processInfo.systemUptime
            if stopReason == nil {
                if cancellation.isCancelled {
                    stopReason = .cancelled
                } else if now - startedAt >= request.timeout {
                    stopReason = .timedOut
                }
                if stopReason != nil, process.isRunning {
                    process.terminate()
                    terminationSentAt = now
                }
            }
            if let sentAt = terminationSentAt,
               now - sentAt >= 1,
               !sentKill,
               process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                sentKill = true
            }
            usleep(5_000)
        }

        process.waitUntilExit()
        // Nonblocking final drains capture pending bytes without waiting forever
        // for an unrelated descendant that inherited a pipe.
        drain(outFD, into: &stdout, passes: 256)
        drain(errFD, into: &stderr, passes: 256)

        return ProcessOutcome(
            termination: stopReason ?? .exited,
            exitStatus: process.terminationStatus,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated
        )
    }

    private static func makeNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
    }

    private static func drain(_ fd: Int32, into tail: inout ByteTail, passes: Int = 16) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<passes {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!, raw.count)
            }
            if count <= 0 { break }
            buffer.withUnsafeBytes { tail.append($0, count: count) }
        }
    }
}

/// Share one limiter across all process-backed executors in an application.
public actor ActionConcurrencyLimiter {
    private let maximumGlobal: Int
    private var activeBindings = Set<UUID>()

    public init(maximumGlobal: Int = 2) {
        self.maximumGlobal = max(1, min(2, maximumGlobal))
    }

    /// nil means admission succeeded. There is no queue of stale gestures.
    public func acquire(bindingID: UUID) -> ActionResult? {
        if activeBindings.contains(bindingID) {
            return ActionResult(.busy, message: "Already running")
        }
        guard activeBindings.count < maximumGlobal else {
            return ActionResult(.busy, message: "Two actions are already running.")
        }
        activeBindings.insert(bindingID)
        return nil
    }

    public func release(bindingID: UUID) {
        activeBindings.remove(bindingID)
    }
}

public actor ShortcutRunner {
    private let factory: any ProcessFactory
    private let discovery: ShortcutDiscovery
    private let limiter: ActionConcurrencyLimiter

    public init(
        factory: any ProcessFactory = FoundationProcessFactory(),
        discovery: ShortcutDiscovery? = nil,
        limiter: ActionConcurrencyLimiter = ActionConcurrencyLimiter()
    ) {
        self.factory = factory
        self.discovery = discovery ?? ShortcutDiscovery(factory: factory)
        self.limiter = limiter
    }

    public nonisolated static func runRequest(
        exactName: String,
        inputFile: URL? = nil,
        timeout: TimeInterval = 300
    ) -> ProcessRequest {
        var arguments = ["run", exactName]
        if let inputFile {
            arguments += ["--input-path", inputFile.path]
        }
        return ProcessRequest(
            executable: "/usr/bin/shortcuts",
            arguments: arguments,
            timeout: timeout
        )
    }

    public func run(
        bindingID: UUID,
        exactName: String,
        literalInput: String? = nil,
        timeout: TimeInterval = 300
    ) async -> ActionResult {
        if Task.isCancelled { return ActionResult(.cancelled, message: "Cancelled.") }
        if let rejection = await limiter.acquire(bindingID: bindingID) { return rejection }

        let result = await runAdmitted(
            exactName: exactName,
            literalInput: literalInput,
            timeout: timeout
        )
        await limiter.release(bindingID: bindingID)
        return result
    }

    /// The same admission rules apply to shell scripts and screencapture.
    public func runProcess(
        bindingID: UUID,
        request: ProcessRequest
    ) async -> ActionResult {
        if Task.isCancelled { return ActionResult(.cancelled, message: "Cancelled.") }
        if let rejection = await limiter.acquire(bindingID: bindingID) { return rejection }
        let outcome = await factory.makeProcess().run(request)
        await limiter.release(bindingID: bindingID)
        return outcome.actionResult
    }

    private func runAdmitted(
        exactName: String,
        literalInput: String?,
        timeout: TimeInterval
    ) async -> ActionResult {
        do {
            try ActionKind.runShortcut(name: exactName, input: literalInput).validate()
            // Refresh on execution: a previously cached Shortcut may have been removed.
            // Swift String equality is Unicode-canonical; compare UTF-8 bytes for an
            // exact CLI name rather than accepting a normalized or fuzzy substitute.
            let names = try await discovery.refresh()
            guard names.contains(where: { $0.utf8.elementsEqual(exactName.utf8) }) else {
                return ActionResult(
                    .unavailable,
                    message: "Shortcut missing: “\(exactName)”. Choose an exact name from Refresh."
                )
            }
            if Task.isCancelled { return ActionResult(.cancelled, message: "Cancelled.") }

            var temporaryDirectory: URL?
            defer {
                if let temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
            }

            var inputFile: URL?
            if let literalInput {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Pip-Shortcut-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                temporaryDirectory = directory
                let file = directory.appendingPathComponent("input.txt")
                try Data(literalInput.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: file.path
                )
                inputFile = file
            }

            let outcome = await factory.makeProcess().run(
                Self.runRequest(exactName: exactName, inputFile: inputFile, timeout: timeout)
            )
            return outcome.actionResult
        } catch let error as ShortcutDiscoveryError {
            switch error {
            case .commandFailed(let result):
                return result
            default:
                return ActionResult(.failed, message: error.localizedDescription)
            }
        } catch {
            return ActionResult(
                Task.isCancelled ? .cancelled : .failed,
                message: error.localizedDescription
            )
        }
    }
}
