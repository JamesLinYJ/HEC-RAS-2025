import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainInputImportSource: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let name: String
    let revision: String
    let isValid: Bool
    let error: String?
    let width: Int?
    let height: Int?
    let bandCount: Int?
    let cellSize: Double?
    let projection: String?
    let minimum: Double?
    let maximum: Double?
    let defaultScaleFactor: Double?
    let overviewCount: Int?
    let overviews: [String]?

    init(id: String, path: String, name: String, revision: String, isValid: Bool,
         error: String?, width: Int?, height: Int?, bandCount: Int?, cellSize: Double?,
         projection: String?, minimum: Double?, maximum: Double?, defaultScaleFactor: Double?,
         overviewCount: Int? = nil, overviews: [String]? = nil) {
        self.id = id; self.path = path; self.name = name; self.revision = revision
        self.isValid = isValid; self.error = error; self.width = width; self.height = height
        self.bandCount = bandCount; self.cellSize = cellSize; self.projection = projection
        self.minimum = minimum; self.maximum = maximum; self.defaultScaleFactor = defaultScaleFactor
        self.overviewCount = overviewCount; self.overviews = overviews
    }
}

struct TerrainInputImportInspection: Decodable, Sendable {
    let targetProjection: String
    let sources: [TerrainInputImportSource]
    let roundingOptions: [String]
    let unitConversionOptions: [String]
    let stitchTilesDefault: Bool

    func validate() throws {
        let supportedRounding: Set<String> = [
            "None", "Tenths", "Hundredths", "Thousandths", "Sixteenths",
            "ThirtySeconds", "SixtyFourths", "HundredTwentyEighths", "ThousandTwentyFourths"
        ]
        let supportedConversions: Set<String> = ["Default", "None", "FeetToMeters", "MetersToFeet", "Custom"]
        guard !sources.isEmpty,
              sources.allSatisfy({ !$0.id.isEmpty && !$0.path.isEmpty }),
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map(\.path)).count == sources.count,
              !roundingOptions.isEmpty, Set(roundingOptions).count == roundingOptions.count,
              roundingOptions.allSatisfy(supportedRounding.contains), roundingOptions.contains("None"),
              !unitConversionOptions.isEmpty, Set(unitConversionOptions).count == unitConversionOptions.count,
              unitConversionOptions.allSatisfy(supportedConversions.contains), unitConversionOptions.contains("Default") else {
            throw ProjectFileError.invalid("The terrain input inspection response is incomplete or unsupported.")
        }
        for source in sources where source.isValid {
            guard !source.path.isEmpty, !source.name.isEmpty, !source.revision.isEmpty,
                  let width = source.width, width > 0,
                  let height = source.height, height > 0,
                  source.bandCount == 1,
                  let scale = source.defaultScaleFactor, scale.isFinite else {
                throw ProjectFileError.invalid("The terrain input inspection returned invalid raster metadata.")
            }
            if let overviewCount = source.overviewCount, let overviews = source.overviews {
                guard overviewCount >= 0, overviewCount == overviews.count,
                      overviews.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw ProjectFileError.invalid("The terrain input overview metadata is incomplete.")
                }
            } else {
                throw ProjectFileError.invalid("The terrain input overview metadata is incomplete.")
            }
        }
    }
}

struct TerrainInputImportSelection: Codable, Identifiable, Equatable, Sendable {
    let path: String
    let sourceRevision: String
    var rounding: String
    var unitConversion: String
    var customScaleFactor: Double?
    var sourceID: String? = nil
    var actualScaleFactor: Double? = nil
    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, sourceRevision, rounding, unitConversion, customScaleFactor, actualScaleFactor
        case sourceID = "sourceId"
    }
}

struct TerrainInputAppendRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let files: [TerrainInputImportSelection]
    let stitchTiles: Bool
    let draftToken: String
    let batchToken: String
}

struct TerrainInputImportStatusRequest: Encodable, Sendable {
    let request: TerrainInputAppendRequest
}

struct TerrainInputOperationResult: Decodable, Identifiable, Equatable, Sendable {
    let operationID: String
    let order: Int
    let sourceIDs: [String]
    let sourcePaths: [String]
    let sourceRevisions: [String]
    let status: String
    let outputInputID: String?
    let outputName: String?
    let diagnostic: String?
    let progress: Double?

    var id: String { operationID }
    var isPending: Bool { status == "Queued" || status == "Running" }
    var isStaged: Bool { status == "Staged" }
    var isRetryable: Bool { status == "Failed" || status == "Cancelled" }

    func validate(allowPending: Bool) throws {
        let allowed = allowPending ? ["Queued", "Running", "Staged", "Failed", "Cancelled"] : ["Staged", "Failed", "Cancelled"]
        guard !operationID.isEmpty, order >= 0, !sourceIDs.isEmpty,
              sourceIDs.count == sourcePaths.count, sourcePaths.count == sourceRevisions.count,
              sourceIDs.allSatisfy({ !$0.isEmpty }), sourcePaths.allSatisfy({ !$0.isEmpty }),
              sourceRevisions.allSatisfy({ !$0.isEmpty }), allowed.contains(status),
              progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              status != "Staged" || outputInputID?.isEmpty == false else {
            throw ProjectFileError.invalid("The terrain import operation response is incomplete or unsupported.")
        }
    }
}

