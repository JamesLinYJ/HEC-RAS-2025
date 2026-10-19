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
        SourceTimestamp.parse(value)
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

    init(layerId: String, bands: [SpatialGridBand], units: String, dataType: String,
         timeBehavior: SpatialGridTimeBehavior = .projectBackwards) {
        self.layerId = layerId
        self.bands = bands
        self.units = units
        self.dataType = dataType
        self.timeBehavior = timeBehavior
    }
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
    @State private var preview = DataToolPreview()
    @State private var previewID: String?
    @State private var preparing = false
    @State private var error: String?
    @State private var prepared: String?
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?
    @State private var boundAssetID: String?
    @State private var boundProjectSessionID: UUID?
    @State private var scopeInvalidated = false
    private var selection: SpatialGridSelection {
        .init(layerId: layer.id, bands: bands, units: units, dataType: dataType, timeBehavior: timeBehavior)
    }
    private struct Inputs: Encodable {
        let layerId: String; let bands: [SpatialGridBand]; let units: String; let dataType: String
        let files: [String]; let subdataset: String; let previewId: String?
    }
    private var signature: Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Inputs(layerId: layer.id, bands: bands, units: units, dataType: dataType,
            files: files.map(\.path), subdataset: subset, previewId: previewID))
    }
    private var sourceGroups: [SpatialGridTimestampSourceGroup] { SpatialGridOverlapSelection.groups(in: bands) }
    private var importSources: [SpatialGridImportSource] { SpatialGridOverlapSelection.sources(in: bands) }
    private var issueSelectionAvailable: Bool {
        sourceGroups.contains { group in
            group.bands.count > 1 && group.bands.allSatisfy { $0.issueTime.flatMap(SpatialGridBand.date) != nil }
        }
    }
    private var valid: Bool {
        let included = bands.filter(\.included)
        return scopeIsCurrent && session.canEdit && !preparing && !session.isBusy && !included.isEmpty
            && included.allSatisfy { $0.time.flatMap(SpatialGridBand.date) != nil }
            && !sourceGroups.isEmpty && sourceGroups.allSatisfy { $0.selectedBandIDs.count == 1 }
            && prepared == signature?.base64EncodedString()
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
                Button("Cancel", role: .cancel) { work?.cancel(); dismiss() }.disabled(session.isSaving)
                Button("Import and Save Model") {
                    let expectedAssetID = boundAssetID
                    let expectedProjectSessionID = boundProjectSessionID
                    let capturedSelection = selection
                    let capturedSignature = signature
                    work = Task {
                        guard !Task.isCancelled, scopeIsCurrent, session.modelAssetID == expectedAssetID,
                              store.projectSessionID == expectedProjectSessionID,
                              capturedSignature != nil, prepared == capturedSignature?.base64EncodedString() else { return }
                        let saved = await session.importGrid(capturedSelection)
                        guard !Task.isCancelled else { return }
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
                                Text("Drop more raster files here to add them.")
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
                    }.formStyle(.grouped).disabled(preparing || session.isSaving || !canInspect)
                    if preparing || session.isSaving { ProgressView(session.isSaving ? "Importing Grids…" : "Reading Raster Data…").padding() }
                }.frame(minWidth: 280, idealWidth: 330, maxWidth: 430)
                VSplitView {
                    DataToolPreviewView(preview: preview, loading: preparing, isCurrent: prepared == signature?.base64EncodedString()).frame(minHeight: 220)
                    Table($bands) {
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
                    }.disabled(preparing || session.isSaving).frame(minHeight: 210)
                }.frame(minWidth: 600)
            }
            .dropDestination(for: URL.self) { urls, _ in addFiles(urls) }
            if let message = error ?? session.error { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12) }
        }.frame(minWidth: 1040, minHeight: 700)
        .interactiveDismissDisabled(session.isSaving)
        .onAppear {
            if scopeInvalidated
                || (boundAssetID != nil && boundAssetID != session.modelAssetID)
                || (boundProjectSessionID != nil && boundProjectSessionID != store.projectSessionID) {
                work?.cancel(); requestID = UUID()
                files = []; bands = []; subsets = []; unitOptions = []; previewID = nil
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
        .onDisappear { work?.cancel() }
    }
    @discardableResult private func addFiles(_ urls: [URL]) -> Bool {
        guard canInspect else { return false }
        let candidates = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !candidates.isEmpty else { return false }
        var known = Set(files.map(\.standardizedFileURL))
        let additions = candidates.filter { known.insert($0).inserted }
        guard !additions.isEmpty else { return true }
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
            preparing = false; bands = []; subsets = []; unitOptions = []; previewID = nil
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
