import Foundation
import RASWorkspaceCore

private struct RasterRGBExportInspectionRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String
    let currentView: RasterMapViewExtent?
}

private struct RasterRGBExportPreviewRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String
    let region: String
    let cellSize: Double
    let currentView: RasterMapViewExtent?
    let plotOptions: [String: String]
}

private struct RasterRGBExportExecuteRequest: Encodable, Sendable {
    let source: RasterMapSourceDescriptor
    let projectXml: String
    let region: String
    let cellSize: Double
    let currentView: RasterMapViewExtent?
    let outputPath: String
    let plotOptions: [String: String]
}

private struct DepthShapefileExportInspectionRequest: Encodable, Sendable {
    let map: ResultExportMapTreeRequest
    let selectionOverrides: [MapResultSelectionOverride]
    let contextToken: String
}

private struct DepthShapefileExportPreviewRequest: Encodable, Sendable {
    let map: ResultExportMapTreeRequest
    let selectionOverrides: [MapResultSelectionOverride]
    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let resultPath: String
    let resultRevision: String
    let profileIndex: Int
    let viewport: RasterMapViewExtent
    let cellSize: Double
    let simplifyDistance: Double
}

private struct DepthShapefileExportExecuteRequest: Encodable, Sendable {
    let map: ResultExportMapTreeRequest
    let selectionOverrides: [MapResultSelectionOverride]
    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let resultPath: String
    let resultRevision: String
    let profileIndex: Int
    let cellSize: Double
    let simplifyDistance: Double
    let outputPath: String
}

private struct ResultExportControl: Encodable, Sendable {
    let type = "cancel"
}

@MainActor
final class BackendResultExportProvider {
    private let client: BackendProcessClient
    private var activeRasterOperation: BackendDuplexOperation<ResultExportControl,
        BackendProgressUpdate, RasterRGBExportExecutionResult>?
    private var activeDepthOperation: BackendDuplexOperation<ResultExportControl,
        BackendProgressUpdate, DepthShapefileExportExecutionResult>?

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspectRaster(_ capture: RasterRGBExportCapture) async throws -> RasterRGBExportInspection {
        let request = RasterRGBExportInspectionRequest(source: capture.source,
            projectXml: capture.projectXml, currentView: capture.currentView)
        return try await client.request("rasterExport.inspect", parameters: request,
            as: RasterRGBExportInspection.self)
    }

    func previewRaster(_ capture: RasterRGBExportCapture, inspection: RasterRGBExportInspection,
                       region: RasterRGBExportRegion, cellSize: Double,
                       plotOptions: [String: String]) async throws -> RasterRGBExportPreview {
        let request = RasterRGBExportPreviewRequest(source: capture.source,
            projectXml: capture.projectXml, region: region.rawValue, cellSize: cellSize,
            currentView: capture.currentView, plotOptions: plotOptions)
        let response: RasterRGBExportPreview = try await client.request("rasterExport.preview",
            parameters: request)
        try ResultExportReplyValidation.rasterPreview(response, capture: capture,
            inspection: inspection, region: region, cellSize: cellSize)
        return response
    }

    func exportRaster(_ capture: RasterRGBExportCapture, inspection: RasterRGBExportInspection,
                      region: RasterRGBExportRegion, cellSize: Double, outputPath: String,
                      plotOptions: [String: String],
                      progress: @MainActor (BackendProgressUpdate) -> Void) async throws -> RasterRGBExportExecutionResult {
        let request = RasterRGBExportExecuteRequest(source: capture.source,
            projectXml: capture.projectXml, region: region.rawValue, cellSize: cellSize,
            currentView: capture.currentView, outputPath: outputPath, plotOptions: plotOptions)
        let operation = try client.startDuplex("rasterExport.execute", parameters: request,
            control: ResultExportControl.self, event: BackendProgressUpdate.self,
            as: RasterRGBExportExecutionResult.self)
        activeRasterOperation = operation
        defer { activeRasterOperation = nil }
        var cancellationSent = false
        for try await update in operation.events {
            if Task.isCancelled && !cancellationSent {
                cancel(operation)
                cancellationSent = true
            }
            progress(update)
        }
        let response = try await operation.value()
        try ResultExportReplyValidation.rasterExecution(response, capture: capture,
            inspection: inspection, outputPath: outputPath, cellSize: cellSize)
        return response
    }

