import Charts
import SwiftUI

struct UnitCalculatorPresentation: Sendable {
    var fromUnitName = ""
    var fromUnits: [UnitCalculatorUnitChoice] = []
    var toUnits: [EditorChoice] = []
    var fromUnitID = ""
}

/// NumberBox's embedded UnitCalculatorButton keeps its source value linked to
/// the NumberBox and fixes the source unit supplied by FromSelectedUnit. This
/// native popover uses that same typed source unit, but keeps edits local until
/// the user explicitly applies a valid finite result.
@MainActor
struct OriginalUnitCalculatorButton: View {
    let title: String
    @Binding var rawValue: String
    let contextID: String
    let canCommit: @MainActor () -> Bool
    let fromUnitTypeID: String
    let storageUnitTypeID: String
    let isEditable: Bool
    var minimum: Double? = nil
    var maximum: Double? = nil
    var normalizeRawValue: ((Double) -> Double?)? = nil
    var invalidRawValueMessage = "The value does not meet the source field requirements."
    var onCommit: (@MainActor () -> Void)? = nil

    @State private var isPresented = false
    @State private var presentedContext: UnitCalculatorButtonContext?
    @StateObject private var lifecycle = UnitCalculatorPopoverLifecycle()
    @State private var provider = BackendUnitCalculatorProvider()

    private var canOpen: Bool {
        isEditable && canCommit() && !fromUnitTypeID.isEmpty && !storageUnitTypeID.isEmpty
            && UnitCalculatorNumberFormat.number(from: rawValue) != nil
    }

    var body: some View {
        Button {
            guard canOpen else { return }
            let presentationID = UUID()
            let ownerCanCommitAtOpen = canCommit
            lifecycle.activePresentationID = presentationID
            presentedContext = UnitCalculatorButtonContext(
                id: contextID,
                presentationID: presentationID,
                rawValue: rawValue,
                fromUnitTypeID: fromUnitTypeID,
                storageUnitTypeID: storageUnitTypeID,
                minimum: minimum,
                maximum: maximum,
                normalizeRawValue: normalizeRawValue,
                invalidRawValueMessage: invalidRawValueMessage,
                canCommit: {
                    lifecycle.activePresentationID == presentationID && ownerCanCommitAtOpen()
                },
                invalidateOwner: {
                    if lifecycle.activePresentationID == presentationID {
                        lifecycle.activePresentationID = nil
                    }
                },
                onApply: { rawValue = $0; onCommit?() }
            )
            isPresented = true
        } label: {
            Image(systemName: "function")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(LocalizedStringKey("Open Unit Calculator"))
        .help(L10n.text("Open Unit Calculator"))
        .disabled(!canOpen)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            if let presentedContext {
                ContextualUnitCalculatorPopover(
                    title: title,
                    context: presentedContext,
                    currentOwnerContextID: { contextID },
                    currentPresentationID: { lifecycle.activePresentationID },
                    currentCanCommit: canCommit,
                    provider: provider
                )
                .frame(width: 440)
            }
        }
        .onChange(of: contextID) { _, _ in closePopover() }
        .onChange(of: isEditable) { _, editable in if !editable { closePopover() } }
        .onChange(of: isPresented) { _, presented in
            if !presented { lifecycle.activePresentationID = nil }
        }
    }

    private func closePopover() {
        guard isPresented else { return }
        lifecycle.activePresentationID = nil
        isPresented = false
    }
}

@MainActor
private final class UnitCalculatorPopoverLifecycle: ObservableObject {
    @Published var activePresentationID: UUID?
}

@MainActor
private struct UnitCalculatorButtonContext {
    let id: String
    let presentationID: UUID
    let rawValue: String
    let fromUnitTypeID: String
    let storageUnitTypeID: String
    let minimum: Double?
    let maximum: Double?
    let normalizeRawValue: ((Double) -> Double?)?
    let invalidRawValueMessage: String
    let canCommit: @MainActor () -> Bool
    let invalidateOwner: @MainActor () -> Void
    let onApply: @MainActor (String) -> Void
}

struct UnitCalculatorCommitTicket: Equatable {
    let requestToken: UUID
    let ownerContextID: String
    let presentationID: UUID

    func isCurrent(requestToken: UUID, ownerContextID: String, presentationID: UUID?, ownerCanCommit: Bool) -> Bool {
        self.requestToken == requestToken && self.ownerContextID == ownerContextID
            && self.presentationID == presentationID && ownerCanCommit
    }
}

