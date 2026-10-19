import Foundation

@MainActor
final class MapTreeMeshErrorDraftProvider: MapTreeMeshErrorProviding {
    typealias DraftScan = @MainActor (MapTreeMeshErrorContext, Int) async throws -> MapTreeMeshErrorDraftScanResult

    private let savedSource: any MapTreeMeshErrorProviding
    private let scanDraft: DraftScan

    init(savedSource: any MapTreeMeshErrorProviding, scanDraft: @escaping DraftScan) {
        self.savedSource = savedSource
        self.scanDraft = scanDraft
    }

    func load(_ context: MapTreeMeshErrorContext) async throws -> MapTreeMeshErrorSnapshot {
        let saved = try await savedSource.load(context)
        return try await currentMeshSnapshot(saved, context: context)
    }

    func set(_ context: MapTreeMeshErrorContext, checkMeshErrors: Bool?,
             maxFacesPerNodeEntry: Double?) async throws
        -> (MapTreeMeshErrorContext, MapTreeMeshErrorSnapshot) {
        let (updatedContext, saved) = try await savedSource.set(context,
            checkMeshErrors: checkMeshErrors, maxFacesPerNodeEntry: maxFacesPerNodeEntry)
        return (updatedContext, try await currentMeshSnapshot(saved, context: updatedContext))
    }

    private func currentMeshSnapshot(_ saved: MapTreeMeshErrorSnapshot,
                                     context: MapTreeMeshErrorContext) async throws
        -> MapTreeMeshErrorSnapshot {
        guard let draftIdentity = context.geometryMeshDraftIdentity else { return saved }
        let result = MapTreeMeshErrorSnapshotCopy.replacing(saved,
            geometryMeshDraftIdentity: draftIdentity, issues: [],
            totalIssueCount: 0, omittedIssueCount: 0)
        guard saved.checkMeshErrors else {
            return MapTreeMeshErrorSnapshotCopy.replacing(result,
                status: "disabled", diagnostic: .some(nil))
        }
        guard saved.status == "draftSettings" || saved.status == "available" || saved.status == "partial" else {
            return result
        }
        let draftResult = try await scanDraft(context, saved.maxFacesPerNode)
        let visibleResult = MapTreeMeshErrorSnapshotCopy.replacing(result,
            isChecked: draftResult.mapVisible,
            isEffectivelyVisible: draftResult.mapVisible)
        guard let scan = draftResult.scan else {
            return MapTreeMeshErrorSnapshotCopy.replacing(visibleResult,
                status: "draftPending",
                diagnostic: "Mesh diagnostics are waiting for the current generated mesh draft.")
        }
        guard scan.maxFacesPerNode == saved.maxFacesPerNode else {
            return MapTreeMeshErrorSnapshotCopy.replacing(visibleResult,
                status: "draftUnavailable",
                diagnostic: "The generated mesh scan returned a different threshold.")
        }
        return MapTreeMeshErrorDraftProjection.install(scan, on: visibleResult,
            draftIdentity: draftIdentity)
    }
}

private enum MapTreeMeshErrorSnapshotCopy {
    static func replacing(_ source: MapTreeMeshErrorSnapshot,
                          geometryMeshDraftIdentity: String? = nil,
                          isChecked: Bool? = nil,
                          isEffectivelyVisible: Bool? = nil,
                          status: String? = nil,
                          diagnostic: String?? = nil,
                          issues: [MapTreeMeshErrorIssue]? = nil,
                          totalIssueCount: Int? = nil,
                          omittedIssueCount: Int? = nil) -> MapTreeMeshErrorSnapshot {
        let nextDiagnostic: String?
        if let diagnostic {
            nextDiagnostic = diagnostic
        } else {
            nextDiagnostic = source.diagnostic
        }
        return MapTreeMeshErrorSnapshot(
            projectSessionID: source.projectSessionID,
            mapWorkflowIdentity: source.mapWorkflowIdentity,
            contextToken: source.contextToken,
            projectCanonicalPath: source.projectCanonicalPath,
            projectRevision: source.projectRevision,
            projectXmlSHA: source.projectXmlSHA,
            visualizationRevision: source.visualizationRevision,
            mapID: source.mapID,
            mapIndex: source.mapIndex,
            mapName: source.mapName,
            mapType: source.mapType,
            flowAreaNode: source.flowAreaNode,
            sourcePath: source.sourcePath,
            sourceRevision: source.sourceRevision,
            checkMeshErrors: source.checkMeshErrors,
            maxFacesPerNode: source.maxFacesPerNode,
            isChecked: isChecked ?? source.isChecked,
            isEffectivelyVisible: isEffectivelyVisible ?? source.isEffectivelyVisible,
            status: status ?? source.status,
            diagnostic: nextDiagnostic,
            issues: issues ?? source.issues,
            totalIssueCount: totalIssueCount ?? source.totalIssueCount,
            omittedIssueCount: omittedIssueCount ?? source.omittedIssueCount,
            previousVisualizationRevision: source.previousVisualizationRevision,
            geometryMeshDraftIdentity: geometryMeshDraftIdentity ?? source.geometryMeshDraftIdentity)
    }
}

