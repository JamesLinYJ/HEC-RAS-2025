import CryptoKit
import Foundation
import RASWorkspaceCore

struct BugReportGeometryChoice: Equatable, Sendable, Identifiable {
    let assetID: String
    let name: String
    let path: String
    var revision: String? = nil
    var id: String { assetID }

    init(assetID: String, name: String, path: String, revision: String? = nil) {
        self.assetID = assetID
        self.name = name
        self.path = path
        self.revision = revision
    }
}

/// Exact project and launch context owned by WorkspaceStore. `projectXML` is
/// the current editor draft, including its unsaved Description; the backend
/// applies this same string only after checking its fingerprint and disk SHA.
struct BugReportNativeContext: Equatable, Sendable {
    let projectSessionID: UUID
    let projectPath: String?
    let projectRevision: String?
    let projectXML: String?
    let projectXMLFingerprint: String?
    let rasVersion: String?
    let applicationUID: String
    let crashContext: String?
    let geometries: [BugReportGeometryChoice]

    init(projectSessionID: UUID, projectPath: String?, projectRevision: String?,
         projectXML: String?, projectXMLFingerprint: String? = nil, rasVersion: String? = nil,
         applicationUID: String, crashContext: String? = nil,
         geometries: [BugReportGeometryChoice] = []) {
        self.projectSessionID = projectSessionID
        self.projectPath = projectPath
        self.projectRevision = projectRevision
        self.projectXML = projectXML
        self.projectXMLFingerprint = projectXMLFingerprint ?? projectXML.map(Self.fingerprint)
        self.rasVersion = rasVersion
        self.applicationUID = applicationUID
        self.crashContext = crashContext
        self.geometries = geometries
    }

    var effectiveProjectXMLFingerprint: String? {
        guard let projectXML else { return nil }
        let actual = Self.fingerprint(projectXML)
        guard projectXMLFingerprint?.caseInsensitiveCompare(actual) == .orderedSame else { return nil }
        return actual
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }
}

@MainActor
final class BackendBugReportProvider: ToolProvider {
    private let client: BackendProcessClient
    private var project: ProjectDocument?
    private var projectSessionID: UUID?
    private var prepareGeneration = 0
    private var contextGeneration = 0
    private var executing = false
    private var componentCache: (key: String, result: ComponentsResult)?
    private var geometryCaptures: [String: GeometryCapture] = [:]
    private var prepared: PreparedReport?

    var reportContext: @MainActor () -> BugReportNativeContext? = { nil }
    var onRunningChanged: (@MainActor (Bool) -> Void)?
    var onMessage: @MainActor (WorkspaceMessageSeverity, String) -> Void = { _, _ in }

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func setProject(_ document: ProjectDocument?, sessionID: UUID) {
        project = document
        projectSessionID = sessionID
        contextGeneration += 1
        prepareGeneration += 1
        componentCache = nil
        geometryCaptures.removeAll()
        prepared = nil
    }

    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        guard request.kind == ToolKind.reportIssue.id, !executing else { throw DataToolError.unavailable }
        prepareGeneration += 1
        let generation = prepareGeneration
        prepared = nil
        let captured = try currentContext(for: request)
        let contextGeneration = self.contextGeneration
        let cacheKey = stableContextKey(captured)

        let components: ComponentsResult
        if let componentCache, componentCache.key == cacheKey {
            components = componentCache.result
        } else {
            components = try await client.request("support.bugReport.components",
                parameters: ComponentsRequest(), as: ComponentsResult.self)
            try Task.checkCancellation()
            guard generation == prepareGeneration, self.contextGeneration == contextGeneration,
                  sameCurrentContext(captured) else { throw CancellationError() }
            guard !components.rasVersion.isEmpty,
                  Set(components.components.map(\.id)).count == components.components.count,
                  components.components.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else {
                throw BugReportProviderError.invalidResponse("The bug report service returned invalid categories.")
            }
            componentCache = (cacheKey, components)
        }
        guard let knownIssuesURL = URL(string: components.knownIssuesUrl),
              knownIssuesURL.scheme == "https", knownIssuesURL.host != nil,
              Set(components.components.map(\.id)).count == components.components.count,
              components.components.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else {
            throw BugReportProviderError.invalidResponse("The bug report service returned invalid categories.")
        }
        if let expectedVersion = captured.rasVersion, expectedVersion != components.rasVersion {
            throw BugReportProviderError.stale("The running HEC-RAS version changed while preparing the report.")
        }

