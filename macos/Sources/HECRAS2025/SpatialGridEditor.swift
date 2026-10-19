import Foundation
import RASWorkspaceCore
import SwiftUI

struct SpatialGridBand: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let file: String
    let dataset: String
    let band: Int
    let revision: String
    var time: String?
    let issueTime: String?
    let units: String
    let dataType: String
    var included: Bool
    var component: String
    static func date(_ value: String) -> Date? {
        SpatialGridTimestamp.parse(value)
    }
}
enum SpatialGridTimestamp {
    static func parse(_ value: String) -> Date? {
        if hasExplicitTimeZone(value) { return SourceTimestamp.parse(value) }
        return OriginalDateTimeDraftCodec.parseStoredValue(value)
    }

    private static func hasExplicitTimeZone(_ value: String) -> Bool {
        if value.hasSuffix("Z") || value.hasSuffix("z") { return true }
        let suffix = Array(value.suffix(6))
        for length in [3, 5, 6] where suffix.count >= length {
            let candidate = Array(suffix.suffix(length))
            guard candidate.first == "+" || candidate.first == "-" else { continue }
            let offset = candidate.dropFirst()
            let digits = offset.filter { $0.isNumber }
            if (digits.count == 2 || digits.count == 4)
                && offset.allSatisfy({ $0.isNumber || $0 == ":" }) { return true }
        }
        return false
    }
}
enum SpatialGridTimeBehavior: String, Encodable, CaseIterable, Identifiable, Sendable {
    case projectBackwards = "ProjectBackwards"
    case projectForwards = "ProjectForwards"

    var id: String { rawValue }
}
struct SpatialGridSelection: Encodable, Sendable {
    let layerId: String
    let bands: [SpatialGridBand]
    let units: String
    let dataType: String
    let timeBehavior: SpatialGridTimeBehavior
    let dssSource: DssGridImportSelection?

    init(layerId: String, bands: [SpatialGridBand], units: String, dataType: String,
         timeBehavior: SpatialGridTimeBehavior = .projectBackwards,
         dssSource: DssGridImportSelection? = nil) {
        self.layerId = layerId
        self.bands = bands
        self.units = units
        self.dataType = dataType
        self.timeBehavior = timeBehavior
        self.dssSource = dssSource
    }
}
struct DssGridSeriesInfo: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let groupPath: String
    let title: String
    let times: [String]
    let recordPaths: [String]
    let units: String
    let dataType: String
    let projection: String
    let rows: Int
    let columns: Int
    let cellSize: Double
    let left: Double
    let bottom: Double
    let right: Double
    let top: Double
    let noDataValue: Float
    let sourceNullValue: Float
    let sourceUndefinedValue: Float
    let gridIdentity: String

    var timeSummary: String {
        guard let first = times.first, let last = times.last else { return "No valid frames" }
        return "\(times.count) · \(first) – \(last)"
    }
}
struct DssGridImportComponent: Encodable, Sendable {
    let component: String
    let seriesId: String
    let times: [String]
    let recordPaths: [String]
    let gridIdentity: String
}
struct DssGridImportSelection: Encodable, Sendable {
    let sourcePath: String
    let revision: String
    let draftIdentity: String
    let operationId: String
    let components: [DssGridImportComponent]
}
struct DssGridImportDuplexResult: Decodable, Sendable {
    let state: String
    let snapshot: BackendModelProvider.ModelSnapshot?
    let errorMessage: String?
    let refreshWarning: String?
}
struct DssGridImportControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}
struct SpatialGridPreview: Decodable, Sendable {
    let width: Int; let height: Int; let rgba: Data
    let minX: Double; let minY: Double; let maxX: Double; let maxY: Double
    let minimum: Double?; let maximum: Double?
    func validate() throws { _ = try presentation(name: "Raster") }
    func presentation(name: String) throws -> DataToolPreview {
        let layer = try MapRasterLayer(id: name, name: name, width: width, height: height, rgba: rgba,
            lowerLeft: .init(x: minX, y: minY), upperRight: .init(x: maxX, y: maxY))
        return .init(rasters: [layer])
    }
}
struct SpatialGridData: Decodable, Sendable {
    let layerId: String; let times: [String]; let components: [String]; let units: String; let projection: String
    let rows: Int; let columns: Int; let selectedTimeId: String?; let selectedComponent: String?
    let preview: SpatialGridPreview?; let error: String?
    func presentation(basedOn original: SpatialDatasetPresentation? = nil) throws -> SpatialDatasetPresentation {
        var result = original ?? .init(); result.gridData = self
        result.timeSteps = try components.flatMap { component in
            try times.map { time in
                guard let date = SpatialGridBand.date(time) else { throw ProjectFileError.invalid("Invalid raster timestep.") }
                return DataToolTimeStep(id: component + "|" + time, title: (component == "Value" ? "" : component + " · ") + date.formatted(date: .abbreviated, time: .standard), date: date)
            }
        }
        result.canSelectTime = !times.isEmpty
        result.selectedTimeStepID = selectedTimeId.map { (selectedComponent ?? components.first ?? "Value") + "|" + $0 }
        result.preview = try preview?.presentation(name: layerId) ?? .init()
        return result
    }
}
struct SpatialGridInspection: Decodable, Sendable {
    let bands: [SpatialGridBand]; let subdatasets: [String]; let preview: SpatialGridPreview?
    let unitOptions: [String]; let units: String; let dataType: String
    let dssGridSources: [DssGridSeriesInfo]?
    let dssGridDraftIdentity: String?
    let dssGridSourcePath: String?
    let dssGridRevision: String?
}

