import CryptoKit
import SwiftUI

/// Read-only Result output-block profile browser. The parent inspector supplies
/// the canonical result identity returned by its source-backed inspection.
struct ResultProfilePanel: View {
    let identity: ResultProfileIdentity?
    let projectPath: String?
    let projectXML: String?
    let projectContextID: String
    @ObservedObject var session: ResultProfileSession
    @State private var outputBlockName = ""
    @State private var variableID = ""
    @State private var flowAreaIndex = 0
    @State private var elementIndexText = "0"
    @State private var displayMode = "Chart"

    private var catalog: ResultProfileCatalog? { session.catalog }
    private var outputBlocks: [ResultProfileOutputBlock] { catalog?.outputBlocks ?? [] }
    private var selectedBlock: ResultProfileOutputBlock? { outputBlocks.first { $0.name == outputBlockName } }
    private var variables: [ResultProfileVariable] { selectedBlock?.variables ?? [] }
    private var selectedVariable: ResultProfileVariable? { variables.first { $0.id == variableID } }
    private var flowAreas: [ResultProfileFlowArea] { catalog?.flowAreas ?? [] }
    private var selectedFlowArea: ResultProfileFlowArea? { flowAreas.first { $0.index == flowAreaIndex } }
    private var elementCount: Int { selectedVariable.flatMap { selectedFlowArea?.elementCount(for: $0.elementKind) } ?? 0 }
    private var elementIndex: Int? { Int(elementIndexText) }
    private var canReadSelection: Bool {
        identity != nil && (selectedBlock?.profileCount ?? 0) > 0 && selectedVariable != nil
            && selectedFlowArea != nil && elementIndex.map { $0 >= 0 && $0 < elementCount } == true
            && !session.isLoadingCatalog && !session.isLoadingSeries
    }
    private var displayedSeries: ResultProfileSeries? { session.series }
    private var displayedVariableName: String { displayedSeries?.variable ?? selectedVariable?.name ?? L10n.text("Value") }
    private var displayedUnits: String { displayedSeries?.units ?? selectedVariable?.units ?? "" }
    private var displayedValueTitle: String {
        displayedUnits.isEmpty ? displayedVariableName : L10n.format("%@ (%@)", displayedVariableName, displayedUnits)
    }
    private var loadTaskID: String {
        let xmlHash = SHA256.hash(data: Data((projectXML ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
        return [identity?.resultPath ?? "", identity?.revision ?? "", projectPath ?? "", projectContextID, xmlHash]
            .joined(separator: "\u{1f}")
    }
    private var chartPresentation: SeriesEditorPresentation {
        let datasetID = ResultProfileChartData.datasetID
        let chart = SeriesChartPresentation(
            title: displayedSeries?.resultName ?? catalog?.resultName ?? L10n.text("Result Profile"),
            axes: [
                .init(id: "time", direction: .x, title: L10n.text("Time"), isDate: true),
                .init(id: "value", direction: .y, title: displayedValueTitle, titleIsUserData: true)
            ],
            datasets: [.init(id: datasetID, name: displayedValueTitle,
                xAxisID: "time", yAxisID: "value", colorRGBA: "FF3478C8")]
        )
        return SeriesEditorPresentation(xTitle: L10n.text("Time"), yTitle: displayedValueTitle, xIsDate: true, chart: chart)
    }
    private var chartSamples: [ChartSample] {
        guard let displayedSeries else { return [] }
        return ResultProfileChartData.samples(for: displayedSeries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            if selectedVariable != nil, selectedFlowArea != nil {
                ResultProfileMeshPicker(session: session, flowAreaIndex: flowAreaIndex,
                    elementKind: selectedVariable?.elementKind,
                    selectedElementIndex: elementIndex,
                    selectElement: { index in
                        elementIndexText = String(index)
                        syncSelection()
                        Task { await session.readSelectedSeries() }
                    })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if session.isLoadingCatalog {
                ProgressView(L10n.text("Loading stored result profiles…")).frame(maxWidth: .infinity, minHeight: 90)
            } else if outputBlocks.isEmpty || !hasSelectableElements {
                Label(L10n.text(noProfileMessage), systemImage: "chart.xyaxis.line")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
            if displayMode == "Chart" {
                SeriesChartView(samples: chartSamples, presentation: chartPresentation,
                    emptyMessage: "Select a stored output element to view its values.")
                    .frame(minHeight: 300)
            } else {
                valuesTable
            }
            ResultProfileSampleLinePanel(session: session)
            if session.isLoadingSeries { ProgressView().controlSize(.small).padding(.bottom, 8) }
            else if let reason = displayedSeries?.unavailableReason {
                Text(L10n.text(reason)).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .task(id: loadTaskID) {
            guard let identity else { session.clear(); return }
            outputBlockName = ""
            variableID = ""
            flowAreaIndex = 0
            elementIndexText = "0"
            await session.load(identity)
            await session.loadSampleSources(projectPath: projectPath, projectXml: projectXML,
                contextID: projectContextID + ":" + loadTaskID)
            if let selection = session.selection {
                outputBlockName = selection.outputBlockName
                variableID = selection.variableID
                flowAreaIndex = selection.flowAreaIndex
                elementIndexText = String(selection.elementIndex)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(catalog?.resultName ?? L10n.text("Result Profiles")).font(.headline).textSelection(.enabled)
                Text(profileCountDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L10n.text("Display"), selection: $displayMode) {
                Text(L10n.text("Chart")).tag("Chart")
                Text(L10n.text("Table")).tag("Table")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            Button {
                guard let identity else { return }
                Task {
                    await session.load(identity, force: true)
                    await session.loadSampleSources(projectPath: projectPath, projectXml: projectXML,
                        contextID: projectContextID + ":" + loadTaskID)
                    installSelection(session.selection)
                }
            } label: {
                Label(L10n.text("Reload"), systemImage: "arrow.clockwise")
            }
            .disabled(identity == nil || session.isLoadingCatalog || session.isLoadingSeries)
        }
        .padding(12)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker(L10n.text("Output Block"), selection: Binding(get: { outputBlockName }, set: { name in
                outputBlockName = name
                let block = outputBlocks.first { $0.name == name }
                let variable = block?.variables.first
                variableID = variable?.id ?? ""
                if let variable, let area = flowAreas.first(where: { ($0.elementCount(for: variable.elementKind) ?? 0) > 0 }) {
                    flowAreaIndex = area.index
                }
                elementIndexText = "0"
                syncSelection()
            })) {
                if outputBlocks.isEmpty { Text(L10n.text("No Stored Output Blocks")).tag("") }
                ForEach(outputBlocks) { block in
                    Text(L10n.format("%@ (%d)", block.name, block.profileCount)).tag(block.name)
                }
            }
            .frame(maxWidth: 240)
            .disabled(outputBlocks.isEmpty || session.isLoadingCatalog)

            Picker(L10n.text("Variable"), selection: Binding(get: { variableID }, set: { variableID = $0; syncSelection() })) {
                if variables.isEmpty { Text(L10n.text("No Variables")).tag("") }
                ForEach(variables) { variable in Text(variable.name).tag(variable.id) }
            }
            .frame(maxWidth: 190)
            .disabled(variables.isEmpty || session.isLoadingSeries)

            Picker(L10n.text("Flow Area"), selection: Binding(get: { flowAreaIndex }, set: { flowAreaIndex = $0; syncSelection() })) {
                if flowAreas.isEmpty { Text(L10n.text("No Flow Areas")).tag(-1) }
                ForEach(flowAreas) { area in
                    Text(L10n.format("%@ (%d cells / %d faces)", area.name, area.cellCount, area.faceCount)).tag(area.index)
                }
            }
            .frame(maxWidth: 320)
            .disabled(flowAreas.isEmpty || session.isLoadingSeries)

            TextField(L10n.text("Element index"), text: Binding(get: { elementIndexText }, set: { elementIndexText = $0; syncSelection() }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 112)
                .help(elementCount > 0
                    ? L10n.format("Zero-based %@ index (0…%d)", selectedVariable?.elementKind.lowercased() ?? L10n.text("mesh element"), elementCount - 1)
                    : L10n.text("No source mesh elements are available."))
                .disabled(elementCount == 0 || session.isLoadingSeries)

            Button {
                Task { await session.readSelectedSeries() }
            } label: { Label(L10n.text("Plot"), systemImage: "chart.xyaxis.line") }
                .disabled(!canReadSelection)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35))
    }

    private var valuesTable: some View {
        let points = displayedSeries?.available == true ? displayedSeries?.points ?? [] : []
        return Table(points) {
            TableColumn(L10n.text("Profile")) { point in Text(point.profileName).textSelection(.enabled) }
            TableColumn(L10n.text("Time")) { point in Text(point.time).textSelection(.enabled) }
            TableColumn(displayedValueTitle) { point in
                Text(point.value.map { $0.formatted() } ?? "—")
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .overlay {
            if points.isEmpty {
                Label(L10n.text(displayedSeries?.unavailableReason ?? "Select a stored output element to view its values."), systemImage: "tablecells")
                    .font(.callout).foregroundStyle(.secondary).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minHeight: 220)
        .padding(12)
    }

    private var noProfileMessage: String {
        guard identity != nil else { return "Choose a result to inspect its stored profiles." }
        if outputBlocks.isEmpty { return "This result has no stored output-block profiles." }
        if flowAreas.isEmpty { return "This result has no embedded 2D flow area mesh for element time series." }
        return "This result has no selectable mesh elements for its stored profiles."
    }

    private var hasSelectableElements: Bool {
        guard !flowAreas.isEmpty else { return false }
        return outputBlocks.contains { block in
            block.profileCount > 0 && block.variables.contains { variable in
                flowAreas.contains { ($0.elementCount(for: variable.elementKind) ?? 0) > 0 }
            }
        }
    }

    private var profileCountDescription: String {
        let total = outputBlocks.reduce(0) { $0 + $1.profileCount }
        return L10n.format("%d output blocks • %d stored profiles", outputBlocks.count, total)
    }

    private func syncSelection() {
        guard let block = selectedBlock, let variable = selectedVariable,
              let index = elementIndex else {
            session.select(nil)
            return
        }
        session.select(ResultProfileSelection(outputBlockName: block.name, variableID: variable.id,
            flowAreaIndex: flowAreaIndex, elementIndex: index))
    }

    private func installSelection(_ selection: ResultProfileSelection?) {
        guard let selection else { return }
        outputBlockName = selection.outputBlockName
        variableID = selection.variableID
        flowAreaIndex = selection.flowAreaIndex
        elementIndexText = String(selection.elementIndex)
    }
}