        let selectedIDs = componentIDs(from: request.fields)
        let selectedGeometryID = request.fields["JiraBugReportForm/SelectedGeometry"] ?? ""
        let selectedGeometryComponent = components.components.contains {
            selectedIDs.contains($0.id) && $0.attachesGeometry
        }
        var selectedGeometryRevision: String?
        if selectedGeometryComponent, !selectedGeometryID.isEmpty {
            guard let geometry = captured.geometries.first(where: { $0.assetID == selectedGeometryID }) else {
                throw BugReportProviderError.stale("The selected Geometry is no longer in this Project.")
            }
            let requestIdentity = geometryCaptureKey(captured, geometry)
            if let cached = geometryCaptures[requestIdentity] {
                selectedGeometryRevision = cached.geometryRevision
            } else {
                let captureRequest = try geometryRequest(context: captured, geometry: geometry,
                    expectedGeometryRevision: geometry.revision)
                let capture = try await client.request("support.bugReport.geometryCapture",
                    parameters: captureRequest, as: GeometryCapture.self)
                try Task.checkCancellation()
                guard generation == prepareGeneration, self.contextGeneration == contextGeneration,
                      sameCurrentContext(captured) else { throw CancellationError() }
                try validate(capture, context: captured, geometry: geometry)
                geometryCaptures[requestIdentity] = capture
                selectedGeometryRevision = capture.geometryRevision
            }
        }

        guard generation == prepareGeneration, self.contextGeneration == contextGeneration,
              sameCurrentContext(captured) else { throw CancellationError() }

        var fields = request.fields
        if fields["JiraBugReportForm/SelectedGeometry"] == nil {
            fields["JiraBugReportForm/SelectedGeometry"] = ""
        }
        var editor = EditorSnapshot(fields: fields, rows: [:], samples: [:], canEdit: true, images: request.images)
        let choices = captured.geometries.map { geometry in
            EditorChoice(id: geometry.assetID,
                title: "\(geometry.name) — \(geometry.path)", titleIsUserData: true)
        }
        editor.choiceOptions["JiraBugReportForm/SelectedGeometry"] = choices

