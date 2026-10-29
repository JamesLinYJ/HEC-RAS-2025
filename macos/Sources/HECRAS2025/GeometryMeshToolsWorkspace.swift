import SwiftUI

private struct GeometryMeshToolsPropertyChartRoute: Hashable {
    let owner: GeometryMeshToolsOwnerCapture
    let elementKind: GeometryMeshElementKind
    let elementIndex: Int
    let projectContext: GeometryMeshToolsProjectContext
    let selectedRegionIDs: [Int]

    var id: String {
        [owner.identity, elementKind.rawValue, String(elementIndex)].joined(separator: "|")
    }
}

struct GeometryMeshToolsWorkspaceView: View {
    @ObservedObject var session: GeometryMeshSession
    @ObservedObject var store: WorkspaceStore
    var onFindCompleted: (() -> Void)? = nil

    @State private var selectedFlowAreaID = ""
    @State private var elementKind = GeometryMeshElementKind.cell
    @State private var elementIndex = "0"
    @State private var exportKind = GeometryMeshShapefileExportKind.cellCenters
    @State private var pendingPropertyChart: GeometryMeshToolsPropertyChartRoute?
    @State private var propertyChartGeneration = UUID()
    @State private var propertyChartTask: Task<Void, Never>?
    @State private var isPreparingPropertyChart = false
    @State private var propertyChartWorkflowError: String?

    private var meshFlowAreas: [GeometryMeshFlowAreaRow] {
        session.flowAreas.filter(\.hasMesh)
    }

    private var selectedFlowArea: GeometryMeshFlowAreaRow? {
        meshFlowAreas.first { $0.id == selectedFlowAreaID }
    }

    private var parsedIndex: Int? {
        guard let value = Int(elementIndex), value >= 0 else { return nil }
        return value
    }

    private var projectContext: GeometryMeshToolsProjectContext? {
        GeometryMeshToolsProjectContext(projectSessionID: store.projectSessionID,
            coreLayerContext: store.captureCoreLayerRequestContext())
    }


