import RASWorkspaceCore
import SwiftUI

struct RasterCalculatorWorkspace: View {
    @ObservedObject private var store: WorkspaceStore
    @StateObject private var session: RasterCalculatorSession
    @Environment(\.dismiss) private var dismiss
    let mapID: UUID
    private let onClose: (() -> Void)?
    @State private var previewScale: CGFloat = 1
    @State private var previewOffset = CGSize.zero

    init(store: WorkspaceStore, mapID: UUID,
         viewport: @escaping @MainActor () -> RasterMapViewExtent? = { nil },
         editingLayerID: String? = nil, onClose: (() -> Void)? = nil) {
        self.store = store
        self.mapID = mapID
        self.onClose = onClose
        _session = StateObject(wrappedValue: RasterCalculatorSession(store: store,
            mapID: mapID, viewport: viewport, editingLayerID: editingLayerID))
    }

    private var busy: Bool { session.isLoading || session.isEvaluating }
    private var canRun: Bool { session.canEvaluate && !busy }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                inputSection
                Divider()
                constantsSection
            }
            .frame(minWidth: 420, idealWidth: 520)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Layer Name", text: $session.layerName)
                expressionEditor
                noDataPicker
                profilePicker
                HStack(spacing: 10) {
                    Button("Preview") { Task { _ = await session.evaluate() } }
                        .disabled(!canRun)
                    if session.isEditingExisting {
                        Button("Save to Existing") { Task { _ = await session.saveToExisting() } }
                            .buttonStyle(.glassProminent)
                            .disabled(!canRun)
                        Button("Add to Map") { Task { _ = await session.addToMap() } }
                            .buttonStyle(.bordered)
                            .disabled(!canRun)
                    } else {
                        Button("Add to Map") { Task { _ = await session.addToMap() } }
                            .buttonStyle(.glassProminent)
                            .disabled(!canRun)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = session.loadErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { Task { await session.retryLoad() } }.disabled(busy)
                }
                CalculatorPreviewCanvas(layer: session.previewLayer,
                    isCurrent: session.isPreviewCurrent, scale: $previewScale,
                    offset: $previewOffset)
                    .frame(minHeight: 260)
            }
            .padding(16)
            .frame(minWidth: 420, idealWidth: 640)
        }
        .navigationTitle("Raster Calculator")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { close() }
            }
        }
        .task { await session.load() }
        .onChange(of: store.mapWorkflowIdentity(mapID)) { _, _ in
            if !session.refreshForCurrentMap() { close() }
        }
        .onChange(of: session.previewLayer?.id) { _, _ in
            previewScale = 1
            previewOffset = .zero
        }
        .onDisappear { session.invalidate() }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input Layers").font(.headline)
                Spacer()
                Button { session.addInput() } label: { Label("Add Input", systemImage: "plus") }
                    .disabled(busy || session.inspection == nil)
            }
            if session.recipe.inputs.isEmpty {
                ContentUnavailableView("No input layers", systemImage: "square.stack.3d.up",
                    description: Text("Add a Terrain or Result map to start an expression."))
                    .frame(minHeight: 100)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.recipe.inputs) { input in
                        inputEditor(input)
                        Divider()
                    }
                }
            }
            Text("Built-in: ndv, pi, e, tau. Inputs with a non-default NoData also expose <var>_ndv.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxHeight: .infinity)
    }

    private func inputEditor(_ input: RasterCalculatorInput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Variable", text: inputBinding(input, keyPath: \.variableName))
                    .frame(width: 100)
                Button(role: .destructive) { session.removeInput(input.id) } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).help("Remove input")
            }
            Picker("Source", selection: Binding(get: { input.sourceID }, set: {
                session.selectSource($0, for: input.id)
            })) {
                Text("Choose a source").tag("")
                ForEach(session.sources) { source in
                    Text(sourceLabel(source)).tag(source.id).disabled(!source.isAvailable)
                }
            }
            if let choice = session.sources.first(where: { $0.id == input.sourceID }) {
                Text(choice.assetPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if session.canAdoptCurrentSourceVersion(for: input.id) {
                    Button("Use Current Source Version") {
                        session.adoptCurrentSourceVersion(for: input.id)
                    }
                    .controlSize(.small)
                    .disabled(busy)
                }
                if let reason = choice.unavailableReason {
                    Label(RasterCalculatorErrorPresentation.text(reason), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if input.kind == "resultMap" {
                    Picker("Map Type", selection: Binding(get: { input.mapType ?? choice.mapTypes.first ?? "" }, set: { value in
                        session.updateInput(input.id) { $0.mapType = value.isEmpty ? nil : value }
                    })) {
                        ForEach(choice.mapTypes, id: \.self) { value in
                            Text(mapTypeLabel(value)).tag(value)
                        }
                    }
                    Toggle("Use as key frame", isOn: Binding(get: { input.isKeyFrame }, set: {
                        session.setKeyFrame($0, inputID: input.id)
                    }))
                    Toggle("Force horizontal", isOn: inputBoolBinding(input.id, keyPath: \.forceHorizontal))
                    Text(L10n.format("Profiles: %d", choice.profileCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let noData = choice.noDataValue {
                    Text(L10n.format("NoData: %@", noData.formatted(.number.precision(.significantDigits(1...7)))) )
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var constantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Named Constants").font(.headline)
                Spacer()
                Button { session.addConstant() } label: { Label("Add Constant", systemImage: "plus") }
                    .disabled(busy || session.inspection == nil)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(session.recipe.constants) { constant in
                        HStack {
                            TextField("Name", text: constantBinding(constant.id, keyPath: \.name))
                            TextField("Value", text: constantBinding(constant.id, keyPath: \.value))
                                .frame(width: 120)
                            Button(role: .destructive) { session.removeConstant(constant.id) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: 260)
    }

    private var expressionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Expression").font(.headline)
            TextEditor(text: $session.recipe.expression)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("Raster expression")
            Text("Enter a raster expression using the variable names above.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var noDataPicker: some View {
        Picker("NoData Behavior", selection: $session.recipe.noDataBehavior) {
            ForEach(session.noDataBehaviors, id: \.self) { value in
                Text(noDataLabel(value)).tag(value)
            }
        }
        .disabled(session.inspection == nil || busy)
    }

    @ViewBuilder
    private var profilePicker: some View {
        if session.recipe.inputs.contains(where: { $0.kind == "resultMap" && !$0.sourceID.isEmpty }),
           !session.profiles.isEmpty {
            Picker("Profile", selection: Binding(get: { session.selectedProfileIndex }, set: { value in
                Task { await session.selectProfile(value) }
            })) {
                ForEach(session.profiles) { profile in Text(profile.time).tag(profile.index) }
            }
            .disabled(busy)
        }
    }

    private func inputBinding<Value>(_ input: RasterCalculatorInput,
                                     keyPath: WritableKeyPath<RasterCalculatorInput, Value>) -> Binding<Value> where Value: Equatable {
        Binding(get: {
            session.recipe.inputs.first(where: { $0.id == input.id })?[keyPath: keyPath]
                ?? input[keyPath: keyPath]
        }, set: { value in session.updateInput(input.id) { $0[keyPath: keyPath] = value } })
    }

    private func inputBoolBinding(_ id: UUID, keyPath: WritableKeyPath<RasterCalculatorInput, Bool>) -> Binding<Bool> {
        Binding(get: { session.recipe.inputs.first(where: { $0.id == id })?[keyPath: keyPath] ?? false },
            set: { value in session.updateInput(id) { $0[keyPath: keyPath] = value } })
    }

    private func constantBinding(_ id: UUID, keyPath: WritableKeyPath<RasterCalculatorConstant, String>) -> Binding<String> {
        Binding(get: { session.recipe.constants.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { value in session.updateConstant(id) { $0[keyPath: keyPath] = value } })
    }

    private func sourceLabel(_ source: RasterCalculatorSourceChoice) -> String {
        "\(source.kind == "terrain" ? L10n.text("Terrain") : L10n.text("Result Map")) · \(source.name) · \(source.assetPath)"
    }

    private func mapTypeLabel(_ value: String) -> String {
        switch value {
        case "Depth": L10n.text("Depth")
        case "WaterSurfaceElevation": L10n.text("Water Surface Elevation")
        case "Velocity": L10n.text("Velocity")
        case "DepthTimesVelocity": L10n.text("Depth × Velocity")
        default: value
        }
    }

    private func noDataLabel(_ value: String) -> String {
        switch value {
        case "Allow": L10n.text("Allow (propagate)")
        case "WriteNDV": L10n.text("Map as NoData")
        case "WriteZero": L10n.text("Map as Zero")
        default: value
        }
    }

    private func close() {
        session.invalidate()
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct CalculatorPreviewCanvas: View {
    let layer: MapRasterLayer?
    let isCurrent: Bool
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    @GestureState private var drag = CGSize.zero

    private var points: [MapPoint] { layer?.points ?? [] }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: layer.map { [$0] } ?? [], points: points,
                    scale: scale, offset: CGSize(width: offset.width + drag.width,
                        height: offset.height + drag.height), revision: layer?.id.hashValue ?? 0)
                if layer == nil {
                    ContentUnavailableView("Preview the expression", systemImage: "map")
                } else if !isCurrent {
                    Label("Update preview to reflect changed settings.", systemImage: "arrow.clockwise")
                        .font(.caption).padding(10).glassEffect(.regular, in: .rect(cornerRadius: 10))
                        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                HStack {
                    Button { scale = min(1_000_000, scale * 1.3) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { scale = max(0.000001, scale / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { scale = 1; offset = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                }
                .buttonStyle(.borderless).padding(10).glassEffect(.regular, in: .capsule).padding(10)
                .disabled(layer == nil)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in offset.width += value.translation.width; offset.height += value.translation.height })
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                scale = min(1_000_000, max(0.000001, scale * value.magnification))
            })
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
