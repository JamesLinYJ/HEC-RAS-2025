import Foundation
import RASWorkspaceCore

/// A local catalog row for a Result which the source compute callback has
/// created but the next catalog snapshot cannot yet read. It is keyed by the
/// actual canonical Result path and run owner; it never predicts a Plan output.
struct TransientResultComputeRow: Equatable, Sendable, Identifiable {
    let projectSessionID: UUID
    let editorID: UUID
    let operationOwnerToken: String
    let operationContextID: String
    let runID: String
    let resultPath: String
    let resultName: String
    let resultRevision: String?
    var status: WorkspaceResultComputeStatus

    init(entry: WorkspaceResultComputeEntry) {
        projectSessionID = entry.projectSessionID
        editorID = entry.editorID
        operationOwnerToken = entry.operationOwnerToken
        operationContextID = entry.operationContextID
        runID = entry.runID
        resultPath = Self.canonical(entry.resultPath)
        resultName = entry.resultName
        resultRevision = entry.resultRevision
        status = entry.status
    }

    var id: String {
        "transient-result-compute:" + [projectSessionID.uuidString, runID, resultPath]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    var node: LayerTreeNode {
        LayerTreeNode(
            id: id,
            sourceClass: "TransientResultComputeNode",
            name: resultName,
            assetID: resultPath,
            properties: [
                .init(id: "Name", label: "Name", value: resultName),
                .init(id: "Filename", label: "Filename", value: resultPath)
            ],
            catalogSummary: .init(name: resultName, filename: resultPath),
            resultComputeSourcePath: resultPath,
            resultComputeSourceRevision: resultRevision,
            transientResultComputeRunID: runID,
            transientResultComputeStatus: status.rawValue)
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

enum TransientResultComputeProjection {
    private static let materializedResultClasses: Set<String> = [
        "ObservableResult", "ResultNode", "ResultNodeVM"
    ]

    static func materializedResultPaths(in roots: [LayerTreeNode]?) -> Set<String> {
        var paths = Set<String>()
        func visit(_ node: LayerTreeNode) {
            if materializedResultClasses.contains(node.sourceClass),
               let path = node.resultComputeSourcePath ?? node.assetID, !path.isEmpty {
                paths.insert(canonical(path))
            }
            for child in node.children ?? [] { visit(child) }
        }
        for root in roots ?? [] { visit(root) }
        return paths
    }

    static func apply(snapshotRoots: [LayerTreeNode]?, rows: [String: TransientResultComputeRow],
                      projectSessionID: UUID?) -> [LayerTreeNode]? {
        guard let projectSessionID else { return snapshotRoots }
        let candidates = rows.values
            .filter { $0.projectSessionID == projectSessionID }
            .sorted { $0.resultPath.localizedStandardCompare($1.resultPath) == .orderedAscending }
        guard !candidates.isEmpty else { return snapshotRoots }

        let materialized = materializedResultPaths(in: snapshotRoots)
        let missing = candidates.filter { !materialized.contains(canonical($0.resultPath)) }
        guard !missing.isEmpty else { return snapshotRoots }
        let transientNodes = missing.map(\.node)

        guard var roots = snapshotRoots else {
            return [catalogRoot(projectSessionID: projectSessionID, resultNodes: transientNodes)]
        }
        let resultGroupCount = countResultsGroups(in: roots)
        if resultGroupCount == 1 {
            roots = roots.map { inserting(transientNodes, into: $0) }
            return roots
        }

        let resultGroup = resultsGroup(projectSessionID: projectSessionID, nodes: transientNodes)
        if roots.count == 1, roots[0].sourceClass == "ModelSectionContext" {
            var root = roots[0]
            root.children = (root.children ?? []) + [resultGroup]
            roots[0] = root
        } else {
            roots.append(resultGroup)
        }
        return roots
    }

    private static func countResultsGroups(in roots: [LayerTreeNode]) -> Int {
        func count(_ node: LayerTreeNode) -> Int {
            let current = node.sourceClass == "ResultRootContext" && node.name == "Results" ? 1 : 0
            return current + (node.children ?? []).reduce(0) { $0 + count($1) }
        }
        return roots.reduce(0) { $0 + count($1) }
    }

    private static func inserting(_ nodes: [LayerTreeNode], into node: LayerTreeNode) -> LayerTreeNode {
        var copy = node
        if copy.sourceClass == "ResultRootContext", copy.name == "Results" {
            copy.children = (copy.children ?? []) + nodes
            return copy
        }
        if let children = copy.children {
            copy.children = children.map { inserting(nodes, into: $0) }
        }
        return copy
    }

    private static func catalogRoot(projectSessionID: UUID, resultNodes: [LayerTreeNode]) -> LayerTreeNode {
        LayerTreeNode(
            id: "transient-catalog:\(projectSessionID.uuidString)",
            sourceClass: "ModelSectionContext",
            name: "Project",
            localizeName: true,
            children: [resultsGroup(projectSessionID: projectSessionID, nodes: resultNodes)])
    }

    private static func resultsGroup(projectSessionID: UUID, nodes: [LayerTreeNode]) -> LayerTreeNode {
        LayerTreeNode(
            id: "transient-results:\(projectSessionID.uuidString)",
            sourceClass: "ResultRootContext",
            name: "Results",
            localizeName: true,
            children: nodes)
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}
