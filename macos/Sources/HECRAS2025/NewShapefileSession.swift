import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

enum NewShapefileGeometryType: String, CaseIterable, Identifiable, Sendable {
    case point = "Point"
    case polyline = "Polyline"
    case polygon = "Polygon"

    var id: String { rawValue }
}

enum NewShapefileProjectionChoice: String, CaseIterable, Identifiable, Sendable {
    case project = "Project"
    case local = "Local"

    var id: String { rawValue }
}

struct NewShapefileMapRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let expectedVisualizationRevision: String?
    let kind: String
    let mapID: String
    let mapIndex: Int?
    let mapName: String?
    let mapType: String?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct NewShapefileCreateRequest: Encodable, Sendable {
    let map: NewShapefileMapRequest
    let expectedProjectRevision: String
    let projectSessionID: String
    let mapID: String
    let operationID: String
    let destinationPath: String
    let shapeType: String
    let projectionChoice: String
}

struct NewShapefileCreateReceipt: Decodable, Hashable, Sendable {
    let operationID: String
    let projectSessionID: String
    let mapID: String
    let projectPath: String
    let projectRevision: String
    let visualizationRevision: String?
    let mapIndex: Int?
    let mapName: String?
    let mapType: String
    let destinationPath: String
    let shapeType: String
    let projectionChoice: String
    let projectionWKT: String?
    let family: MapSourceFamilyCapture
    let createdUtc: String
}

struct NewShapefileMapContext: Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let projectPath: URL
    let projectRevision: String
    let map: NewShapefileMapRequest
    let projectionType: String
    let projectionValue: String
    let defaultDirectory: URL

    var isLocalProject: Bool {
        projectionType.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Local") == .orderedSame
    }

    var defaultProjectionChoice: NewShapefileProjectionChoice {
        isLocalProject ? .local : .project
    }

    @MainActor var projectionSummary: String {
        let type = projectionType.isEmpty ? L10n.text("Not specified") : L10n.text(projectionType)
        return projectionValue.isEmpty ? type : type + " · " + projectionValue
    }
}

@MainActor
protocol NewShapefileCreationProvider {
    func create(_ request: NewShapefileCreateRequest) async throws -> NewShapefileCreateReceipt
}

@MainActor
struct BackendNewShapefileProvider: NewShapefileCreationProvider {
    let client: BackendProcessClient

    func create(_ request: NewShapefileCreateRequest) async throws -> NewShapefileCreateReceipt {
        let receipt = try await client.request("map.shapefile.create", parameters: request,
            as: NewShapefileCreateReceipt.self)
        try validate(receipt, request: request)
        return receipt
    }