struct SpatialGridDatasetView: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    @State private var display = "Map"
    private var presentation: SpatialDatasetPresentation { session.spatialPresentations[layer.id] ?? .init() }
    private var data: SpatialGridData? { presentation.gridData }
    private var frameLoadID: String {
        (session.modelAssetID ?? "") + "|" + (session.sourceFileRevision ?? "") + "|" + String(session.isBusy) + "|" + presentation.timeSteps.map(\.id).joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $display) { Text("Map").tag("Map"); Text("Table").tag("Table") }.pickerStyle(.segmented).frame(width: 230)
                Spacer()
                if let data { Text("\(data.columns) × \(data.rows) · \(data.units)").monospacedDigit() }
            }.padding(12)
            if let error = data?.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding() }
            if display == "Map" {
                DataToolPreviewView(preview: presentation.preview, loading: session.loadingSelection, isCurrent: !session.loadingSelection)
                if let preview = data?.preview {
                    HStack {
                        Text("Sampled Range"); Text(preview.minimum?.formatted() ?? "—"); Text("…"); Text(preview.maximum?.formatted() ?? "—")
                        Text(data?.units ?? "")
                        Spacer(); Text("Preview uses the source raster coordinate system.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
            } else {
                Table(presentation.timeSteps) {
                    TableColumn("Timestep") { step in Text(step.title) }
                }
            }
            SpatialDatasetTimeline(layerID: layer.id, presentation: presentation, session: session)
        }
        .task(id: frameLoadID) {
            if !session.isBusy, presentation.selectedTimeStepID == nil, let step = presentation.timeSteps.first {
                _ = await session.perform(.selectSpatialTime(layerID: layer.id, stepID: step.id))
            }
        }
    }
}

