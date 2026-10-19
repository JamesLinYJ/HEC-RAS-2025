import Darwin
import Foundation
import XCTest
@testable import RASWorkspaceCore

@MainActor
final class BackendProgressTests: XCTestCase {
    private struct Payload: Decodable, Sendable {
        let value: String
        let acknowledged: Bool?
    }
    private struct DuplexCommand: Encodable, Sendable { let action: String }
    private struct DuplexPayload: Decodable, Sendable { let value: String }
    private struct DuplexEvent: Decodable, Sendable {
        let sequence: Int
        let payload: String
    }

    private func client(_ source: String) -> BackendProcessClient {
        .init(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", source])
    }

    func testProgressStreamsBeforeTerminalAcrossSplitUnicodeAndLargeStderr() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-progress-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let acknowledgementURL = directory.appendingPathComponent("progress-ack")
        let collector = ProgressRecorder(acknowledgementURL: acknowledgementURL)
        let script = #"""
        import json, os, sys, time
        request = json.loads(sys.stdin.readline())
        assert request.get("streamProgress") is True
        request_id = request["id"]
        acknowledgement = request["parameters"]["acknowledgementPath"]
        sys.stderr.buffer.write(("诊断🌊" * 140000).encode("utf-8"))
        sys.stderr.flush()
        event = json.dumps({"id": request_id, "progress": {"fraction": 0.375, "message": "正在计算 🌊 — 已分块", "taskName": "Plan solver"}}, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        marker = "🌊".encode("utf-8")
        split = event.index(marker) + 2
        os.write(sys.stdout.fileno(), event[:split])
        sys.stdout.flush()
        time.sleep(0.03)
        os.write(sys.stdout.fileno(), event[split:])
        sys.stdout.flush()
        deadline = time.monotonic() + 4.0
        while not os.path.exists(acknowledgement) and time.monotonic() < deadline:
            time.sleep(0.005)
        terminal = {"id": request_id, "result": {"value": "completed", "acknowledged": os.path.exists(acknowledgement)}}
        sys.stdout.buffer.write(json.dumps(terminal, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n")
        sys.stdout.flush()
        """#

        let request = Task {
            try await client(script).request(
                "stream", parameters: ["acknowledgementPath": acknowledgementURL.path], as: Payload.self,
                progress: { update in collector.receive(update) })
        }
        let receivedBeforeTimeout = await waitUntil(timeout: .seconds(2)) { !collector.updates.isEmpty }
        if !receivedBeforeTimeout { request.cancel() }

        do {
            let result = try await request.value
            XCTAssertTrue(receivedBeforeTimeout, "The child must be released by a progress callback before its terminal response.")
            XCTAssertEqual(result.value, "completed")
            XCTAssertEqual(result.acknowledged, true)
        } catch is CancellationError {
            XCTAssertTrue(receivedBeforeTimeout, "The request was cancelled while cleaning up a child that did not stream progress.")
        }

        let updates = collector.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.fraction, 0.375)
        XCTAssertEqual(updates.first?.message, "正在计算 🌊 — 已分块")
        XCTAssertEqual(updates.first?.taskName, "Plan solver")
    }

    func testBackendOperationEventsPreserveInvocationOrderAcrossCallerAndChildThreads() async throws {
        let script = #"""
        import json, sys
        request = json.loads(sys.stdin.readline())
        request_id = request["id"]
        def emit(value):
            sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        emit({"id": request_id, "progress": {"fraction": 0.6, "message": "halfway", "taskName": "event-order-check"}})
        emit({"id": request_id, "result": {"value": "complete", "state": "completed", "succeeded": True}})
        """#
        let recorder = BackendOperationEventRecorder()
        let observer = BackendOperationEventCenter.shared.addObserver { event in
            if event.method == "event-order-check" { recorder.receive(event) }
        }
        defer { BackendOperationEventCenter.shared.removeObserver(observer) }

        let result: Payload = try await client(script).request("event-order-check",
            parameters: [String: String](), as: Payload.self, progress: { _ in })

        XCTAssertEqual(result.value, "complete")
        let events = recorder.events
        XCTAssertEqual(events.count, 3)
        guard events.count == 3 else { return }
        XCTAssertEqual(events.map(\.phase), [.started, .progress, .completed])
        XCTAssertEqual(Set(events.map(\.invocationID)).count, 1)
        XCTAssertTrue(events.allSatisfy { $0.isJob })
        XCTAssertEqual(events[1].progress, 0.6)
        XCTAssertEqual(events[2].sourceSucceeded, true)
    }

    func testStreamProtocolRejectsMismatchedIDsInvalidLinesAndInvalidOrdering() async {
        let script = #"""
        import json, sys
        request = json.loads(sys.stdin.readline())
        request_id = request["id"]
        mode = request["parameters"]["mode"]
        def emit(value):
            sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        result = {"value": "ok"}
        progress = {"fraction": 0.5, "message": "halfway"}
        if mode == "mismatched-progress-id":
            emit({"id": "different-request", "progress": progress})
            emit({"id": request_id, "result": result})
        elif mode == "mismatched-terminal-id":
            emit({"id": request_id, "progress": progress})
            emit({"id": "different-request", "result": result})
        elif mode == "progress-after-terminal":
            emit({"id": request_id, "result": result})
            emit({"id": request_id, "progress": progress})
        elif mode == "multiple-terminals":
            emit({"id": request_id, "result": result})
            emit({"id": request_id, "result": result})
        elif mode == "malformed-line":
            sys.stdout.write("{not-json}\n")
            sys.stdout.flush()
            emit({"id": request_id, "result": result})
        elif mode == "fraction-below-zero":
            emit({"id": request_id, "progress": {"fraction": -0.01}})
            emit({"id": request_id, "result": result})
        elif mode == "fraction-above-one":
            emit({"id": request_id, "progress": {"fraction": 1.01}})
            emit({"id": request_id, "result": result})
        """#
        let backend = client(script)
        let modes = [
            "mismatched-progress-id", "mismatched-terminal-id", "progress-after-terminal",
            "multiple-terminals", "malformed-line", "fraction-below-zero", "fraction-above-one"
        ]

        for mode in modes {
            do {
                let _: Payload = try await backend.request("stream", parameters: ["mode": mode], as: Payload.self, progress: { _ in })
                XCTFail("Expected protocolFailure for mode \(mode)")
            } catch let error as BackendServiceError {
                XCTAssertEqual(error.code, "protocolFailure", "Unexpected failure for mode \(mode): \(error)")
            } catch {
                XCTFail("Unexpected error for mode \(mode): \(error)")
            }
        }
    }

    func testRemoteErrorIsPreservedAsTheTerminalFailure() async {
        let script = #"""
        import json, sys
        request = json.loads(sys.stdin.readline())
        response = {"id": request["id"], "error": {"code": "sourceChanged", "message": "外部文件已修改"}}
        sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        sys.exit(1)
        """#

        do {
            let _: Payload = try await client(script).request("save", parameters: [String: String](), as: Payload.self, progress: { _ in })
            XCTFail("Expected the backend's source conflict")
        } catch let error as BackendServiceError {
            XCTAssertEqual(error.code, "sourceChanged")
            XCTAssertEqual(error.message, "外部文件已修改")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLegacySingleTerminalWithoutProgressAndWithoutTrailingNewlineStillWorks() async throws {
        let script = #"""
        import json, sys
        request = json.loads(sys.stdin.readline())
        assert request.get("streamProgress") is True
        response = {"id": request["id"], "result": {"value": "legacy"}}
        sys.stdout.write(json.dumps(response, separators=(",", ":")))
        sys.stdout.flush()
        """#
        let collector = ProgressRecorder()

        let result: Payload = try await client(script).request(
            "legacy", parameters: [String: String](), as: Payload.self,
            progress: { update in collector.receive(update) })

        XCTAssertEqual(result.value, "legacy")
        XCTAssertTrue(collector.updates.isEmpty)
    }

    func testCancellationKillsTheChildAndSuppressesBufferedLateProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-progress-cancel-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyURL = directory.appendingPathComponent("child-ready")
        let releaseURL = directory.appendingPathComponent("release-child")
        let script = #"""
        import json, os, sys, time
        request = json.loads(sys.stdin.readline())
        request_id = request["id"]
        parameters = request["parameters"]
        with open(parameters["pidPath"], "w", encoding="utf-8") as output:
            output.write(str(os.getpid()))
        deadline = time.monotonic() + 5.0
        while not os.path.exists(parameters["releasePath"]) and time.monotonic() < deadline:
            time.sleep(0.005)
        def line(message):
            return json.dumps({"id": request_id, "progress": {"fraction": 0.25, "message": message}}, separators=(",", ":")).encode("utf-8") + b"\n"
        os.write(sys.stdout.fileno(), line("first") + line("already-buffered-late"))
        sys.stdout.flush()
        time.sleep(5)
        """#
        let cancellation = RequestCancellation()
        let recorder = ProgressRecorder(onFirstUpdate: { cancellation.cancel() })
        let request = Task {
            try await client(script).request(
                "cancel-stream", parameters: ["pidPath": readyURL.path, "releasePath": releaseURL.path], as: Payload.self,
                progress: { update in recorder.receive(update) })
        }
        cancellation.install { request.cancel() }
        let childStarted = await waitUntil(timeout: .seconds(2)) { FileManager.default.fileExists(atPath: readyURL.path) }
        XCTAssertTrue(childStarted, "The real child process did not start.")
        guard childStarted else {
            request.cancel()
            _ = try? await request.value
            return
        }
        try Data().write(to: releaseURL)

        do {
            _ = try await request.value
            XCTFail("Expected cancellation after the first progress event")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let pidText = try String(contentsOf: readyURL, encoding: .utf8)
        let childPID = try XCTUnwrap(Int32(pidText))
        let childExited = await waitUntil(timeout: .seconds(2)) { Darwin.kill(childPID, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(childExited, "Cancellation must terminate and reap the Python child process.")
        XCTAssertEqual(recorder.updates.map(\.message), ["first"], "Buffered progress after cancellation must not reach the callback.")
    }

    func testDuplexBackpressurePreservesEventsAndTerminalClosesControlPipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-duplex-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyURL = directory.appendingPathComponent("child-ready")
        let stdinClosedURL = directory.appendingPathComponent("stdin-closed")
        let script = #"""
        import json, os, sys, time
        request = json.loads(sys.stdin.readline())
        assert request.get("duplex") is True
        request_id = request["id"]
        with open(request["parameters"]["readyPath"], "w", encoding="utf-8") as marker:
            marker.write("ready")
        def emit(value):
            sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        payload = "x" * 40000
        for sequence in range(24):
            emit({"id": request_id, "progress": {"sequence": sequence, "payload": payload}})
        emit({"id": request_id, "result": {"value": "complete"}})
        # The host must close stdin as soon as it accepts the terminal frame;
        # otherwise child disposal and host process.waitUntilExit deadlock.
        sys.stdin.buffer.read()
        with open(request["parameters"]["stdinClosedPath"], "w", encoding="utf-8") as marker:
            marker.write("closed")
        time.sleep(0.15)
        """#
        let backend = client(script)
        let operation = try backend.startDuplex(
            "compute", parameters: ["readyPath": readyURL.path, "stdinClosedPath": stdinClosedURL.path],
            control: DuplexCommand.self, event: DuplexEvent.self, as: DuplexPayload.self)
        let started = await waitUntil(timeout: .seconds(2)) { FileManager.default.fileExists(atPath: readyURL.path) }
        XCTAssertTrue(started, "The duplex backend did not begin emitting its frames.")
        try await Task.sleep(for: .milliseconds(100))

        let eventTask = Task { () throws -> [DuplexEvent] in
            var events: [DuplexEvent] = []
            for try await event in operation.events { events.append(event) }
            return events
        }
        let terminalAccepted = await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: stdinClosedURL.path)
        }
        XCTAssertTrue(terminalAccepted, "The host must close stdin after accepting the terminal response.")
        operation.cancel()
        let events = try await eventTask.value
        let result = try await operation.value()

        XCTAssertEqual(result.value, "complete")
        XCTAssertEqual(events.map(\.sequence), Array(0..<24), "Backpressure must preserve every incremental event in order.")
        XCTAssertTrue(events.allSatisfy { $0.payload.count == 40000 })
    }

    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedUpdates: [BackendProgressUpdate] = []
    private let acknowledgementURL: URL?
    private let onFirstUpdate: (@Sendable () -> Void)?

    init(acknowledgementURL: URL? = nil, onFirstUpdate: (@Sendable () -> Void)? = nil) {
        self.acknowledgementURL = acknowledgementURL
        self.onFirstUpdate = onFirstUpdate
    }

    var updates: [BackendProgressUpdate] { lock.withLock { storedUpdates } }

    func receive(_ update: BackendProgressUpdate) {
        let first = lock.withLock {
            storedUpdates.append(update)
            return storedUpdates.count == 1
        }
        guard first else { return }
        if let acknowledgementURL {
            try? Data("received".utf8).write(to: acknowledgementURL, options: .atomic)
        }
        onFirstUpdate?()
    }
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { self.action = action }
    }

    func cancel() {
        let action = lock.withLock { self.action }
        action?()
    }
}

private final class BackendOperationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [BackendOperationEvent] = []

    var events: [BackendOperationEvent] { lock.withLock { storedEvents } }

    func receive(_ event: BackendOperationEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}
