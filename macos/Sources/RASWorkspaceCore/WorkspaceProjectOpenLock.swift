import Darwin
import Foundation

public enum WorkspaceProjectOpenLockError: LocalizedError, Equatable, Sendable {
    case invalidProjectURL
    case alreadyOpen(URL)
    case unsafeLockFile(URL)
    case systemFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectURL:
            "Choose a saved local HEC-RAS project to open."
        case .alreadyOpen:
            "This project is already open in another HEC-RAS instance."
        case .unsafeLockFile:
            "The project lock file cannot be opened safely."
        case .systemFailure:
            "Could not update the project lock file."
        }
    }

    public var diagnosticDetail: String? {
        switch self {
        case .systemFailure(let message): message
        default: nil
        }
    }
}

/// An advisory lock matching the retained project-folder lock lifetime.
/// A lease is acquired separately from any currently open project, so a failed
/// candidate open cannot release or replace the current project's lock.
public enum WorkspaceProjectOpenLock {
    public static func acquire(for projectURL: URL) throws -> Lease {
        guard projectURL.isFileURL, !projectURL.path.isEmpty else {
            throw WorkspaceProjectOpenLockError.invalidProjectURL
        }

        let standardized = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let isDirectory = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let projectDirectory = isDirectory ? standardized : standardized.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: projectDirectory.path),
              (try? projectDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceProjectOpenLockError.invalidProjectURL
        }
        if !isDirectory {
            guard standardized.pathExtension.lowercased() == "ras",
                  FileManager.default.isReadableFile(atPath: standardized.path) else {
                throw WorkspaceProjectOpenLockError.invalidProjectURL
            }
        }

        let lockURL = projectDirectory.appendingPathComponent(".lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw WorkspaceProjectOpenLockError.unsafeLockFile(lockURL)
            }
            throw WorkspaceProjectOpenLockError.systemFailure(String(cString: strerror(errno)))
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw WorkspaceProjectOpenLockError.unsafeLockFile(lockURL)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw WorkspaceProjectOpenLockError.alreadyOpen(projectDirectory)
            }
            throw WorkspaceProjectOpenLockError.systemFailure(String(cString: strerror(lockError)))
        }

        do {
            try writeOwnerProcessID(Int32(getpid()), to: descriptor)
            return Lease(lockURL: lockURL, descriptor: descriptor,
                         device: status.st_dev, inode: status.st_ino)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func writeOwnerProcessID(_ processID: Int32, to descriptor: Int32) throws {
        let data = Array("\(processID)\n".utf8)
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw WorkspaceProjectOpenLockError.systemFailure(String(cString: strerror(errno)))
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written else {
            throw WorkspaceProjectOpenLockError.systemFailure(String(cString: strerror(errno)))
        }
    }

    public final class Lease: @unchecked Sendable {
        public let projectLockURL: URL
        private let descriptor: Int32
        private let device: dev_t
        private let inode: ino_t
        private let stateLock = NSLock()
        private var released = false

        fileprivate init(lockURL: URL, descriptor: Int32, device: dev_t, inode: ino_t) {
            projectLockURL = lockURL
            self.descriptor = descriptor
            self.device = device
            self.inode = inode
        }

        public var isReleased: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return released
        }

        public func release() {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !released else { return }
            released = true

            // Remove only the same regular file this lease opened. This keeps
            // a replacement lock from another process intact.
            var current = stat()
            if lstat(projectLockURL.path, &current) == 0,
               current.st_dev == device, current.st_ino == inode,
               current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                _ = unlink(projectLockURL.path)
            }
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }

        deinit { release() }
    }
}
