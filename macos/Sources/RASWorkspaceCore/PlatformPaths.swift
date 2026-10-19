import Foundation

// Replaces WinRT StorageFolder / drive-letter assumptions at the UI boundary.
// Foreign absolute paths require an explicit user mapping; they are never
// silently treated as relative paths on the receiving platform.
public struct PathMapping: Codable, Equatable, Sendable {
    public let sourceRoot: String
    public let destination: URL
    public init(sourceRoot: String, destination: URL) { self.sourceRoot = sourceRoot; self.destination = destination }
}

public enum PlatformPaths {
    /// Follow a file link for its kind while retaining the caller's URL as
    /// the presentation/relative-path owner. Directory links are not files;
    /// recursive callers still skip their descendants to avoid cycles.
    public static func isRegularSourceFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isRegularFile == true { return true }
        guard values.isSymbolicLink == true else { return false }
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        return try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }

    public static func resolve(_ reference: String, relativeTo base: URL, mappings: [PathMapping] = []) throws -> URL {
        try resolve(reference, relativeTo: base, mappings: mappings, preserveSymlinkPresentation: false)
    }

    /// Resolve a persisted presentation path using lexical `.`/`..` cleanup
    /// while retaining the path's final symlink component. `standardizedFileURL`
    /// may replace that component with its target on some Foundation versions,
    /// which loses format-significant aliases such as `.geojson` -> `.data`.
    public static func resolvePresentationPath(_ reference: String, relativeTo base: URL,
                                               mappings: [PathMapping] = []) throws -> URL {
        try resolve(reference, relativeTo: base, mappings: mappings, preserveSymlinkPresentation: true)
    }

    private static func resolve(_ reference: String, relativeTo base: URL, mappings: [PathMapping],
                                preserveSymlinkPresentation: Bool) throws -> URL {
        guard !reference.isEmpty else { throw ProjectFileError.invalid("The file reference is empty.") }
        func normalizeURL(_ url: URL) -> URL {
            guard preserveSymlinkPresentation else { return url.standardizedFileURL }
            let path = Self.lexicallyNormalizedAbsolutePath(url.path)
            return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        }
        var pathReference = reference
        if reference.lowercased().hasPrefix("file:"),
           let components = URLComponents(string: reference), components.scheme?.lowercased() == "file" {
            // Work with the encoded path directly; converting through a
            // standardized URL here can follow a final file symlink.
            let filePath = components.percentEncodedPath.removingPercentEncoding ?? components.path
            if let host = components.host, !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame {
                pathReference = "//" + host + filePath
            } else if filePath.count >= 4, filePath.hasPrefix("/"), filePath.dropFirst(2).hasPrefix(":/") {
                pathReference = String(filePath.dropFirst())
            } else { return normalizeURL(URL(fileURLWithPath: filePath)) }
        }
        let normalizedReference = pathReference.replacingOccurrences(of: "\\", with: "/")
        let isDrivePath = normalizedReference.count >= 3 && normalizedReference.dropFirst().hasPrefix(":/") && normalizedReference.first?.isLetter == true
        let isUNCPath = normalizedReference.hasPrefix("//")
        if normalizedReference.count >= 2, normalizedReference.dropFirst().hasPrefix(":"), !isDrivePath {
            throw ProjectFileError.invalid("A drive-relative Windows path needs an explicit absolute location.")
        }
        if isDrivePath || isUNCPath {
            for mapping in mappings.sorted(by: { $0.sourceRoot.count > $1.sourceRoot.count }) {
                let root = mapping.sourceRoot.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let source = isUNCPath ? normalizedReference.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : normalizedReference
                if source.caseInsensitiveCompare(root) == .orderedSame { return normalizeURL(mapping.destination) }
                if source.lowercased().hasPrefix(root.lowercased() + "/") {
                    let suffix = String(source.dropFirst(root.count + 1))
                    let mappedPath = mapping.destination.path + "/" + suffix
                    return normalizeURL(URL(fileURLWithPath: mappedPath))
                }
            }
            throw ProjectFileError.invalid("Map the Windows location \(reference) to a folder on this computer before opening it.")
        }
        if pathReference.hasPrefix("\\"), !isUNCPath {
            throw ProjectFileError.invalid("A root-relative Windows path needs an explicit volume location.")
        }
        return normalizedReference.hasPrefix("/")
            ? normalizeURL(URL(fileURLWithPath: normalizedReference))
            : normalizeURL(URL(fileURLWithPath: base.path + "/" + normalizedReference))
    }

    private static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if let last = components.last, last != ".." { components.removeLast() }
                else if !isAbsolute { components.append(component) }
                continue
            }
            components.append(component)
        }
        let body = components.map { String($0) }.joined(separator: "/")
        if isAbsolute { return body.isEmpty ? "/" : "/" + body }
        return body.isEmpty ? "." : body
    }
    public static var defaultProjectDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("RAS Projects", isDirectory: true)
    }
    public static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HEC/RAS/_temp", isDirectory: true)
    }
}
