import AppKit
import CoreGraphics
import RASWorkspaceCore
import SwiftUI

struct RasterRGBExportToolView: View {
    @ObservedObject private var store: WorkspaceStore
    @StateObject private var session = RasterRGBExportSession()

    init(store: WorkspaceStore) { self.store = store }

    private var sources: [RasterMapSourceDescriptor] {
        store.rasterMapSources.sorted {
            ($0.mapName, $0.nodeName, $0.id) < ($1.mapName, $1.nodeName, $1.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                settings.frame(minWidth: 330, idealWidth: 390, maxWidth: 520)
                previewPane.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1040, maxWidth: 1400,
               minHeight: 540, idealHeight: 720, maxHeight: 1000)
        .interactiveDismissDisabled(session.exporting)
        .task(id: session.previewKey) {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await session.loadPreview(store: store)
        }
        .onDisappear { session.invalidate() }
        .alert(L10n.text("Export RGB Raster"), isPresented: Binding(
            get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { session.errorMessage = nil }
        } message: { Text(L10n.text(session.errorMessage ?? "")) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(L10n.text("Export RGB Raster"), systemImage: "square.3.layers.3d")
                .font(.title2.weight(.semibold))
            Spacer()
            if session.inspecting || session.loadingPreview {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("Preparing export preview"))
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(12)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox(L10n.text("Raster Source")) {
                    Picker(L10n.text("Raster Layer"), selection: Binding(
                        get: { session.selectedSourceID ?? "" },
                        set: { id in Task { await session.selectSource(id.isEmpty ? nil : id, store: store) } })) {
                        Text(L10n.text("Choose a raster layer…")).tag("")
                        ForEach(sources) { source in
                            Text("\(source.nodeName) — \(source.mapName)").tag(source.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(session.exporting || sources.isEmpty)
                    if sources.isEmpty {
                        Label(L10n.text("No source-backed raster layers are available."), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    }
                }

                if let inspection = session.inspection {
                    GroupBox(L10n.text("Output")) {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker(L10n.text("Region"), selection: $session.region) {
                                ForEach(RasterRGBExportRegion.allCases) { region in
                                    Text(region.title).tag(region)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(session.exporting)
                            if session.region == .currentView && session.capture?.currentView == nil {
                                Label(L10n.text("The map has no current viewport. Choose Full Layer Extent."),
                                      systemImage: "rectangle.dashed")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Text(L10n.text("Cell Size"))
                                Spacer()
                                TextField("", value: $session.cellSize,
                                    format: .number.precision(.significantDigits(1...9)))
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 130)
                                    .disabled(session.exporting)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(L10n.text("Raster extent"))
                                Text(verbatim: "\(inspection.fullMinX), \(inspection.fullMinY) — \(inspection.fullMaxX), \(inspection.fullMaxY)")
                            }
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let suggested = inspection.suggestedCellSize {
                                Button {
                                    session.cellSize = suggested
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(L10n.text("Use visible-resolution cell size"))
                                        Text(verbatim: "(\(suggested))")
                                    }
                                    .font(.caption)
                                }.disabled(session.exporting)
                            }
                        }
                    }

                    if !inspection.plotOptions.isEmpty {
                        GroupBox(L10n.text("Raster Plot Options")) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(inspection.plotOptions) { option in
                                    plotOptionRow(option)
                                }
                            }
                        }
                    }
                } else if session.inspecting {
                    ProgressView(L10n.text("Reading the selected raster and its symbology…"))
                        .controlSize(.small)
                } else {
                    ContentUnavailableView(L10n.text("Choose a raster layer"),
                        systemImage: "square.3.layers.3d",
                        description: Text(L10n.text("Select the exact source layer whose current symbology should be exported.")))
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func plotOptionRow(_ option: RasterRGBExportPlotOption) -> some View {
        let enabled = session.availablePlotOption(option) && !session.exporting
        if option.isBoolean {
            Toggle(isOn: Binding(get: {
                session.plotOptionValues[option.propertyName]?.lowercased() == "true"
            }, set: { session.setPlotOption(option.propertyName, value: $0 ? "true" : "false") })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(option.label.isEmpty ? option.name : option.label))
                    if !option.description.isEmpty,
                       option.description != option.propertyName,
                       option.description != option.name {
                        Text(L10n.text(option.description)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)
        } else {
            Picker(L10n.text(option.label.isEmpty ? option.name : option.label), selection: Binding(
                get: { session.plotOptionValues[option.propertyName] ?? option.value },
                set: { session.setPlotOption(option.propertyName, value: $0) })) {
                ForEach(option.enumValues) { choice in
                    Text(L10n.text(choice.label)).tag(choice.value)
                }
            }
            .disabled(!enabled)
            .help(L10n.text(option.description))
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Preview"), systemImage: "eye")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await session.refreshViewport(store: store) }
                } label: {
                    Label(L10n.text("Refresh View"), systemImage: "arrow.clockwise")
                }
                .disabled(session.exporting || session.selectedSourceID == nil || session.inspecting)
            }
            if let preview = session.preview, let image = preview.raster.image {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(Color(nsColor: .textBackgroundColor))
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 12) {
                        Text("\(preview.outputWidth) × \(preview.outputHeight)")
                        Text(ByteCountFormatter.string(fromByteCount: preview.estimatedFileSizeBytes, countStyle: .file))
                    }
                    .font(.caption.monospacedDigit())
                    .padding(9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(10)
                }
            } else if session.loadingPreview {
                ContentUnavailableView(L10n.text("Rendering preview…"), systemImage: "hourglass")
            } else {
                ContentUnavailableView(L10n.text("Preview unavailable"), systemImage: "photo",
                    description: Text(L10n.text("Choose a raster layer and a valid extent and cell size to preview the export.")))
            }
            if let output = session.output, output.state == "completed" {
                receipt(path: output.outputPath, artifacts: output.artifacts)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if session.exporting {
                HStack(spacing: 12) {
                    ProgressView(value: session.progress?.fraction)
                    Text(L10n.text(session.progress?.taskName ?? session.progress?.message ?? "Exporting RGB TIFF…"))
                        .font(.caption).lineLimit(1)
                    Button(L10n.text("Cancel Export"), role: .cancel) { session.cancel() }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Button(L10n.text("Cancel"), role: .cancel) { store.activeTool = nil }
                    .keyboardShortcut(.cancelAction).disabled(session.exporting)
                Spacer()
                Button {
                    Task { await chooseAndExport() }
                } label: {
                    Label(L10n.text("Export RGB TIFF…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private var canExport: Bool {
        session.capture != nil && session.inspection != nil && !session.inspecting
            && !session.exporting && session.cellSize.isFinite && session.cellSize > 0
            && (session.region != .currentView || session.capture?.currentView != nil)
    }

    private func chooseAndExport() async {
        guard let source = sources.first(where: { $0.id == session.selectedSourceID }),
              let destination = store.system.chooseExportDestination(
                name: source.nodeName + ".tif", extensions: ["tif"], title: "Export RGB Raster") else { return }
        guard let target = ExportDestinationTarget.normalize(destination, extension: "tif") else {
            session.errorMessage = L10n.text("Choose a TIFF file with the .tif extension.")
            return
        }
        guard !ExportDestinationTarget.exists(target, extensions: ["tif"]) else {
            session.errorMessage = L10n.text("The selected output or one of its sidecar files already exists.")
            return
        }
        await session.export(to: target.path, store: store)
    }

    @ViewBuilder
    private func receipt(path: String?, artifacts: [ExportArtifactReceipt]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text("Export complete"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let path { Text(path).font(.caption).textSelection(.enabled).lineLimit(2) }
            ForEach(artifacts) { artifact in
                Text("\(artifact.sizeBytes) bytes · SHA-256 \(artifact.sha256)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct DepthShapefileExportToolView: View {
    @ObservedObject private var store: WorkspaceStore
    @StateObject private var session: DepthShapefileExportSession

    init(store: WorkspaceStore) {
        self.store = store
        _session = StateObject(wrappedValue: DepthShapefileExportSession(mapID: store.lastActiveMapID))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Export Depth Shapefile"), systemImage: "square.stack.3d.up")
                    .font(.title2.weight(.semibold))
                Spacer()
                if session.inspecting || session.loadingPreview {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(12)
            Divider()
            HSplitView {
                settings.frame(minWidth: 330, idealWidth: 390, maxWidth: 520)
                previewPane.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1040, maxWidth: 1400,
               minHeight: 540, idealHeight: 720, maxHeight: 1000)
        .interactiveDismissDisabled(session.exporting)
        .task { await session.inspect(store: store) }
        .task(id: session.previewKey) {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await session.loadPreview(store: store)
        }
        .onDisappear { session.invalidate() }
        .alert(L10n.text("Export Depth Shapefile"), isPresented: Binding(
            get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { session.errorMessage = nil }
        } message: { Text(L10n.text(session.errorMessage ?? "")) }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox(L10n.text("Active Result")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L10n.text("Result Owner"), selection: Binding(
                            get: { session.selection.ownerID ?? "" },
                            set: { session.chooseOwner($0.isEmpty ? nil : $0) })) {
                            Text(L10n.text("Choose an active Result…")).tag("")
                            ForEach(session.inspection?.owners ?? []) { owner in
                                Text("\(owner.name) · \(owner.resultName)").tag(owner.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(session.exporting || session.inspection == nil)
                        if let owner = session.selectedOwner {
                            Text(owner.resultPath).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(2)
                            HStack {
                                Text(L10n.text("Profile"))
                                Spacer()
                                Picker(L10n.text("Profile"), selection: Binding(
                                    get: { session.selection.profileIndex ?? -1 },
                                    set: { session.chooseProfile($0 >= 0 ? $0 : nil) })) {
                                    Text(L10n.text("Choose a profile…")).tag(-1)
                                    ForEach(owner.profiles) { profile in
                                        Text("\(profile.name) · \(profile.time)").tag(profile.index)
                                    }
                                }
                                .labelsHidden().frame(maxWidth: 230)
                                .disabled(session.exporting)
                            }
                        } else if session.inspection?.owners.isEmpty == true {
                            Label(L10n.text("No active Result or MultiResult with a slot-zero profile is available."),
                                  systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if session.inspecting {
                            ProgressView(L10n.text("Reading the active map Result context…"))
                                .controlSize(.small)
                        }
                    }
                }

                GroupBox(L10n.text("Contour Settings")) {
                    VStack(alignment: .leading, spacing: 12) {
                        numericField("Cell Size", value: $session.cellSize)
                        numericField("Simplify Distance", value: $session.simplifyDistance)
                        Text(L10n.text("The preview follows the current map viewport. Export writes the selected profile’s complete depth contour coverage."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let owner = session.selectedOwner, let profile = session.selectedProfile {
                    GroupBox(L10n.text("Selected Source")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(owner.name).font(.headline)
                            Text(owner.resultName).font(.subheadline)
                            Text("\(profile.name) · \(profile.time)").font(.caption)
                            Text(L10n.text("Slot 0 · Depth · Allow negative depths"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(L10n.text(title))
            Spacer()
            TextField("", value: value,
                format: .number.precision(.significantDigits(1...9)))
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                .frame(width: 130).disabled(session.exporting)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Contour Preview"), systemImage: "map")
                    .font(.headline)
                Spacer()
                Button { Task { await session.refreshViewport(store: store) } } label: {
                    Label(L10n.text("Refresh View"), systemImage: "arrow.clockwise")
                }
                .disabled(session.exporting || session.inspecting || session.selectedOwner == nil)
            }
            if let preview = session.preview {
                ZStack {
                    if let payload = preview.resultRaster, let image = payload.cgImage {
                        Image(decorative: image, scale: 1).resizable()
                            .interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Color(nsColor: .textBackgroundColor)
                    }
                    DepthContourCanvas(viewport: preview.viewport,
                        polygons: preview.polygons, polylines: preview.polylines)
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 5) {
                        Text(verbatim: "\(preview.polygons.count)")
                        Text(L10n.text("preview polygons"))
                        Text("·")
                        Text(verbatim: preview.profileName)
                    }
                    .font(.caption.monospacedDigit()).padding(9)
                    .glassEffect(.regular, in: .capsule).padding(10)
                }
            } else if session.loadingPreview {
                ContentUnavailableView(L10n.text("Rendering depth contours…"), systemImage: "hourglass")
            } else {
                ContentUnavailableView(L10n.text("Choose an active Result and profile"),
                    systemImage: "map",
                    description: Text(L10n.text("The preview shows depth contours for the exact slot-zero Result profile and current viewport.")))
            }
            if let output = session.output, output.state == "completed" {
                receipt(path: output.outputPath, artifacts: output.artifacts)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if session.exporting {
                HStack(spacing: 12) {
                    ProgressView(value: session.progress?.fraction)
                    Text(L10n.text(session.progress?.taskName ?? session.progress?.message ?? "Exporting depth contours…"))
                        .font(.caption).lineLimit(1)
                    Button(L10n.text("Cancel Export"), role: .cancel) { session.cancel() }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Button(L10n.text("Cancel"), role: .cancel) { store.activeTool = nil }
                    .keyboardShortcut(.cancelAction).disabled(session.exporting)
                Spacer()
                Button { Task { await chooseAndExport() } } label: {
                    Label(L10n.text("Export Shapefile…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(!canExport)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private var canExport: Bool {
        session.capture != nil && session.selectedOwner != nil && session.selectedProfile != nil
            && !session.exporting && !session.inspecting && session.cellSize.isFinite
            && session.cellSize > 0 && session.simplifyDistance.isFinite
            && session.simplifyDistance >= 0
    }

    private func chooseAndExport() async {
        guard let owner = session.selectedOwner,
              let destination = store.system.chooseExportDestination(
                name: owner.resultName + "-depth.shp", extensions: ["shp"],
                title: "Export Depth Shapefile") else { return }
        guard let target = ExportDestinationTarget.normalize(destination, extension: "shp") else {
            session.errorMessage = L10n.text("Choose a Shapefile with the .shp extension.")
            return
        }
        guard !ExportDestinationTarget.exists(target,
                extensions: ["shp", "shx", "dbf", "prj", "cpg"]) else {
            session.errorMessage = L10n.text("The selected output or one of its sidecar files already exists.")
            return
        }
        await session.export(to: target.path, store: store)
    }

    @ViewBuilder
    private func receipt(path: String?, artifacts: [ExportArtifactReceipt]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text("Export complete"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let path { Text(path).font(.caption).textSelection(.enabled).lineLimit(2) }
            ForEach(artifacts) { artifact in
                Text("\(URL(fileURLWithPath: artifact.path).lastPathComponent) · \(artifact.sizeBytes) bytes · SHA-256 \(artifact.sha256)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

private struct DepthContourCanvas: View {
    let viewport: RasterMapViewExtent
    let polygons: [[GeometryTopologyCoordinate]]
    let polylines: [[GeometryTopologyCoordinate]]

    var body: some View {
        Canvas { context, size in
            guard viewport.maxX > viewport.minX, viewport.maxY > viewport.minY else { return }
            for polygon in polygons where polygon.count >= 3 {
                var path = makePath(polygon, size: size)
                path.closeSubpath()
                context.stroke(path, with: .color(.red), lineWidth: 1.5)
            }
            for line in polylines where line.count >= 2 {
                context.stroke(makePath(line, size: size), with: .color(.orange), lineWidth: 1.25)
            }
        }
        .accessibilityLabel(L10n.text("Depth contour outlines"))
    }

    private func makePath(_ coordinates: [GeometryTopologyCoordinate], size: CGSize) -> Path {
        var path = Path()
        for (index, coordinate) in coordinates.enumerated() {
            let point = CGPoint(x: (coordinate.x - viewport.minX) / (viewport.maxX - viewport.minX) * size.width,
                                y: (viewport.maxY - coordinate.y) / (viewport.maxY - viewport.minY) * size.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private enum ExportDestinationTarget {
    static func normalize(_ url: URL, `extension`: String) -> URL? {
        let suffix = `extension`.lowercased()
        if url.pathExtension.isEmpty { return url.appendingPathExtension(suffix) }
        guard url.pathExtension.lowercased() == suffix else { return nil }
        return url
    }

    static func exists(_ url: URL, extensions: [String]) -> Bool {
        let base = url.deletingPathExtension()
        return extensions.contains { suffix in
            FileManager.default.fileExists(atPath: base.appendingPathExtension(suffix).path)
        }
    }
}

private extension MapResultRenderLayerPayload {
    var cgImage: CGImage? {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !overflow, !byteOverflow, !rowOverflow,
              rgba.count == byteCount, let provider = CGDataProvider(data: rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
