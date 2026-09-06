import Foundation
import XCTest
@testable import PipActions
import PipDomain

private actor FakeProcessController {
    private let names: [String]
    private let suspended: Bool
    private var requests: [ProcessRequest] = []
    private var waiting: [CheckedContinuation<ProcessOutcome, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var executionCount = 0
    private(set) var capturedInputs: [Data] = []

    init(names: [String], suspended: Bool = false) {
        self.names = names
        self.suspended = suspended
    }

    func run(_ request: ProcessRequest) async -> ProcessOutcome {
        requests.append(request)
        if request.arguments == ["list"] {
            return ProcessOutcome(stdout: Data((names.joined(separator: "\n") + "\n").utf8))
        }

        if let flag = request.arguments.firstIndex(of: "--input-path"),
           request.arguments.indices.contains(flag + 1),
           let data = try? Data(contentsOf: URL(fileURLWithPath: request.arguments[flag + 1])) {
            capturedInputs.append(data)
        }

        executionCount += 1
        if !suspended {
            notifyWaiters()
            return ProcessOutcome(
                stdout: Data("done".utf8),
                stderr: Data("diagnostic containing the word error".utf8)
            )
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            notifyWaiters()
        }
    }

    func waitForExecutions(_ count: Int) async {
        if executionCount >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func notifyWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in waiters {
            if executionCount >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        waiters = remaining
    }

    func finishAll(_ outcome: ProcessOutcome = ProcessOutcome()) {
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations {
            continuation.resume(returning: outcome)
        }
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }
}

private struct FakeProcess: RunningProcess {
    let controller: FakeProcessController

    func run(_ request: ProcessRequest) async -> ProcessOutcome {
        await controller.run(request)
    }
}

private struct FakeProcessFactory: ProcessFactory {
    let controller: FakeProcessController

    func makeProcess() -> any RunningProcess {
        FakeProcess(controller: controller)
    }
}

final class ShortcutRunnerTests: XCTestCase {
    func testArgumentConstructionNeverInterpolatesIntoShell() {
        let name = #" Focus; $(touch /tmp/should-not-exist) "quoted" "#
        let file = URL(fileURLWithPath: "/tmp/input with spaces.txt")
        let request = ShortcutRunner.runRequest(exactName: name, inputFile: file)
        XCTAssertEqual(request.executable, "/usr/bin/shortcuts")
        XCTAssertEqual(request.arguments, ["run", name, "--input-path", file.path])
        XCTAssertEqual(request.timeout, 300)
    }

    func testLiteralInputUsesTemporaryFileAndExitZeroWinsOverStderr() async throws {
        let name = " Exact Name "
        let controller = FakeProcessController(names: [name])
        let runner = ShortcutRunner(factory: FakeProcessFactory(controller: controller))
        let literal = "Don't expand $HOME or `commands`.\nSecond line."
        let result = await runner.run(
            bindingID: UUID(), exactName: name, literalInput: literal
        )
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.exitStatus, 0)
        let inputs = await controller.capturedInputs
        XCTAssertEqual(inputs, [Data(literal.utf8)])

        let requests = await controller.recordedRequests()
        let run = try XCTUnwrap(requests.first { $0.arguments.first == "run" })
        XCTAssertEqual(Array(run.arguments.prefix(2)), ["run", name])
        let path = try XCTUnwrap(run.arguments.last)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMissingShortcutIsNotFuzzyMatchedOrExecuted() async {
        let controller = FakeProcessController(names: ["Start Focus", "start focus "])
        let runner = ShortcutRunner(factory: FakeProcessFactory(controller: controller))
        let result = await runner.run(bindingID: UUID(), exactName: "start focus")
        XCTAssertEqual(result.status, .unavailable)
        let requests = await controller.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [["list"]])
    }

    func testOnePerBindingTwoGlobalAndReleaseAfterCompletion() async {
        let controller = FakeProcessController(names: ["One"], suspended: true)
        let runner = ShortcutRunner(factory: FakeProcessFactory(controller: controller))
        let firstID = UUID()
        let secondID = UUID()

        let first = Task { await runner.run(bindingID: firstID, exactName: "One") }
        await controller.waitForExecutions(1)

        let duplicate = await runner.run(bindingID: firstID, exactName: "One")
        XCTAssertEqual(duplicate.status, .busy)
        XCTAssertEqual(duplicate.message, "Already running")

        let second = Task { await runner.run(bindingID: secondID, exactName: "One") }
        await controller.waitForExecutions(2)

        let third = await runner.run(bindingID: UUID(), exactName: "One")
        XCTAssertEqual(third.status, .busy)
        let requests = await controller.recordedRequests()
        XCTAssertEqual(requests.filter { $0.arguments.first == "run" }.count, 2)

        await controller.finishAll()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult.status, .completed)
        XCTAssertEqual(secondResult.status, .completed)

        let again = Task { await runner.run(bindingID: firstID, exactName: "One") }
        await controller.waitForExecutions(3)
        await controller.finishAll(ProcessOutcome(termination: .timedOut, exitStatus: 15))
        let againResult = await again.value
        XCTAssertEqual(againResult.status, .failed)

        let afterTimeout = Task { await runner.run(bindingID: firstID, exactName: "One") }
        await controller.waitForExecutions(4)
        await controller.finishAll(ProcessOutcome(termination: .cancelled, exitStatus: 15))
        let cancelled = await afterTimeout.value
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testDiscoveryPreservesSpacesAndCachesUntilRefresh() async throws {
        let controller = FakeProcessController(names: [" Z ", "A", "\tB\t"])
        let discovery = ShortcutDiscovery(factory: FakeProcessFactory(controller: controller))
        let first = try await discovery.list()
        let cached = try await discovery.list()
        XCTAssertEqual(Set(first), Set([" Z ", "A", "\tB\t"]))
        XCTAssertEqual(first, cached)
        let before = await controller.recordedRequests()
        XCTAssertEqual(before.count, 1)
        _ = try await discovery.refresh()
        let after = await controller.recordedRequests()
        XCTAssertEqual(after.count, 2)

        XCTAssertEqual(
            Set(ShortcutDiscovery.parseList(" A \r\nB\t\nC\r")),
            Set([" A ", "B\t", "C"])
        )
    }

    func testNonzeroExitIsFailureEvenWithOptimisticOutput() {
        let result = ProcessOutcome(
            exitStatus: 7, stdout: Data("Everything succeeded!".utf8)
        ).actionResult
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.exitStatus, 7)
    }
}