struct TerrainInputAppendResult: Decodable, Sendable {
    let snapshot: BackendModelProvider.ModelSnapshot
    let draftToken: String
    let batchToken: String
    let mode: String
    let batchStatus: String
    let operations: [TerrainInputOperationResult]

    var hasStagedOutputs: Bool { operations.contains(where: \.isStaged) }
    var hasPendingOperations: Bool { operations.contains(where: \.isPending) }
    var failedOperations: [TerrainInputOperationResult] { operations.filter(\.isRetryable) }
    var isTerminal: Bool { ["Completed", "Partial", "Failed", "Cancelled", "CancelledPartial"].contains(batchStatus) }

    func validate(expectedDraftToken: String, expectedBatchToken: String, expectedMode: String? = nil,
                  allowPending: Bool = false) throws {
        let batchStatuses = allowPending
            ? ["Running", "Completed", "Partial", "Failed", "Cancelled", "CancelledPartial"]
            : ["Completed", "Partial", "Failed", "Cancelled", "CancelledPartial"]
        guard draftToken == expectedDraftToken, batchToken == expectedBatchToken,
              expectedMode.map({ mode == $0 }) ?? true,
              ["Individual", "Stitched"].contains(mode), batchStatuses.contains(batchStatus),
              !operations.isEmpty, Set(operations.map(\.operationID)).count == operations.count,
              Set(operations.map(\.order)).count == operations.count else {
            throw ProjectFileError.invalid("The terrain import batch response does not match the active request.")
        }
        for operation in operations { try operation.validate(allowPending: allowPending) }
        guard allowPending || (!hasPendingOperations && isTerminal) else {
            throw ProjectFileError.invalid("The terrain import batch response is not complete.")
        }
    }
}

struct TerrainInputImportStatus: Decodable, Sendable {
    let state: String
    let result: TerrainInputAppendResult?
    let operations: [TerrainInputOperationResult]
    var resultUnavailableCode: String? = nil
    var diagnostic: String? = nil

    var isTerminal: Bool { ["Completed", "Partial", "Failed", "Cancelled", "CancelledPartial"].contains(state) }
    var isNotFound: Bool { state == "NotFound" }

    func validate(draftToken: String, batchToken: String, expectedMode: String? = nil) throws {
        guard ["NotFound", "Running", "Completed", "Partial", "Failed", "Cancelled", "CancelledPartial"].contains(state),
              Set(operations.map(\.operationID)).count == operations.count,
              resultUnavailableCode != nil || diagnostic == nil else {
            throw ProjectFileError.invalid("The terrain import status response is incomplete or unsupported.")
        }
        if isNotFound {
            guard result == nil, operations.isEmpty, resultUnavailableCode == nil, diagnostic == nil else {
                throw ProjectFileError.invalid("The missing terrain import status contains unexpected operations.")
            }
            return
        }
        for operation in operations { try operation.validate(allowPending: !isTerminal) }
        if isTerminal {
            if let resultUnavailableCode {
                guard resultUnavailableCode == "sourceChanged", result == nil,
                      !operations.isEmpty, !operations.contains(where: \.isPending) else {
                    throw ProjectFileError.invalid("The terrain import status reports an unsupported unavailable result.")
                }
                return
            }
            guard let result, result.batchStatus == state else {
                throw ProjectFileError.invalid("The completed terrain import status has no matching result.")
            }
            guard result.operations == operations else {
                throw ProjectFileError.invalid("The completed terrain import status disagrees with its result envelope.")
            }
            try result.validate(expectedDraftToken: draftToken, expectedBatchToken: batchToken,
                expectedMode: expectedMode)
        } else if result != nil || resultUnavailableCode != nil || diagnostic != nil {
            throw ProjectFileError.invalid("The running terrain import status unexpectedly contains a final result.")
        }
    }
}

struct TerrainInputImportCancelReceipt: Decodable, Sendable {
    let accepted: Bool
    let state: String
    let operationID: String?
}

struct TerrainInputImportSheet: View {
    let initialFiles: [URL]
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var initialSettings: [String: TerrainInputImportInitialSettings] = [:]
    var initialStitchTiles: Bool? = nil
    var ownedInitialFilePaths: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    @State private var files: [URL] = []
    @State private var inspection: TerrainInputImportInspection?
    @State private var selections: [TerrainInputImportSelection] = []
    @State private var customScaleText: [String: String] = [:]
    @State private var actualScaleText: [String: String] = [:]
    @State private var excludedSourcePaths: Set<String> = []
    @State private var successfullyStagedSources: Set<String> = []
    @State private var failedSourceVersions: [String: String] = [:]
    @State private var completedBatches: [TerrainInputAppendResult] = []
    @State private var selectedPath: String?
    @State private var selectedPropertyPaths: Set<String> = []
    @StateObject private var propertySession = RasterImportContextPropertiesSession()
    @State private var stitchTiles = true
    @State private var hasUserChosenStitchTiles = false
    @State private var inspectedFilePaths: [String] = []
    @State private var isInspecting = false
    @State private var isAppending = false
    @State private var isCheckingStatus = false
    @State private var isCancellingOperation = false
    @State private var requiresRetryInspection = false
    @State private var error: String?
    @State private var ownerIdentity = ""
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?

