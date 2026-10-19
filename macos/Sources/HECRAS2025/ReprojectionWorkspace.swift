import SwiftUI

@MainActor
struct ReprojectionWorkspace: View {
    @ObservedObject private var store: WorkspaceStore
    @StateObject private var session: ReprojectionSession
    @State private var searchTarget: SearchTarget?

    private struct SearchTarget: Identifiable {
        let side: ReprojectionSide
        var id: String { side.rawValue }
    }

    init(store: WorkspaceStore) {
        self.store = store
        _session = StateObject(wrappedValue: ReprojectionSession(provider: store.reprojectionProvider))
    }

    private var projectProjection: ProjectionDefinitionDraft? {
        guard let document = store.document, !document.projectionType.isEmpty else { return nil }
        let type = ProjectionDefinitionDraft.canonicalType(document.projectionType)
        let value = type == "Local" ? document.projectionValue.uppercased() : document.projectionValue
        return ProjectionDefinitionDraft(type: type, value: value)
    }

    private var contextIdentity: String {
        ReprojectionSession.contextIdentity(
            projectSessionID: store.projectSessionID,
            projectProjection: projectProjection
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Reprojection").font(.title2.weight(.semibold))
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                Button("Reproject") { Task { await session.transformNow() } }
                    .disabled(session.isBusy)
                    .keyboardShortcut(.defaultAction)
                Button("Close") {
                    session.close()
                    store.activeTool = nil
                }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if let error = session.identifyError {
                Text(L10n.text(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }
            if let error = session.errorMessage {
                Text(L10n.text(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }

            Divider()

            HSplitView {
                projectionColumn(side: .source)
                    .frame(minWidth: 340, idealWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    Image(systemName: "arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 44)
                projectionColumn(side: .destination)
                    .frame(minWidth: 340, idealWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: contextIdentity) {
            session.configure(
                projectSessionID: store.projectSessionID,
                projectProjection: projectProjection,
                contextIdentity: contextIdentity
            )
        }
        .sheet(item: $searchTarget) { target in
            ProjectionSearchView(provider: store.projectionProvider) { match in
                session.setOption(.custom, for: target.side)
                session.setCustomProjectionText(String(match.code), for: target.side)
                searchTarget = nil
            }
        }
        .onDisappear { session.close() }
    }

    @ViewBuilder
    private func projectionColumn(side: ReprojectionSide) -> some View {
        VStack(spacing: 0) {
            projectionDefinition(side: side)
                .frame(minHeight: 250, idealHeight: 300, maxHeight: 360)
            Divider()
            if side == .source {
                sourceTable
            } else {
                destinationTable
            }
        }
    }

    private func projectionDefinition(side: ReprojectionSide) -> some View {
        let optionBinding = Binding<ReprojectionOption>(
            get: { option(for: side) },
            set: { session.setOption($0, for: side) }
        )
        return Form {
            Section {
                Picker("Projection", selection: optionBinding) {
                    ForEach(ReprojectionOption.allCases) { option in
                        Text(L10n.text(option == .webMercator ? "Web Mercator" : option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.menu)

                if option(for: side) == .custom {
                    HStack {
                        Button("Find Coordinate System…") { searchTarget = SearchTarget(side: side) }
                            .disabled(store.projectionProvider == nil)
                        Button("Choose Projection Source") {
                            Task {
                                let files = store.system.chooseProjectionSourceFiles()
                                await session.identifyProjection(paths: files, for: side)
                            }
                        }
                    }

                    TextEditor(text: customProjectionBinding(for: side))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 54, maxHeight: 86)
                        .accessibilityLabel(Text("Projection Definition"))

                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                        Text("Drop projection source files here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if session.isIdentifyingProjection {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        let files = urls.filter(\.isFileURL)
                        guard !files.isEmpty else { return false }
                        Task { await session.identifyProjection(paths: files, for: side) }
                        return true
                    }
                }

                projectionSummary(for: side)
            } header: {
                Text(L10n.text(side == .source ? "Source Projection" : "Destination Projection"))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func projectionSummary(for side: ReprojectionSide) -> some View {
        let summary = side == .source ? session.sourceProjectionSummary : session.destinationProjectionSummary
        let fallbackName = side == .source ? session.sourceSummary : session.destinationSummary
        LabeledContent("Name", value: summary?.projectionName ?? localizedOptionOrRaw(fallbackName))
            .textSelection(.enabled)
        LabeledContent("Validity", value: localizedProjectionValidity(summary?.validity))
            .textSelection(.enabled)
        LabeledContent("Units", value: summary?.unitName ?? "—")
            .textSelection(.enabled)
        if let summary {
            LabeledContent("Projected", value: L10n.text(summary.isProjected ? "Yes" : "No"))
            LabeledContent("Vertical", value: L10n.text(summary.isVertical ? "Yes" : "No"))
            ProjectionAreaOfUseSummary(areaOfUse: summary.areaOfUse, projectedUnitName: summary.unitName)
        }
        LabeledContent("EPSG Code", value: summary?.epsgCode ?? "—")
            .textSelection(.enabled)
        LabeledContent("UTM Zone", value: summary?.utmZone ?? "—")
            .textSelection(.enabled)
    }

    private var sourceTable: some View {
        VStack(spacing: 0) {
            Table(session.rows) {
                TableColumn("X") { row in
                    TextField("X", text: coordinateBinding(rowID: row.id, axis: .x))
                        .textFieldStyle(.plain)
                        .accessibilityLabel(Text("Source X"))
                }
                TableColumn("Y") { row in
                    TextField("Y", text: coordinateBinding(rowID: row.id, axis: .y))
                        .textFieldStyle(.plain)
                        .accessibilityLabel(Text("Source Y"))
                }
            }
            HStack {
                Button("Add Rows") { session.addRows() }
                    .disabled(!session.canAddRows)
                Spacer()
            }
            .padding(12)
        }
    }

    private var destinationTable: some View {
        Table(session.rows) {
            TableColumn("X") { row in
                Text(destinationCoordinate(for: row, axis: .x))
                    .textSelection(.enabled)
                    .accessibilityLabel(Text("Destination X"))
            }
            TableColumn("Y") { row in
                Text(destinationCoordinate(for: row, axis: .y))
                    .textSelection(.enabled)
                    .accessibilityLabel(Text("Destination Y"))
            }
            TableColumn("Status") { row in
                Text(session.resultsByID[row.id].map { L10n.text($0.status.localizationKey) } ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func option(for side: ReprojectionSide) -> ReprojectionOption {
        side == .source ? session.sourceOption : session.destinationOption
    }

    private func localizedOptionOrRaw(_ value: String) -> String {
        switch value {
        case ReprojectionOption.project.rawValue: L10n.text("Project")
        case ReprojectionOption.wgs84.rawValue: L10n.text("WGS84")
        case ReprojectionOption.webMercator.rawValue: L10n.text("Web Mercator")
        case ReprojectionOption.custom.rawValue: L10n.text("Custom")
        default: value
        }
    }

    private func customProjectionBinding(for side: ReprojectionSide) -> Binding<String> {
        Binding(
            get: {
                side == .source ? session.sourceCustomProjectionText : session.destinationCustomProjectionText
            },
            set: { session.setCustomProjectionText($0, for: side) }
        )
    }

    private func coordinateBinding(rowID: String, axis: ReprojectionAxis) -> Binding<String> {
        Binding(
            get: {
                guard let row = session.rows.first(where: { $0.id == rowID }) else { return "" }
                return axis == .x ? row.xText : row.yText
            },
            set: { session.setCoordinate(rowID: rowID, axis: axis, text: $0) }
        )
    }

    private func destinationCoordinate(for row: ReprojectionInputRow, axis: ReprojectionAxis) -> String {
        guard let result = session.resultsByID[row.id], result.status == .transformed else { return "" }
        let value = axis == .x ? result.x : result.y
        guard let value, value.isFinite else { return "" }
        return String(value).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }
}
