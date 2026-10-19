import Darwin
import Foundation
import XCTest
@testable import RASWorkspaceCore

final class SourceFilePathsTests: XCTestCase {
    func testPhysicalIdentitySurvivesIntermediateAliasesAndMissingOutputFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let alias = folder.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let input = original.appendingPathComponent("input.h5")
        try Data("identity only".utf8).write(to: input)
        let physical = try XCTUnwrap(original.path.withCString { Darwin.realpath($0, nil) })
        defer { Darwin.free(physical) }
        let prefix = String(cString: physical)
        XCTAssertEqual(SourceFilePaths.canonical(alias.appendingPathComponent("input.h5")), prefix + "/input.h5")
        XCTAssertEqual(SourceFilePaths.canonical(alias.appendingPathComponent("new/output.h5")), prefix + "/new/output.h5")
    }
}
