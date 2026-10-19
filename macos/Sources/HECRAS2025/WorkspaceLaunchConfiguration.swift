import Foundation

/// Parsed counterpart to the retained App.OnLaunched command-line options.
/// Options with no portable consumer remain data here rather than implying a
/// behavior that the retained source does not define.
struct WorkspaceLaunchConfiguration: Equatable, Sendable {
    let safeMode: Bool
    let streamPipeName: String?
    let initialProjectURL: URL?
    let postCrashLaunch: Bool
    let testFirstLaunch: Bool
    let debugMode: Bool

    var hasStreamMode: Bool { streamPipeName != nil }
    /// The retained `--first-launch` switch disables application-data reads
    /// and writes for this process. It does not reset or delete persisted data.
    var suppressesAppDataIO: Bool { testFirstLaunch }
    /// Mirrors the retained `-debug` launch flag.
    var launchDebugEnabled: Bool { debugMode }

    /// Used by ordinary launches when no process arguments were supplied by a
    /// caller. The app entry point passes `currentProcess` explicitly.
    static let standard = WorkspaceLaunchConfiguration(arguments: [])

    init(arguments: [String]) {
        safeMode = arguments.contains("-safemode")
        streamPipeName = arguments.first(where: { $0.hasPrefix("-stream=") })
            .map { String($0.dropFirst("-stream=".count)) }
        postCrashLaunch = arguments.contains("-crashed")
        testFirstLaunch = arguments.contains("--first-launch")
        debugMode = arguments.contains("-debug")

        if arguments.count > 1 {
            let candidate = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            initialProjectURL = candidate.pathExtension.lowercased() == "ras" ? candidate : nil
        } else {
            initialProjectURL = nil
        }
    }

    static var currentProcess: Self { Self(arguments: ProcessInfo.processInfo.arguments) }
}