@MainActor
private struct ContextualUnitCalculatorPopover: View {
    let title: String
    let context: UnitCalculatorButtonContext
    let currentOwnerContextID: @MainActor () -> String
    let currentPresentationID: @MainActor () -> UUID?
    let currentCanCommit: @MainActor () -> Bool
    let provider: BackendUnitCalculatorProvider

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: UnitCalculatorPresentation?
    @State private var fromInput = ""
    @State private var toOutput = ""
    @State private var initialFromInput: String?
    @State private var targetUnitID = ""
    @State private var isLoading = true
    @State private var isConverting = false
    @State private var errorMessage: String?
    @State private var requestToken = UUID()

    private var originalRawValue: String { context.rawValue }
    private var fromUnitTypeID: String { context.fromUnitTypeID }
    private var storageUnitTypeID: String { context.storageUnitTypeID }
    private var minimum: Double? { context.minimum }
    private var maximum: Double? { context.maximum }
    private var normalizeRawValue: ((Double) -> Double?)? { context.normalizeRawValue }
    private var invalidRawValueMessage: String { context.invalidRawValueMessage }
    private var ownerCanCommit: @MainActor () -> Bool { { context.canCommit() && currentCanCommit() } }
    private var liveOwnerContextID: String { currentOwnerContextID() }
    private var liveOwnerCanCommit: Bool { ownerCanCommit() }