    func inspectDepth(_ capture: DepthShapefileExportCapture) async throws -> DepthShapefileExportInspection {
        let request = DepthShapefileExportInspectionRequest(map: capture.mapTree,
            selectionOverrides: capture.selectionOverrides, contextToken: capture.contextToken)
        let response: DepthShapefileExportInspection = try await client.request("depthExport.inspect",
            parameters: request)
        try ResultExportReplyValidation.depthInspection(response, capture: capture)
        return response
    }

    func previewDepth(_ capture: DepthShapefileExportCapture,
                      owner: DepthShapefileExportOwner,
                      profile: DepthShapefileExportProfile,
                      cellSize: Double, simplifyDistance: Double) async throws -> DepthShapefileExportPreview {
        guard let viewport = capture.viewport else {
            throw BackendServiceError(code: "invalidInput", message: L10n.text("A current map view is required for the contour preview."))
        }
        let request = DepthShapefileExportPreviewRequest(map: capture.mapTree,
            selectionOverrides: capture.selectionOverrides, contextToken: capture.contextToken,
            resultNode: owner.node, selectionIndex: 0, resultPath: owner.resultPath,
            resultRevision: owner.resultRevision, profileIndex: profile.index,
            viewport: viewport, cellSize: cellSize, simplifyDistance: simplifyDistance)
        let response: DepthShapefileExportPreview = try await client.request("depthExport.preview",
            parameters: request)
        try ResultExportReplyValidation.depthPreview(response, capture: capture,
            owner: owner, profile: profile, cellSize: cellSize,
            simplifyDistance: simplifyDistance)
        return response
    }

    func exportDepth(_ capture: DepthShapefileExportCapture,
                     owner: DepthShapefileExportOwner,
                     profile: DepthShapefileExportProfile,
                     cellSize: Double, simplifyDistance: Double, outputPath: String,
                     progress: @MainActor (BackendProgressUpdate) -> Void) async throws -> DepthShapefileExportExecutionResult {
        let request = DepthShapefileExportExecuteRequest(map: capture.mapTree,
            selectionOverrides: capture.selectionOverrides, contextToken: capture.contextToken,
            resultNode: owner.node, selectionIndex: 0, resultPath: owner.resultPath,
            resultRevision: owner.resultRevision, profileIndex: profile.index,
            cellSize: cellSize, simplifyDistance: simplifyDistance, outputPath: outputPath)
        let operation = try client.startDuplex("depthExport.execute", parameters: request,
            control: ResultExportControl.self, event: BackendProgressUpdate.self,
            as: DepthShapefileExportExecutionResult.self)
        activeDepthOperation = operation
        defer { activeDepthOperation = nil }
        var cancellationSent = false
        for try await update in operation.events {
            if Task.isCancelled && !cancellationSent {
                cancel(operation)
                cancellationSent = true
            }
            progress(update)
        }
        let response = try await operation.value()
        try ResultExportReplyValidation.depthExecution(response, capture: capture,
            owner: owner, profile: profile, outputPath: outputPath,
            cellSize: cellSize, simplifyDistance: simplifyDistance)
        return response
    }

    func cancelActiveExport() {
        if let activeRasterOperation { cancel(activeRasterOperation) }
        if let activeDepthOperation { cancel(activeDepthOperation) }
    }

    private func cancel<Control, Event, Result>(
        _ operation: BackendDuplexOperation<Control, Event, Result>
    ) where Control: Encodable & Sendable, Event: Decodable & Sendable,
           Result: Decodable & Sendable {
        if !operation.requestSourceCancellation() { operation.cancel() }
    }
}
