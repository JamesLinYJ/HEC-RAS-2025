import RASWorkspaceCore
import SwiftUI

/// Native workbench for the original TerrainModCreator, PolygonRasterModificationLayerProperties,
/// LeveeModEditor, and ChannelModEditor control groups.
struct TerrainModificationWorkbench: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var section = TerrainModificationSection.raster
    @State private var enhancementCapture: TerrainAIEnhanceCapture?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $section) {
                    ForEach(TerrainModificationSection.allCases) { item in
                        Text(LocalizedStringKey(item.rawValue)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 500)
                Spacer()
                Button {
                    enhancementCapture = TerrainAIEnhanceCapture.make(session: session, store: store)
                } label: {
                    Label(L10n.text("AI Enhance"), systemImage: "mountain.2.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(TerrainAIEnhanceCapture.make(session: session, store: store) == nil)
                .help(L10n.text("Combines real USGS elevation data for the active map extent and stages one terrain input."))
            }
            .padding(12)

            Group {
                switch section {
                case .raster:
                    TerrainRasterModificationPage(session: session, store: store)
                case .levees:
                    TerrainLeveeModificationPage(session: session, store: store)
                case .channels:
                    TerrainChannelModificationPage(session: session, store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $enhancementCapture) { capture in
            TerrainAIEnhanceSheet(session: session, store: store, capture: capture)
        }
    }
}

private enum TerrainModificationSection: String, CaseIterable, Identifiable {
    case raster = "Raster Modifications"
    case levees = "Levees"
    case channels = "Channels"
    var id: String { rawValue }
}

/// The source fields stay visible with their original SwiftUI control types,
/// even before an adapter has supplied data. SourceField disables fields that
/// have no bound value, so the screen cannot imply that edits were accepted.
struct BoundSourceForm: View {
    let title: String
    let schemas: [String]
    var fieldIDs: Set<String>? = nil
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private struct SectionData: Identifiable {
        let id: String
        let title: String
        let fields: [SourceEditorField]
    }

    private var sections: [SectionData] {
        schemas.flatMap { schemaID -> [SectionData] in
            guard let schema = SourceEditorLibrary.shared.schema(schemaID) else { return [] }
            let fields = schema.fields.filter { fieldIDs == nil || fieldIDs!.contains($0.id) }
            guard !fields.isEmpty else { return [] }
            let groups = schema.groups.isEmpty
                ? [SourceEditorGroup(title: schema.title, fields: fields.map(\.id))]
                : schema.groups
            return groups.enumerated().compactMap { index, group in
                let members = group.fields.compactMap { id in fields.first { $0.id == id } }
                return members.isEmpty ? nil : SectionData(id: schemaID + "/" + String(index), title: group.title, fields: members)
            }
        }
    }

    private var scopedSelectionPrefix: String? {
        let tableID: String
        switch title {
        case "Channel Mod": tableID = "ChannelModEditor/Features"
        case "Levee Mod Detail": tableID = "LeveeModsTable"
        case "Levee Mod Properties Detail": tableID = "LeveeModPropertiesEditor/PropertySets"
        default:
            if title == "Channel Mod Parent" || title == "Channel Mod Terrain Input Properties",
               let selected = session.fields[TerrainEditorContract.sourceField], !selected.isEmpty {
                return "TerrainInputs/\(selected)"
            }
            return nil
        }
        guard let ids = session.tablePresentations[tableID]?.selection?.rowIDs, !ids.isEmpty else { return nil }
        if title != "Levee Mod Properties Detail" && ids.count != 1 { return nil }
        return "TerrainSelection/" + ids.sorted().joined(separator: "+")
    }

    private func scoped(_ field: SourceEditorField) -> SourceEditorField {
        field.inScope(scopedSelectionPrefix)
    }

    private var hasBoundData: Bool {
        schemas.compactMap { SourceEditorLibrary.shared.schema($0) }.flatMap(\.fields).contains { field in
            fieldIDs == nil || fieldIDs!.contains(field.id)
                ? session.fields[scoped(field).storageID] != nil || session.rows[scoped(field).storageID] != nil || session.sourceCollections[scoped(field).storageID] != nil
                : false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(LocalizedStringKey(title))
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            if !hasBoundData {
                TerrainAdapterStatus()
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            Form {
                ForEach(sections) { section in
                    Section(LocalizedStringKey(section.title)) {
                        ForEach(section.fields) { field in
                            fieldRow(field)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fieldRow(_ field: SourceEditorField) -> some View {
        let field = scoped(field)
        if title == "Levee Mod Properties Detail", let mismatchID = leveeResetMismatch(for: field),
           session.fields[field.scoped(mismatchID)] == "true" {
            HStack(spacing: 8) {
                SourceField(field: field, session: session, store: store)
                Button("Reset", systemImage: "arrow.uturn.backward") {
                    session.set(field.storageID, "__forceReset")
                }
                .buttonStyle(.borderless)
                .help("Reset this value to the source inherited state.")
                .disabled(!field.canEditDraft(in: session) || store.isSavingAll)
            }
            if isRightSideInheritedField(field), let value = session.fields[field.storageID], value.isEmpty {
                Text(L10n.text(inheritedPlaceholder(for: field))).font(.caption).foregroundStyle(.secondary)
            }
        } else if title == "Levee Mod Properties Detail", isRightSideInheritedField(field),
                  let value = session.fields[field.storageID], value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SourceField(field: field, session: session, store: store)
                Text(L10n.text(inheritedPlaceholder(for: field)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        } else {
            SourceField(field: field, session: session, store: store)
        }
    }

    private func leveeResetMismatch(for field: SourceEditorField) -> String? {
        switch field.id {
        case "TopWidthString": "TopWidthHasMismatch"
        case "LeftWidthString": "LeftWidthHasMismatch"
        case "RightWidthString": "RightWidthHasMismatch"
        case "LeftGradeString": "LeftGradeHasMismatch"
        case "RightGradeString": "RightGradeHasMismatch"
        default: nil
        }
    }

    private func isRightSideInheritedField(_ field: SourceEditorField) -> Bool {
        let id = field.id.lowercased()
        return id.contains("rightwidth") || id.contains("rightgrade")
    }

    private func inheritedPlaceholder(for field: SourceEditorField) -> String {
        let hasMismatch = field.mixedBy.flatMap { session.fields[field.scoped($0)] }
            .map { $0.lowercased() == "true" } ?? false
        return hasMismatch ? "(varies)" : "(same as left)"
    }
}

private struct TerrainAdapterStatus: View {
    var body: some View {
        Label("The original model adapter for this tool is unavailable.", systemImage: "externaldrive.badge.questionmark")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A native table that renders actual source rows and source columns when
/// supplied. Fallback columns mirror the inspected original control, while
/// row creation, deletion, and edits remain gated by source capabilities.
private struct TerrainSourceTable: View {
    let title: String
    let tableID: String
    let fallbackColumns: [SourceTableColumn]
    var rowAdornment: ((EditorRow) -> TerrainRowAdornment)? = nil
    var selectionDidChange: ((Set<String>) -> Void)? = nil
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var localSelection: Set<String> = []
    @State private var showDeleteConfirmation = false

    private var rows: [EditorRow] { session.rows[tableID] ?? [] }
    private var presentation: EditorTablePresentation? { session.tablePresentations[tableID] }
    private var columns: [SourceTableColumn] {
        guard let source = presentation?.columns, !source.isEmpty else { return fallbackColumns }
        return source.filter { $0.visible != false }
    }
    private var hasSourceTable: Bool { session.rows[tableID] != nil || presentation != nil }
    private var selectedIDs: Set<String> { presentation?.selection?.rowIDs ?? localSelection }
    private var selection: Binding<Set<String>> {
        Binding(
            get: { selectedIDs },
            set: { ids in
                if presentation?.selection != nil {
                    Task { await session.perform(.selectTableRows(table: tableID, ids: ids)) }
                } else {
                    localSelection = ids
                }
                selectionDidChange?(ids)
            }
        )
    }
    private var canAdd: Bool { session.canEdit && presentation?.canAddRows == true }
    private var canDelete: Bool { session.canEdit && !selectedIDs.isEmpty && presentation?.canDeleteRows == true }
    private var canCopy: Bool { session.canEdit && !selectedIDs.isEmpty && presentation?.canCopyRows == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(LocalizedStringKey(title)).font(.headline)
                Spacer()
                ControlGroup {
                    Button { Task { await session.perform(.addRow(table: tableID)) } } label: {
                        Label("Add", systemImage: "plus")
                    }.disabled(!canAdd)
                    Button { Task { await session.perform(.copyRows(table: tableID, ids: selectedIDs)) } } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.disabled(!canCopy)
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Label("Remove", systemImage: "minus")
                    }.disabled(!canDelete)
                }
                Menu("Actions") {
                    Button("Add") { Task { await session.perform(.addRow(table: tableID)) } }.disabled(!canAdd)
                    Button("Copy") { Task { await session.perform(.copyRows(table: tableID, ids: selectedIDs)) } }.disabled(!canCopy)
                    Button("Remove", role: .destructive) { showDeleteConfirmation = true }.disabled(!canDelete)
                    Divider()
                    Button("Copy Table", systemImage: "doc.on.clipboard") { copySelectedRows() }
                        .disabled(selectedIDs.isEmpty)
                }
                .menuStyle(.borderlessButton)
                .disabled(!hasSourceTable && !session.canEdit)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !hasSourceTable {
                TerrainAdapterStatus().padding(.horizontal, 12).padding(.bottom, 8)
            }

            Table(rows, selection: selection) {
                if let rowAdornment {
                    TableColumn("Shape") { (row: EditorRow) in
                        let adornment = rowAdornment(row)
                        Label(LocalizedStringKey(adornment.title), systemImage: adornment.systemImage)
                    }
                    .width(min: 76, ideal: 104)
                }
                TableColumnForEach(columns) { column in
                    TableColumn(column.localizedTitle) { (row: EditorRow) in
                        TableCell(column: column, rowID: row.id, tableID: tableID, session: session, store: store)
                    }
                    .width(min: 70, ideal: column.width.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? 140)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Copy Table", systemImage: "doc.on.clipboard") { copySelectedRows(ids) }.disabled(ids.isEmpty)
                if presentation?.canDeleteRows == true {
                    Button("Remove", role: .destructive) { remove(ids) }.disabled(ids.isEmpty || !session.canEdit)
                }
            }
            .overlay {
                if rows.isEmpty {
                    Text(hasSourceTable ? "—" : "Model data unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
        .confirmationDialog("Remove", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove(selectedIDs) }
            Button("Cancel", role: .cancel) { }
        }
        .frame(minWidth: 260, minHeight: 180)
        .onChange(of: session.modelAssetID) { _, _ in
            localSelection = []
            selectionDidChange?([])
        }
    }

    private func remove(_ ids: Set<String>) {
        Task { await session.perform(.removeRows(table: tableID, ids: ids)) }
    }

    private func copySelectedRows(_ ids: Set<String>? = nil) {
        let selected = rows.filter { (ids ?? selectedIDs).contains($0.id) }
        guard !selected.isEmpty else { return }
        let header = columns.map(\.localizedTitle).joined(separator: "\t")
        let body = selected.map { row in columns.map { row.values[$0.id] ?? "" }.joined(separator: "\t") }
        store.system.copy(([header] + body).joined(separator: "\n"))
    }
}

private struct TerrainRowAdornment {
    let title: String
    let systemImage: String
}

private func terrainModificationAdornment(_ row: EditorRow) -> TerrainRowAdornment {
    let shape = terrainRowValue(row, aliases: ["Shape", "ShapeType", "GeometryType", "VectorModShape"])?.lowercased() ?? "polygon"
    if shape.contains("triangle") { return .init(title: "Triangle", systemImage: "triangle") }
    if shape.contains("square") { return .init(title: "Square", systemImage: "square") }
    if shape.contains("rectangle") { return .init(title: "Rectangle", systemImage: "rectangle") }
    if shape.contains("circle") { return .init(title: "Circle", systemImage: "circle") }
    if shape.contains("ellipse") { return .init(title: "Ellipse", systemImage: "oval") }
    if shape.contains("highground") || shape.contains("high ground") { return .init(title: "High Ground", systemImage: "mountain.2") }
    if shape.contains("channel") { return .init(title: "Channel", systemImage: "water.waves") }
    if shape.contains("custom") { return .init(title: "Custom", systemImage: "scribble.variable") }
    return .init(title: "Polygon", systemImage: "pentagon")
}

private func terrainRowValue(_ row: EditorRow, aliases: [String]) -> String? {
    for alias in aliases {
        if let value = row.values.first(where: { $0.key.caseInsensitiveCompare(alias) == .orderedSame })?.value,
           !value.isEmpty { return value }
    }
    return nil
}

private func terrainColumn(_ id: String, _ title: String, _ sourceType: String, readOnly: Bool = true) -> SourceTableColumn {
    SourceTableColumn(id: id, title: title, sourceType: sourceType, readOnly: readOnly)
}

private struct TerrainRasterModificationPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var page = "Value"
    @State private var selectedModificationIDs: Set<String> = []
    @State private var placementShape = "Triangle"
    @State private var showValueAndType = true

    private let valueFields: Set<String> = [
        "Context_ValueProperties_Value",
        "Context_ValueProperties_ModificationType"
    ]
    private let shapeFields: Set<String> = [
        "Context_ShapeProperties_Height",
        "Context_ShapeProperties_Width",
        "Context_ShapeProperties_Rotation"
    ]
    private let featureColumns = [
        terrainColumn("ModificationType", "Modification Type", "string"),
        terrainColumn("Value", "Value", "float")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $page) {
                Text("Value").tag("Value")
                Text("Shape").tag("Shape")
                Text("Placement").tag("Placement")
                Text("Output Statistics").tag("Output Statistics")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            .padding(12)

            HSplitView {
                TerrainSourceTable(
                    title: "Raster Modifications",
                    tableID: "PolygonRasterModificationLayerProperties/Features",
                    fallbackColumns: featureColumns,
                    rowAdornment: terrainModificationAdornment,
                    selectionDidChange: { selectedModificationIDs = $0 },
                    session: session,
                    store: store
                )
                .frame(minWidth: 300, idealWidth: 380)

                Group {
                    switch page {
                    case "Value":
                        VStack(spacing: 0) {
                            Toggle("Show Value and Type", isOn: $showValueAndType)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            if showValueAndType {
                                BoundSourceForm(title: "Value", schemas: ["TerrainModCreator"], fieldIDs: valueFields, session: session, store: store)
                            } else {
                                Text("Value and modification type controls are hidden.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    case "Shape":
                        TerrainShapeSettings(session: session, store: store)
                    case "Placement":
                        TerrainModificationPlacementPage(
                            session: session,
                            store: store,
                            shape: $placementShape,
                            showValueAndType: $showValueAndType
                        )
                    default:
                        TerrainRasterStatisticsView(session: session, selectedIDs: selectedModificationIDs)
                    }
                }
                .frame(minWidth: 300)
            }
        }
        .onAppear {
            selectedModificationIDs = session.tablePresentations["PolygonRasterModificationLayerProperties/Features"]?.selection?.rowIDs ?? selectedModificationIDs
        }
        .onChange(of: session.tablePresentations["PolygonRasterModificationLayerProperties/Features"]?.selection?.rowIDs) { _, ids in
            if let ids { selectedModificationIDs = ids }
        }
        .onChange(of: session.modelAssetID) { _, _ in selectedModificationIDs = [] }
    }
}

private struct TerrainShapeSettings: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private let scope = "TerrainModCreator"
    private let shapeRoute = "Context_ShapeProperties_Shape"
    private let shapeFields: Set<String> = [
        "Context_ShapeProperties_Height",
        "Context_ShapeProperties_Width",
        "Context_ShapeProperties_Rotation"
    ]
    private let sourceEligibleShapes: [(id: String, symbol: String)] = [
        ("Triangle", "triangle"),
        ("Rectangle", "rectangle"),
        ("Custom", "scribble.variable")
    ]
    private var field: SourceEditorField? {
        SourceEditorLibrary.shared.schema("TerrainModCreator")?.fields.first { $0.id == shapeRoute }
    }
    private var fieldID: String { scope + "/" + shapeRoute }
    var body: some View {
        VStack(spacing: 0) {
            Text("Shape").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            if session.fields[fieldID] == nil { TerrainAdapterStatus().padding(.horizontal, 16).padding(.bottom, 8) }
            Form {
                Section("Shape") {
                    if field != nil {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                            ForEach(sourceEligibleShapes, id: \.id) { choice in
                                let selected = session.fields[fieldID] == choice.id
                                Button {
                                    session.set(fieldID, choice.id)
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: choice.symbol).font(.title2)
                                        Text(LocalizedStringKey(choice.id)).font(.caption)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 68)
                                    .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                                }
                                .buttonStyle(.plain)
                                .disabled(!session.canEdit || session.isBusy || session.loadingSelection || session.fields[fieldID] == nil)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .accessibilityLabel(field.map { LocalizedStringKey($0.title) } ?? "Shape")
                    }
                    ForEach(SourceEditorLibrary.shared.schema("TerrainModCreator")?.fields.filter { shapeFields.contains($0.id) } ?? []) { field in
                        SourceField(field: field, session: session, store: store)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerrainModificationPlacementPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Binding var shape: String
    @Binding var showValueAndType: Bool

    private let choices: [(String, String)] = [
        ("Triangle", "triangle"), ("Square", "square"), ("Rectangle", "rectangle"),
        ("Circle", "circle"), ("Ellipse", "oval"), ("High Ground", "mountain.2"),
        ("Channel", "water.waves"), ("Custom", "scribble.variable")
    ]

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 10) {
                    Toggle("Show Value and Type", isOn: $showValueAndType)
                        .padding(.horizontal, 14)
                    TerrainShapeSettings(session: session, store: store)
                    if showValueAndType {
                        BoundSourceForm(
                            title: "Value",
                            schemas: ["TerrainModCreator"],
                            fieldIDs: ["Context_ValueProperties_Value", "Context_ValueProperties_ModificationType"],
                            session: session,
                            store: store
                        )
                    }
                }
            }
            .frame(minWidth: 270)

            VStack(alignment: .leading, spacing: 12) {
                Text("Map Placement").font(.title2.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], spacing: 8) {
                    ForEach(choices, id: \.0) { item in
                        let selected = shape == item.0
                        Button { shape = item.0 } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.1).font(.title3)
                                Text(LocalizedStringKey(item.0)).font(.caption)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                TerrainModificationShapePreview(session: session, placementShape: shape)
                    .frame(minHeight: 210)
                ControlGroup {
                    Button("Select", systemImage: "cursorarrow") { }.disabled(true)
                    Button("Draw", systemImage: "pencil.tip.crop.circle") { }.disabled(true)
                    Button("Create", systemImage: "plus") { }.disabled(true)
                }
                Label("Map selection and modification creation require the terrain geometry provider.", systemImage: "externaldrive.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct TerrainModificationShapePreview: View {
    @ObservedObject var session: ModelEditorSession
    let placementShape: String

    private var propertyShape: String { session.fields["TerrainModCreator/Context_ShapeProperties_Shape"] ?? "" }
    private var width: Double? { session.fields["TerrainModCreator/Context_ShapeProperties_Width"].flatMap(Double.init) }
    private var height: Double? { session.fields["TerrainModCreator/Context_ShapeProperties_Height"].flatMap(Double.init) }
    private var rotation: Double { session.fields["TerrainModCreator/Context_ShapeProperties_Rotation"].flatMap(Double.init) ?? 0 }
    private var isBound: Bool { width != nil && height != nil && !propertyShape.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shape Preview").font(.headline)
                Spacer()
                Text(LocalizedStringKey(placementShape)).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let widthValue = max(abs(width ?? 1), 0.001)
                    let heightValue = max(abs(height ?? 1), 0.001)
                    let scale = min(size.width * 0.62 / widthValue, size.height * 0.62 / heightValue)
                    let rect = CGRect(x: center.x - widthValue * scale / 2, y: center.y - heightValue * scale / 2, width: widthValue * scale, height: heightValue * scale)
                    var path = Path()
                    switch placementShape {
                    case "Triangle":
                        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.closeSubpath()
                    case "Circle", "Ellipse":
                        path.addEllipse(in: rect)
                    case "Custom":
                        path.addRect(rect)
                    default:
                        path.addRect(rect)
                    }
                    let transform = CGAffineTransform(translationX: center.x, y: center.y)
                        .rotated(by: rotation * .pi / 180)
                        .translatedBy(x: -center.x, y: -center.y)
                    path = path.applying(transform)
                    if placementShape == "Custom" {
                        context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    } else {
                        context.fill(path, with: .color(.accentColor.opacity(0.22)))
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }
                }
                .overlay {
                    if placementShape == "Custom" {
                        Text("Draw the custom polygon on the map")
                            .font(.caption)
                            .padding(6)
                            .background(.regularMaterial, in: Capsule())
                    } else if !isBound {
                        Text("Shape parameters are not supplied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 14) {
                Label(L10n.format("Width: %@", width.map { $0.formatted() } ?? "—"), systemImage: "arrow.left.and.right")
                Label(L10n.format("Height: %@", height.map { $0.formatted() } ?? "—"), systemImage: "arrow.up.and.down")
                Label(L10n.format("Rotation: %@", String(rotation)), systemImage: "rotate.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TerrainRasterStatisticsView: View {
    @ObservedObject var session: ModelEditorSession
    let selectedIDs: Set<String>

    private var tableID: String { "PolygonRasterModificationLayerProperties/Features" }
    private var selectedRows: [EditorRow] {
        (session.rows[tableID] ?? []).filter { selectedIDs.contains($0.id) }
    }
    private var row: EditorRow? { selectedRows.count == 1 ? selectedRows.first : nil }
    private func value(_ aliases: [String]) -> String {
        if let row, let value = terrainRowValue(row, aliases: aliases) { return value }
        for alias in aliases {
            if let value = session.fields.first(where: { $0.key.hasSuffix("/" + alias) })?.value, !value.isEmpty { return value }
        }
        return "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Output Statistics").font(.title2.weight(.semibold)).padding(.horizontal, 16).padding(.top, 14)
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(selectedRows.isEmpty ? "Select one modification to inspect its values." : selectedRows.count == 1 ? "One modification selected." : "Select one modification to inspect its values.")
                Spacer()
                Button("Select on Map", systemImage: "scope") { }.disabled(true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
            Form {
                Section("Selected Modification") {
                    TerrainMetricRow(title: "Shape Rotation", value: value(["ShapeRotation", "Rotation"]))
                    TerrainMetricRow(title: "Shape Width", value: value(["ShapeWidth", "Width"]))
                    TerrainMetricRow(title: "Shape Height", value: value(["ShapeHeight", "Height"]))
                    TerrainMetricRow(title: "Value", value: value(["Value"]))
                    TerrainMetricRow(title: "Raster Mod Type", value: value(["RasterModType", "ModificationType"]))
                }
                if row == nil || value(["ShapeRotation", "Rotation"]) == "—" || value(["ShapeWidth", "Width"]) == "—" || value(["ShapeHeight", "Height"]) == "—" {
                    Section {
                        Label("Detailed polygon dimensions depend on feature geometry from the terrain provider.", systemImage: "externaldrive.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerrainMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(LocalizedStringKey(title), value: value)
    }
}

private struct TerrainLeveeModificationPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var page = "Features"
    @State private var selectedLeveeIDs: Set<String> = []

    private let featureColumns = [
        terrainColumn("Name", "Name", "string"),
        terrainColumn("LeveePropertyName", "Simple Cut/Fill Properties", "string"),
        terrainColumn("LineLength", "Line Length", "double")
    ]
    private let propertyColumns = [
        terrainColumn("Name", "Name", "string"),
        terrainColumn("Mode", "Mode", "string")
    ]
    private let profileColumns = [
        terrainColumn("Station", "Station", "double", readOnly: false),
        terrainColumn("Elevation", "Elevation", "double", readOnly: false)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $page) {
                Text("Features").tag("Features")
                Text("Properties").tag("Properties")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(12)

            if page == "Features" {
                HSplitView {
                    TerrainSourceTable(
                        title: "Levees",
                        tableID: "LeveeModsTable",
                        fallbackColumns: featureColumns,
                        selectionDidChange: { selectedLeveeIDs = $0 },
                        session: session,
                        store: store
                    )
                        .frame(minWidth: 310, idealWidth: 400)
                    VSplitView {
                        BoundSourceForm(title: "Levee Mod Detail", schemas: ["LeveeModDetailEditor"], session: session, store: store)
                            .frame(minHeight: 220)
                        TerrainLeveeProfilePanel(
                            session: session,
                            store: store,
                            selectedLeveeIDs: selectedLeveeIDs,
                            profileColumns: profileColumns
                        )
                        .frame(minHeight: 190)
                    }
                    .frame(minWidth: 360)
                }
            } else {
                HSplitView {
                    TerrainSourceTable(title: "Properties", tableID: "LeveeModPropertiesEditor/PropertySets", fallbackColumns: propertyColumns, session: session, store: store)
                        .frame(minWidth: 310, idealWidth: 400)
                    BoundSourceForm(title: "Levee Mod Properties Detail", schemas: ["LeveeModPropertiesDetailEditor"], session: session, store: store)
                        .frame(minWidth: 360)
                }
            }
        }
        .onAppear { selectedLeveeIDs = session.tablePresentations["LeveeModsTable"]?.selection?.rowIDs ?? selectedLeveeIDs }
        .onChange(of: session.tablePresentations["LeveeModsTable"]?.selection?.rowIDs) { _, ids in
            if let ids { selectedLeveeIDs = ids }
        }
        .onChange(of: session.modelAssetID) { _, _ in selectedLeveeIDs = [] }
    }
}

private struct TerrainLeveeProfilePanel: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let selectedLeveeIDs: Set<String>
    let profileColumns: [SourceTableColumn]
    @State private var display = "Profile"
    @State private var sortError: String?
    @State private var sorting = false

    private let featureTableID = "LeveeModsTable"
    private let profileTableID = "LeveeModDetailEditor/Profile"
    private var profileRows: [EditorRow] { session.rows[profileTableID] ?? [] }
    private var selectedLevee: EditorRow? {
        (session.rows[featureTableID] ?? []).first { selectedLeveeIDs.contains($0.id) }
    }
    private var profileValues: [(station: Double, elevation: Double)] {
        profileRows.compactMap { row in
            guard let stationText = terrainRowValue(row, aliases: ["Station"]),
                  let elevationText = terrainRowValue(row, aliases: ["Elevation"]),
                  let station = Double(stationText), station.isFinite,
                  let elevation = Double(elevationText), elevation.isFinite else { return nil }
            return (station, elevation)
        }
    }
    private var stations: [Double] { profileValues.map { $0.station } }
    private var invalidPointCount: Int { profileRows.count - profileValues.count }
    private var hasEnoughData: Bool { profileValues.count > 1 }
    private var hasDuplicates: Bool { Set(stations).count != stations.count }
    private var isSorted: Bool { zip(stations, stations.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 } }
    private var lineLength: Double? {
        if let selectedLevee,
           let text = terrainRowValue(selectedLevee, aliases: ["LineLength", "Line Length"]),
           let value = Double(text) {
            return value
        }

        if let text = session.fields.first(where: { $0.key.hasSuffix("/LineLength") })?.value,
           let value = Double(text) {
            return value
        }

        return nil
    }
    private var stationLengthValid: Bool? {
        guard hasEnoughData, isSorted, let lineLength, let last = stations.last else { return nil }
        let tolerance = lineLength * 0.05
        return last > lineLength - tolerance && last < lineLength + tolerance
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Profile View", selection: $display) {
                    Text("Profile").tag("Profile")
                    Text("Chart").tag("Chart")
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                Button("Select on Map", systemImage: "scope") { selectLeveeOnMap() }
                    .disabled(selectedLevee == nil || session.isBusy || session.loadingSelection)
                Button("Sort Stations", systemImage: "arrow.up.arrow.down") { Task { await sortSelectedProfile() } }
                    .disabled(selectedLevee == nil || profileRows.isEmpty || sorting || session.isBusy || session.loadingSelection)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            profileFeedback
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            if let sortError {
                Label(sortError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 12).padding(.bottom, 8)
            }

            if display == "Profile" {
                TerrainSourceTable(title: "Profile", tableID: profileTableID, fallbackColumns: profileColumns, session: session, store: store)
            } else {
                TerrainStationElevationChart(
                    title: "Levee Profile",
                    series: [.init(id: "levee", title: "Levee", rows: profileRows, color: .blue)],
                    emptyMessage: "Select a levee with station/elevation rows to show its profile."
                )
            }
        }
        .onChange(of: session.modelAssetID) { _, _ in display = "Profile" }
    }

    private func selectLeveeOnMap() {
        guard let selectedLevee else { return }
        Task { _ = await session.perform(.selectTableRows(table: featureTableID, ids: [selectedLevee.id])) }
    }

    @MainActor private func sortSelectedProfile() async {
        guard let selectedLevee,
              let inputID = session.fields[TerrainEditorContract.sourceField], !inputID.isEmpty else { return }
        sorting = true; sortError = nil
        defer { sorting = false }
        do {
            let result = try await session.terrainTopology(inputID: inputID, operation: .sortProfile,
                featureIDs: [selectedLevee.id])
            guard result.inputId == inputID, result.sourceRevision == session.terrainSourceRevision,
                  result.selectedFeatureIDs == [selectedLevee.id] else {
                throw ProjectFileError.invalid("The sorted profile belongs to a different levee selection.")
            }
        } catch { sortError = L10n.text(error.localizedDescription) }
    }

    @ViewBuilder private var profileFeedback: some View {
        VStack(alignment: .leading, spacing: 4) {
            if invalidPointCount > 0 {
                Label(L10n.format("%d rows need finite station and elevation values.", invalidPointCount), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !hasEnoughData {
                Label("Add at least two valid profile points.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if hasDuplicates {
                Label("Duplicate station values.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if hasEnoughData && !isSorted {
                Label("Stations are not in ascending order.", systemImage: "arrow.up.arrow.down").foregroundStyle(.orange)
            }
            if stationLengthValid == false {
                Label("Last station does not match the levee line length.", systemImage: "ruler").foregroundStyle(.orange)
            }
            if hasEnoughData && !hasDuplicates && isSorted && stationLengthValid == true {
                Label("Profile stations are valid.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            if hasEnoughData && !hasDuplicates && isSorted && stationLengthValid == nil {
                Label("Station/length check awaits feature data.", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if let selectedLevee {
                HStack {
                    Label(terrainRowValue(selectedLevee, aliases: ["Name"]) ?? selectedLevee.id, systemImage: "point.3.connected.trianglepath.dotted")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

private enum ChannelDetailMode: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case terrain = "Terrain Profile"
    case chart = "Chart"
    var id: String { rawValue }
}

private struct TerrainChannelModificationPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var page = "Channel Mod Parent"
    @State private var selectedChannelIDs: Set<String> = []

    private let channelColumns = [
        terrainColumn("Name", "Name", "string"),
        terrainColumn("LineLength", "Line Length", "double")
    ]
    private let profileColumns = [
        terrainColumn("Station", "Station", "double", readOnly: false),
        terrainColumn("Elevation", "Elevation", "double", readOnly: false)
    ]
    private let terrainColumns = [
        terrainColumn("Station", "Station", "double"),
        terrainColumn("Elevation", "Elevation", "double")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $page) {
                Text("Channel Mod Parent").tag("Channel Mod Parent")
                Text("Channel Mod").tag("Channel Mod")
                Text("Channel Mod Terrain Input Properties").tag("Channel Mod Terrain Input Properties")
                Text("Geometry").tag("Geometry")
            }
            .pickerStyle(.segmented)
            .padding(12)

            switch page {
            case "Channel Mod Parent":
                ChannelModParentPage(session: session, store: store, selectedChannelIDs: $selectedChannelIDs)
            case "Channel Mod":
                ChannelModDetailPage(
                    session: session,
                    store: store,
                    channelColumns: channelColumns,
                    profileColumns: profileColumns,
                    terrainColumns: terrainColumns,
                    selectedChannelIDs: $selectedChannelIDs
                )
            case "Channel Mod Terrain Input Properties":
                BoundSourceForm(title: page, schemas: ["ChannelModTerrainInputProperties"], session: session, store: store)
            default:
                ChannelTopologyPage(session: session, store: store)
            }
        }
        .onChange(of: session.tablePresentations["ChannelModEditor/Features"]?.selection?.rowIDs) { _, ids in
            if let ids { selectedChannelIDs = ids }
        }
        .onAppear { selectedChannelIDs = session.tablePresentations["ChannelModEditor/Features"]?.selection?.rowIDs ?? selectedChannelIDs }
        .onChange(of: session.modelAssetID) { _, _ in selectedChannelIDs = [] }
    }
}

private struct ChannelModParentPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Binding var selectedChannelIDs: Set<String>

    private let importedFields: Set<String> = [
        "Context_Context_Context_TinMaxSegmentLength",
        "Context_Context_Context_ModificationType"
    ]

    private var importedState: Bool? {
        guard let rows = session.rows["ChannelModEditor/Features"] else { return nil }
        return !rows.isEmpty
    }

    private var selectedChannel: EditorRow? {
        (session.rows["ChannelModEditor/Features"] ?? []).first { selectedChannelIDs.contains($0.id) }
    }
    private var selectedChannelName: String {
        guard let selectedChannel else { return "Select a channel" }
        return terrainRowValue(selectedChannel, aliases: ["Name"]) ?? selectedChannel.id
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label(importedState == true ? "Imported channel geometry" : importedState == false ? "No channel geometry imported" : "Import state unavailable", systemImage: importedState == true ? "checkmark.circle.fill" : "point.3.connected.trianglepath.dotted")
                    Spacer()
                    if importedState != true {
                        Menu("Import 1D Geometry") {
                            Button("From Version 6 HDF") { }.disabled(true)
                            Button("From 2025 Classic Geometry") { }.disabled(true)
                        }
                        .disabled(true)
                    }
                }
                .padding(12)
                if importedState == true {
                    BoundSourceForm(
                        title: "Channel Mod Parent",
                        schemas: ["ChannelModParentEditor"],
                        fieldIDs: importedFields,
                        session: session,
                        store: store
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Channel Geometry", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                        Text(importedState == false
                             ? "Import channel geometry to show TIN segment length and modification type."
                             : "The current model adapter does not report whether geometry has been imported.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Label("TIN Segment Length", systemImage: "ruler")
                            Spacer()
                            Text("—").foregroundStyle(.secondary)
                        }
                        HStack {
                            Label("Modification Type", systemImage: "slider.horizontal.3")
                            Spacer()
                            Text("—").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                    .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                }
            }
                .frame(minHeight: 240)
            TerrainSourceTable(
                title: "Channels",
                tableID: "ChannelModEditor/Features",
                fallbackColumns: [terrainColumn("Name", "Name", "string"), terrainColumn("LineLength", "Line Length", "double")],
                selectionDidChange: { selectedChannelIDs = $0 },
                session: session,
                store: store
            )
            .frame(minHeight: 200)
            if let selectedChannel {
                HStack {
                    Label(selectedChannelName, systemImage: "point.3.connected.trianglepath.dotted")
                    if let length = terrainRowValue(selectedChannel, aliases: ["LineLength", "Line Length"]) {
                        Text(L10n.format("Line Length: %@", length)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct ChannelModDetailPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let channelColumns: [SourceTableColumn]
    let profileColumns: [SourceTableColumn]
    let terrainColumns: [SourceTableColumn]
    @Binding var selectedChannelIDs: Set<String>
    @State private var detailMode = ChannelDetailMode.profile

    private var terrainProfileRowIDs: Set<String> {
        Set((session.rows["ChannelModEditor/TerrainProfile"] ?? []).map(\.id))
    }
    private var canCopyTerrainProfile: Bool {
        session.canEdit && !session.isBusy && selectedChannelIDs.count == 1 && !terrainProfileRowIDs.isEmpty
            && session.tablePresentations["ChannelModEditor/TerrainProfile"]?.canCopyRows == true
    }

    var body: some View {
        HSplitView {
            TerrainSourceTable(
                title: "Channels",
                tableID: "ChannelModEditor/Features",
                fallbackColumns: channelColumns,
                selectionDidChange: { selectedChannelIDs = $0 },
                session: session,
                store: store
            )
                .frame(minWidth: 300, idealWidth: 370)
            VSplitView {
                BoundSourceForm(title: "Channel Mod", schemas: ["ChannelModEditor"], session: session, store: store)
                    .frame(minHeight: 150)
                VStack(spacing: 0) {
                    Picker("View", selection: $detailMode) {
                        ForEach(ChannelDetailMode.allCases) { mode in Text(LocalizedStringKey(mode.rawValue)).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                    switch detailMode {
                    case .profile:
                        VStack(spacing: 0) {
                            HStack {
                                Spacer()
                                Button("Copy Terrain to Profile", systemImage: "arrow.down.to.line") {
                                    Task {
                                        await session.perform(.copyRows(table: "ChannelModEditor/TerrainProfile", ids: terrainProfileRowIDs))
                                    }
                                }
                                .disabled(!canCopyTerrainProfile)
                                .help("Sample the selected channel over the current terrain and replace its profile.")
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            TerrainSourceTable(title: "Profile", tableID: "ChannelModEditor/Profile", fallbackColumns: profileColumns, session: session, store: store)
                        }
                    case .terrain:
                        TerrainSourceTable(title: "Terrain Profile", tableID: "ChannelModEditor/TerrainProfile", fallbackColumns: terrainColumns, session: session, store: store)
                    case .chart:
                        TerrainChannelProfileChart(session: session, selectedChannelIDs: selectedChannelIDs)
                    }
                }
                .frame(minHeight: 230)
            }
            .frame(minWidth: 360)
        }
    }
}

private struct TerrainChannelProfileChart: View {
    @ObservedObject var session: ModelEditorSession
    let selectedChannelIDs: Set<String>
    private var profileRows: [EditorRow] { session.rows["ChannelModEditor/Profile"] ?? [] }
    private var terrainRows: [EditorRow] { session.rows["ChannelModEditor/TerrainProfile"] ?? [] }
    private var selectedChannel: EditorRow? {
        (session.rows["ChannelModEditor/Features"] ?? []).first { selectedChannelIDs.contains($0.id) }
    }
    private var selectedChannelName: String {
        guard let selectedChannel else { return "Select a channel" }
        return terrainRowValue(selectedChannel, aliases: ["Name"]) ?? selectedChannel.id
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(selectedChannelName, systemImage: "point.3.connected.trianglepath.dotted")
                if let length = selectedChannel.flatMap({ terrainRowValue($0, aliases: ["LineLength", "Line Length"]) }) {
                    Text(L10n.format("Line Length: %@", length)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select on Map", systemImage: "scope") { selectChannelOnMap() }
                    .disabled(selectedChannel == nil || session.isBusy || session.loadingSelection)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            TerrainStationElevationChart(
                title: "Channel Profile",
                series: [
                    .init(id: "profile", title: "Profile", rows: profileRows, color: .blue),
                    .init(id: "terrain", title: "Terrain Profile", rows: terrainRows, color: .brown)
                ],
                emptyMessage: "Select a channel with profile data to display its station/elevation chart."
            )
        }
    }

    private func selectChannelOnMap() {
        guard let selectedChannel else { return }
        Task {
            _ = await session.perform(.selectTableRows(table: "ChannelModEditor/Features", ids: [selectedChannel.id]))
        }
    }
}

private struct TerrainProfileSeries: Identifiable {
    let id: String
    let title: String
    let rows: [EditorRow]
    let color: Color
}

private struct TerrainStationElevationChart: View {
    let title: String
    let series: [TerrainProfileSeries]
    let emptyMessage: String
    @State private var hiddenSeries: Set<String> = []

    private var visibleSeries: [TerrainProfileSeries] { series.filter { !hiddenSeries.contains($0.id) } }
    private var visiblePoints: [CGPoint] { visibleSeries.flatMap { points(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Spacer()
                ForEach(series) { item in
                    Button {
                        if hiddenSeries.contains(item.id) { hiddenSeries.remove(item.id) }
                        else { hiddenSeries.insert(item.id) }
                    } label: {
                        Label(LocalizedStringKey(item.title), systemImage: hiddenSeries.contains(item.id) ? "circle" : "circle.fill")
                            .foregroundStyle(item.color.opacity(hiddenSeries.contains(item.id) ? 0.35 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(hiddenSeries.contains(item.id) ? [] : .isSelected)
                }
            }
            GeometryReader { proxy in
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                    let allPoints = visiblePoints
                    guard allPoints.count > 1,
                          let minX = allPoints.map(\.x).min(), let maxX = allPoints.map(\.x).max(),
                          let minY = allPoints.map(\.y).min(), let maxY = allPoints.map(\.y).max() else { return }
                    let dx = max(maxX - minX, .ulpOfOne)
                    let dy = max(maxY - minY, .ulpOfOne)
                    for item in visibleSeries {
                        let values = points(for: item)
                        guard values.count > 1 else { continue }
                        var path = Path()
                        for (index, point) in values.enumerated() {
                            let mapped = CGPoint(
                                x: 30 + (point.x - minX) / dx * max(size.width - 42, 1),
                                y: size.height - 24 - (point.y - minY) / dy * max(size.height - 36, 1)
                            )
                            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
                            let marker = CGRect(x: mapped.x - 2.5, y: mapped.y - 2.5, width: 5, height: 5)
                            context.fill(Path(ellipseIn: marker), with: .color(item.color))
                        }
                        context.stroke(path, with: .color(item.color), lineWidth: 2)
                    }
                }
                .overlay {
                    if visiblePoints.isEmpty {
                        Text(LocalizedStringKey(emptyMessage))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(18)
                    }
                }
                .accessibilityLabel(LocalizedStringKey(title))
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Text("Station").font(.caption2).foregroundStyle(.secondary).padding(6)
            }
            .overlay(alignment: .topLeading) {
                Text("Elevation").font(.caption2).foregroundStyle(.secondary).padding(6)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func points(for item: TerrainProfileSeries) -> [CGPoint] {
        item.rows.compactMap { row in
            guard let station = terrainRowValue(row, aliases: ["Station"]).flatMap(Double.init),
                  let elevation = terrainRowValue(row, aliases: ["Elevation"]).flatMap(Double.init),
                  station.isFinite, elevation.isFinite else { return nil }
            return CGPoint(x: station, y: elevation)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for step in 0...4 {
            let x = 30 + CGFloat(step) / 4 * max(size.width - 42, 1)
            let y = 10 + CGFloat(step) / 4 * max(size.height - 36, 1)
            grid.move(to: CGPoint(x: x, y: 8)); grid.addLine(to: CGPoint(x: x, y: size.height - 24))
            grid.move(to: CGPoint(x: 30, y: y)); grid.addLine(to: CGPoint(x: size.width - 12, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
    }
}

private struct ChannelTopologyPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        TerrainTopologyWorkbench(session: session, store: store)
    }
}