    var body: some View {
        HSplitView {
            Form {
                Section(L10n.text("Find mesh element")) {
                    flowAreaPicker
                    Picker(L10n.text("Element type"), selection: $elementKind) {
                        ForEach(GeometryMeshElementKind.allCases) { kind in
                            Text(L10n.text(kind.rawValue)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField(L10n.text("Source index"), text: $elementIndex)
                        .monospacedDigit()
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.text("Indexes are zero-based source mesh ordinals. Negative or out-of-range indexes are rejected."))
                        .font(.caption).foregroundStyle(.secondary)

                    if let selectedFlowArea {
                        LabeledContent(L10n.text("Flow Area ID"), value: selectedFlowArea.id)
                            .textSelection(.enabled)
                        Button(L10n.text("Find in Mesh Map"), systemImage: "scope") {
                            Task { await findSelectedElement() }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(session.isFindingMeshElement || session.isExportingMeshShapefile
                            || session.isComputingPropertyTables || isPreparingPropertyChart
                            || parsedIndex == nil || selectedFlowAreaID.isEmpty)
                    } else {
                        ContentUnavailableView(L10n.text("Select a meshed Flow Area"),
                            systemImage: "square.grid.3x3",
                            description: Text(L10n.text("Find and export use the exact source Flow Area ID and name.")))
                            .frame(minHeight: 120)
                    }

                    if session.isFindingMeshElement {
                        ProgressView(L10n.text("Finding source mesh element…"))
                            .controlSize(.small)
                    }
                    if let find = session.meshElementFind {
                        findReceipt(find)
                    }
                }

                Section(L10n.text("Export mesh Shapefile")) {
                    flowAreaPicker
                    Picker(L10n.text("Export type"), selection: $exportKind) {
                        ForEach(GeometryMeshShapefileExportKind.allCases) { kind in
                            Text(L10n.text(kind.rawValue)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(exportDescription)
                        .font(.caption).foregroundStyle(.secondary)

                    Button(L10n.text("Choose destination and export…"), systemImage: "square.and.arrow.up") {
                        chooseDestinationAndExport()
                    }
                    .buttonStyle(.glass)
                    .disabled(selectedFlowArea == nil || session.isFindingMeshElement
                        || session.isExportingMeshShapefile || session.isComputingPropertyTables
                        || isPreparingPropertyChart)

                    if session.isExportingMeshShapefile {
                        if let fraction = session.meshShapefileExportProgress?.fraction,
                           fraction.isFinite, fraction >= 0 {
                            ProgressView(value: min(1, fraction))
                        } else {
                            ProgressView()
                        }
                        Text(session.meshShapefileExportProgress?.message
                            ?? L10n.text("Writing Shapefile family…"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.text("Cancel export"), systemImage: "xmark.circle") {
                            session.cancelMeshShapefileExport()
                        }
                        .disabled(session.isCancellingMeshShapefileExport)
                    }
                    if let outcome = session.meshShapefileExportOutcome {
                        Label(L10n.text(outcome), systemImage: outcome == "completed"
                            ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(outcome == "completed" ? .green : .secondary)
                    }
                }

                if let error = session.meshToolsError {
                    Section(L10n.text("Mesh tools")) {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if !session.meshShapefileExportReceipts.isEmpty {
                    Section(L10n.text("Saved exports")) {
                        ForEach(session.meshShapefileExportReceipts) { receipt in
                            exportReceipt(receipt)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 340, idealWidth: 430, maxWidth: 520)

            chartPane
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: restoreSelection)
        .onChange(of: selectedFlowAreaID) { _, id in
            if let pendingPropertyChart, pendingPropertyChart.owner.flowAreaID != id {
                retirePropertyChart(cancelCompute: true)
            }
            session.selectFlowArea(id.isEmpty ? nil : id)
        }
        .onChange(of: session.selectedFlowAreaID) { _, id in
            let next = id ?? ""
            if selectedFlowAreaID != next { selectedFlowAreaID = next }
        }
        .onChange(of: projectContext) { _, context in
            if let pendingPropertyChart, pendingPropertyChart.projectContext != context {
                retirePropertyChart(cancelCompute: true)
            }
            session.clearMeshElementFindTargetIfOwnerChanged(projectContext: context)
        }
        .onChange(of: session.geometryMeshIdentity) { _, _ in
            session.clearMeshElementFindTargetIfOwnerChanged(projectContext: projectContext)
        }
        .onChange(of: session.meshToolsChartSourceIdentity) { _, _ in
            // A successful child computation intentionally changes only the
            // mesh-draft SHA. Keep its route until computePropertyTables()
            // returns and the exact element can be found under a fresh owner.
            if !isPreparingPropertyChart, let pendingPropertyChart,
               !session.isMeshToolsChartSourceCurrent(pendingPropertyChart.owner,
                   projectContext: pendingPropertyChart.projectContext) {
                retirePropertyChart(cancelCompute: true)
            }
        }
        .onChange(of: session.meshElementFind?.identity) { _, identity in
            if identity == nil && !isPreparingPropertyChart {
                retirePropertyChart(cancelCompute: false)
            }
        }
        .onChange(of: session.selectedRegionIDs.sorted()) { _, selected in
            if let pendingPropertyChart,
               pendingPropertyChart.selectedRegionIDs != selected,
               !isPreparingPropertyChart {
                retirePropertyChart(cancelCompute: false)
            }
        }
        .onDisappear { retirePropertyChart(cancelCompute: true) }
    }

    @ViewBuilder private var chartPane: some View {
        if isPreparingPropertyChart {
            propertyTableComputeProgress
        } else if let route = pendingPropertyChart,
                  route.projectContext == projectContext,
                  route.selectedRegionIDs == session.selectedRegionIDs.sorted(),
                  selectedFlowAreaID == route.owner.flowAreaID,
                  session.isMeshToolsOwnerCurrent(route.owner, projectContext: route.projectContext) {
            VStack(spacing: 12) {
                if let propertyChartWorkflowError {
                    Label(L10n.text(propertyChartWorkflowError), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GeometryMeshElementChartWindowView(session: session, ownerCapture: route.owner,
                    elementKind: route.elementKind, elementIndex: route.elementIndex,
                    projectContext: route.projectContext,
                    onComputeAndPlotRequested: { requestPropertyTableComputeAndPlot(route) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                GeometryMeshElementCrossResultChartEntry(store: store, session: session,
                    ownerCapture: route.owner, elementKind: route.elementKind,
                    elementIndex: route.elementIndex, projectContext: route.projectContext)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(route.id)
        } else if let find = session.meshElementFind,
                  find.result.elementKind == GeometryMeshElementKind.node.rawValue {
            ContentUnavailableView(L10n.text("Charts are not available for nodes"),
                systemImage: "chart.xyaxis.line",
                description: Text(L10n.text("Find a Cell or Face to inspect its source property curve.")))
        } else if pendingPropertyChart != nil {
            ContentUnavailableView(L10n.text("The Geometry mesh selection changed"),
                systemImage: "arrow.clockwise",
                description: Text(L10n.text("Find the element again before opening its property curve.")))
        } else {
            ContentUnavailableView(L10n.text("Find and export geometry mesh data"),
                systemImage: "magnifyingglass.circle",
                description: Text(L10n.text("Find locates exact source coordinates in the Mesh Map. Cell and Face results also show source property curves here. Export writes Cell Centers or perimeter faces from the selected Flow Area.")))
        }
    }

    private var flowAreaPicker: some View {
        Picker(L10n.text("Flow Area"), selection: $selectedFlowAreaID) {
            Text(L10n.text("Choose a Flow Area…")).tag("")
            ForEach(meshFlowAreas) { row in
                Text("\(row.name) · \(row.id)").tag(row.id)
            }
        }
        .pickerStyle(.menu)
        .disabled(meshFlowAreas.isEmpty || session.isFindingMeshElement || session.isExportingMeshShapefile
            || session.isComputingPropertyTables || isPreparingPropertyChart)
    }

    private var exportDescription: String {
        switch exportKind {
        case .cellCenters:
            L10n.text("Writes one point at each source mesh cell center.")
        case .perimeterFaces:
            L10n.text("Writes faces with one adjacent cell outside the mesh; each record includes Face, CellA, CellB, and Length.")
        }
    }

    private func restoreSelection() {
        if let id = session.selectedFlowAreaID, meshFlowAreas.contains(where: { $0.id == id }) {
            selectedFlowAreaID = id
        } else {
            selectedFlowAreaID = ""
        }
    }

    private func findSelectedElement() async {
        retirePropertyChart(cancelCompute: false)
        guard let selectedFlowArea, let client = store.runtimeInfoClient else {
            session.reportMeshToolsError(L10n.text("The geometry mesh service is unavailable."))
            return
        }
        let provider = BackendGeometryMeshElementToolsProvider(client: client)
        let found = await session.findElement(flowAreaID: selectedFlowArea.id,
            elementKind: elementKind, index: parsedIndex ?? -1,
            currentProjectContext: { projectContext }, provider: provider)
        if found, let presentation = session.meshElementFind,
           let kind = GeometryMeshElementKind(rawValue: presentation.result.elementKind),
           kind == .cell || kind == .face,
           let projectContext {
            pendingPropertyChart = GeometryMeshToolsPropertyChartRoute(owner: presentation.owner,
                elementKind: kind, elementIndex: presentation.result.index,
                projectContext: projectContext, selectedRegionIDs: session.selectedRegionIDs.sorted())
            propertyChartWorkflowError = nil
        }
        if found { onFindCompleted?() }
    }

    private var propertyTableComputeProgress: some View {
        VStack(alignment: .leading, spacing: 14) {
            OperationProgressView(title: "Computing property tables…",
                message: L10n.text(session.propertyTablesProgress?.message
                    ?? session.propertyTablesProgress?.taskName
                    ?? "Processing property tables for this geometry…"),
                fraction: session.propertyTablesProgress?.fraction,
                cancelling: session.isCancellingPropertyTables,
                cancel: session.isComputingPropertyTables && !session.isCancellingPropertyTables
                    ? { session.cancelPropertyTables() } : nil)
            if !session.propertyTablesMessages.isEmpty {
                ForEach(Array(session.propertyTablesMessages.enumerated()), id: \.offset) { _, message in
                    Text(L10n.text(message)).font(.callout).textSelection(.enabled)
                }
            }
            if let error = session.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func requestPropertyTableComputeAndPlot(_ route: GeometryMeshToolsPropertyChartRoute) {
        guard pendingPropertyChart == route, !isPreparingPropertyChart else { return }
        guard route.projectContext == projectContext,
              route.selectedRegionIDs == session.selectedRegionIDs.sorted(),
              selectedFlowAreaID == route.owner.flowAreaID,
              session.isMeshToolsOwnerCurrent(route.owner, projectContext: projectContext),
              session.canComputePropertyTables else {
            propertyChartWorkflowError = L10n.text("The Geometry mesh selection changed. Find the element again.")
            return
        }
        guard let client = store.runtimeInfoClient else {
            propertyChartWorkflowError = L10n.text("The geometry mesh service is unavailable.")
            return
        }
        let generation = UUID()
        propertyChartGeneration = generation
        propertyChartWorkflowError = nil
        isPreparingPropertyChart = true
        let provider = BackendGeometryMeshElementToolsProvider(client: client)
        propertyChartTask = Task {
            await computePropertyTablesAndReplot(route, generation: generation, toolsProvider: provider)
        }
    }

    private func computePropertyTablesAndReplot(_ route: GeometryMeshToolsPropertyChartRoute,
        generation: UUID, toolsProvider: BackendGeometryMeshElementToolsProvider) async {
        defer {
            if propertyChartGeneration == generation {
                isPreparingPropertyChart = false
                propertyChartTask = nil
            }
        }

        let computed = await session.computePropertyTables()
        guard propertyChartGeneration == generation, !Task.isCancelled else { return }
        guard computed else {
            guard pendingPropertyChart == route,
                  route.projectContext == projectContext,
                  route.selectedRegionIDs == session.selectedRegionIDs.sorted(),
                  selectedFlowAreaID == route.owner.flowAreaID,
                  session.isMeshToolsChartSourceCurrent(route.owner, projectContext: projectContext) else {
                pendingPropertyChart = nil
                propertyChartWorkflowError = L10n.text("The Geometry mesh selection changed. Find the element again.")
                return
            }
            propertyChartWorkflowError = session.propertyTablesOutcome == "cancelled"
                ? L10n.text("Property-table calculation was cancelled. The Geometry draft and source HDF were not changed.")
                : session.error ?? L10n.text("The source could not compute property tables for this geometry.")
            return
        }
        guard pendingPropertyChart == route,
              route.projectContext == projectContext,
              route.selectedRegionIDs == session.selectedRegionIDs.sorted(),
              selectedFlowAreaID == route.owner.flowAreaID,
              session.isMeshToolsChartSourceCurrent(route.owner, projectContext: projectContext),
              let refreshedOwner = session.meshToolsOwnerCapture(flowAreaID: route.owner.flowAreaID,
                  projectContext: route.projectContext),
              GeometryMeshSession.sameMeshToolsChartSource(route.owner, refreshedOwner),
              route.owner.meshDraftSHA256.caseInsensitiveCompare(refreshedOwner.meshDraftSHA256) != .orderedSame else {
            propertyChartWorkflowError = L10n.text("The Geometry mesh selection changed. Find the element again.")
            pendingPropertyChart = nil
            return
        }

        let found = await session.findElement(flowAreaID: route.owner.flowAreaID,
            elementKind: route.elementKind, index: route.elementIndex,
            currentProjectContext: { projectContext }, provider: toolsProvider)
        guard propertyChartGeneration == generation, !Task.isCancelled else { return }
        guard found, let presentation = session.meshElementFind,
              presentation.owner == refreshedOwner,
              presentation.result.elementKind == route.elementKind.rawValue,
              presentation.result.index == route.elementIndex,
              session.isMeshToolsOwnerCurrent(presentation.owner, projectContext: projectContext),
              session.selectedFlowAreaID == route.owner.flowAreaID,
              session.selectedRegionIDs.sorted() == route.selectedRegionIDs else {
            propertyChartWorkflowError = session.meshToolsError
                ?? L10n.text("The Geometry mesh selection changed. Find the element again.")
            pendingPropertyChart = nil
            return
        }

        pendingPropertyChart = GeometryMeshToolsPropertyChartRoute(owner: presentation.owner,
            elementKind: route.elementKind, elementIndex: route.elementIndex,
            projectContext: route.projectContext, selectedRegionIDs: route.selectedRegionIDs)
        propertyChartWorkflowError = nil
    }

    private func retirePropertyChart(cancelCompute: Bool) {
        propertyChartGeneration = UUID()
        pendingPropertyChart = nil
        propertyChartWorkflowError = nil
        guard isPreparingPropertyChart else { return }
        propertyChartTask?.cancel()
        propertyChartTask = nil
        isPreparingPropertyChart = false
        if cancelCompute && session.isComputingPropertyTables {
            session.cancelPropertyTables()
        }
    }

    private func chooseDestinationAndExport() {
        guard let selectedFlowArea else { return }
        let suffix = exportKind == .cellCenters ? "cell-centers" : "perimeter-faces"
        let basename = safeFilename(selectedFlowArea.name) + "-" + suffix + ".shp"
        guard let selectedURL = store.system.chooseExportDestination(name: basename,
            extensions: ["shp"], title: L10n.text("Export Geometry Mesh Shapefile")) else { return }
        let outputURL = GeometryMeshShapefileDestination.normalized(selectedURL)
        let collisions = GeometryMeshShapefileDestination.existingFamily(at: outputURL)
        guard collisions.isEmpty else {
            session.reportMeshToolsError(L10n.text("The selected output or one of its Shapefile sidecar files already exists. Choose a new name."))
            return
        }
        guard let client = store.runtimeInfoClient else {
            session.reportMeshToolsError(L10n.text("The geometry mesh service is unavailable."))
            return
        }
        let provider = BackendGeometryMeshElementToolsProvider(client: client)
        Task {
            await session.exportShapefile(flowAreaID: selectedFlowArea.id,
                exportKind: exportKind, outputURL: outputURL,
                currentProjectContext: { projectContext }, provider: provider)
        }
    }

    private func findReceipt(_ presentation: GeometryMeshElementFindPresentation) -> some View {
        let result = presentation.result
        return VStack(alignment: .leading, spacing: 4) {
            Label(L10n.format("%@ %@ found", L10n.text(result.elementKind), result.index.formatted()),
                systemImage: "scope")
                .font(.callout.weight(.medium))
            Text("\(result.flowAreaName) · \(result.flowAreaID)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("X \(result.x.formatted()), Y \(result.y.formatted())")
                .font(.caption.monospacedDigit()).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 10))
    }

    private func exportReceipt(_ presentation: GeometryMeshShapefileExportPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L10n.text(presentation.result.exportKind), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                if let url = presentation.shapefileURL {
                    Button(L10n.text("Reveal"), systemImage: "folder") { store.system.reveal(url) }
                        .buttonStyle(.borderless)
                }
            }
            Text("\(presentation.result.flowAreaName) · \(presentation.result.flowAreaID)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let path = presentation.result.outputPath {
                Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
            }
            Text(L10n.format("%@ features", presentation.result.featureCount.formatted()))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            ForEach(Array(presentation.result.artifacts.enumerated()), id: \.offset) { _, artifact in
                Text("\(URL(fileURLWithPath: artifact.path).lastPathComponent) · \(artifact.sizeBytes.formatted()) bytes · SHA-256 \(artifact.sha256)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.vertical, 5)
    }

    private func safeFilename(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || "/:".unicodeScalars.contains(scalar)
                ? "-" : Character(scalar)
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "flow-area" : result
    }
}