    private var parsedFromInput: Double? { UnitCalculatorNumberFormat.number(from: fromInput) }
    private var parsedToOutput: Double? { UnitCalculatorNumberFormat.number(from: toOutput) }
    private var fromInputMatchesInitial: Bool {
        guard let current = parsedFromInput,
              let initial = initialFromInput.flatMap({ UnitCalculatorNumberFormat.number(from: $0) }) else { return false }
        return current == initial
    }
    private var canApply: Bool {
        guard ownerCanCommit(), !isLoading, !isConverting, let value = parsedFromInput else { return false }
        return value.isFinite && !fromInputMatchesInitial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey("Unit Calculator")).font(.headline)
            Text(LocalizedStringKey(title)).font(.subheadline).foregroundStyle(.secondary)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 92)
            } else if let catalog {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        UnitCalculatorNumberField(title: "From Value", value: fromBinding, isEditable: true) { value in
                            editFrom(value)
                        }
                        Text(verbatim: catalog.fromUnitName.isEmpty ? "—" : catalog.fromUnitName)
                            .textSelection(.enabled)
                    }
                    Text("=").font(.title2).frame(maxWidth: .infinity)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        UnitCalculatorNumberField(title: "To Value", value: toBinding, isEditable: true) { value in
                            editTo(value)
                        }
                        Picker("To Unit", selection: targetBinding) {
                            Text("Choose a unit").tag("")
                            ForEach(catalog.toUnits) { unit in Text(verbatim: unit.title).tag(unit.id) }
                        }
                        .frame(minWidth: 130)
                        .disabled(catalog.toUnits.isEmpty)
                    }
                }
            }

            if isConverting { ProgressView().controlSize(.small) }
            if let errorMessage {
                Text(verbatim: errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancelAndDismiss() }
                Button("Use Value") {
                    if let ticket = beginApply() { Task { await applyValue(ticket) } }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(16)
        .task { await load() }
        .onDisappear { invalidatePendingRequests() }
        .onChange(of: liveOwnerContextID) { _, _ in cancelAndDismiss() }
        .onChange(of: liveOwnerCanCommit) { _, canCommit in if !canCommit { cancelAndDismiss() } }
    }

    private var fromBinding: Binding<String> {
        Binding(get: { fromInput }, set: { fromInput = $0 })
    }
    private var toBinding: Binding<String> {
        Binding(get: { toOutput }, set: { toOutput = $0 })
    }
    private var targetBinding: Binding<String> {
        Binding(get: { targetUnitID }, set: { value in
            guard targetUnitID != value else { return }
            targetUnitID = value
            requestToken = UUID()
            isConverting = false
            guard !value.isEmpty else { return }
            Task { await reverseFromTarget(value) }
        })
    }

    private func load() async {
        let ticket = UnitCalculatorCommitTicket(requestToken: requestToken, ownerContextID: context.id, presentationID: context.presentationID)
        guard ownerCanCommit() else { cancelAndDismiss(); return }
        guard let raw = UnitCalculatorNumberFormat.number(from: originalRawValue), raw.isFinite else {
            isLoading = false
            errorMessage = L10n.text("Enter a finite number.")
            return
        }
        do {
            let loaded = try await provider.loadUnits(fromUnitID: fromUnitTypeID, toUnitID: storageUnitTypeID)
            guard isCurrent(ticket) else { return }
            guard loaded.fromUnitID == fromUnitTypeID,
                  loaded.toUnits.contains(where: { $0.id == storageUnitTypeID }) else {
                throw DataToolError.unavailable
            }
            let displayed = try await provider.convert(
                value: raw,
                fromUnitID: storageUnitTypeID,
                toUnitID: fromUnitTypeID
            )
            guard isCurrent(ticket) else { return }
            try Task.checkCancellation()
            catalog = loaded
            fromInput = String(displayed)
            initialFromInput = fromInput
            toOutput = originalRawValue
            targetUnitID = storageUnitTypeID
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(ticket) else { return }
            isLoading = false
            errorMessage = L10n.text("Conversion is unavailable for this unit.")
        }
    }

    private func editFrom(_ value: String) {
        fromInput = value
        errorMessage = nil
        let token = UUID()
        requestToken = token
        let ticket = UnitCalculatorCommitTicket(requestToken: token, ownerContextID: context.id, presentationID: context.presentationID)
        isConverting = false
        guard let parsed = UnitCalculatorNumberFormat.number(from: value), parsed.isFinite,
              !targetUnitID.isEmpty else { return }
        isConverting = true
        Task {
            do {
                let converted = try await provider.convert(
                    value: parsed,
                    fromUnitID: fromUnitTypeID,
                    toUnitID: targetUnitID
                )
                guard isCurrent(ticket) else { return }
                toOutput = String(converted)
                isConverting = false
            } catch is CancellationError {
                guard isCurrent(ticket) else { return }
                isConverting = false
            } catch {
                guard isCurrent(ticket) else { return }
                isConverting = false
                errorMessage = L10n.text("Conversion is unavailable for this unit.")
            }
        }
    }

    private func editTo(_ value: String) {
        toOutput = value
        errorMessage = nil
        let token = UUID()
        requestToken = token
        let ticket = UnitCalculatorCommitTicket(requestToken: token, ownerContextID: context.id, presentationID: context.presentationID)
        isConverting = false
        guard let parsed = UnitCalculatorNumberFormat.number(from: value), parsed.isFinite,
              !targetUnitID.isEmpty else { return }
        isConverting = true
        Task {
            do {
                let converted = try await provider.convert(
                    value: parsed,
                    fromUnitID: fromUnitTypeID,
                    toUnitID: targetUnitID,
                    direction: .toFrom
                )
                guard isCurrent(ticket) else { return }
                fromInput = String(converted)
                isConverting = false
            } catch is CancellationError {
                guard isCurrent(ticket) else { return }
                isConverting = false
            } catch {
                guard isCurrent(ticket) else { return }
                isConverting = false
                errorMessage = L10n.text("Conversion is unavailable for this unit.")
            }
        }
    }

    private func reverseFromTarget(_ unitID: String) async {
        let token = UUID()
        requestToken = token
        let ticket = UnitCalculatorCommitTicket(requestToken: token, ownerContextID: context.id, presentationID: context.presentationID)
        guard ownerCanCommit() else { cancelAndDismiss(); return }
        guard let value = parsedToOutput, value.isFinite else { return }
        isConverting = true
        errorMessage = nil
        do {
            let converted = try await provider.convert(
                value: value,
                fromUnitID: fromUnitTypeID,
                toUnitID: unitID,
                direction: .toFrom
            )
            guard isCurrent(ticket) else { return }
            fromInput = String(converted)
            isConverting = false
        } catch is CancellationError {
            guard isCurrent(ticket) else { return }
            isConverting = false
        } catch {
            guard isCurrent(ticket) else { return }
            isConverting = false
            errorMessage = L10n.text("Conversion is unavailable for this unit.")
        }
    }

    private func beginApply() -> UnitCalculatorCommitTicket? {
        guard ownerCanCommit() else { cancelAndDismiss(); return nil }
        guard !isLoading, !isConverting,
              let displayed = parsedFromInput, displayed.isFinite else { return nil }
        if fromInputMatchesInitial {
            cancelAndDismiss()
            return nil
        }
        let token = UUID()
        requestToken = token
        isConverting = true
        errorMessage = nil
        return UnitCalculatorCommitTicket(requestToken: token, ownerContextID: context.id, presentationID: context.presentationID)
    }

    private func applyValue(_ ticket: UnitCalculatorCommitTicket) async {
        guard isCurrent(ticket), let displayed = parsedFromInput, displayed.isFinite else { return }
        isConverting = true
        errorMessage = nil
        do {
            let raw = try await provider.convert(
                value: displayed,
                fromUnitID: fromUnitTypeID,
                toUnitID: storageUnitTypeID
            )
            guard isCurrent(ticket) else { return }
            guard raw.isFinite else { throw DataToolError.unavailable }
            let normalizedRaw: Double
            if let normalizeRawValue {
                guard let normalized = normalizeRawValue(raw) else {
                    errorMessage = invalidRawValueMessage
                    isConverting = false
                    return
                }
                normalizedRaw = normalized
            } else {
                normalizedRaw = raw
            }
            if let minimum, normalizedRaw < minimum {
                errorMessage = L10n.format("Enter a value greater than or equal to %@.", minimum.formatted())
                isConverting = false
                return
            }
            if let maximum, normalizedRaw > maximum {
                errorMessage = L10n.format("Enter a value less than or equal to %@.", maximum.formatted())
                isConverting = false
                return
            }
            guard isCurrent(ticket) else { return }
            context.onApply(String(normalizedRaw))
            isConverting = false
            dismiss()
        } catch is CancellationError {
            guard isCurrent(ticket) else { return }
            isConverting = false
        } catch {
            guard isCurrent(ticket) else { return }
            isConverting = false
            errorMessage = L10n.text("Conversion is unavailable for this unit.")
        }
    }

    private func isCurrent(_ ticket: UnitCalculatorCommitTicket) -> Bool {
        let current = ticket.isCurrent(
            requestToken: requestToken,
            ownerContextID: liveOwnerContextID,
            presentationID: currentPresentationID(),
            ownerCanCommit: ownerCanCommit()
        )
        if !current && requestToken == ticket.requestToken { cancelAndDismiss() }
        return current
    }

    private func cancelAndDismiss() {
        invalidatePendingRequests()
        dismiss()
    }

    private func invalidatePendingRequests() {
        requestToken = UUID()
        isConverting = false
        context.invalidateOwner()
    }
}