struct SpatialGridImportSheet: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var openCumulusImporter: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var bands: [SpatialGridBand] = []
    @State private var subsets: [String] = []
    @State private var subset = ""
    @State private var units = ""
    @State private var dataType = ""
    @State private var timeBehavior: SpatialGridTimeBehavior = .projectBackwards
    @State private var unitOptions: [String] = []
    @State private var dssSources: [DssGridSeriesInfo]?
    @State private var dssSourcePath: String?
    @State private var dssRevision: String?
    @State private var dssDraftIdentity: String?
    @State private var dssValueSeriesID = ""
    @State private var dssXSeriesID = ""
    @State private var dssYSeriesID = ""
    @State private var preview = DataToolPreview()
    @State private var previewID: String?
    @State private var preparing = false
    @State private var error: String?
    @State private var prepared: String?
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?
    @State private var gridProgress: BackendProgressUpdate?
    @State private var gridImportCancel: GridImportCancelHandler?
    @State private var gridCancelRequested = false
    @State private var boundAssetID: String?
    @State private var boundProjectSessionID: UUID?
    @State private var scopeInvalidated = false
    private func selection(operationID: String? = nil) -> SpatialGridSelection {
        let dssImport: DssGridImportSelection? = {
            guard let dssSources, let dssSourcePath, let dssRevision, let dssDraftIdentity,
                  let operationID else { return nil }
            let chosen: [DssGridImportComponent]
            if layer == .wind {
                chosen = [("X", dssXSeriesID), ("Y", dssYSeriesID)].compactMap { component, id in
                    guard let source = dssSources.first(where: { $0.id == id }) else { return nil }
                    return DssGridImportComponent(component: component, seriesId: source.id,
                        times: source.times, recordPaths: source.recordPaths, gridIdentity: source.gridIdentity)
                }
            } else {
                chosen = dssSources.first(where: { $0.id == dssValueSeriesID }).map { source in
                    [DssGridImportComponent(component: "Value", seriesId: source.id,
                        times: source.times, recordPaths: source.recordPaths, gridIdentity: source.gridIdentity)]
                } ?? []
            }
            guard chosen.count == (layer == .wind ? 2 : 1) else { return nil }
            return DssGridImportSelection(sourcePath: dssSourcePath, revision: dssRevision,
                draftIdentity: dssDraftIdentity, operationId: operationID, components: chosen)
        }()
        return .init(layerId: layer.id, bands: bands, units: units, dataType: dataType,
            timeBehavior: timeBehavior, dssSource: dssImport)
    }
    private struct Inputs: Encodable {
        let layerId: String; let bands: [SpatialGridBand]; let units: String; let dataType: String
        let files: [String]; let subdataset: String; let previewId: String?
        let dssSourcePath: String?; let dssRevision: String?; let dssDraftIdentity: String?
        let dssValueSeriesID: String; let dssXSeriesID: String; let dssYSeriesID: String
    }
    private var signature: Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Inputs(layerId: layer.id, bands: bands, units: units, dataType: dataType,
            files: files.map(\.path), subdataset: subset, previewId: previewID,
            dssSourcePath: dssSourcePath, dssRevision: dssRevision, dssDraftIdentity: dssDraftIdentity,
            dssValueSeriesID: dssValueSeriesID, dssXSeriesID: dssXSeriesID, dssYSeriesID: dssYSeriesID))
    }
    private var sourceGroups: [SpatialGridTimestampSourceGroup] { SpatialGridOverlapSelection.groups(in: bands) }
    private var importSources: [SpatialGridImportSource] { SpatialGridOverlapSelection.sources(in: bands) }
    private var selectedDssDetails: [DssGridSeriesInfo] {
        guard let dssSources else { return [] }
        let ids = layer == .wind ? [dssXSeriesID, dssYSeriesID] : [dssValueSeriesID]
        return ids.filter { !$0.isEmpty }.reduce(into: [DssGridSeriesInfo]()) { result, id in
            if let source = dssSources.first(where: { $0.id == id }), !result.contains(where: { $0.id == id }) {
                result.append(source)
            }
        }
    }
    private var issueSelectionAvailable: Bool {
        sourceGroups.contains { group in
            group.bands.count > 1 && group.bands.allSatisfy { $0.issueTime.flatMap(SpatialGridBand.date) != nil }
        }
    }
    private var valid: Bool {
        guard scopeIsCurrent && session.canEdit && !preparing && !session.isBusy else { return false }
        if let dssSources {
            if layer == .wind {
                guard let x = dssSources.first(where: { $0.id == dssXSeriesID }),
                      let y = dssSources.first(where: { $0.id == dssYSeriesID }),
                      x.id != y.id, dssWindComponentsMatch(x, y),
                      unitOptions.contains(units), units.caseInsensitiveCompare(x.units) == .orderedSame,
                      units.caseInsensitiveCompare(y.units) == .orderedSame,
                      x.dataType.caseInsensitiveCompare("INST_VAL") == .orderedSame,
                      y.dataType.caseInsensitiveCompare("INST_VAL") == .orderedSame,
                      prepared == signature?.base64EncodedString() else { return false }
                return true
            }
            guard let dssValue = dssSources.first(where: { $0.id == dssValueSeriesID }),
                  unitOptions.contains(units), units.caseInsensitiveCompare(dssValue.units) == .orderedSame,
                  prepared == signature?.base64EncodedString() else { return false }
            if layer == .precipitation {
                let expected = dataType == "per-avg" ? "PER_AVER" : dataType == "per-cum" ? "PER_CUM" : ""
                return dssValue.dataType.caseInsensitiveCompare(expected) == .orderedSame
            }
            return dssValue.dataType.caseInsensitiveCompare("INST_VAL") == .orderedSame
        }
        let included = bands.filter(\.included)
        return !included.isEmpty
            && included.allSatisfy { $0.time.flatMap(SpatialGridBand.date) != nil }
            && !sourceGroups.isEmpty && sourceGroups.allSatisfy { $0.selectedBandIDs.count == 1 }
            && prepared == signature?.base64EncodedString()
    }
    private func dssWindComponentsMatch(_ x: DssGridSeriesInfo, _ y: DssGridSeriesInfo) -> Bool {
        x.times == y.times && x.rows == y.rows && x.columns == y.columns
            && x.cellSize == y.cellSize && x.noDataValue == y.noDataValue
            && x.projection == y.projection && x.gridIdentity == y.gridIdentity
    }
    private func dssSourceTitle(_ source: DssGridSeriesInfo) -> String {
        "\(source.title) · \(source.times.count) · \(source.units) · \(source.dataType)"
    }
    private func selectDssSeries(_ id: String) {
        guard let source = dssSources?.first(where: { $0.id == id }) else {
            previewID = nil
            prepared = nil
            reload()
            return
        }
        if unitOptions.contains(where: { $0.caseInsensitiveCompare(source.units) == .orderedSame }) {
            units = unitOptions.first(where: { $0.caseInsensitiveCompare(source.units) == .orderedSame }) ?? source.units
        }
        switch source.dataType.uppercased() {
        case "PER_AVER": dataType = "per-avg"
        case "PER_CUM": dataType = "per-cum"
        case "INST_VAL": dataType = "inst-val"
        default: break
        }
        previewID = source.id
        prepared = nil
        reload()
    }
    private var scopeIsCurrent: Bool {
        !scopeInvalidated && boundAssetID != nil && boundAssetID == session.modelAssetID
            && boundProjectSessionID == store.projectSessionID
    }
    private var canInspect: Bool {
        scopeIsCurrent && session.canEdit && !session.isBusy && !session.loadingSelection && !store.isSavingAll && !preparing
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Import Grid Data", systemImage: layer.symbol).font(.title2.weight(.semibold)); Spacer()
                Button(gridCancelRequested ? "Cancelling…" : "Cancel", role: .cancel) {
                    if session.isSaving {
                        if gridImportCancel?() == true { gridCancelRequested = true }
                    } else {
                        work?.cancel(); dismiss()
                    }
                }.disabled(gridCancelRequested || (session.isSaving && gridImportCancel == nil))
                Button("Import and Save Model") {
                    let expectedAssetID = boundAssetID
                    let expectedProjectSessionID = boundProjectSessionID
                    let capturedSelection = selection(operationID: UUID().uuidString.lowercased())
                    let capturedSignature = signature
                    gridProgress = nil
                    gridCancelRequested = false
                    work = Task {
                        guard !Task.isCancelled, scopeIsCurrent, session.modelAssetID == expectedAssetID,
                              store.projectSessionID == expectedProjectSessionID,
                              capturedSignature != nil, prepared == capturedSignature?.base64EncodedString() else { return }
                        let saved = await session.importGrid(capturedSelection, progress: { update in
                            gridProgress = update
                        }, cancellationAvailable: { cancel in
                            gridImportCancel = cancel
                            if gridCancelRequested { _ = cancel?() }
                        })
                        guard !Task.isCancelled else { return }
                        gridImportCancel = nil
                        gridProgress = nil
                        gridCancelRequested = false
                        if saved, session.modelAssetID == expectedAssetID,
                           store.projectSessionID == expectedProjectSessionID { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).disabled(!valid).keyboardShortcut(.defaultAction)
            }.padding(16)
            Text("Import saves this boundary model’s current edits together with the selected grids. Other project files are unchanged.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    Form {
                        Section("Input Files") {
                            Button("Add Files…") {
                                addFiles(store.system.chooseInputFiles())
                            }
                            .disabled(!canInspect)
                            if files.isEmpty {
                                Label("Choose raster files or drop them here.", systemImage: "square.and.arrow.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(dssSources == nil ? "Drop more raster files here to add them." : "A DSS import uses one source file.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button {
                                work?.cancel()
                                openCumulusImporter?()
                                dismiss()
                            } label: {
                                Label("Open Cumulus Importer", systemImage: "cloud.download")
                            }
                            .disabled(store.toolProvider == nil || openCumulusImporter == nil || !canInspect)
                            if store.toolProvider == nil || openCumulusImporter == nil {
                                Text("Cumulus import is unavailable because its model-provider route is not connected.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(files, id: \.standardizedFileURL) { file in
                                HStack {
                                    Text(file.lastPathComponent).help(file.path); Spacer()
                                    Button { removeFile(file) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove File")
                                }
                            }
                            if !subsets.isEmpty {
                                Picker("Subdataset", selection: $subset) { Text("None").tag(""); ForEach(subsets, id: \.self) { Text($0).tag($0) } }
                                    .onChange(of: subset) { _, _ in prepared = nil; reload() }
                            }
                        }
                        if let dssSources {
                            Section("DSS Grid Series") {
                                if layer == .wind {
                                    Picker("Wind X Series", selection: $dssXSeriesID) {
                                        Text("Choose a complete series…").tag("")
                                        ForEach(dssSources) { source in Text(dssSourceTitle(source)).tag(source.id) }
                                    }.onChange(of: dssXSeriesID) { _, value in selectDssSeries(value) }
                                    Picker("Wind Y Series", selection: $dssYSeriesID) {
                                        Text("Choose a complete series…").tag("")
                                        ForEach(dssSources) { source in Text(dssSourceTitle(source)).tag(source.id) }
                                    }.onChange(of: dssYSeriesID) { _, value in selectDssSeries(value) }
                                    if let x = dssSources.first(where: { $0.id == dssXSeriesID }),
                                       let y = dssSources.first(where: { $0.id == dssYSeriesID }) {
                                        if dssWindComponentsMatch(x, y) {
                                            Label("X and Y have matching frames, grid spacing, NoData and projection.", systemImage: "checkmark.circle")
                                                .font(.caption).foregroundStyle(.green)
                                        } else {
                                            Label("Choose X and Y series with matching valid times, grid spacing, NoData and projection.", systemImage: "exclamationmark.triangle")
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                    } else {
                                        Text("Select two distinct complete series from this DSS file.").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Picker("Value Series", selection: $dssValueSeriesID) {
                                        Text("Choose a complete series…").tag("")
                                        ForEach(dssSources) { source in Text(dssSourceTitle(source)).tag(source.id) }
                                    }.onChange(of: dssValueSeriesID) { _, value in selectDssSeries(value) }
                                }
                                ForEach(selectedDssDetails) { source in
                                    LabeledContent(source.title, value: source.timeSummary)
                                    LabeledContent("Grid", value: "\(source.columns) × \(source.rows) · \(source.cellSize.formatted())")
                                    LabeledContent("Projection", value: source.projection.isEmpty ? "Unprojected" : source.projection)
                                        .lineLimit(2).help(source.projection)
                                    LabeledContent("NoData", value: source.noDataValue.formatted())
                                }
                                if let dssSourcePath { Text(dssSourcePath).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
                            }
                        }
                        Section("Import Options") {
                            Picker("Source Units", selection: $units) { ForEach(unitOptions, id: \.self) { Text($0).tag($0) } }
                            if layer == .precipitation {
                                Picker("Data Type", selection: $dataType) { Text("Period Average").tag("per-avg"); Text("Period Cumulative").tag("per-cum") }
                            }
                            Picker("Time Behavior", selection: $timeBehavior) {
                                Text("Project Backwards").tag(SpatialGridTimeBehavior.projectBackwards)
                                Text("Project Forwards").tag(SpatialGridTimeBehavior.projectForwards)
                            }
                            Button("Generate Preview") { reload() }.disabled(files.isEmpty)
                            HStack {
                                Button("Latest Issue Time") { selectIssues(latest: true) }
                                Button("Earliest Issue Time") { selectIssues(latest: false) }
                            }.disabled(!issueSelectionAvailable)
                        }
                        if dssSources == nil {
                        Section("Source by Timestep") {
                            Text("Choose one source for each timestep. Overlapping sources can be changed independently.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !importSources.isEmpty {
                                Menu(L10n.text("Select All Keyframes from Source")) {
                                    ForEach(importSources) { source in
                                        Button(sourceTitle(source)) { selectAllKeyframes(from: source) }
                                    }
                                }
                                .disabled(!canInspect)
                            }
                            if sourceGroups.isEmpty {
                                Label("Assign a valid timestep to a raster band to choose its source.", systemImage: "clock.badge.questionmark")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(sourceGroups) { group in
                                    if group.bands.count > 1 || group.selectedBandID == nil {
                                        Picker(sourceGroupTitle(group), selection: Binding<String?>(
                                            get: { group.selectedBandID },
                                            set: { chooseSource($0, in: group) }
                                        )) {
                                            Text("No Source").tag(String?.none)
                                            ForEach(group.bands) { band in
                                                Text(sourceTitle(band)).tag(Optional(band.id)).help(band.file)
                                            }
                                        }
                                    } else if let selected = group.bands.first(where: \.included) {
                                        LabeledContent(sourceGroupTitle(group), value: sourceTitle(selected))
                                    }
                                }
                            }
                        }
                        Section("Source Preview") {
                            Picker("Raster Band", selection: Binding<String?>(get: { previewID }, set: { value in
                                previewID = value
                                reload()
                            })) {
                                Text("None").tag(String?.none)
                                ForEach(bands) { Text(sourceTitle($0)).tag(Optional($0.id)).help($0.file) }
                            }
                            Text("Set missing timestamps and resolve overlapping bands before importing.").font(.caption).foregroundStyle(.secondary)
                        }
                        }
                    }.formStyle(.grouped).disabled(preparing || session.isSaving || !canInspect)
                    if preparing || session.isSaving {
                        VStack(spacing: 5) {
                            if session.isSaving, let fraction = gridProgress?.fraction {
                                ProgressView(value: fraction) { Text(gridProgress?.taskName ?? "Importing Grids…") }
                            } else {
                                ProgressView(session.isSaving ? (gridProgress?.taskName ?? "Importing Grids…") : "Reading Raster Data…")
                            }
                            if session.isSaving, let message = gridProgress?.message {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding()
                    }
                }.frame(minWidth: 280, idealWidth: 330, maxWidth: 430)
                VSplitView {
                    DataToolPreviewView(preview: preview, loading: preparing, isCurrent: prepared == signature?.base64EncodedString()).frame(minHeight: 220)
                    if dssSources == nil { Table($bands) {
                        TableColumn("Use Band") { band in
                            let bandID = band.wrappedValue.id
                            Toggle("Use Band", isOn: Binding(get: { band.wrappedValue.included }, set: { setBandIncluded($0, id: bandID) })).labelsHidden()
                        }.width(65)
                        TableColumn("File") { band in Text(sourceTitle(band.wrappedValue)).help(band.wrappedValue.file) }.width(min: 190)
                        TableColumn("Timestep") { band in
                            let bandID = band.wrappedValue.id
                            if let value = band.wrappedValue.time.flatMap(SpatialGridBand.date) {
                                DatePicker("Timestep", selection: Binding(get: { band.wrappedValue.time.flatMap(SpatialGridBand.date) ?? value }, set: { updateBandTime(id: bandID, date: $0) })).labelsHidden()
                            } else {
                                Button("Set Timestep…") { updateBandTime(id: bandID, date: Date()) }
                            }
                        }.width(min: 230)
                        TableColumn("Issue Time") { band in Text(band.wrappedValue.issueTime.flatMap(SpatialGridBand.date)?.formatted() ?? "—") }.width(min: 160)
                        TableColumn("Component") { band in
                            if layer == .wind {
                                let bandID = band.wrappedValue.id
                                Picker("Component", selection: Binding(get: { band.wrappedValue.component }, set: { updateBandComponent(id: bandID, component: $0) })) {
                                    Text("X").tag("X"); Text("Y").tag("Y")
                                }.labelsHidden()
                            }
                            else { Text("Value") }
                        }.width(80)
                    }.disabled(preparing || session.isSaving).frame(minHeight: 210) }
                }.frame(minWidth: 600)
            }
            .dropDestination(for: URL.self) { urls, _ in addFiles(urls) }
            if let message = error ?? session.error { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12) }
        }.frame(minWidth: 1040, minHeight: 700)
        .interactiveDismissDisabled(session.isSaving && gridImportCancel == nil)
        .onAppear {
            if scopeInvalidated
                || (boundAssetID != nil && boundAssetID != session.modelAssetID)
                || (boundProjectSessionID != nil && boundProjectSessionID != store.projectSessionID) {
                work?.cancel(); requestID = UUID()
                files = []; bands = []; subsets = []; unitOptions = []; dssSources = nil; dssSourcePath = nil
                dssRevision = nil; dssDraftIdentity = nil; dssValueSeriesID = ""; dssXSeriesID = ""; dssYSeriesID = ""; previewID = nil
                units = ""; dataType = ""; timeBehavior = .projectBackwards; preview = .init(); prepared = nil; preparing = false
                error = L10n.text("The model changed. Close and reopen the grid importer.")
            }
            boundAssetID = session.modelAssetID
            boundProjectSessionID = store.projectSessionID
            scopeInvalidated = false
        }
        .onChange(of: session.modelAssetID) { _, assetID in
            if boundAssetID == nil, let assetID, !scopeInvalidated {
                boundAssetID = assetID
                return
            }
            guard assetID != boundAssetID else { return }
            invalidateChangedScope()
        }
        .onChange(of: store.projectSessionID) { _, projectSessionID in
            guard projectSessionID != boundProjectSessionID else { return }
            invalidateChangedScope()
        }
        .onDisappear {
            if let gridImportCancel { _ = gridImportCancel() }
        }
    }
    @discardableResult private func addFiles(_ urls: [URL]) -> Bool {
        guard canInspect else { return false }
        let candidates = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !candidates.isEmpty else { return false }
        var known = Set(files.map(\.standardizedFileURL))
        let additions = candidates.filter { known.insert($0).inserted }
        guard !additions.isEmpty else { return true }
        let combined = files + additions
        let dssFiles = combined.filter { $0.pathExtension.caseInsensitiveCompare("dss") == .orderedSame }
        guard dssFiles.isEmpty || (dssFiles.count == 1 && combined.count == 1) else {
            error = L10n.text("Choose one DSS file by itself. DSS grid records cannot be combined with other source files.")
            prepared = nil
            return false
        }
        let folders = Array(Set(additions.map { $0.deletingLastPathComponent().standardizedFileURL }))
        guard store.system.authorizeExternalFolders(folders) else {
            error = L10n.text("File access was not granted.")
            prepared = nil
            return false
        }
        let containsFolder = additions.contains { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !containsFolder else {
            error = L10n.text("Drop files, not folders.")
            prepared = nil
            return false
        }
        files.append(contentsOf: additions)
        reload()
        return true
    }
    private func removeFile(_ file: URL) {
        guard canInspect else { return }
        files.removeAll { $0.standardizedFileURL == file.standardizedFileURL }
        reload()
    }
    private func invalidateChangedScope() {
        work?.cancel()
        requestID = UUID()
        scopeInvalidated = true
        boundAssetID = nil
        boundProjectSessionID = nil
        files = []; bands = []; subsets = []; unitOptions = []; previewID = nil
        units = ""; dataType = ""; timeBehavior = .projectBackwards; preview = .init(); prepared = nil; preparing = false
        error = L10n.text("The model changed. Close and reopen the grid importer.")
    }
    private func reload() {
        work?.cancel(); let id = UUID(); requestID = id; error = nil; prepared = nil; preparing = false
        guard !files.isEmpty else {
            preparing = false; bands = []; subsets = []; unitOptions = []; dssSources = nil; dssSourcePath = nil
            dssRevision = nil; dssDraftIdentity = nil; dssValueSeriesID = ""; dssXSeriesID = ""; dssYSeriesID = ""; previewID = nil
            units = ""; dataType = ""; preview = .init()
            return
        }
        guard canInspect else { preparing = false; return }
        preparing = true
        let requestedFiles = files
        let requestedSubset = subset.isEmpty ? nil : subset
        let requestedBands = bands
        let requestedPreviewID = previewID
        let expectedAssetID = boundAssetID
        let expectedProjectSessionID = boundProjectSessionID
        work = Task {
            defer { if requestID == id { preparing = false } }
            do {
                let result = try await session.inspectGrid(layerID: layer.id, files: requestedFiles, subdataset: requestedSubset,
                    bands: requestedBands, previewID: requestedPreviewID)
                guard requestID == id, !Task.isCancelled, scopeIsCurrent,
                      session.modelAssetID == expectedAssetID, store.projectSessionID == expectedProjectSessionID else { return }
                if let inspectedDssSources = result.dssGridSources {
                    dssSources = inspectedDssSources
                    dssSourcePath = result.dssGridSourcePath
                    dssRevision = result.dssGridRevision
                    dssDraftIdentity = result.dssGridDraftIdentity
                    let sourceIDs = Set(inspectedDssSources.map(\.id))
                    if !sourceIDs.contains(dssValueSeriesID) { dssValueSeriesID = "" }
                    if !sourceIDs.contains(dssXSeriesID) { dssXSeriesID = "" }
                    if !sourceIDs.contains(dssYSeriesID) { dssYSeriesID = "" }
                    bands = []
                    subsets = []
                    unitOptions = result.unitOptions
                    if !unitOptions.contains(where: { $0.caseInsensitiveCompare(units) == .orderedSame }) {
                        units = result.units
                    }
                    if dataType.isEmpty { dataType = result.dataType }
                    let desiredPreviewID = requestedPreviewID.flatMap { sourceIDs.contains($0) ? $0 : nil }
                        ?? inspectedDssSources.first?.id
                    previewID = desiredPreviewID
                    preview = try result.preview?.presentation(name: layer.id) ?? .init()
                    prepared = signature?.base64EncodedString()
                    if inspectedDssSources.isEmpty {
                        error = L10n.text("No readable DSS grid series were found in this file.")
                    }
                    return
                }
                dssSources = nil
                dssSourcePath = nil
                dssRevision = nil
                dssDraftIdentity = nil
                dssValueSeriesID = ""; dssXSeriesID = ""; dssYSeriesID = ""
                let normalizedBands = SpatialGridOverlapSelection.normalized(result.bands, preserving: requestedBands)
                let responsePreviewID = requestedPreviewID.flatMap { requested in result.bands.contains(where: { $0.id == requested }) ? requested : nil }
                    ?? result.bands.first?.id
                let desiredPreviewID = requestedPreviewID.flatMap { requested in normalizedBands.contains(where: { $0.id == requested }) ? requested : nil }
                    ?? normalizedBands.first(where: \.included)?.id
                    ?? normalizedBands.first?.id
                bands = normalizedBands; subsets = result.subdatasets; unitOptions = result.unitOptions
                previewID = desiredPreviewID
                if !unitOptions.contains(units) { units = result.units }
                if dataType.isEmpty { dataType = result.dataType }
                guard responsePreviewID == desiredPreviewID else {
                    preparing = false
                    reload()
                    return
                }
                preview = try result.preview?.presentation(name: layer.id) ?? .init()
                prepared = signature?.base64EncodedString()
            } catch {
                if requestID == id, !Task.isCancelled, scopeIsCurrent,
                   session.modelAssetID == expectedAssetID, store.projectSessionID == expectedProjectSessionID {
                    self.error = L10n.text(error.localizedDescription)
                }
            }
        }
    }
    private func selectIssues(latest: Bool) {
        let updated = SpatialGridOverlapSelection.selectingIssueTimes(in: bands, latest: latest)
        guard updated != bands else { return }
        bands = updated
        previewID = SpatialGridOverlapSelection.groups(in: updated).first(where: { $0.selectedBandID != nil })?.selectedBandID ?? updated.first?.id
        reload()
    }
    private func selectAllKeyframes(from source: SpatialGridImportSource) {
        guard canInspect,
              let updated = SpatialGridOverlapSelection.selectingAllKeyframes(from: source.id, in: bands),
              updated != bands else { return }
        bands = updated
        previewID = updated.first(where: { band in
            band.included && SourceFilePaths.canonical(URL(fileURLWithPath: band.file))
                == SourceFilePaths.canonical(URL(fileURLWithPath: source.file))
                && band.dataset == source.dataset && band.revision == source.revision
        })?.id ?? updated.first(where: { $0.included })?.id
            ?? updated.first?.id
        reload()
    }
    private func chooseSource(_ bandID: String?, in group: SpatialGridTimestampSourceGroup) {
        guard canInspect, let updated = SpatialGridOverlapSelection.selecting(bandID, in: group.id, from: bands) else { return }
        bands = updated
        previewID = bandID ?? bands.first(where: \.included)?.id ?? bands.first?.id
        reload()
    }
    private func setBandIncluded(_ included: Bool, id: String) {
        guard canInspect, bands.contains(where: { $0.id == id }) else { return }
        if let group = sourceGroups.first(where: { $0.bands.contains(where: { $0.id == id }) }) {
            guard let updated = SpatialGridOverlapSelection.selecting(included ? id : nil, in: group.id, from: bands) else { return }
            bands = updated
        } else {
            for index in bands.indices where bands[index].id == id { bands[index].included = included }
        }
        if included { previewID = id }
        else if previewID == id { previewID = bands.first(where: \.included)?.id ?? bands.first?.id }
        reload()
    }
    private func updateBandTime(id: String, date: Date) {
        guard canInspect, let index = bands.firstIndex(where: { $0.id == id }) else { return }
        bands[index].time = ISO8601DateFormatter().string(from: date)
        bands = SpatialGridOverlapSelection.normalized(bands, preserving: bands)
        reload()
    }
    private func updateBandComponent(id: String, component: String) {
        guard canInspect, let index = bands.firstIndex(where: { $0.id == id }) else { return }
        bands[index].component = component
        bands = SpatialGridOverlapSelection.normalized(bands, preserving: bands)
        reload()
    }
    private func sourceGroupTitle(_ group: SpatialGridTimestampSourceGroup) -> String {
        let time = group.time.formatted(date: .abbreviated, time: .shortened)
        return group.component == "Value" ? time : group.component + " · " + time
    }
    private func sourceTitle(_ band: SpatialGridBand) -> String {
        let file = URL(fileURLWithPath: band.file)
        let parent = file.deletingLastPathComponent().lastPathComponent
        let fileName = parent.isEmpty ? file.lastPathComponent : parent + "/" + file.lastPathComponent
        let dataset = band.dataset == band.file ? "" : " · " + band.dataset
        let issue = band.issueTime.flatMap(SpatialGridBand.date).map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return fileName + dataset + " · " + L10n.text("Band") + " " + String(band.band + 1) + issue
    }
    private func sourceTitle(_ source: SpatialGridImportSource) -> String {
        let file = URL(fileURLWithPath: source.file)
        let parent = file.deletingLastPathComponent().lastPathComponent
        let fileName = parent.isEmpty ? file.lastPathComponent : parent + "/" + file.lastPathComponent
        let dataset = source.dataset == source.file ? "" : " · " + source.dataset
        let samePathAndDataset = importSources.filter {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.file)) == SourceFilePaths.canonical(URL(fileURLWithPath: source.file))
                && $0.dataset == source.dataset
        }
        let revision = samePathAndDataset.count > 1 ? " · " + String(source.revision.prefix(8)) : ""
        return fileName + dataset + revision
    }
}