        var dataSent = [
            ReportDatum(id: "UID", label: "Application ID", value: captured.applicationUID),
            ReportDatum(id: "RasVersion", label: "RAS Version", value: components.rasVersion)
        ]
        if request.reportFromCrash, let crashContext = captured.crashContext, !crashContext.isEmpty {
            dataSent.append(ReportDatum(id: "CrashContext", label: "Crash context", value: crashContext))
        }
        let support = SupportPresentation(components: components.components.map {
            ReportComponent(id: $0.id, name: $0.name, attachesGeometry: $0.attachesGeometry)
        }, geometryChoices: choices, knownIssuesURL: knownIssuesURL, dataSent: dataSent,
            showsModelForm: false, modelUploadImplemented: false)
        prepared = PreparedReport(requestSignature: requestSignature(request), context: captured,
            contextGeneration: contextGeneration, componentIDs: Set(components.components.map(\.id)),
            rasVersion: components.rasVersion, geometryRevision: selectedGeometryRevision,
            componentGeometryAttachment: selectedGeometryComponent)
        return DataToolPresentation(editor: editor, canExecute: true, canCancel: false, support: support)
    }

    func execute(_ request: ToolRequest) async throws {
        guard request.kind == ToolKind.reportIssue.id, !executing,
              let prepared, prepared.requestSignature == requestSignature(request),
              prepared.contextGeneration == contextGeneration,
              sameCurrentContext(prepared.context) else {
            throw BugReportProviderError.stale("Refresh the report before submitting it.")
        }
        let selectedIDs = componentIDs(from: request.fields)
        guard selectedIDs.allSatisfy(prepared.componentIDs.contains) else {
            throw BugReportProviderError.stale("One or more report categories are no longer available.")
        }
        let geometryID = request.fields["JiraBugReportForm/SelectedGeometry"] ?? ""
        var geometryCaptureRequest: GeometryCaptureRequest?
        if prepared.componentGeometryAttachment, !geometryID.isEmpty {
            guard let choice = prepared.context.geometries.first(where: { $0.assetID == geometryID }),
                  let geometryRevision = prepared.geometryRevision else {
                throw BugReportProviderError.stale("The selected Geometry must be refreshed before submitting.")
            }
            geometryCaptureRequest = try geometryRequest(context: prepared.context, geometry: choice,
                expectedGeometryRevision: geometryRevision)
        }

        let fields = request.fields
        let imageAttachments = (request.images[BugReportLimits.imageField] ?? []).map { image in
            BugReportImageRequest(name: image.name, contentType: Self.contentType(for: image.name), data: image.data)
        }
        let crashContext: String?
        if let currentCrash = prepared.context.crashContext, !currentCrash.isEmpty {
            crashContext = currentCrash
        } else if request.reportFromCrash {
            crashContext = "The application was launched with the post-crash flag."
        } else {
            crashContext = nil
        }
        let contextGeneration = self.contextGeneration
        executing = true
        onRunningChanged?(true)
        defer {
            executing = false
            onRunningChanged?(false)
            self.prepared = nil
        }
        let errorLog = await Self.readApplicationLogTail()
        guard contextGeneration == self.contextGeneration,
              self.prepared?.requestSignature == prepared.requestSignature,
              sameCurrentContext(prepared.context) else {
            throw BugReportProviderError.stale("The report context changed before submission. Refresh the report and try again.")
        }
        let payload = SubmitRequest(uid: prepared.context.applicationUID, rasVersion: prepared.rasVersion,
            os: fields["JiraBugReportForm/Report_Os"] ?? ReportSystemInfo().os,
            cores: fields["JiraBugReportForm/Report_Cores"] ?? String(ProcessInfo.processInfo.processorCount),
            timezone: fields["JiraBugReportForm/Report_Timezone"] ?? TimeZone.current.identifier,
            email: fields["JiraBugReportForm/Report_Email"] ?? "",
            summary: fields["JiraBugReportForm/Report_Summary"] ?? "",
            description: fields["JiraBugReportForm/Report_Description"] ?? "",
            errorLog: errorLog, componentIDs: selectedIDs.sorted(), images: imageAttachments,
            crashContext: crashContext, geometry: geometryCaptureRequest)

        let receipt = try await client.request("support.bugReport.submit", parameters: payload,
            as: SubmitReceipt.self)
        guard !receipt.issueKey.isEmpty else {
            throw BugReportProviderError.invalidResponse("The bug report service returned an incomplete receipt.")
        }
        if receipt.attachmentWarnings.isEmpty {
            onMessage(.information, L10n.format("Bug report %@ was sent.", receipt.issueKey))
        } else {
            let warning = receipt.attachmentWarnings.map(L10n.text).joined(separator: " ")
            onMessage(.warning, L10n.format("Bug report %@ was sent, but some attachments failed.", receipt.issueKey)
                + " " + warning)
        }
    }

    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        try await prepare(request)
    }

    func searchProjections(_ query: String) async throws -> [ToolProjectionMatch] {
        throw DataToolError.unavailable
    }

    private func currentContext(for request: ToolRequest) throws -> BugReportNativeContext {
        guard let context = reportContext(), let sessionID = projectSessionID,
              request.context?.projectSessionID == sessionID,
              context.projectSessionID == sessionID,
              context.applicationUID.count == 10,
              context.applicationUID.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else {
            throw BugReportProviderError.stale("The report context is no longer available. Reopen the report.")
        }
        if let projectPath = context.projectPath {
            guard let project, let projectURL = project.url,
                  Self.canonicalPath(projectURL.path) == Self.canonicalPath(projectPath),
                  context.projectRevision.map(Self.isSHA256) == true,
                  context.projectXML != nil, context.effectiveProjectXMLFingerprint != nil else {
                throw BugReportProviderError.stale("The saved Project context is incomplete or has changed.")
            }
        } else if project != nil || context.projectXML != nil || !context.geometries.isEmpty {
            throw BugReportProviderError.stale("The Project context no longer matches the open document.")
        }
        guard Set(context.geometries.map(\.assetID)).count == context.geometries.count,
              context.geometries.allSatisfy({ choice in
                  URL(fileURLWithPath: choice.assetID).path == choice.assetID &&
                      URL(fileURLWithPath: choice.path).path == choice.path &&
                      Self.canonicalPath(choice.assetID) == Self.canonicalPath(choice.path) &&
                      !choice.name.isEmpty &&
                      (choice.revision.map(Self.isSHA256) ?? true)
              }) else {
            throw BugReportProviderError.stale("The Project Geometry choices are not uniquely identified.")
        }
        return context
    }

    private func sameCurrentContext(_ captured: BugReportNativeContext) -> Bool {
        guard let current = reportContext(), current.projectSessionID == captured.projectSessionID,
              projectSessionID == captured.projectSessionID,
              current.applicationUID == captured.applicationUID,
              current.projectRevision == captured.projectRevision,
              current.projectXML == captured.projectXML,
              current.rasVersion == captured.rasVersion,
              current.geometries == captured.geometries,
              current.effectiveProjectXMLFingerprint == captured.effectiveProjectXMLFingerprint,
              current.crashContext == captured.crashContext,
              Self.canonicalPath(current.projectPath ?? "") == Self.canonicalPath(captured.projectPath ?? "") else {
            return false
        }
        if let project = project, project.url.map({ Self.canonicalPath($0.path) }) != captured.projectPath.map(Self.canonicalPath) {
            return false
        }
        return true
    }

    private func geometryRequest(context: BugReportNativeContext, geometry: BugReportGeometryChoice,
                                 expectedGeometryRevision: String?) throws -> GeometryCaptureRequest {
        guard let projectPath = context.projectPath, let projectRevision = context.projectRevision,
              let projectXML = context.projectXML, let xmlFingerprint = context.effectiveProjectXMLFingerprint else {
            throw BugReportProviderError.stale("A saved Project is required to attach a Geometry.")
        }
        return GeometryCaptureRequest(projectPath: projectPath, expectedProjectRevision: projectRevision,
            projectXml: projectXML, projectXmlFingerprint: xmlFingerprint,
            geometryAssetID: geometry.assetID, geometryName: geometry.name,
            geometryPath: geometry.path, expectedGeometryRevision: expectedGeometryRevision)
    }

    private func validate(_ capture: GeometryCapture, context: BugReportNativeContext,
                          geometry: BugReportGeometryChoice) throws {
        guard Self.canonicalPath(capture.projectPath) == Self.canonicalPath(context.projectPath ?? ""),
              capture.projectRevision.caseInsensitiveCompare(context.projectRevision ?? "") == .orderedSame,
              capture.projectXmlFingerprint.caseInsensitiveCompare(context.effectiveProjectXMLFingerprint ?? "") == .orderedSame,
              capture.geometryAssetID == Self.canonicalPath(geometry.assetID),
              capture.geometryPath == Self.canonicalPath(geometry.path),
              capture.geometryName == geometry.name,
              Self.isSHA256(capture.geometryRevision),
              geometry.revision.map({ $0.caseInsensitiveCompare(capture.geometryRevision) == .orderedSame }) ?? true else {
            throw BugReportProviderError.stale("The selected Geometry changed while it was being checked.")
        }
    }

    private func stableContextKey(_ context: BugReportNativeContext) -> String {
        [context.projectSessionID.uuidString, context.projectPath ?? "", context.projectRevision ?? "",
         context.effectiveProjectXMLFingerprint ?? "", context.applicationUID]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func geometryCaptureKey(_ context: BugReportNativeContext,
                                    _ geometry: BugReportGeometryChoice) -> String {
        stableContextKey(context) + "|" + geometry.assetID + "|" + geometry.name + "|" + geometry.path
    }

    private func requestSignature(_ request: ToolRequest) -> String {
        var parts = [request.kind, request.context?.projectSessionID.uuidString ?? "",
            request.reportFromCrash ? "crash" : "normal"]
        for (key, value) in request.fields.sorted(by: { $0.key < $1.key }) {
            parts.append("field:\(key.utf8.count):\(key):\(value.utf8.count):\(value)")
        }
        for image in (request.images[BugReportLimits.imageField] ?? []) {
            let digest = SHA256.hash(data: image.data).map { String(format: "%02X", $0) }.joined()
            parts.append("image:\(image.id):\(image.name):\(digest)")
        }
        let value = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private func componentIDs(from fields: [String: String]) -> [String] {
        (fields["JiraBugReportForm/Report_Components"] ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
        }
    }

    private static func contentType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "application/octet-stream"
        }
    }

    private static func readApplicationLogTail() async -> String {
        let url = WorkspaceApplicationPaths.applicationLog
        do {
            let data = try await Task.detached(priority: .utility) { () throws -> Data in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                let start = end > UInt64(BugReportLogLimits.maximumBytes)
                    ? end - UInt64(BugReportLogLimits.maximumBytes) : 0
                try handle.seek(toOffset: start)
                return try handle.readToEnd() ?? Data()
            }.value
            return String(decoding: data.suffix(BugReportLogLimits.maximumBytes), as: UTF8.self)
        } catch {
            return ""
        }
    }

    private struct PreparedReport {
        let requestSignature: String
        let context: BugReportNativeContext
        let contextGeneration: Int
        let componentIDs: Set<String>
        let rasVersion: String
        let geometryRevision: String?
        let componentGeometryAttachment: Bool
    }

    private struct ComponentsRequest: Encodable, Sendable {}
    private struct Component: Decodable, Sendable { let id: String; let name: String; let attachesGeometry: Bool }
    private struct ComponentsResult: Decodable, Sendable {
        let rasVersion: String
        let knownIssuesUrl: String
        let components: [Component]
    }
    private struct GeometryCaptureRequest: Encodable, Sendable {
        let projectPath: String
        let expectedProjectRevision: String
        let projectXml: String
        let projectXmlFingerprint: String
        let geometryAssetID: String
        let geometryName: String
        let geometryPath: String
        let expectedGeometryRevision: String?
    }
    private struct GeometryCapture: Decodable, Sendable {
        let projectPath: String
        let projectRevision: String
        let projectXmlFingerprint: String
        let geometryAssetID: String
        let geometryName: String
        let geometryPath: String
        let geometryRevision: String
    }
    private struct BugReportImageRequest: Encodable, Sendable {
        let name: String
        let contentType: String
        let data: Data
    }
    private struct SubmitRequest: Encodable, Sendable {
        let uid: String
        let rasVersion: String
        let os: String
        let cores: String
        let timezone: String
        let email: String
        let summary: String
        let description: String
        let errorLog: String
        let componentIDs: [String]
        let images: [BugReportImageRequest]
        let crashContext: String?
        let geometry: GeometryCaptureRequest?
    }
    private struct SubmitReceipt: Decodable, Sendable {
        let issueKey: String
        let attachmentWarnings: [String]
    }
}

private enum BugReportLogLimits {
    static let maximumBytes = 25_600
}

private enum BugReportProviderError: LocalizedError {
    case stale(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .stale(let message), .invalidResponse(let message): message
        }
    }
}