struct WilcockCasePresentation: Identifiable, Sendable {
    let id: String
    let name: String
}
struct CalculationChart: Sendable {
    let title: String
    let xLabel: String
    let yLabel: String
    let samples: [ChartSample]
}
struct WilcockPresentation: Sendable {
    var cases: [WilcockCasePresentation] = []
    var selectedCaseID: String? = nil
    var canAddCases = false
    var removableCaseIDs: Set<String> = []
    var btmChart: CalculationChart? = nil
    var stabChart: CalculationChart? = nil
    var outputPlots: [EditorChoice] = []
}

struct UnitCalculatorContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    private var source: UnitCalculatorPresentation { state.presentation.unitCalculator ?? .init() }
    var body: some View {
        VStack(spacing: 18) {
            Picker("From Unit", selection: unit("FromSelectedUnit")) {
                Text("Choose a unit").tag("")
                ForEach(source.fromUnits) { unit in
                    Text(verbatim: unit.sourcePickerTitle).tag(unit.id)
                }
            }
            .frame(maxWidth: 360)
            .disabled(!editor.canEdit || source.fromUnits.isEmpty)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 18) {
                GridRow {
                    UnitCalculatorNumberField(title: "From Value", value: number("FromInput"), isEditable: editor.canEdit) { _ in
                        state.triggeringField = "UnitCalculator/FromInput"
                    }
                    Button { copy("FromInput") } label: { Image(systemName: "doc.on.clipboard") }.help("Copy Input")
                    Text(verbatim: source.fromUnitName.isEmpty ? "—" : source.fromUnitName).textSelection(.enabled)
                }
                GridRow { Text("=").font(.title2).gridCellColumns(3).frame(maxWidth: .infinity) }
                GridRow {
                    UnitCalculatorNumberField(title: "To Value", value: number("ToOutput"), isEditable: editor.canEdit) { _ in
                        state.triggeringField = "UnitCalculator/ToOutput"
                    }
                    Button { copy("ToOutput") } label: { Image(systemName: "doc.on.clipboard") }.help("Copy Output")
                    Picker("To Unit", selection: unit("ToSelectedUnit")) {
                        Text("Choose a unit").tag("")
                        ForEach(source.toUnits) { unit in
                            Text(verbatim: unit.title).tag(unit.id)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160)
                    .disabled(!editor.canEdit || source.fromUnitID.isEmpty || source.toUnits.isEmpty)
                }
            }
            if source.fromUnitID.isEmpty {
                Text("Choose a source unit before converting values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!editor.canEdit)
    }
    private func number(_ id: String) -> Binding<String> {
        let key = "UnitCalculator/" + id
        return Binding(get: { editor.fields[key] ?? "0" }, set: { editor.set(key, $0); state.triggeringField = key })
    }
    private func unit(_ id: String) -> Binding<String> {
        let key = "UnitCalculator/" + id
        let fallback = id == "FromSelectedUnit" ? source.fromUnitID : ""
        return Binding(get: { editor.fields[key] ?? fallback }, set: { editor.set(key, $0); state.triggeringField = key })
    }
    private func copy(_ id: String) { if let value = editor.fields["UnitCalculator/" + id], !value.isEmpty { store.system.copy(value) } }
}

// WilcockMainControl contains BTM and STAB tabs. SBTM/ISBTM are modes of the
// merged BTM surface, rather than four simultaneous generic property forms.
struct WilcockContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let perform: @MainActor (DataToolOperation, String?) -> Void
    @State private var tab = "BTM"
    private var inverse: Bool { editor.fields["WilcockBTMControl/MergedBTM_IsISBTMMode"] == "true" }
    private var source: WilcockPresentation { state.presentation.wilcock ?? .init() }
    var body: some View {
        TabView(selection: $tab) {
            btm.tabItem { Text("BTM") }.tag("BTM")
            stab.tabItem { Text("STAB") }.tag("STAB")
        }.padding(12)
    }
    private var btm: some View {
        VSplitView {
            HSplitView {
                VStack(spacing: 0) {
                    Form {
                        Picker("BTM Mode", selection: Binding(get: { inverse }, set: { value in set("WilcockBTMControl/MergedBTM_IsISBTMMode", String(value)) })) {
                            Text("SBTM Mode").tag(false); Text("ISBTM Mode").tag(true)
                        }.pickerStyle(.segmented)
                        if inverse {
                            TextField("qT (m²/s)", text: text("WilcockBTMControl/MergedBTM_TotalTransportRate"))
                            LabeledContent("u* (m/s)", value: editor.fields["WilcockBTMControl/MergedBTM_ShearVelocity"] ?? "—")
                        } else {
                            TextField("u* (m/s)", text: text("WilcockBTMControl/MergedBTM_ShearVelocity"))
                            LabeledContent("qT (m²/s)", value: editor.fields["WilcockBTMControl/MergedBTM_TotalTransportRate"] ?? "—")
                        }
                    }.formStyle(.grouped).frame(height: 175).disabled(!editor.canEdit)
                    CalculationTableView(title: "Grain Size Distribution", tableID: "WilcockBTMControl/GrainSize", editor: editor, store: store)
                }.frame(minWidth: 360, idealWidth: 460)
                CalculationChartView(chart: source.btmChart).frame(minWidth: 300)
            }.frame(minHeight: 300)
            ScrollView {
                DisclosureGroup("Output Statistics") {
                    CalculationTableView(title: "Output Statistics", tableID: "WilcockBTMControl/Statistics", editor: editor, store: store).frame(height: 210)
                    if inverse { CalculationTableView(title: "Convergence Information", tableID: "WilcockBTMControl/Convergence", editor: editor, store: store).frame(height: 210) }
                }.padding(16)
            }.frame(minHeight: 100, idealHeight: 190)
        }
    }
    private var stab: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 16) {
                    Form {
                        Section("Inputs") {
                            ForEach(["BMin", "BMax", "Z", "Ns", "Nspec", "TcTauStarC", "TcM"], id: \.self) { name in
                                TextField(LocalizedStringKey(parameterLabel(name)), text: text("WilcockSTABControl/STAB_" + name))
                            }
                            Toggle("Threshold Slope", isOn: Binding(get: { editor.fields["WilcockSTABControl/STAB_UseThresholdSlope"] == "true" }, set: { value in set("WilcockSTABControl/STAB_UseThresholdSlope", String(value)) }))
                        }
                    }.formStyle(.grouped).frame(height: 405).disabled(!editor.canEdit)
                    HStack {
                        Button("Add Case") { perform(.addCase, nil) }.disabled(!source.canAddCases)
                        Button("Import Case From BTM") { perform(.importCase, nil) }.disabled(!source.canAddCases)
                        Button("Delete Selected Case", role: .destructive) { perform(.removeCase, state.selectedCalculatorCaseID) }.disabled(!source.removableCaseIDs.contains(state.selectedCalculatorCaseID ?? ""))
                    }.disabled(state.busy)
                    Picker("Case", selection: $state.selectedCalculatorCaseID) {
                        Text("None").tag(String?.none)
                        ForEach(source.cases) { value in Text(value.name).tag(Optional(value.id)) }
                    }.padding(.horizontal, 12)
                    CalculationTableView(title: "Cases", tableID: "WilcockSTABControl/Cases", editor: editor, store: store).frame(height: 150)
                    CalculationTableView(title: "Transport Grain Size", tableID: "WilcockSTABControl/TransportGrainSize", editor: editor, store: store).frame(height: 230)
                }.padding(8)
            }.frame(minWidth: 390, idealWidth: 470, maxWidth: 650)
            VSplitView {
                VStack {
                    HStack {
                        Button { changePlot(-1) } label: { Image(systemName: "chevron.left") }.help("Previous Plot")
                        Picker("Output Plot", selection: text("WilcockSTABControl/_currentOutputChartIndex")) {
                            if source.outputPlots.isEmpty { Text("None").tag("") }
                            ForEach(source.outputPlots) { plot in Text(plot.titleIsUserData == true ? plot.title : L10n.text(plot.title)).tag(plot.id) }
                        }
                        Button { changePlot(1) } label: { Image(systemName: "chevron.right") }.help("Next Plot")
                    }.padding(12).disabled(source.outputPlots.isEmpty)
                    CalculationChartView(chart: source.stabChart)
                }.frame(minHeight: 270)
                CalculationTableView(title: "Output Statistics", tableID: "WilcockSTABControl/Statistics", editor: editor, store: store).frame(minHeight: 180)
            }.frame(minWidth: 320)
        }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { editor.fields[key] ?? "" }, set: { set(key, $0) }) }
    private func set(_ key: String, _ value: String) { editor.set(key, value); state.triggeringField = key }
    private func parameterLabel(_ key: String) -> String {
        switch key { case "Z": "z"; case "Ns": "ns"; case "Nspec": "Specified n"; case "TcTauStarC": "τ*c"; case "TcM": "m"; default: key }
    }
    private func changePlot(_ delta: Int) {
        guard !source.outputPlots.isEmpty else { return }
        let index = source.outputPlots.firstIndex { $0.id == editor.fields["WilcockSTABControl/_currentOutputChartIndex"] } ?? 0
        set("WilcockSTABControl/_currentOutputChartIndex", source.outputPlots[(index + delta + source.outputPlots.count) % source.outputPlots.count].id)
    }
}

