import Darwin
import Foundation
import Testing
@testable import RASWorkspaceCore

@Suite struct WorkspaceProjectOpenLockTests {
    @Test func failedCandidateAcquireLeavesCurrentLeaseHeld() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-lock-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectURL = projectDirectory.appendingPathComponent("project.ras")
        try Data("<Project />".utf8).write(to: projectURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let current = try WorkspaceProjectOpenLock.acquire(for: projectURL)
        #expect(current.isReleased == false)
        #expect(FileManager.default.fileExists(atPath: current.projectLockURL.path))
        #expect(String(decoding: try Data(contentsOf: current.projectLockURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()))

        #expect(throws: WorkspaceProjectOpenLockError.self) {
            try WorkspaceProjectOpenLock.acquire(for: projectURL)
        }
        #expect(current.isReleased == false)

        current.release()
        current.release()
        #expect(current.isReleased)
        #expect(!FileManager.default.fileExists(atPath: current.projectLockURL.path))

        let replacement = try WorkspaceProjectOpenLock.acquire(for: projectURL)
        #expect(!replacement.isReleased)
        replacement.release()
    }

    @Test func leasesForDifferentProjectsDoNotConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstProject = first.appendingPathComponent("first.ras")
        let secondProject = second.appendingPathComponent("second.ras")
        try Data("<Project />".utf8).write(to: firstProject)
        try Data("<Project />".utf8).write(to: secondProject)

        let firstLease = try WorkspaceProjectOpenLock.acquire(for: firstProject)
        let secondLease = try WorkspaceProjectOpenLock.acquire(for: secondProject)
        #expect(firstLease.projectLockURL != secondLease.projectLockURL)
        firstLease.release()
        secondLease.release()
    }

    @Test func releasingLeaseDoesNotRemoveAReplacementLockFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-lock-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectURL = projectDirectory.appendingPathComponent("project.ras")
        try Data("<Project />".utf8).write(to: projectURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let lease = try WorkspaceProjectOpenLock.acquire(for: projectURL)
        try FileManager.default.removeItem(at: lease.projectLockURL)
        let replacement = Data("replacement owner\n".utf8)
        try replacement.write(to: lease.projectLockURL, options: .withoutOverwriting)

        lease.release()
        #expect(FileManager.default.fileExists(atPath: lease.projectLockURL.path))
        #expect(try Data(contentsOf: lease.projectLockURL) == replacement)
    }
}
