import Charts
import SwiftUI

struct WilcockWorkspace: View {
    @ObservedObject var store: WorkspaceStore
    var onClose: (() -> Void)? = nil

    init(store: WorkspaceStore, onClose: (() -> Void)? = nil) {
        self.store = store
        self.onClose = onClose
    }

    var body: some View {
        if let provider = store.wilcockProvider {
            WilcockSessionWorkspace(provider: provider, onClose: onClose)
        } else {
            ContentUnavailableView(
                L10n.text("Wilcock is unavailable"),
                systemImage: "chart.xyaxis.line",
                description: Text(L10n.text("Wilcock calculations are not available right now."))
            )
            .frame(minWidth: 840, minHeight: 560)
        }
    }
}

private struct WilcockSessionWorkspace: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: WilcockSession
    @State private var page: WilcockCalculatorSection = .btm
    @State private var isConfirmingCaseImport = false
    @State private var caseImportConfirmationDraft: WilcockDraft?
    @State private var importConfirmationPolicy: WilcockBTMImportPolicy?

    private let onClose: (() -> Void)?

    init(provider: any WilcockProvider, onClose: (() -> Void)?) {
        _session = StateObject(wrappedValue: WilcockSession(provider: provider))
        self.onClose = onClose
    }

    private var snapshot: WilcockWorkspaceSnapshot? { session.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            header

            if session.isStale, snapshot != nil {
                Label(L10n.text("Inputs changed. Calculate to update results."), systemImage: "arrow.clockwise.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.quaternary.opacity(0.55))
            }

            if let issueKey = session.inputIssueKey, !issueKey.isEmpty {
                Label(L10n.text(issueKey), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary)
            }

            if let errorMessage = session.errorMessage, !errorMessage.isEmpty, snapshot != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.text(errorMessage))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("Retry")) { retry() }
                        .disabled(session.isBusy)
                }
                .padding(12)
                .background(.quaternary)
            }

            if session.isLoading && snapshot == nil {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text(L10n.text("Loading Wilcock data"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                pagePicker
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                switch page {
                case .btm:
                    btmPage(snapshot)
                case .stab:
                    stabPage(snapshot)
                case .state:
                    statePage(snapshot)
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Wilcock data is unavailable"), systemImage: "chart.xyaxis.line")
                } description: {
                    Text(L10n.text("Load Wilcock data to view its inputs and results."))
                } actions: {
                    Button(L10n.text("Retry")) { retry() }
                        .disabled(session.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .task {
            if session.snapshot == nil { _ = await session.load() }
        }
        .onDisappear { session.invalidate() }
        .confirmationDialog(
            L10n.text(importConfirmationPolicy == .append ? "Import Case" : "Replace existing cases?"),
            isPresented: $isConfirmingCaseImport,
            titleVisibility: .visible
        ) {
            Button(L10n.text(importConfirmationPolicy == .append ? "Import" : "Replace Cases"),
                   role: importConfirmationPolicy == .append ? .none : .destructive) {
                confirmCaseImport()
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                caseImportConfirmationDraft = nil
                importConfirmationPolicy = nil
            }
        } message: {
            Text(L10n.text(importConfirmationPolicy == .append
                ? "Import transport case from BTM as a new case?"
                : "Importing this case will replace the existing STAB cases."))
        }
        .onChange(of: session.draft) { _, newDraft in
            guard let caseImportConfirmationDraft, caseImportConfirmationDraft != newDraft else { return }
            self.caseImportConfirmationDraft = nil
            importConfirmationPolicy = nil
            isConfirmingCaseImport = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(L10n.text("Wilcock Sediment Calculator"), systemImage: "chart.xyaxis.line")
                .font(.title3.weight(.semibold))
            Spacer()
            if session.isCalculating {
                ProgressView().controlSize(.small)
                Text(L10n.text("Calculating"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { _ = await session.calculate() }
            } label: {
                Label(L10n.text("Calculate"), systemImage: "arrow.clockwise")
            }
            .disabled(snapshot == nil || session.isBusy)

            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Label(L10n.text("Close"), systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var pagePicker: some View {
        Picker(L10n.text("Calculation"), selection: $page) {
            Text(L10n.text("BTM")).tag(WilcockCalculatorSection.btm)
            Text(L10n.text("STAB")).tag(WilcockCalculatorSection.stab)
            Text(L10n.text("STATE")).tag(WilcockCalculatorSection.state)
        }
        .pickerStyle(.segmented)
        .disabled(session.isBusy)
    }

    private func btmPage(_ snapshot: WilcockWorkspaceSnapshot) -> some View {
        let activeInputID = session.draft.btmMode == .sbtm ? "btm.sbtm.input" : "btm.isbtm.input"
        let inputTables = tables(in: snapshot, section: .btm, role: .input)
            .filter { $0.id == activeInputID }
        let outputTables = tables(in: snapshot, section: .btm, role: .output)

        return VSplitView {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionStatus(snapshot, section: .btm)

                        Form {
                            Picker(L10n.text("BTM Mode"), selection: Binding(
                                get: { session.draft.btmMode },
                                set: { value in updateDraft { $0.btmMode = value } }
                            )) {
                                Text(L10n.text("SBTM Mode")).tag(WilcockBTMMode.sbtm)
                                Text(L10n.text("ISBTM Mode")).tag(WilcockBTMMode.isbtm)
                            }
                            .pickerStyle(.segmented)

                            if session.draft.btmMode == .sbtm {
                                scalarField("Shear Velocity", get: { session.draft.sbtm.shearVelocity }) { value in
                                    updateDraft { $0.sbtm.shearVelocity = value }
                                }
                                scalarField("Water Density", get: { session.draft.sbtm.waterDensity }) { value in
                                    updateDraft { $0.sbtm.waterDensity = value }
                                }
                                scalarField("Sediment Density", get: { session.draft.sbtm.sedimentDensity }) { value in
                                    updateDraft { $0.sbtm.sedimentDensity = value }
                                }
                            } else {
                                scalarField("Total Transport Rate", get: { session.draft.isbtm.totalTransportRate }) { value in
                                    updateDraft { $0.isbtm.totalTransportRate = value }
                                }
                            }
                        }
                        .formStyle(.grouped)
                        .disabled(session.isBusy)

                        ForEach(inputTables) { table in
                            WilcockTablePanel(table: table, session: session)
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 390, idealWidth: 470, maxWidth: 570)

                VStack(spacing: 0) {
                    chart(snapshot.charts.first { $0.section == .btm }, isStale: session.isStale)
                    if session.isStale {
                        staleResultsNotice
                    }
                }
                .frame(minWidth: 360, idealWidth: 540)
            }
            .frame(minHeight: 330)

            resultTables(outputTables, section: .btm, snapshot: snapshot, isStale: session.isStale)
                .frame(minHeight: 140, idealHeight: 240)
        }
    }

    private func stabPage(_ snapshot: WilcockWorkspaceSnapshot) -> some View {
        let inputTables = tables(in: snapshot, section: .stab, role: .input)
        let outputTables = tables(in: snapshot, section: .stab, role: .output)
        let plots = snapshot.charts.filter { $0.section == .stab }

        return HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionStatus(snapshot, section: .stab)

                    Form {
                        Section(L10n.text("Inputs")) {
                            scalarField("B Min", get: { session.draft.stab.bMin }) { value in updateDraft { $0.stab.bMin = value } }
                            scalarField("B Max", get: { session.draft.stab.bMax }) { value in updateDraft { $0.stab.bMax = value } }
                            scalarField("Side Slope Z", get: { session.draft.stab.z }) { value in updateDraft { $0.stab.z = value } }
                            scalarField("Side Slope Roughness", get: { session.draft.stab.ns }) { value in updateDraft { $0.stab.ns = value } }
                            scalarField("Specify n", get: { session.draft.stab.nSpec }) { value in updateDraft { $0.stab.nSpec = value } }
                            Toggle(L10n.text("Threshold Slope"), isOn: Binding(
                                get: { session.draft.stab.useThresholdSlope },
                                set: { value in updateDraft { $0.stab.useThresholdSlope = value } }
                            ))
                            if session.draft.stab.useThresholdSlope {
                                scalarField("Threshold Slope Tau Star C", get: { session.draft.stab.tcTauStarC }) { value in updateDraft { $0.stab.tcTauStarC = value } }
                                scalarField("Threshold Slope D50", get: { session.draft.stab.tcD50 }) { value in updateDraft { $0.stab.tcD50 = value } }
                                scalarField("Threshold Slope D84", get: { session.draft.stab.tcD84 }) { value in updateDraft { $0.stab.tcD84 = value } }
                                scalarField("Threshold Slope M", get: { session.draft.stab.tcM }) { value in updateDraft { $0.stab.tcM = value } }
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .disabled(session.isBusy)

                    caseControls(snapshot)

                    ForEach(inputTables) { table in
                        WilcockTablePanel(table: table, session: session)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 420, idealWidth: 500, maxWidth: 630)

            VSplitView {
                VStack(spacing: 0) {
                    plotPicker(plots)
                        .padding(10)
                    chart(selectedChart(plots), isStale: session.isStale)
                    if session.isStale {
                        staleResultsNotice
                    }
                }
                .frame(minHeight: 300)
                resultTables(outputTables, section: .stab, snapshot: snapshot, isStale: session.isStale)
                    .frame(minHeight: 180)
            }
            .frame(minWidth: 380)
        }
    }

    private func statePage(_ snapshot: WilcockWorkspaceSnapshot) -> some View {
        let inputTables = tables(in: snapshot, section: .state, role: .input)
        let outputTables = tables(in: snapshot, section: .state, role: .output)

        return VSplitView {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionStatus(snapshot, section: .state)
                        ForEach(inputTables) { table in
                            WilcockTablePanel(table: table, session: session)
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 390, idealWidth: 500, maxWidth: 600)

                VStack(spacing: 0) {
                    chart(snapshot.charts.first { $0.section == .state }, isStale: session.isStale)
                    if session.isStale {
                        staleResultsNotice
                    }
                }
                .frame(minWidth: 360, idealWidth: 560)
            }
            .frame(minHeight: 320)

            resultTables(outputTables, section: .state, snapshot: snapshot, isStale: session.isStale)
                .frame(minHeight: 160, idealHeight: 260)
        }
    }

    private func caseControls(_ snapshot: WilcockWorkspaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task { _ = await session.addCase() }
                } label: {
                    Label(L10n.text("Add Case"), systemImage: "plus")
                }
                .disabled(!snapshot.canAddCase || session.isBusy)

                Button {
                    requestCaseImport()
                } label: {
                    Label(L10n.text("Import Case From BTM"), systemImage: "square.and.arrow.down")
                }
                .disabled((!snapshot.canImportCase && !session.isStale)
                    || (snapshot.btmImportPolicy == .unavailable && !session.isStale)
                    || session.isBusy)

                Button(L10n.text("Delete Selected Case"), systemImage: "trash", role: .destructive) {
                    guard let caseID = session.selectedCaseID else { return }
                    Task { _ = await session.deleteCase(id: caseID) }
                }
                .disabled(!snapshot.canRemoveSelectedCase || session.selectedCaseID == nil
                    || session.isBusy)
            }

            if !session.isStale,
               snapshot.btmImportPolicy == .unavailable,
               let reason = snapshot.btmImportReasonKey,
               !reason.isEmpty {
                Label(L10n.text(reason), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(L10n.text("Case"), selection: Binding(
                get: { session.selectedCaseID },
                set: { session.selectCase(id: $0) }
            )) {
                Text(L10n.text("Select a Case")).tag(String?.none)
                ForEach(session.caseChoices) { choice in
                    Text(L10n.format("Case %d", choice.sourceIndex + 1)).tag(Optional(choice.id))
                }
            }
            .disabled(session.caseChoices.isEmpty || session.isBusy)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func plotPicker(_ charts: [WilcockSourceChart]) -> some View {
        Picker(L10n.text("Output Plot"), selection: Binding(
            get: { session.selectedPlotIndex },
            set: { session.selectPlot(index: $0) }
        )) {
            ForEach(Array(charts.enumerated()), id: \.element.id) { index, value in
                Text(L10n.text(value.titleKey)).tag(index)
            }
        }
        .disabled(charts.isEmpty || session.isBusy)
    }

    private func selectedChart(_ charts: [WilcockSourceChart]) -> WilcockSourceChart? {
        guard !charts.isEmpty else { return nil }
        return charts.indices.contains(session.selectedPlotIndex) ? charts[session.selectedPlotIndex] : charts.first
    }

    /// Null or non-finite source pairs break a line into separate segments so
    /// Charts never draws across a missing calculation sample.
    private func finiteSegments(for series: WilcockSourceSeries) -> [[(x: Double, y: Double)]] {
        var segments: [[(x: Double, y: Double)]] = []
        var current: [(x: Double, y: Double)] = []
        for point in series.points {
            guard let x = point.x, let y = point.y, x.isFinite, y.isFinite else {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
                continue
            }
            current.append((x, y))
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    @ViewBuilder
    private func chart(_ source: WilcockSourceChart?, isStale: Bool) -> some View {
        if let source, source.series.contains(where: { !finiteSegments(for: $0).isEmpty }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(source.titleKey))
                    .font(.headline)
                    .padding(.horizontal, 12)

                Chart {
                    ForEach(source.series) { series in
                        ForEach(Array(finiteSegments(for: series).enumerated()), id: \.offset) { segmentEntry in
                            ForEach(Array(segmentEntry.element.enumerated()), id: \.offset) { pointEntry in
                                let point = pointEntry.element
                                LineMark(
                                    x: .value(L10n.text(source.xAxisKey), point.x),
                                    y: .value(L10n.text(source.yAxisKey), point.y),
                                    series: .value(L10n.text("Series"), "\(series.id):\(segmentEntry.offset)")
                                )
                                .foregroundStyle(sourceColor(series.colorARGB))
                                .lineStyle(StrokeStyle(lineWidth: lineWidth(series.strokeWidth)))
                            }
                        }
                    }
                }
                .chartXAxisLabel(L10n.text(source.xAxisKey))
                .chartYAxisLabel(L10n.text(source.yAxisKey))
                .frame(minHeight: 210)

                if !source.series.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            ForEach(source.series) { series in
                                HStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(sourceColor(series.colorARGB))
                                        .frame(width: 18, height: 3)
                                    Text(seriesLabel(series))
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .opacity(isStale ? 0.46 : 1)
            .padding(8)
        } else {
            ContentUnavailableView(L10n.text("No calculation results"), systemImage: "chart.xyaxis.line")
                .opacity(isStale ? 0.46 : 1)
        }
    }

    private func resultTables(
        _ tables: [WilcockSourceTable],
        section: WilcockCalculatorSection,
        snapshot: WilcockWorkspaceSnapshot,
        isStale: Bool
    ) -> some View {
        let completeOutputID: String = {
            switch section {
            case .btm: return "btm.output"
            case .stab: return "stab.completeOutput"
            case .state: return "state.completeOutput"
            }
        }()
        let rawFallback = tables.contains(where: { $0.id == completeOutputID && !$0.rows.isEmpty })
            ? nil
            : rawResults(for: section, snapshot: snapshot)
        return Group {
            if tables.isEmpty && (rawFallback?.isEmpty ?? true) {
                ContentUnavailableView(L10n.text("No calculation results"), systemImage: "tablecells")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(tables) { table in
                            WilcockTablePanel(table: table, session: session)
                        }
                        if let rawFallback, !rawFallback.isEmpty {
                            WilcockRawResultDisclosure(values: rawFallback)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .opacity(isStale ? 0.46 : 1)
    }

    private func rawResults(
        for section: WilcockCalculatorSection,
        snapshot: WilcockWorkspaceSnapshot
    ) -> [String: WilcockJSONValue]? {
        switch section {
        case .btm:
            return snapshot.btmMode == .isbtm ? snapshot.isbtmResults : snapshot.sbtmResults
        case .stab:
            return snapshot.stabResults
        case .state:
            return snapshot.stateResults
        }
    }

    private var staleResultsNotice: some View {
        Label(L10n.text("Inputs changed. Calculate to update results."), systemImage: "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
    }

    @ViewBuilder
    private func sectionStatus(_ snapshot: WilcockWorkspaceSnapshot, section: WilcockCalculatorSection) -> some View {
        let errorKey: String? = {
            switch section {
            case .btm:
                return session.draft.btmMode == .sbtm ? snapshot.sbtmErrorKey : snapshot.isbtmErrorKey
            case .stab: return snapshot.stabErrorKey
            case .state: return snapshot.stateErrorKey
            }
        }()
        let issues = snapshot.inputIssues.filter { $0.section == section }

        if errorKey != nil || !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let errorKey {
                    Label(L10n.text(errorKey), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(issues) { issue in
                    Label(L10n.text(issue.messageKey), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tables(
        in snapshot: WilcockWorkspaceSnapshot,
        section: WilcockCalculatorSection,
        role: WilcockTableRole
    ) -> [WilcockSourceTable] {
        snapshot.tables.filter { $0.section == section && $0.role == role }
    }

    private func scalarField(
        _ titleKey: String,
        get: @escaping @MainActor @Sendable () -> String,
        set: @escaping @MainActor @Sendable (String) -> Void
    ) -> some View {
        TextField(L10n.text(titleKey), text: Binding(get: get, set: set))
            .textFieldStyle(.roundedBorder)
    }

    private func updateDraft(_ update: (inout WilcockDraft) -> Void) {
        var draft = session.draft
        update(&draft)
        session.editDraft(draft)
    }

    private func retry() {
        Task {
            if session.snapshot == nil {
                _ = await session.load()
            } else {
                _ = await session.calculate()
            }
        }
    }

    private func requestCaseImport() {
        guard !session.isBusy else { return }
        let submittedDraft = session.draft
        if session.importConfirmationRequired {
            guard let policy = session.snapshot?.btmImportPolicy, policy != .unavailable else { return }
            caseImportConfirmationDraft = submittedDraft
            importConfirmationPolicy = policy
            isConfirmingCaseImport = true
            return
        }
        Task {
            let accepted = await session.importCaseFromBTM(confirmImport: false)
            guard accepted,
                  session.importConfirmationRequired,
                  session.draft == submittedDraft,
                  !session.isStale else { return }
            guard let policy = session.snapshot?.btmImportPolicy, policy != .unavailable else { return }
            caseImportConfirmationDraft = submittedDraft
            importConfirmationPolicy = policy
            isConfirmingCaseImport = true
        }
    }

    private func confirmCaseImport() {
        guard let confirmedDraft = caseImportConfirmationDraft,
              confirmedDraft == session.draft,
              session.importConfirmationRequired,
              !session.isStale,
              importConfirmationPolicy == session.snapshot?.btmImportPolicy else {
            caseImportConfirmationDraft = nil
            importConfirmationPolicy = nil
            isConfirmingCaseImport = false
            return
        }
        caseImportConfirmationDraft = nil
        importConfirmationPolicy = nil
        Task { _ = await session.importCaseFromBTM(confirmImport: true) }
    }

    private func seriesLabel(_ series: WilcockSourceSeries) -> String {
        guard let caseIndex = series.caseIndex else { return L10n.text(series.labelKey) }
        return L10n.format("Case %d · %@", caseIndex + 1, L10n.text(series.labelKey))
    }

    private func sourceColor(_ raw: String) -> Color {
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
        guard let value = UInt64(digits, radix: 16) else { return .accentColor }
        if digits.count == 8 {
            let alpha = Double((value >> 24) & 0xFF) / 255
            let red = Double((value >> 16) & 0xFF) / 255
            let green = Double((value >> 8) & 0xFF) / 255
            let blue = Double(value & 0xFF) / 255
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        }
        if digits.count == 6 {
            let red = Double((value >> 16) & 0xFF) / 255
            let green = Double((value >> 8) & 0xFF) / 255
            let blue = Double(value & 0xFF) / 255
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }
        return .accentColor
    }

    private func lineWidth(_ value: Double) -> CGFloat {
        guard value.isFinite, value > 0 else { return 2 }
        return CGFloat(value)
    }
}

private struct WilcockRawResultDisclosure: View {
    let values: [String: WilcockJSONValue]

    var body: some View {
        DisclosureGroup(L10n.text("All calculation values")) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    WilcockRawResultNode(label: key, value: values[key] ?? .null)
                }
            }
            .padding(.top, 6)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }
}

private struct WilcockRawResultNode: View {
    let label: String
    let value: WilcockJSONValue

    var body: some View {
        switch value {
        case .object(let fields):
            DisclosureGroup {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(fields.keys.sorted(), id: \.self) { key in
                        WilcockRawResultNode(label: key, value: fields[key] ?? .null)
                    }
                }
                .padding(.top, 5)
            } label: {
                Text(verbatim: label)
            }
        case .array(let items):
            if items.allSatisfy({ $0.scalarText != nil }) {
                DisclosureGroup {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text(L10n.text("Row")).font(.caption.weight(.semibold))
                            Text(L10n.text("Value")).font(.caption.weight(.semibold))
                        }
                        ForEach(items.indices, id: \.self) { index in
                            GridRow {
                                Text(L10n.format("Row %d", index + 1))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: items[index].scalarText ?? "—")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    Text(verbatim: "\(label) (\(items.count))")
                }
            } else {
                DisclosureGroup {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(items.indices, id: \.self) { index in
                            WilcockRawResultNode(label: L10n.format("Row %d", index + 1), value: items[index])
                        }
                    }
                    .padding(.top, 5)
                } label: {
                    Text(verbatim: "\(label) (\(items.count))")
                }
            }
        default:
            LabeledContent {
                Text(verbatim: value.scalarText ?? "—")
                    .textSelection(.enabled)
            } label: {
                Text(verbatim: label)
            }
        }
    }
}

private extension WilcockJSONValue {
    var scalarText: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return "—"
        case .array, .object: return nil
        }
    }
}

private struct WilcockTablePanel: View {
    let table: WilcockSourceTable
    @ObservedObject var session: WilcockSession

    private var canResizeColumns: Bool {
        table.role == .input && table.id != "stab.caseInputs"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(table.titleKey))
                .font(.headline)
                .padding(.horizontal, 8)

            if canResizeColumns && !table.columns.filter(\.isEditable).isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        ForEach(table.columns.filter(\.isEditable)) { column in
                            HStack(spacing: 5) {
                                Text(L10n.text(column.titleKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    _ = session.appendInputRow(tableID: table.id, columnID: column.id)
                                } label: {
                                    Label(L10n.text("Add"), systemImage: "plus")
                                }
                                .labelStyle(.titleAndIcon)
                                .controlSize(.small)
                                .disabled(session.isBusy)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
            }

            if table.rows.isEmpty {
                ContentUnavailableView(L10n.text("No items"), systemImage: "tablecells")
                    .frame(minHeight: 70)
            } else if table.columns.isEmpty {
                Text(L10n.text("No table columns are available."))
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                Table(table.rows) {
                    TableColumn(L10n.text("Row")) { row in
                        Text(rowLabel(row))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 110)

                    TableColumnForEach(table.columns) { column in
                        TableColumn(L10n.text(column.titleKey)) { row in
                            cell(row: row, column: column)
                        }
                        .width(min: 90, ideal: 145)
                    }
                }
                .frame(minHeight: min(CGFloat(table.rows.count) * 30 + 34, 300))
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }

    private func rowLabel(_ row: WilcockSourceRow) -> String {
        if let titleKey = row.titleKey {
            return L10n.text(titleKey)
        }
        if row.id.hasPrefix("case:"), let index = Int(row.id.dropFirst("case:".count)) {
            return L10n.format("Case %d", index + 1)
        }
        if row.id.hasPrefix("grain:"), let index = Int(row.id.dropFirst("grain:".count)) {
            return L10n.format("Row %d", index + 1)
        }
        if row.id.hasPrefix("index:"), let index = Int(row.id.dropFirst("index:".count)) {
            return L10n.format("Row %d", index + 1)
        }
        if row.id.hasPrefix("value:"), let index = Int(row.id.dropFirst("value:".count)) {
            return L10n.format("Row %d", index + 1)
        }
        return L10n.text("Row")
    }

    @ViewBuilder
    private func cell(row: WilcockSourceRow, column: WilcockSourceColumn) -> some View {
        let columnIndex = table.columns.firstIndex(where: { $0.id == column.id }) ?? 0
        let value = row.cells.indices.contains(columnIndex) ? row.cells[columnIndex] : ""
        if table.role == .input && column.isEditable {
            HStack(spacing: 4) {
                TextField("", text: Binding(
                    get: {
                        let currentIndex = table.columns.firstIndex(where: { $0.id == column.id }) ?? 0
                        return row.cells.indices.contains(currentIndex) ? row.cells[currentIndex] : ""
                    },
                    set: { session.setCell(tableID: table.id, rowID: row.id, columnID: column.id, rawText: $0) }
                ))
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text(column.titleKey))
                .disabled(session.isBusy)

                if canResizeColumns {
                    Button(role: .destructive) {
                        _ = session.removeInputRow(tableID: table.id, rowID: row.id, columnID: column.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L10n.text("Remove"))
                    .accessibilityLabel(L10n.text("Remove"))
                    .disabled(session.isBusy)
                }
            }
        } else {
            Text(verbatim: value.isEmpty ? "—" : value)
                .textSelection(.enabled)
        }
    }
}
