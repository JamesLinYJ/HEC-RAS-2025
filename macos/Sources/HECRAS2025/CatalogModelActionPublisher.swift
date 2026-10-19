import CryptoKit
import Foundation
import RASWorkspaceCore

struct CatalogModelActionRecoveryError: LocalizedError {
    let cause: String
    let recoveryDirectory: String
    private let message: String
    @MainActor init(cause: String, recoveryDirectory: String) {
        self.cause = cause; self.recoveryDirectory = recoveryDirectory
        message = L10n.format("The model action failed. Recovery files are retained at %@. %@", recoveryDirectory, cause)
    }
    var errorDescription: String? { message }
}

/// Publishes source-produced HDFs and the corresponding association/visual
/// changes as one reversible operation. Every Trash input is backed up first;
/// if a later Trash operation fails, earlier inputs are restored from backups.
@MainActor
enum CatalogModelActionPublisher {
    static func publish(_ receipt: CatalogModelActionReceipt, asset: ProjectAsset,
        project: ProjectDocument, visualization: VisualizationDocument?, system: any WorkspaceSystemServices) throws {
        let files = FileManager.default
        let isCopy = ["clone", "duplicate"].contains(receipt.action)
        guard ["rename", "clone", "duplicate", "delete"].contains(receipt.action), !receipt.originalName.isEmpty,
              receipt.originalAssetPath == asset.url.path,
              canonical(receipt.canonicalOriginalAssetPath) == canonical(asset.url.path),
              digest(try Data(contentsOf: asset.url, options: .mappedIfSafe)) == receipt.originalSHA,
              receipt.actualClone == isCopy, let directory = project.directory else {
            throw ProjectFileError.invalid("The model action no longer matches the selected source file.")
        }
        let knownModels = Set(project.assets.map { canonical($0.url.path) })
        let staged = receipt.stagedTargets
        guard Set(staged.map { canonical($0.targetPath) }).count == staged.count,
              staged.isEmpty == (receipt.action == "delete") else {
            throw ProjectFileError.invalid("The model action returned invalid publication targets.")
        }
        for owner in receipt.stagingDirectories {
            let url = URL(fileURLWithPath: owner.path).standardizedFileURL
            guard owner.token.count == 32, owner.token.allSatisfy(\.isHexDigit),
                  url.lastPathComponent == owner.token,
                  url.deletingLastPathComponent().lastPathComponent == ".catalog-action-staging",
                  canonical(url.deletingLastPathComponent().deletingLastPathComponent().path)
                    == canonical(asset.url.deletingLastPathComponent().path),
                  let marker = try? String(contentsOf: url.appendingPathComponent(".catalog-action-owner"), encoding: .utf8),
                  marker.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) == owner.token else {
                throw ProjectFileError.invalid("The model action staging ownership is invalid.")
            }
        }
        for target in staged {
            let stageURL = URL(fileURLWithPath: target.stagePath).standardizedFileURL
            let destination = URL(fileURLWithPath: target.targetPath).standardizedFileURL
            guard receipt.stagingDirectories.contains(where: {
                let parent = URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
                return stageURL.resolvingSymlinksInPath().pathComponents.starts(with: parent)
                    && stageURL.resolvingSymlinksInPath().pathComponents.count > parent.count
            }), destination.pathExtension.lowercased() == "h5",
               canonical(destination.path) != canonical(asset.url.path),
               digest(try Data(contentsOf: stageURL, options: .mappedIfSafe)) == target.stageSHA else {
                throw ProjectFileError.invalid("A staged model file changed before publication.")
            }
            if let expected = target.expectedTargetSHA {
                guard knownModels.contains(canonical(destination.path)), try fileDigest(destination) == expected else {
                    throw ProjectFileError.modifiedExternally
                }
            } else {
                guard !exists(destination), target.targetPath == receipt.newAssetPath,
                      canonical(destination.deletingLastPathComponent().path) == canonical(asset.url.deletingLastPathComponent().path) else {
                    throw ProjectFileError.invalid("A model file already exists with that name.")
                }
            }
        }
        let trash = receipt.trashPaths ?? []
        if isCopy {
            guard trash.isEmpty,
                  receipt.action != "clone" || receipt.metadataMutations.isEmpty else { throw ProjectFileError.modifiedExternally }
        } else {
            guard trash.filter(\.originalAsset).count == 1,
                  trash.contains(where: { $0.originalAsset && $0.path == receipt.originalAssetPath
                      && $0.revision == receipt.originalSHA }),
                  Set(trash.map { canonical($0.path) }).count == trash.count else {
                throw ProjectFileError.invalid("The model action returned invalid Trash inputs.")
            }
        }
        for item in trash {
            guard try fileDigest(URL(fileURLWithPath: item.path)) == item.revision else { throw ProjectFileError.modifiedExternally }
        }
        let mutations = receipt.metadataMutations.map {
            ProjectModelMetadataMutation(section: $0.section, rowName: $0.rowName,
                identityAttribute: $0.identityAttribute, identityValue: $0.identityValue,
                attribute: $0.attribute, oldValue: $0.oldValue, newValue: $0.newValue, removeRow: $0.removeRow)
        }
        let metadata = try project.prepareModelMetadataMutations(mutations)
        let visual = isCopy ? nil : try visualization?.prepareModelReferenceChange(
            type: receipt.kind, oldName: receipt.originalName, newName: receipt.action == "rename" ? receipt.newName : nil)
        let backupDirectory = directory.appendingPathComponent(".catalog-action-recovery-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        var backups: [(original: URL, backup: URL, revision: String)] = []
        var published: [CatalogModelActionStagedTarget] = []
        var completedTrash: [CatalogModelActionTrashPath] = []
        var retainRecovery = false
        defer { if !retainRecovery { try? files.removeItem(at: backupDirectory) } }
        do {
            let originals = staged.compactMap { target -> (String, String)? in
                target.expectedTargetSHA.map { (target.targetPath, $0) }
            } + trash.map { ($0.path, $0.revision) }
            for (index, item) in originals.enumerated() {
                let original = URL(fileURLWithPath: item.0)
                guard try fileDigest(original) == item.1 else { throw ProjectFileError.modifiedExternally }
                let backup = backupDirectory.appendingPathComponent(String(index) + "-" + original.lastPathComponent)
                try files.copyItem(at: original, to: backup)
                guard try fileDigest(backup) == item.1 else { throw ProjectFileError.modifiedExternally }
                backups.append((original, backup, item.1))
            }
            for target in staged {
                let destination = URL(fileURLWithPath: target.targetPath)
                let data = try Data(contentsOf: URL(fileURLWithPath: target.stagePath), options: .mappedIfSafe)
                guard digest(data) == target.stageSHA else { throw ProjectFileError.modifiedExternally }
                if let expected = target.expectedTargetSHA {
                    guard try fileDigest(destination) == expected else { throw ProjectFileError.modifiedExternally }
                    try data.write(to: destination, options: .atomic)
                } else {
                    // .withoutOverwriting is enforced by the file-system open,
                    // rather than an earlier existence check alone.
                    try data.write(to: destination, options: .withoutOverwriting)
                }
                published.append(target)
            }
            try metadata.apply()
            try visual?.apply()
            for item in trash {
                let source = item.originalAsset ? asset.url : URL(fileURLWithPath: item.path)
                guard try fileDigest(source) == item.revision else { throw ProjectFileError.modifiedExternally }
                try system.trash(source)
                guard !exists(source) else { throw ProjectFileError.invalid("The model file was not moved to Trash.") }
                completedTrash.append(item)
            }
        } catch {
            let originalError = error
            var recoveryErrors: [String] = []
            do { try visual?.rollback() } catch { recoveryErrors.append(error.localizedDescription) }
            metadata.rollback()
            for target in published.reversed() {
                let destination = URL(fileURLWithPath: target.targetPath)
                do {
                    guard try fileDigest(destination) == target.stageSHA else { throw ProjectFileError.modifiedExternally }
                    if target.expectedTargetSHA != nil {
                        let backup = try backups.first(where: { canonical($0.original.path) == canonical(destination.path) })
                            .unwrapModelActionBackup()
                        try Data(contentsOf: backup.backup, options: .mappedIfSafe).write(to: destination, options: .atomic)
                    } else { try files.removeItem(at: destination) }
                } catch { recoveryErrors.append(destination.path + ": " + error.localizedDescription) }
            }
            for item in completedTrash {
                let original = item.originalAsset ? asset.url : URL(fileURLWithPath: item.path)
                do {
                    guard !exists(original) else { throw ProjectFileError.modifiedExternally }
                    let backup = try backups.first(where: { $0.original.path == item.path || canonical($0.original.path) == canonical(original.path) })
                        .unwrapModelActionBackup()
                    try files.copyItem(at: backup.backup, to: original)
                } catch { recoveryErrors.append(original.path + ": " + error.localizedDescription) }
            }
            if !recoveryErrors.isEmpty {
                retainRecovery = true
                throw CatalogModelActionRecoveryError(cause: originalError.localizedDescription + "\n" + recoveryErrors.joined(separator: "\n"),
                    recoveryDirectory: backupDirectory.path)
            }
            throw originalError
        }
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined() }
    private static func fileDigest(_ url: URL) throws -> String { digest(try Data(contentsOf: url, options: .mappedIfSafe)) }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private extension Optional {
    func unwrapModelActionBackup() throws -> Wrapped {
        guard let self else { throw ProjectFileError.modifiedExternally }
        return self
    }
}
