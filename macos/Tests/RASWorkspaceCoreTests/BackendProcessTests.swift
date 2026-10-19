import Foundation
import XCTest
@testable import RASWorkspaceCore

@MainActor
final class BackendProcessTests: XCTestCase {
    private struct Result: Decodable, Sendable { let value: String }
    private func client(_ source: String) -> BackendProcessClient {
        .init(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", source])
    }
    func testLargeUnicodeResponseAndStderrAreDrainedConcurrently() async throws {
        let client = client("import json,sys; r=json.load(sys.stdin); sys.stderr.write('diagnostic'*100000); json.dump({'id':r['id'],'result':{'value':r['parameters']['value']}},sys.stdout)")
        let text = String(repeating: "中文计划 🌊", count: 100000)
        let result = try await client.request("echo", parameters: ["value": text], as: Result.self)
        XCTAssertEqual(result.value, text)
    }
    func testRemoteErrorsRetainCodeAndMessage() async throws {
        let client = client("import json,sys; r=json.load(sys.stdin); json.dump({'id':r['id'],'error':{'code':'sourceChanged','message':'外部文件已修改'}},sys.stdout); sys.exit(1)")
        do { let _: Result = try await client.request("save", parameters: [String: String]()); XCTFail("Expected source conflict") }
        catch let error as BackendServiceError { XCTAssertEqual(error.code, "sourceChanged"); XCTAssertEqual(error.message, "外部文件已修改") }
    }
    func testMismatchedIdentityIsRejected() async throws {
        let client = client("import json,sys; json.load(sys.stdin); json.dump({'id':'other-request','result':{'value':'wrong'}},sys.stdout)")
        do { let _: Result = try await client.request("load", parameters: [String: String]()); XCTFail("Expected protocol error") }
        catch let error as BackendServiceError { XCTAssertEqual(error.code, "protocolFailure") }
    }
    func testCancellationStopsTheActualChildProcess() async throws {
        let client = client("import json,sys,time; json.load(sys.stdin); time.sleep(30)")
        let request = Task { try await client.request("wait", parameters: [String: String](), as: Result.self) }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }
}