    private var selectedSource: TerrainInputImportSource? {
        inspection?.sources.first { $0.path == selectedPath }
    }
    private var inspectedCurrentFiles: Bool { inspectedFilePaths == files.map(\.path) }
    private var validSelections: [TerrainInputImportSelection] {
        guard let inspection else { return [] }
        let validPaths = Set(inspection.sources.filter { $0.isValid && !excludedSourcePaths.contains($0.path) }.map(\.path))
        return selections.filter { validPaths.contains($0.path) }
    }
    private var visibleSources: [TerrainInputImportSource] {
        inspection?.sources.filter { !excludedSourcePaths.contains($0.path) } ?? []
    }
    private var selectedSettingPaths: [String] {
        let chosen = selectedPropertyPaths.isEmpty
            ? Set(selectedPath.map { [$0] } ?? []) : selectedPropertyPaths
        return validSelections.map(\.path).filter(chosen.contains)
    }
    private var selectedSettingSelections: [TerrainInputImportSelection] {
        let paths = Set(selectedSettingPaths)
        return selections.filter { paths.contains($0.path) }
    }
    private var customScaleIsValid: Bool {
        for selection in validSelections where selection.unitConversion == "Custom" {
            guard let raw = customScaleText[selection.path],
                  let value = OriginalUnitNumberInputCodec.parse(raw, locale: .autoupdatingCurrent),
                  value.isFinite, Float(value).isFinite else { return false }
        }
        return true
    }
    private var actualScaleIsValid: Bool {
        for selection in validSelections {
            guard let raw = actualScaleText[selection.path],
                  let value = OriginalUnitNumberInputCodec.parse(raw, locale: .autoupdatingCurrent),
                  value.isFinite, Float(value).isFinite else { return false }
        }
        return true
    }
    private var hasRetryableResults: Bool { !failedSourceVersions.isEmpty }
    private var displayedOperations: [TerrainInputOperationResult] {
        let history = completedBatches.flatMap(\.operations)
        guard session.isTerrainInputImportRunning || session.terrainInputImportCleanupBatchToken != nil,
              let status = session.terrainInputImportStatus else { return history }
        return history + status.operations
    }
    private var activeOperationIDs: Set<String> {
        Set(session.isTerrainInputImportRunning
            ? (session.terrainInputImportStatus?.operations ?? []).filter(\.isPending).map(\.operationID)
            : [])
    }
    private var isManagingImportRequest: Bool {
        isAppending || isCheckingStatus || isCancellingOperation
    }
    private var isImportLocked: Bool {
        isManagingImportRequest || session.isTerrainInputImportRunning || session.isSaving || store.isSavingAll
    }
    private var canAppend: Bool {
        session.provider != nil && session.canEdit && session.terrainInputImportCleanupToken == nil &&
            !session.isBusy && !store.isSavingAll && !isInspecting && !isManagingImportRequest &&
            !session.isTerrainInputImportRunning && !requiresRetryInspection &&
            ownerIdentity == session.terrainInputImportIdentity && inspection != nil && inspectedCurrentFiles &&
            !validSelections.isEmpty && customScaleIsValid && actualScaleIsValid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Terrain Input Import"), systemImage: "square.stack.3d.up").font(.title2.weight(.semibold))
                Spacer()
                if session.isTerrainInputImportRunning {
                    Button(L10n.text("Cancel Import"), role: .cancel) { cancelActiveImport() }
                        .disabled(session.isTerrainInputImportCancelling || isCancellingOperation || session.isSaving)
                } else {
                    Button(completedBatches.isEmpty ? L10n.text("Cancel") : L10n.text("Done"), role: .cancel) { cancel() }
                        .disabled(isManagingImportRequest || session.isSaving)
                }
                if !validSelections.isEmpty {
                    Button(hasRetryableResults ? L10n.text("Retry Failed Inputs") : L10n.text("Add to Terrain")) { append() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canAppend)
                }
            }.padding(16)