struct MapTreeMeshErrorDraftScanResult: Sendable {
    let scan: GeometryMeshDegreeScan?
    let mapVisible: Bool
}

@MainActor
enum MapTreeMeshErrorDraftProjection {
    static let issueLimit = 10_000

    static func install(_ scan: GeometryMeshDegreeScan,
                        on saved: MapTreeMeshErrorSnapshot,
                        draftIdentity: String) -> MapTreeMeshErrorSnapshot {
        let projected = scan.issues.compactMap { issue -> MapTreeMeshErrorIssue? in
            guard issue.meshIndex >= 0, issue.nodeIndex >= 0, issue.faceCount >= 0,
                  let x = issue.x, let y = issue.y, x.isFinite, y.isFinite else { return nil }
            let cells = (issue.cells ?? []).compactMap { cell -> MapTreeMeshErrorCell? in
                guard cell.cellIndex >= 0, cell.coordinates.count >= 3,
                      cell.coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
                return MapTreeMeshErrorCell(cellIndex: cell.cellIndex,
                    coordinates: cell.coordinates.map { MapTreeMeshErrorCoordinate(x: $0.x, y: $0.y) })
            }
            let extent = issue.cellsExtent
            return MapTreeMeshErrorIssue(id: issue.id, meshIndex: issue.meshIndex,
                nodeIndex: issue.nodeIndex, faceCount: issue.faceCount,
                node: MapTreeMeshErrorCoordinate(x: x, y: y),
                cellsMinX: extent?.minX, cellsMinY: extent?.minY,
                cellsMaxX: extent?.maxX, cellsMaxY: extent?.maxY, cells: cells)
        }
        let retained = Array(projected.prefix(issueLimit))
        let omittedCount = max(0, scan.issues.count - retained.count)
        return MapTreeMeshErrorSnapshotCopy.replacing(saved,
            geometryMeshDraftIdentity: draftIdentity,
            status: omittedCount == 0 ? "available" : "partial",
            diagnostic: .some(omittedCount == 0 ? nil
                : L10n.format("%d mesh errors were omitted from the map response.", omittedCount)),
            issues: retained, totalIssueCount: scan.issues.count,
            omittedIssueCount: omittedCount)
    }
}

enum MapTreeMeshErrorDraftIdentity {
    static func presentationIdentity(captureIdentity: String,
                                     sourceRevision: String,
                                     resultIdentity: String,
                                     snapshot: GeometryMeshSnapshot) -> String? {
        guard snapshot.revision.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              snapshot.isDirty, snapshot.generationReport?.meshWasReplaced == true,
              let map = snapshot.map else { return nil }
        let extentIdentity: String
        if let extent = map.extent {
            extentIdentity = [extent.minX, extent.minY, extent.maxX, extent.maxY]
                .map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
        } else {
            extentIdentity = "missing"
        }
        let rowIdentity = snapshot.flowAreas.map {
            $0.id + ":" + $0.name + ":" + String($0.cellCount)
        }.joined(separator: "|")
        let mapIdentity = "\(map.totalCellCount):\(map.renderedCellCount):\(map.omittedCellCount):\(map.invalidCandidateCount)"
        return captureIdentity + "|draft|" + resultIdentity + "|" + sourceRevision
            + "|" + snapshot.draftState + "|" + rowIdentity + "|" + extentIdentity + "|" + mapIdentity
    }
}
