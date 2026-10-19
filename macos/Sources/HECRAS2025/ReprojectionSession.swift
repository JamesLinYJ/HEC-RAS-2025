import Foundation
import SwiftUI

@MainActor
final class ReprojectionSession: ObservableObject {
    static let initialRowCount = 10
    static let addedRowCount = 5

    @Published private(set) var sourceOption: ReprojectionOption = .wgs84
    @Published private(set) var destinationOption: ReprojectionOption = .project
    @Published private(set) var sourceCustomProjectionText = ""
    @Published private(set) var destinationCustomProjectionText = ""
    @Published private(set) var rows = (0..<initialRowCount).map { _ in ReprojectionInputRow() }
    @Published private(set) var sourceSummary = ReprojectionOption.wgs84.rawValue
    @Published private(set) var destinationSummary = ReprojectionOption.project.rawValue
    @Published private(set) var sourceProjectionSummary: ReprojectionProjectionSummary?
    @Published private(set) var destinationProjectionSummary: ReprojectionProjectionSummary?
    @Published private(set) var resultsByID: [String: ReprojectionRowResult] = [:]
    @Published private(set) var errorCode: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var identifyError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isIdentifyingProjection = false
    @Published private(set) var projectSessionID: UUID?
    @Published private(set) var projectProjection: ProjectionDefinitionDraft?
    @Published private(set) var contextIdentity: String?

    private let provider: (any ReprojectionProvider)?
    private var transformTask: Task<Void, Never>?
    private var identifyTask: Task<Void, Never>?
    private var transformGeneration: UInt64 = 0
    private var identifyGeneration: UInt64 = 0
    private var ownerGeneration: UInt64 = 0
    private var sideInputGeneration: [ReprojectionSide: UInt64] = [.source: 0, .destination: 0]
    private var isClosed = false

    init(provider: (any ReprojectionProvider)? = nil) {
        self.provider = provider
    }

    static func contextIdentity(
        projectSessionID: UUID,
        projectProjection: ProjectionDefinitionDraft?
    ) -> String {
        let projection = projectProjection.map {
            ProjectionDefinitionDraft(type: ProjectionDefinitionDraft.canonicalType($0.type), value: $0.value)
        }
        let projectionPart: String
        if let projection {
            projectionPart = "present|\(identityComponent(projection.type))|\(identityComponent(projection.value))"
        } else {
            projectionPart = "absent"
        }
        return "\(projectSessionID.uuidString)|\(projectionPart)"
    }

    func configure(
        projectSessionID: UUID,
        projectProjection: ProjectionDefinitionDraft?,
        contextIdentity proposedIdentity: String
    ) {
        let canonicalProjection = projectProjection.map {
            ProjectionDefinitionDraft(type: ProjectionDefinitionDraft.canonicalType($0.type), value: $0.value)
        }
        let expectedIdentity = Self.contextIdentity(
            projectSessionID: projectSessionID,
            projectProjection: canonicalProjection)
        guard proposedIdentity == expectedIdentity else {
            invalidateRequests()
            clearPresentation()
            self.projectSessionID = nil
            self.projectProjection = nil
            contextIdentity = nil
            errorCode = "invalidContext"
            errorMessage = L10n.text("The reprojection context does not match the current project.")
            return
        }

        let changed = self.projectSessionID != projectSessionID
            || self.projectProjection != canonicalProjection
            || self.contextIdentity != proposedIdentity
        if !changed, !isClosed { return }

        invalidateRequests()
        ownerGeneration &+= 1
        isClosed = false
        self.projectSessionID = projectSessionID
        self.projectProjection = canonicalProjection
        contextIdentity = proposedIdentity
        clearPresentation()
        scheduleTransform()
    }

    func result(for rowID: String) -> ReprojectionRowResult? {
        resultsByID[rowID]
    }

    var canAddRows: Bool { !isClosed && rows.count <= Int.max - Self.addedRowCount }
    var isBusy: Bool { isLoading || isIdentifyingProjection }

    func setOption(_ option: ReprojectionOption, for side: ReprojectionSide) {
        guard !isClosed else { return }
        switch side {
        case .source:
            guard sourceOption != option else { return }
            sourceOption = option
            if option != .custom { sourceCustomProjectionText = "" }
        case .destination:
            guard destinationOption != option else { return }
            destinationOption = option
            if option != .custom { destinationCustomProjectionText = "" }
        }
        invalidateIdentify(for: side)
        scheduleTransform()
    }

    func setCustomProjectionText(_ text: String, for side: ReprojectionSide) {
        guard !isClosed else { return }
        switch side {
        case .source:
            guard sourceCustomProjectionText != text else { return }
            sourceCustomProjectionText = text
        case .destination:
            guard destinationCustomProjectionText != text else { return }
            destinationCustomProjectionText = text
        }
        invalidateIdentify(for: side)
        scheduleTransform()
    }

