import AppKit
import Darwin
import Foundation

enum WorkspaceApplicationPaths {
    static var applicationDataDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("HEC", isDirectory: true)
            .appendingPathComponent("RAS", isDirectory: true)
    }

    static var logDirectory: URL {
        applicationDataDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    static var applicationLog: URL {
        logDirectory.appendingPathComponent("ras.log", isDirectory: false)
    }

    static var errorLog: URL {
        logDirectory.appendingPathComponent("ras-errors.log", isDirectory: false)
    }

    static var logLock: URL {
        logDirectory.appendingPathComponent(".ras-log.lock", isDirectory: false)
    }
}

/// The native Store calls this from its existing operation log boundary so
/// the menu action reveals the same ras.log path used by the retained source.
@MainActor
enum WorkspaceApplicationLog {
    private enum SourceLevel: Int {
        case trace
        case debug
        case information
        case warning
        case error

        var errorLogCode: String {
            switch self {
            case .warning: "WRN"
            case .error: "ERR"
            default: "INF"
            }
        }

        init(_ rawValue: String) {
            switch rawValue.lowercased() {
            case "trace", "verbose": self = .trace
            case "debug": self = .debug
            case "warning", "warn", "wrn": self = .warning
            case "error", "critical", "err": self = .error
            default: self = .information
            }
        }
    }

    static func append(
        _ operation: String,
        _ message: String,
        level: String = "Information",
        at date: Date = Date(),
        errorDetails: String? = nil
    ) throws {
        let sourceLevel = SourceLevel(level)
        // ObservableLog's main file starts at Debug; Trace is not persisted.
        guard sourceLevel.rawValue >= SourceLevel.debug.rawValue else { return }
        let renderedMessage = operation.isEmpty ? message : "\(operation): \(message)"
        let mainLine = "\(timestamp(date, format: "HH:mm:ss.SSS")) \(renderedMessage)\n"
        try append(mainLine, to: WorkspaceApplicationPaths.applicationLog)
        guard sourceLevel.rawValue >= SourceLevel.warning.rawValue else { return }
        let exceptionLine = errorDetails.map { $0.isEmpty ? "" : "\($0)\n" } ?? ""
        let errorLine = "\(timestampWithOffset(date)) [\(sourceLevel.errorLogCode)] \(renderedMessage)\n\(exceptionLine)"
        try append(errorLine, to: WorkspaceApplicationPaths.errorLog)
    }

    private static func timestamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func timestampWithOffset(_ date: Date) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let absoluteOffset = abs(offset)
        let localTime = timestamp(date, format: "yyyy-MM-dd HH:mm:ss.SSS")
        return String(format: "%@ %@%02d:%02d", localTime, sign,
            absoluteOffset / 3600, (absoluteOffset % 3600) / 60)
    }

    private static func append(_ text: String, to fileURL: URL) throws {
        let directory = WorkspaceApplicationPaths.logDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let lockDescriptor = Darwin.open(WorkspaceApplicationPaths.logLock.path,
            O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard lockDescriptor >= 0 else { throw posixError("open log lock") }
        defer { _ = Darwin.close(lockDescriptor) }
        while flock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw posixError("lock application log")
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let logDescriptor = Darwin.open(fileURL.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, mode_t(0o600))
        guard logDescriptor >= 0 else { throw posixError("open application log") }
        defer { _ = Darwin.close(logDescriptor) }
        guard Darwin.fchmod(logDescriptor, mode_t(0o600)) == 0 else { throw posixError("set application log permissions") }

        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(logDescriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write application log")
                }
                guard count > 0 else { throw posixError("write application log") }
                offset += count
            }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        let code = errno
        let detail = String(cString: Darwin.strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(detail)"])
    }
}

@MainActor
enum WorkspacePlatformActions {
    static func revealApplicationData(using system: WorkspaceSystemServices) {
        do {
            try FileManager.default.createDirectory(at: WorkspaceApplicationPaths.applicationDataDirectory,
                withIntermediateDirectories: true)
            system.reveal(WorkspaceApplicationPaths.applicationDataDirectory)
        } catch {
            present(error: error, title: "Open Application Data")
        }
    }

    static func revealApplicationLog(using system: WorkspaceSystemServices) {
        let url = WorkspaceApplicationPaths.applicationLog
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            present(message: L10n.text("The application log is not available yet."), title: "Open Application Log")
            return
        }
        system.reveal(url)
    }

    private static func present(error: Error, title: String) {
        present(message: error.localizedDescription, title: title)
    }

    private static func present(message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text(title)
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }
}