            Text(L10n.text("Imported rasters are staged in this model draft. Save the model to write them to the HDF file."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Button(L10n.text("Add Files…")) { addFiles(store.system.chooseInputFiles()) }
                            .disabled(isImportLocked)
                        Button(L10n.text("Remove")) { removeSelectedSource() }
                            .disabled(selectedPath == nil || isInspecting || isManagingImportRequest || session.isTerrainInputImportRunning)
                        Spacer()
                        Button(L10n.text("Check Inputs"), action: inspect)
                            .disabled(files.isEmpty || isInspecting || isManagingImportRequest || session.isTerrainInputImportRunning || session.provider == nil ||
                                session.terrainInputImportCleanupToken != nil || !ownerIsCurrent)
                    }.padding(12)

                    List(visibleSources, selection: Binding(get: {
                        selectedPropertyPaths.isEmpty ? Set(selectedPath.map { [$0] } ?? []) : selectedPropertyPaths
                    }, set: { paths in
                        selectedPropertyPaths = paths
                        selectedPath = visibleSources.first { paths.contains($0.path) }?.path
                    })) { source in
                        HStack(spacing: 8) {
                            let included = selections.contains { $0.path == source.path }
                            Image(systemName: source.isValid ? (included ? "checkmark.circle.fill" : "circle") : "exclamationmark.triangle.fill")
                                .foregroundStyle(source.isValid ? (included ? .green : .secondary) : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).lineLimit(1)
                                Text(source.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.tag(source.path)
                    }.frame(minHeight: 180)
                        .disabled(isInspecting || isManagingImportRequest || session.isTerrainInputImportRunning || session.isSaving)

                    if session.terrainInputImportCleanupToken != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error ?? session.terrainInputImportCleanupWarning ?? L10n.text("Temporary terrain import files could not be removed."),
                                systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).textSelection(.enabled)
                            Button(L10n.text("Retry Cleanup")) {
                                Task {
                                    let staleResult = session.canRecheckTerrainInputImportStatus
                                    let cleaned = await session.retryTerrainInputImportCleanup()
                                    error = cleaned ? nil : session.error
                                    if cleaned && staleResult {
                                        requiresRetryInspection = true
                                        inspection = nil
                                        inspectedFilePaths = []
                                    }
                                }
                            }
                            .disabled(session.isBusy || store.isSavingAll)
                            if session.canRecheckTerrainInputImportStatus {
                                Button(L10n.text("Check Status Again")) { checkImportStatus() }
                                    .disabled(isManagingImportRequest || session.isSaving || store.isSavingAll)
                            }
                        }.padding(12)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12)
                    } else if isInspecting {
                        ProgressView(L10n.text("Inspecting terrain inputs…")).padding(12)
                    } else if session.provider == nil {
                        Label(L10n.text("The original model adapter for terrain import is unavailable."), systemImage: "externaldrive.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    } else if !inspectedCurrentFiles {
                        Text(L10n.text("Check inputs after changing the selected files.")).font(.caption).foregroundStyle(.secondary).padding(12)
                    } else if let sessionError = session.error {
                        Label(sessionError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12)
                    }
                }.frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

                settingsPane
            }
        }
        .frame(minWidth: 850, idealWidth: 980, minHeight: 600)
        .interactiveDismissDisabled(isManagingImportRequest || session.isTerrainInputImportRunning || session.isSaving)
        .onAppear {
            ownerIdentity = session.terrainInputImportIdentity
            stitchTiles = initialStitchTiles ?? inspection?.stitchTilesDefault ?? true
            hasUserChosenStitchTiles = initialStitchTiles != nil
            if let result = session.terrainInputImportStatus?.result { record(result) }
            if session.canRecheckTerrainInputImportStatus {
                requiresRetryInspection = true
            }
            addFiles(initialFiles)
        }
        .onChange(of: session.terrainInputImportIdentity) { _, identity in
            guard !isManagingImportRequest, !ownerIdentity.isEmpty, identity != ownerIdentity else { return }
            work?.cancel(); requestID = UUID(); dismiss()
        }
        .onChange(of: selectedPath) { _, path in
            if let path, !selectedPropertyPaths.contains(path) { selectedPropertyPaths = [path] }
            if path == nil { selectedPropertyPaths = [] }
        }
        .onChange(of: visibleSources.map(\.path)) { _, paths in
            selectedPropertyPaths.formIntersection(Set(paths))
        }
        .onDisappear {
            requestID = UUID()
            if !isAppending { work?.cancel() }
        }
    }

    private var ownerIsCurrent: Bool { !ownerIdentity.isEmpty && ownerIdentity == session.terrainInputImportIdentity }

    @ViewBuilder private var settingsPane: some View {
        Form {
            if ownerIsCurrent, inspectedCurrentFiles {
                RasterImportContextPropertiesView(session: propertySession,
                    filePaths: visibleSources.filter { source in
                        selectedPropertyPaths.contains(source.path)
                            || selectedPropertyPaths.isEmpty && source.path == selectedPath
                    }.map(\.path), compareProjectionWKT: inspection?.targetProjection)
                    .disabled(isImportLocked || isInspecting)
            }
            if selectedSettingSelections.count > 1 {
                Section(L10n.text("Apply to Selected Inputs")) {
                    Picker(L10n.text("Rounding"), selection: bulkRoundingBinding()) {
                        Text(L10n.text("Mixed")).tag(nil as String?)
                        ForEach(inspection?.roundingOptions ?? [], id: \.self) { value in
                            Text(L10n.text(roundingLabel(value))).tag(Optional(value))
                        }
                    }
                    .disabled(isImportLocked)
                    Picker(L10n.text("Unit Conversion"), selection: bulkUnitConversionBinding()) {
                        Text(L10n.text("Mixed")).tag(nil as String?)
                        ForEach(inspection?.unitConversionOptions ?? [], id: \.self) { value in
                            Text(L10n.text(conversionLabel(value))).tag(Optional(value))
                        }
                    }
                    .disabled(isImportLocked)
                    Text(L10n.format("Applies to %d selected terrain inputs", selectedSettingSelections.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let source = selectedSource {
                Section(L10n.text("Raster Information")) {
                    LabeledContent(L10n.text("Source Projection"), value: source.projection ?? L10n.text("Unavailable"))
                    if let target = inspection?.targetProjection {
                        LabeledContent(L10n.text("Target Projection"), value: target.isEmpty ? L10n.text("Unavailable") : target)
                    }
                    if let width = source.width, let height = source.height {
                        LabeledContent(L10n.text("Raster Size"), value: "\(width) × \(height)")
                    }
                    if let cellSize = source.cellSize {
                        LabeledContent(L10n.text("Cell Size"), value: OriginalUnitNumberInputCodec.format(cellSize, locale: .autoupdatingCurrent))
                    }
                    if let minimum = source.minimum {
                        LabeledContent(L10n.text("Minimum"), value: OriginalUnitNumberInputCodec.format(minimum, locale: .autoupdatingCurrent))
                    }
                    if let maximum = source.maximum {
                        LabeledContent(L10n.text("Maximum"), value: OriginalUnitNumberInputCodec.format(maximum, locale: .autoupdatingCurrent))
                    }
                    RasterOverviewsDisclosure(overviewCount: source.overviewCount, overviews: source.overviews)
                    if !source.isValid, let diagnostic = source.error {
                        Text(L10n.text(diagnostic)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    } else if !source.isValid {
                        Text(L10n.text("This file is not a valid single-band float terrain raster."))
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                if source.isValid, let index = selections.firstIndex(where: { $0.path == source.path }),
                   selectedSettingSelections.count <= 1 {
                    Section(L10n.text("Import Settings")) {
                        Picker(L10n.text("Rounding"), selection: selectionBinding(index, keyPath: \.rounding)) {
                            ForEach(inspection?.roundingOptions ?? [], id: \.self) { value in
                                Text(L10n.text(roundingLabel(value))).tag(value)
                            }
                        }
                        .disabled(isImportLocked)
                        Picker(L10n.text("Unit Conversion"), selection: conversionBinding(index, source: source)) {
                            ForEach(inspection?.unitConversionOptions ?? [], id: \.self) { value in
                                Text(L10n.text(conversionLabel(value))).tag(value)
                            }
                        }
                        .disabled(isImportLocked)
                        if selections[index].unitConversion == "Custom" {
                            TextField(L10n.text("Custom Scale Factor"), text: customScaleBinding(source: source))
                                .textFieldStyle(.roundedBorder)
                                .disabled(isImportLocked)
                            if !customScaleIsValid {
                                Text(L10n.text("Enter a finite custom scale factor."))
                                    .font(.caption).foregroundStyle(.red)
                            }
                        } else {
                            TextField(L10n.text("Actual Scale Factor"), text: actualScaleBinding(source: source))
                                .textFieldStyle(.roundedBorder).disabled(isImportLocked)
                            if !actualScaleIsValid {
                                Text(L10n.text("Enter a finite scale factor."))
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(L10n.text("Select a terrain raster"), systemImage: "square.grid.3x3", description: Text(L10n.text("Add files and check their raster metadata before importing.")))
            }

            if let inspection {
                Section {
                    Toggle(L10n.text("Stitch tiles where possible"), isOn: Binding(
                        get: { stitchTiles }, set: { stitchTiles = $0; hasUserChosenStitchTiles = true }))
                        .disabled(inspection.sources.filter(\.isValid).count < 2 || isImportLocked)
                    Text(L10n.format("%d valid rasters", validSelections.count)).font(.caption).foregroundStyle(.secondary)
                }
            }

            if session.isTerrainInputImportRunning || session.terrainInputImportCleanupBatchToken != nil || !completedBatches.isEmpty {
                Section(L10n.text("Import Results")) {
                    if session.isTerrainInputImportRunning {
                        if session.terrainInputImportStatus?.isNotFound == true {
                            Label(L10n.text("The terrain import is not registered yet. Check its status again before retrying."),
                                  systemImage: "clock.arrow.circlepath")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            ProgressView(L10n.text("Terrain import in progress…"))
                        }
                        Button(L10n.text("Check Status")) { checkImportStatus() }
                            .disabled(isManagingImportRequest || session.isSaving || store.isSavingAll)
                    }
                    if let diagnostic = session.terrainInputImportStatus?.diagnostic,
                       session.terrainInputImportStatus?.resultUnavailableCode == "sourceChanged" {
                        Text(L10n.text(diagnostic)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }

                    ForEach(Array(displayedOperations.enumerated()), id: \.offset) { entry in
                        let operation = entry.element
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: operationSymbol(operation.status))
                                .foregroundStyle(operationColor(operation.status))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(L10n.text(operation.status)).font(.subheadline.weight(.medium))
                                    if let progress = operation.progress, operation.isPending {
                                        ProgressView(value: progress).frame(maxWidth: 90)
                                    }
                                }
                                Text(operation.outputName ?? operation.sourcePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if let diagnostic = operation.diagnostic {
                                    Text(L10n.text(diagnostic)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                            if activeOperationIDs.contains(operation.operationID),
                               session.canCancelTerrainInputImportOperation {
                                Button(L10n.text("Cancel Operation")) { cancelOperation(operation.operationID) }
                                    .disabled(isManagingImportRequest || session.isSaving || store.isSavingAll)
                            }
                        }
                    }
                    if requiresRetryInspection {
                        Text(L10n.text("Check inputs again before retrying failed operations."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, idealWidth: 520)
    }

    private func selectionBinding(_ index: Int, keyPath: WritableKeyPath<TerrainInputImportSelection, String>) -> Binding<String> {
        Binding(get: { selections.indices.contains(index) ? selections[index][keyPath: keyPath] : "" }, set: { value in
            guard selections.indices.contains(index) else { return }
            selections[index][keyPath: keyPath] = value
        })
    }

    private func commonSelectedValue(_ keyPath: KeyPath<TerrainInputImportSelection, String>) -> String? {
        let values = Set(selectedSettingSelections.map { $0[keyPath: keyPath] })
        return values.count == 1 ? values.first : nil
    }

    private func bulkRoundingBinding() -> Binding<String?> {
        Binding(get: {
            commonSelectedValue(\.rounding)
        }, set: { value in
            guard let value else { return }
            let paths = Set(selectedSettingPaths)
            for index in selections.indices where paths.contains(selections[index].path) {
                selections[index].rounding = value
            }
        })
    }

    private func bulkUnitConversionBinding() -> Binding<String?> {
        Binding(get: {
            commonSelectedValue(\.unitConversion)
        }, set: { value in
            guard let value else { return }
            let paths = Set(selectedSettingPaths)
            for index in selections.indices where paths.contains(selections[index].path) {
                let path = selections[index].path
                selections[index].unitConversion = value
                selections[index].actualScaleFactor = nil
                if value == "Custom", let custom = parsedScale(customScaleText[path]) {
                    selections[index].customScaleFactor = custom
                }
                if let source = selectedSourceByPath[path],
                   let scale = effectiveScaleFactor(selections[index], source: source) {
                    actualScaleText[path] = scaleText(scale)
                }
            }
        })
    }

    private var selectedSourceByPath: [String: TerrainInputImportSource] {
        Dictionary(uniqueKeysWithValues: (inspection?.sources ?? []).map { ($0.path, $0) })
    }

    private func conversionBinding(_ index: Int, source: TerrainInputImportSource) -> Binding<String> {
        Binding(get: { selections.indices.contains(index) ? selections[index].unitConversion : "Default" }, set: { value in
            guard selections.indices.contains(index) else { return }
            selections[index].unitConversion = value
            selections[index].actualScaleFactor = nil
            if value == "Custom", let custom = parsedScale(customScaleText[source.path]) {
                selections[index].customScaleFactor = custom
            }
            if let scale = effectiveScaleFactor(selections[index], source: source) {
                actualScaleText[source.path] = scaleText(scale)
            }
        })
    }

    private func actualScaleBinding(source: TerrainInputImportSource) -> Binding<String> {
        Binding(get: {
            if let text = actualScaleText[source.path] { return text }
            guard let selection = selections.first(where: { $0.path == source.path }),
                  let scale = effectiveScaleFactor(selection, source: source) else { return "" }
            return scaleText(scale)
        }, set: { raw in
            actualScaleText[source.path] = raw
            guard let value = parsedScale(raw),
                  let index = selections.firstIndex(where: { $0.path == source.path }) else { return }
            selections[index].actualScaleFactor = value
            if selections[index].unitConversion == "Custom" {
                selections[index].customScaleFactor = value
                customScaleText[source.path] = raw
            }
        })
    }

    private func effectiveScaleFactor(_ selection: TerrainInputImportSelection,
                                      source: TerrainInputImportSource) -> Double? {
        if let actual = selection.actualScaleFactor { return actual }
        switch selection.unitConversion {
        case "Default": return source.defaultScaleFactor ?? 1
        case "None": return 1
        case "FeetToMeters": return 0.3048
        case "MetersToFeet": return 3.28084
        case "Custom": return selection.customScaleFactor ?? parsedScale(customScaleText[source.path]) ?? 1
        default: return nil
        }
    }

    private func parsedScale(_ raw: String?) -> Double? {
        guard let raw,
              let value = OriginalUnitNumberInputCodec.parse(raw, locale: .autoupdatingCurrent),
              value.isFinite, Float(value).isFinite else { return nil }
        return value
    }

    private func scaleText(_ value: Double) -> String {
        OriginalUnitNumberInputCodec.format(value, locale: .autoupdatingCurrent)
    }

    private func customScaleBinding(source: TerrainInputImportSource) -> Binding<String> {
        Binding(get: {
            if let raw = customScaleText[source.path] { return raw }
            return OriginalUnitNumberInputCodec.format(1, locale: .autoupdatingCurrent)
        }, set: { raw in
            customScaleText[source.path] = raw
            if let value = OriginalUnitNumberInputCodec.parse(raw, locale: .autoupdatingCurrent),
               let index = selections.firstIndex(where: { $0.path == source.path }) {
                selections[index].customScaleFactor = value
                selections[index].actualScaleFactor = value
                actualScaleText[source.path] = raw
            }
        })
    }

    private func addFiles(_ urls: [URL]) {
        let incoming = urls.filter(\.isFileURL)
        // Files downloaded by our backend already belong to this workflow;
        // only newly selected external files require a folder authorization.
        let external = incoming.filter { !ownedInitialFilePaths.contains($0.standardizedFileURL.path) }
        guard !incoming.isEmpty,
              store.system.authorizeExternalFolders(Array(Set(external.map { $0.deletingLastPathComponent() }))) else { return }
        for url in incoming where !files.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { files.append(url) }
        inspect()
    }

    private func inspect() {
        work?.cancel()
        let token = UUID(); requestID = token
        guard ownerIsCurrent, !files.isEmpty, session.provider != nil, !session.isBusy, !store.isSavingAll else {
            inspection = nil; selections = []; inspectedFilePaths = []; isInspecting = false
            return
        }
        let oldSelections = Dictionary(selections.map { ($0.path, $0) }, uniquingKeysWith: { _, later in later })
        let paths = files.map(\.path)
        isInspecting = true; error = nil; inspection = nil
        work = Task {
            do {
                let result = try await session.inspectTerrainInputImport(files: files, expectedIdentity: ownerIdentity)
                guard !Task.isCancelled, requestID == token, ownerIsCurrent else { return }
                try result.validate()
                let currentSourcesByPath = Dictionary(uniqueKeysWithValues: result.sources.map {
                    ($0.path, stagedSourceKey($0.id, $0.revision))
                })
                failedSourceVersions = failedSourceVersions.filter { key, path in currentSourcesByPath[path] == key }
                inspection = result
                selections = try result.sources.filter(\.isValid).compactMap { source in
                    let key = stagedSourceKey(source.id, source.revision)
                    if successfullyStagedSources.contains(key) { return nil }
                    if var previous = oldSelections[source.path], previous.sourceRevision == source.revision {
                        previous.sourceID = source.id
                        return previous
                    }
                    if let preset = initialSettings[source.path] {
                        return try preset.selection(for: source)
                    }
                    if failedSourceVersions[key] != nil {
                        return TerrainInputImportSelection(path: source.path, sourceRevision: source.revision,
                            rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: source.id)
                    }
                    return TerrainInputImportSelection(path: source.path, sourceRevision: source.revision,
                        rounding: "None", unitConversion: "Default", customScaleFactor: nil, sourceID: source.id)
                }
                for source in result.sources where source.isValid {
                    let retainedSelectionMatches = oldSelections[source.path]?.sourceRevision == source.revision
                    if !retainedSelectionMatches || customScaleText[source.path] == nil {
                        // RasterFileToImport.UserCustomUnitConversionScaleFactor
                        // starts at 1f independently of the Default projection scale.
                        customScaleText[source.path] = initialSettings[source.path]?.scaleText(locale: .autoupdatingCurrent)
                            ?? OriginalUnitNumberInputCodec.format(1, locale: .autoupdatingCurrent)
                    }
                    if !retainedSelectionMatches || actualScaleText[source.path] == nil,
                       let selection = selections.first(where: { $0.path == source.path }),
                       let actualScale = effectiveScaleFactor(selection, source: source) {
                        actualScaleText[source.path] = scaleText(actualScale)
                    }
                }
                let currentPaths = Set(result.sources.map(\.path))
                customScaleText = customScaleText.filter { currentPaths.contains($0.key) }
                actualScaleText = actualScaleText.filter { currentPaths.contains($0.key) }
                if !result.sources.contains(where: { $0.path == selectedPath && !excludedSourcePaths.contains($0.path) }) {
                    selectedPath = result.sources.first(where: { !excludedSourcePaths.contains($0.path) })?.path
                }
                if !hasUserChosenStitchTiles { stitchTiles = result.stitchTilesDefault }
                inspectedFilePaths = paths
                requiresRetryInspection = false
            } catch {
                guard !Task.isCancelled, requestID == token, ownerIsCurrent else { return }
                self.error = L10n.text(error.localizedDescription)
            }
            if requestID == token { isInspecting = false }
        }
    }

    private func removeSelectedSource() {
        guard let selectedPath else { return }
        excludedSourcePaths.insert(selectedPath)
        selections.removeAll { $0.path == selectedPath }
        self.selectedPath = visibleSources.first(where: { $0.path != selectedPath })?.path
    }

    private func append() {
        guard canAppend else { return }
        let normalized = validSelections.map { selection -> TerrainInputImportSelection in
            var selection = selection
            if let actualScale = parsedScale(actualScaleText[selection.path]) {
                selection.actualScaleFactor = actualScale
            }
            if selection.unitConversion == "Custom" {
                selection.customScaleFactor = customScaleText[selection.path].flatMap {
                    OriginalUnitNumberInputCodec.parse($0, locale: .autoupdatingCurrent)
                }
                selection.actualScaleFactor = selection.customScaleFactor
            } else {
                selection.customScaleFactor = nil
            }
            return selection
        }
        isAppending = true; error = nil
        work = Task {
            guard let inspection else { isAppending = false; return }
            let success = await session.appendTerrainInputImport(normalized, inspection: inspection,
                stitchTiles: stitchTiles, expectedIdentity: ownerIdentity)
            if let success {
                record(success)
                ownerIdentity = session.terrainInputImportIdentity
                if !success.failedOperations.isEmpty { requiresRetryInspection = true }
            }
            isAppending = false
            if success == nil {
                if session.canRecheckTerrainInputImportStatus { requiresRetryInspection = true }
                if ownerIsCurrent { error = session.error ?? L10n.text("Terrain inputs could not be added to the model.") }
                else { dismiss() }
            }
        }
    }

    private func record(_ result: TerrainInputAppendResult) {
        guard !completedBatches.contains(where: { $0.batchToken == result.batchToken }) else { return }
        completedBatches.append(result)
        for operation in result.operations where operation.isStaged {
            for index in operation.sourceIDs.indices {
                let sourceID = operation.sourceIDs[index]
                let revision = operation.sourceRevisions[index]
                let key = stagedSourceKey(sourceID, revision)
                successfullyStagedSources.insert(key)
                failedSourceVersions.removeValue(forKey: key)
            }
        }
        for operation in result.operations where operation.isRetryable {
            for index in operation.sourceIDs.indices {
                failedSourceVersions[stagedSourceKey(operation.sourceIDs[index], operation.sourceRevisions[index])] =
                    operation.sourcePaths[index]
            }
        }
        selections.removeAll { selection in
            guard let sourceID = selection.sourceID else { return false }
            return successfullyStagedSources.contains(stagedSourceKey(sourceID, selection.sourceRevision))
        }
    }

    private func stagedSourceKey(_ sourceID: String, _ revision: String) -> String { sourceID + "|" + revision }

    private func checkImportStatus() {
        guard !isManagingImportRequest,
              session.isTerrainInputImportRunning || session.canRecheckTerrainInputImportStatus else { return }
        isCheckingStatus = true
        work = Task {
            let result = await session.refreshTerrainInputImportStatus(expectedIdentity: ownerIdentity)
            if let result {
                record(result)
                ownerIdentity = session.terrainInputImportIdentity
                requiresRetryInspection = !result.failedOperations.isEmpty
            } else if ownerIsCurrent {
                error = session.error
                if session.canRecheckTerrainInputImportStatus {
                    requiresRetryInspection = true
                }
            }
            isCheckingStatus = false
        }
    }

    private func cancelActiveImport() {
        guard !isCancellingOperation, session.isTerrainInputImportRunning else { return }
        isCancellingOperation = true
        work = Task {
            _ = await session.cancelTerrainInputImport(expectedIdentity: ownerIdentity)
            let result = await session.refreshTerrainInputImportStatus(expectedIdentity: ownerIdentity)
            if let result {
                record(result)
                ownerIdentity = session.terrainInputImportIdentity
                requiresRetryInspection = !result.failedOperations.isEmpty
            } else if ownerIsCurrent {
                error = session.error
            }
            isCancellingOperation = false
        }
    }

    private func cancelOperation(_ operationID: String) {
        guard !isCancellingOperation, session.canCancelTerrainInputImportOperation else { return }
        isCancellingOperation = true
        work = Task {
            _ = await session.cancelTerrainInputImport(expectedIdentity: ownerIdentity, operationID: operationID)
            let result = await session.refreshTerrainInputImportStatus(expectedIdentity: ownerIdentity)
            if let result {
                record(result)
                ownerIdentity = session.terrainInputImportIdentity
                requiresRetryInspection = !result.failedOperations.isEmpty
            } else if ownerIsCurrent {
                error = session.error
            }
            isCancellingOperation = false
        }
    }

    private func cancel() {
        guard !isManagingImportRequest, !session.isTerrainInputImportRunning, !session.isSaving else { return }
        requestID = UUID(); work?.cancel(); dismiss()
    }

    private func operationSymbol(_ status: String) -> String {
        switch status {
        case "Staged": return "checkmark.circle.fill"
        case "Failed": return "xmark.octagon.fill"
        case "Cancelled": return "minus.circle.fill"
        default: return "clock"
        }
    }

    private func operationColor(_ status: String) -> Color {
        switch status {
        case "Staged": return .green
        case "Failed": return .red
        case "Cancelled": return .orange
        default: return .secondary
        }
    }

    private func roundingLabel(_ raw: String) -> String {
        switch raw {
        case "None": return "None"
        case "Tenths": return "1/10"
        case "Hundredths": return "1/100"
        case "Thousandths": return "1/1000"
        case "Sixteenths": return "1/16"
        case "ThirtySeconds": return "1/32"
        case "SixtyFourths": return "1/64"
        case "HundredTwentyEighths": return "1/128"
        case "ThousandTwentyFourths": return "1/1024"
        default: return raw
        }
    }

    private func conversionLabel(_ raw: String) -> String {
        switch raw {
        case "Default": return "Default (Auto-Detect)"
        case "None": return "No Conversion"
        case "FeetToMeters": return "Convert Feet->Meters"
        case "MetersToFeet": return "Convert Meters->Feet"
        case "Custom": return "Custom"
        default: return raw
        }
    }
}