struct CalculationTableView: View {
    let title: String
    let tableID: String
    @ObservedObject var editor: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var columns: [SourceTableColumn] { editor.tablePresentations[tableID]?.columns ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.headline).padding(.horizontal, 12)
            Table(editor.rows[tableID] ?? []) {
                TableColumnForEach(columns) { column in
                    TableColumn(column.titleIsUserData == true ? column.title : L10n.text(column.title)) { (row: EditorRow) in
                        TableCell(column: column, rowID: row.id, tableID: tableID, session: editor, store: store)
                    }.width(min: 60, ideal: column.width ?? 140)
                }
            }
        }
    }
}

struct CalculationChartView: View {
    let chart: CalculationChart?
    var body: some View {
        if let chart, chart.samples.contains(where: { $0.x.isFinite && $0.y.isFinite }) {
            VStack(alignment: .leading) {
                Text(L10n.text(chart.title)).font(.headline)
                Chart(chart.samples.filter { $0.x.isFinite && $0.y.isFinite }) { sample in
                    LineMark(x: .value(L10n.text(chart.xLabel), sample.x), y: .value(L10n.text(chart.yLabel), sample.y))
                        .foregroundStyle(by: .value("Series", L10n.text(sample.series)))
                }.chartXAxisLabel(L10n.text(chart.xLabel)).chartYAxisLabel(L10n.text(chart.yLabel))
            }.padding(20)
        } else { ContentUnavailableView("No calculation results", systemImage: "chart.xyaxis.line") }
    }
}