    func setCoordinate(rowID: String, axis: ReprojectionAxis, text: String) {
        guard !isClosed, let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        switch axis {
        case .x:
            guard rows[index].xText != text else { return }
            rows[index].xText = text
        case .y:
            guard rows[index].yText != text else { return }
            rows[index].yText = text
        }
        scheduleTransform()
    }

    func addRows() {
        guard !isClosed, canAddRows else { return }
        rows.append(contentsOf: (0..<Self.addedRowCount).map { _ in ReprojectionInputRow() })
        scheduleTransform()
    }

    /// Mirrors the retained file-drop behavior: inspect the candidate files in
    /// order and install the first recognized projection as embedded WKT.
    func identifyProjection(paths: [URL], for side: ReprojectionSide) async {
        let candidates = paths.filter { $0.isFileURL }
        guard !isClosed, !candidates.isEmpty else { return }
        guard let provider else {
            identifyError = L10n.text("The reprojection service is unavailable.")
            return
        }

        identifyTask?.cancel()
        identifyGeneration &+= 1
        let generation = identifyGeneration
        let capturedOwnerGeneration = ownerGeneration
        let capturedIdentity = contextIdentity
        let capturedSideGeneration = sideInputGeneration[side, default: 0]
        identifyError = nil
        isIdentifyingProjection = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performIdentify(
                candidates: candidates,
                side: side,
                provider: provider,
                generation: generation,
                ownerGeneration: capturedOwnerGeneration,
                ownerIdentity: capturedIdentity,
                sideInputGeneration: capturedSideGeneration)
        }
        identifyTask = task
        await task.value
    }

    func transformNow() async {
        guard !isClosed, projectSessionID != nil, contextIdentity != nil else { return }
        transformTask?.cancel()
        transformTask = nil
        transformGeneration &+= 1
        let generation = transformGeneration
        let owner = ownerGeneration
        clearTransformationResult()
        isLoading = true
        await performTransform(makeRequest(), generation: generation, ownerGeneration: owner)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        invalidateRequests()
        clearPresentation()
    }

    private func performIdentify(
        candidates: [URL],
        side: ReprojectionSide,
        provider: any ReprojectionProvider,
        generation: UInt64,
        ownerGeneration capturedOwnerGeneration: UInt64,
        ownerIdentity capturedOwnerIdentity: String?,
        sideInputGeneration capturedSideGeneration: UInt64
    ) async {
        var scoped: [(URL, Bool)] = []
        for url in candidates {
            scoped.append((url, url.startAccessingSecurityScopedResource()))
        }
        defer {
            for (url, didStart) in scoped where didStart {
                url.stopAccessingSecurityScopedResource()
            }
            if generation == identifyGeneration {
                identifyTask = nil
                isIdentifyingProjection = false
            }
        }

        do {
            let paths = candidates.map(\.path)
            let request = ReprojectionIdentifyRequest(paths: paths)
            let snapshot = try await provider.identify(request)
            guard isCurrentIdentify(
                generation: generation,
                ownerGeneration: capturedOwnerGeneration,
                ownerIdentity: capturedOwnerIdentity,
                side: side,
                sideInputGeneration: capturedSideGeneration) else { return }
            try snapshot.validate(for: request)
            guard snapshot.recognizedPath != nil,
                  let wkt = snapshot.wkt,
                  snapshot.projectionSummary != nil else {
                identifyError = L10n.text(snapshot.errorMessage ?? "No coordinate system was recognized in the selected files.")
                return
            }

            switch side {
            case .source:
                sourceOption = .custom
                sourceCustomProjectionText = wkt
            case .destination:
                destinationOption = .custom
                destinationCustomProjectionText = wkt
            }
            sideInputGeneration[side, default: 0] &+= 1
            scheduleTransform()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentIdentify(
                generation: generation,
                ownerGeneration: capturedOwnerGeneration,
                ownerIdentity: capturedOwnerIdentity,
                side: side,
                sideInputGeneration: capturedSideGeneration) else { return }
            identifyError = L10n.text(error.localizedDescription)
        }
    }

    private func scheduleTransform(debounce: Duration = .milliseconds(220)) {
        guard !isClosed, projectSessionID != nil, contextIdentity != nil else { return }
        transformTask?.cancel()
        transformGeneration &+= 1
        let generation = transformGeneration
        let owner = ownerGeneration
        let request = makeRequest()
        clearTransformationResult()
        guard let provider else {
            isLoading = false
            errorCode = "serviceUnavailable"
            errorMessage = L10n.text("The reprojection service is unavailable.")
            return
        }
        isLoading = true
        transformTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: debounce) }
            catch { return }
            guard let self, self.isCurrentTransform(generation: generation, ownerGeneration: owner) else { return }
            await self.performTransform(request, provider: provider, generation: generation, ownerGeneration: owner)
        }
    }

    private func performTransform(
        _ request: ReprojectionRequest,
        provider suppliedProvider: (any ReprojectionProvider)? = nil,
        generation: UInt64,
        ownerGeneration capturedOwnerGeneration: UInt64
    ) async {
        guard let provider = suppliedProvider ?? self.provider else {
            guard isCurrentTransform(generation: generation, ownerGeneration: capturedOwnerGeneration) else { return }
            isLoading = false
            errorCode = "serviceUnavailable"
            errorMessage = L10n.text("The reprojection service is unavailable.")
            return
        }

        defer {
            if isCurrentTransform(generation: generation, ownerGeneration: capturedOwnerGeneration) {
                isLoading = false
                transformTask = nil
            }
        }

        do {
            let snapshot = try await provider.transform(request)
            guard isCurrentTransform(generation: generation, ownerGeneration: capturedOwnerGeneration) else { return }
            try snapshot.validate(for: request)
            sourceSummary = snapshot.sourceSummary
            destinationSummary = snapshot.destinationSummary
            sourceProjectionSummary = snapshot.sourceProjectionSummary
            destinationProjectionSummary = snapshot.destinationProjectionSummary
            errorCode = snapshot.errorCode
            if let code = snapshot.errorCode, let message = snapshot.errorMessage {
                errorMessage = L10n.text(Self.fixedErrorMessage(for: code) ?? message)
            } else {
                errorMessage = nil
            }
            resultsByID = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentTransform(generation: generation, ownerGeneration: capturedOwnerGeneration) else { return }
            errorCode = "requestFailed"
            errorMessage = L10n.text(error.localizedDescription)
            resultsByID = [:]
        }
    }

    private func makeRequest() -> ReprojectionRequest {
        ReprojectionRequest(
            sourceOption: sourceOption.rawValue,
            destinationOption: destinationOption.rawValue,
            projectProjection: projectProjection,
            sourceCustomProjectionText: sourceCustomProjectionText,
            destinationCustomProjectionText: destinationCustomProjectionText,
            rows: rows,
            numberCulture: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
    }

    private func isCurrentTransform(generation: UInt64, ownerGeneration capturedOwnerGeneration: UInt64) -> Bool {
        !isClosed && generation == transformGeneration && capturedOwnerGeneration == ownerGeneration
            && projectSessionID != nil && contextIdentity != nil
    }

    private func isCurrentIdentify(
        generation: UInt64,
        ownerGeneration capturedOwnerGeneration: UInt64,
        ownerIdentity capturedOwnerIdentity: String?,
        side: ReprojectionSide,
        sideInputGeneration capturedSideGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled && !isClosed && generation == identifyGeneration
            && capturedOwnerGeneration == ownerGeneration
            && capturedOwnerIdentity == contextIdentity
            && capturedSideGeneration == sideInputGeneration[side, default: 0]
    }

    private func invalidateIdentify(for side: ReprojectionSide) {
        sideInputGeneration[side, default: 0] &+= 1
        identifyGeneration &+= 1
        identifyTask?.cancel()
        identifyTask = nil
        isIdentifyingProjection = false
        identifyError = nil
    }

    private func invalidateRequests() {
        transformGeneration &+= 1
        identifyGeneration &+= 1
        transformTask?.cancel()
        identifyTask?.cancel()
        transformTask = nil
        identifyTask = nil
        isLoading = false
        isIdentifyingProjection = false
    }

    private func clearTransformationResult() {
        sourceSummary = sourceOption.rawValue
        destinationSummary = destinationOption.rawValue
        sourceProjectionSummary = nil
        destinationProjectionSummary = nil
        resultsByID = [:]
        errorCode = nil
        errorMessage = nil
    }

    private func clearPresentation() {
        clearTransformationResult()
        identifyError = nil
    }

    private static func fixedErrorMessage(for code: String) -> String? {
        switch code {
        case "noProjectSource": "No project is open. Please select a different source projection."
        case "noProjectDestination": "No project is open. Please select a different destination projection."
        case "missingCustomSource": "Please enter a custom source projection."
        case "missingCustomDestination": "Please enter a custom destination projection."
        case "invalidCustomSource": "Invalid custom source projection."
        case "invalidCustomDestination": "Invalid custom destination projection."
        case "unsupportedNumberCulture": "The requested number culture is not supported."
        default: nil
        }
    }

    private static func identityComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
