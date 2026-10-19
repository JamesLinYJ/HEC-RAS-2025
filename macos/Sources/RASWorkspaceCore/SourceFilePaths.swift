import Darwin
import Foundation

/// Filesystem identity used by the retained C# host. Foundation may shorten
/// /private/var back to /var even after resolving links, so it cannot establish
/// the canonical-path equality used by source inspection and cancellation.
public enum SourceFilePaths {
    public static func canonical(_ url: URL) -> String {
        let normalized = url.standardizedFileURL
        let path = normalized.path
        if let resolved = path.withCString({ Darwin.realpath($0, nil) }) {
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        // Source output files may not exist yet. Resolve their existing parent
        // without normalizing its physical prefix back into a Foundation alias.
        let parent = normalized.deletingLastPathComponent()
        guard parent.path != path else { return path }
        let prefix = canonical(parent)
        return prefix + (prefix.hasSuffix("/") ? "" : "/") + normalized.lastPathComponent
    }
}