    private func validate(_ receipt: NewShapefileCreateReceipt,
                          request: NewShapefileCreateRequest) throws {
        let expectedPath = SourceFilePaths.canonical(URL(fileURLWithPath: request.destinationPath))
        let returnedPath = SourceFilePaths.canonical(URL(fileURLWithPath: receipt.destinationPath))
        let sourcePath = SourceFilePaths.canonical(URL(fileURLWithPath: receipt.family.sourcePath))
        let expectedProjectPath = SourceFilePaths.canonical(URL(fileURLWithPath: request.map.projectPath))
        let returnedProjectPath = SourceFilePaths.canonical(URL(fileURLWithPath: receipt.projectPath))
        let filesByRole = Dictionary(grouping: receipt.family.files, by: \.role)
        let requiredRoles = ["source", "shx", "dbf"]
        let requiredMembersAreValid = requiredRoles.allSatisfy { role in
            guard let matches = filesByRole[role], matches.count == 1,
                  let revision = matches[0].revision else { return false }
            return matches[0].required && matches[0].exists && revision.count == 64
                && revision.allSatisfy(\.isHexDigit)
        }
        let projectionMembers = filesByRole["prj"] ?? []
        let projectionMember = projectionMembers.count == 1 ? projectionMembers.first : nil
        let projectionIsValid = request.projectionChoice == NewShapefileProjectionChoice.project.rawValue
            ? receipt.projectionWKT?.isEmpty == false && projectionMember?.exists == true
            : receipt.projectionWKT == nil && projectionMember?.exists == false
        guard receipt.operationID.caseInsensitiveCompare(request.operationID) == .orderedSame,
              receipt.projectSessionID.caseInsensitiveCompare(request.projectSessionID) == .orderedSame,
              receipt.mapID.caseInsensitiveCompare(request.mapID) == .orderedSame,
              returnedProjectPath == expectedProjectPath,
              receipt.projectRevision.caseInsensitiveCompare(request.expectedProjectRevision) == .orderedSame,
              receipt.visualizationRevision == request.map.expectedVisualizationRevision,
              receipt.mapIndex == request.map.mapIndex,
              receipt.mapName == request.map.mapName,
              receipt.mapType == (request.map.mapType ?? request.map.kind),
              returnedPath == expectedPath, sourcePath == expectedPath,
              receipt.shapeType == request.shapeType,
              receipt.projectionChoice == request.projectionChoice,
              projectionIsValid, requiredMembersAreValid,
              projectionMembers.count == 1, projectionMember?.required == false,
              receipt.family.family == "shapefile",
              receipt.family.revision.count == 64,
              receipt.family.revision.allSatisfy(\.isHexDigit),
              receipt.family.files.count == 4 else {
            throw BackendServiceError(code: "protocolFailure",
                message: "The backend returned a Shapefile receipt for a different map, project, or destination.")
        }
    }
}

@MainActor
final class NewShapefileSession: ObservableObject {
    typealias ImportCreatedShapefile = @MainActor (NewShapefileCreateReceipt) async throws -> Void

    let context: NewShapefileMapContext
    @Published var filename = "New Layer"
    @Published var destinationDirectory: URL
    @Published var geometryType: NewShapefileGeometryType = .point
    @Published var projectionChoice: NewShapefileProjectionChoice
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var createdReceipt: NewShapefileCreateReceipt?
    @Published private(set) var didImport = false

    private let provider: any NewShapefileCreationProvider
    private let operationID = UUID()
    private let isContextCurrent: @MainActor () -> Bool
    private let importCreated: ImportCreatedShapefile

    init(context: NewShapefileMapContext, provider: any NewShapefileCreationProvider,
         isContextCurrent: @escaping @MainActor () -> Bool,
         importCreated: @escaping ImportCreatedShapefile) {
        self.context = context
        self.provider = provider
        self.isContextCurrent = isContextCurrent
        self.importCreated = importCreated
        self.destinationDirectory = context.defaultDirectory
        self.projectionChoice = context.defaultProjectionChoice
    }

