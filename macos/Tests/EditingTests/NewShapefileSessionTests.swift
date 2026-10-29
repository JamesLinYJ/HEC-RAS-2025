import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class NewShapefileTestProvider: NewShapefileCreationProvider {
    private(set) var requests: [NewShapefileCreateRequest] = []
    var receiptFactory: (NewShapefileCreateRequest) -> NewShapefileCreateReceipt

    init(receiptFactory: @escaping (NewShapefileCreateRequest) -> NewShapefileCreateReceipt) {
        self.receiptFactory = receiptFactory
    }

    func create(_ request: NewShapefileCreateRequest) async throws -> NewShapefileCreateReceipt {
        requests.append(request)
        return receiptFactory(request)
    }
}

@MainActor
private final class NewShapefileTestState {
    var shouldFailImport = true
    var contextIsCurrent = true
    var importCount = 0
}

@MainActor
struct NewShapefileSessionTests {
    @Test func importRetryKeepsReceiptAndDoesNotRunWriterAgain() async {
        let context = makeContext()
        let provider = NewShapefileTestProvider { request in makeReceipt(request: request, context: context) }
        let state = NewShapefileTestState()
        let session = NewShapefileSession(context: context, provider: provider,
            isContextCurrent: { true }, importCreated: { _ in
                state.importCount += 1
                if state.shouldFailImport {
                    throw BackendServiceError(code: "mapImportFailed", message: "Expected first import failure.")
                }
            })
        session.filename = "New stream"
        session.geometryType = .polyline

        let firstAttempt = await session.createOrRetryImport()
        #expect(!firstAttempt)
        #expect(session.createdReceipt?.destinationPath.hasSuffix("New stream.shp") == true)
        #expect(provider.requests.count == 1)
        #expect(state.importCount == 1)

        state.shouldFailImport = false
        let secondAttempt = await session.createOrRetryImport()
        #expect(secondAttempt)
        #expect(session.didImport)
        #expect(provider.requests.count == 1)
        #expect(state.importCount == 2)
        #expect(provider.requests.first?.shapeType == "Polyline")
        #expect(provider.requests.first?.projectionChoice == "Local")
    }

    @Test func staleMapContextDoesNotCreateFiles() async {
        let context = makeContext()
        let provider = NewShapefileTestProvider { request in makeReceipt(request: request, context: context) }
        let session = NewShapefileSession(context: context, provider: provider,
            isContextCurrent: { false }, importCreated: { _ in })

        let result = await session.createOrRetryImport()
        #expect(!result)
        #expect(provider.requests.isEmpty)
        #expect(session.createdReceipt == nil)
    }

    @Test func contextBecomingStaleAfterCreationPreservesReceiptAndCanRetryWithoutRecreating() async {
        let context = makeContext()
        let state = NewShapefileTestState()
        let provider = NewShapefileTestProvider { request in
            state.contextIsCurrent = false
            return makeReceipt(request: request, context: context)
        }
        let session = NewShapefileSession(context: context, provider: provider,
            isContextCurrent: { state.contextIsCurrent }, importCreated: { _ in state.importCount += 1 })

        let firstAttempt = await session.createOrRetryImport()
        let preservedReceipt = session.createdReceipt
        #expect(!firstAttempt)
        #expect(preservedReceipt != nil)
        #expect(!session.didImport)
        #expect(provider.requests.count == 1)
        #expect(state.importCount == 0)

        state.contextIsCurrent = true
        let retry = await session.createOrRetryImport()
        #expect(retry)
        #expect(session.didImport)
        #expect(session.createdReceipt == preservedReceipt)
        #expect(provider.requests.count == 1)
        #expect(state.importCount == 1)
    }

    private func makeContext() -> NewShapefileMapContext {
        let projectID = UUID()
        let mapID = UUID()
        let projectPath = FileManager.default.temporaryDirectory.appendingPathComponent("session.ras")
        let xml = "<Project />"
        let map = NewShapefileMapRequest(projectPath: projectPath.path, projectXml: xml,
            projectXmlSHA: String(repeating: "A", count: 64), expectedVisualizationRevision: nil,
            kind: "Project", mapID: mapID.uuidString, mapIndex: nil, mapName: nil, mapType: nil)
        return NewShapefileMapContext(projectSessionID: projectID, mapID: mapID,
            projectPath: projectPath, projectRevision: String(repeating: "B", count: 64), map: map,
            projectionType: "Local", projectionValue: "", defaultDirectory: FileManager.default.temporaryDirectory)
    }

    private func makeReceipt(request: NewShapefileCreateRequest,
                             context: NewShapefileMapContext) -> NewShapefileCreateReceipt {
        let path = request.destinationPath
        let family = MapSourceFamilyCapture(family: "shapefile", sourcePath: path,
            revision: String(repeating: "C", count: 64), files: [
                .init(inputPath: path, path: path, role: "source", required: true, exists: true,
                      revision: String(repeating: "1", count: 64)),
                .init(inputPath: path, path: path.replacingOccurrences(of: ".shp", with: ".shx"),
                      role: "shx", required: true, exists: true, revision: String(repeating: "2", count: 64)),
                .init(inputPath: path, path: path.replacingOccurrences(of: ".shp", with: ".dbf"),
                      role: "dbf", required: true, exists: true, revision: String(repeating: "3", count: 64)),
                .init(inputPath: path, path: path.replacingOccurrences(of: ".shp", with: ".prj"),
                      role: "prj", required: false, exists: false, revision: nil)
            ])
        return NewShapefileCreateReceipt(operationID: request.operationID,
            projectSessionID: context.projectSessionID.uuidString, mapID: context.mapID.uuidString,
            projectPath: context.projectPath.path, projectRevision: context.projectRevision,
            visualizationRevision: nil, mapIndex: nil, mapName: nil, mapType: "Project",
            destinationPath: path, shapeType: request.shapeType,
            projectionChoice: request.projectionChoice, projectionWKT: nil,
            family: family, createdUtc: "2026-10-19T00:00:00Z")
    }
}