    var destinationPath: String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.lowercased().hasSuffix(".shp") ? String(trimmed.dropLast(4)) : trimmed
        return destinationDirectory.appendingPathComponent(base + ".shp").standardizedFileURL.path
    }

    var canCreate: Bool {
        !isBusy && !didImport && createdReceipt == nil && isContextCurrent()
            && !normalizedFilename.isEmpty && allowedProjectionChoices.contains(projectionChoice)
    }

    var canRetryImport: Bool {
        !isBusy && !didImport && createdReceipt != nil && isContextCurrent()
    }

    var allowedProjectionChoices: [NewShapefileProjectionChoice] {
        context.isLocalProject ? [.local] : [.project]
    }

    var fileNameIsValid: Bool {
        let value = normalizedFilename
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return URL(fileURLWithPath: value).lastPathComponent == value
            && !value.contains(":")
    }

    var normalizedFilename: String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasSuffix(".shp") ? String(trimmed.dropLast(4)) : trimmed
    }

    func createOrRetryImport() async -> Bool {
        if createdReceipt != nil { return await retryImport() }
        guard canCreate, fileNameIsValid else {
            errorMessage = L10n.text("Choose a valid file name and map context.")
            return false
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let request = NewShapefileCreateRequest(map: context.map,
                expectedProjectRevision: context.projectRevision,
                projectSessionID: context.projectSessionID.uuidString,
                mapID: context.mapID.uuidString, operationID: operationID.uuidString,
                destinationPath: destinationPath,
                shapeType: geometryType.rawValue,
                projectionChoice: projectionChoice.rawValue)
            let receipt = try await provider.create(request)
            // Preserve this before checking view ownership or starting import.
            // A failed map transaction can then retry from the real family.
            createdReceipt = receipt
            guard isContextCurrent() else {
                errorMessage = L10n.text("The Shapefile was created, but the selected project or map changed. Its files are preserved.")
                return false
            }
            try await importCreated(receipt)
            didImport = true
            return true
        } catch {
            errorMessage = L10n.text(error.localizedDescription)
            return false
        }
    }

    func retryImport() async -> Bool {
        guard canRetryImport, let receipt = createdReceipt else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await importCreated(receipt)
            didImport = true
            return true
        } catch {
            errorMessage = L10n.text(error.localizedDescription)
            return false
        }
    }
}

@MainActor
extension WorkspaceStore {
    func captureNewShapefileContext(mapID: UUID) throws -> NewShapefileMapContext {
        guard !isOpeningProject, !isRunningProjectTool, !isSavingAll, !isClosingTab,
              let document, let projectPath = document.url,
              let projectRevision = document.sourceRevision,
              runtimeInfoClient != nil else {
            throw BackendServiceError(code: "unsupported",
                message: "Open a saved project and choose a map before creating a Shapefile.")
        }
        let projectXML = document.editorXML(overridingDescription: descriptionDraft)
        let projectXMLSHA = SHA256.hash(data: Data(projectXML.utf8))
            .map { String(format: "%02X", $0) }.joined()
        let coreLayerContext = captureCoreLayerRequestContext()
        let map: NewShapefileMapRequest
        if let savedMap = catalogMapDocuments.first(where: { $0.id.caseInsensitiveCompare(mapID.uuidString) == .orderedSame }),
           let index = savedMap.sourceIndex {
            guard ["Project", "Buildable", "Geometry", "Plan"].contains(savedMap.kind),
                  let visualizationRevision = savedMap.visualizationRevision else {
                throw BackendServiceError(code: "unsupported", message: "Select a saved map before creating a Shapefile.")
            }
            map = NewShapefileMapRequest(projectPath: projectPath.path, projectXml: projectXML,
                projectXmlSHA: projectXMLSHA, expectedVisualizationRevision: visualizationRevision,
                kind: savedMap.kind, mapID: savedMap.id, mapIndex: index,
                mapName: savedMap.name, mapType: savedMap.kind,
                coreLayerContext: coreLayerContext)
        } else {
            guard mapID == MapState.projectMapID,
                  !catalogMapDocuments.contains(where: { $0.sourceIndex != nil }) else {
                throw BackendServiceError(code: "unsupported", message: "Select a saved map before creating a Shapefile.")
            }
            map = NewShapefileMapRequest(projectPath: projectPath.path, projectXml: projectXML,
                projectXmlSHA: projectXMLSHA, expectedVisualizationRevision: nil,
                kind: "Project", mapID: mapID.uuidString, mapIndex: nil,
                mapName: nil, mapType: nil, coreLayerContext: coreLayerContext)
        }
        return NewShapefileMapContext(projectSessionID: projectSessionID, mapID: mapID,
            projectPath: projectPath, projectRevision: projectRevision, map: map,
            projectionType: document.projectionType, projectionValue: document.projectionValue,
            defaultDirectory: projectPath.deletingLastPathComponent()
                .appendingPathComponent("Exports", isDirectory: true))
    }
}
