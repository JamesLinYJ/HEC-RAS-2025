import AppKit
import SwiftUI

/// The native sheet edits the session captured for the map that opened it.
/// The editor remains responsible for the adjacent velocity settings only.
struct BackgroundMapContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let mapID: UUID
    @ObservedObject private var session: BackgroundMapSession
    @State private var particleSettings = false

    init(store: WorkspaceStore, state: DataToolSession, editor: ModelEditorSession, mapID: UUID) {
        self.store = store
        self.state = state
        self.editor = editor
        self.mapID = mapID
        _session = ObservedObject(wrappedValue: store.mapState(for: mapID).backgroundMapSession)
    }

    private var enabled: Bool { session.settings.areBackgroundMapsOn }
    private var selectedStyle: BackgroundMapStyle? {
        session.styles.first { $0.id == session.settings.osmStyle }
    }

    var body: some View {
        HSplitView {
            Form {
                Section("Map Styling") {
                    settingToggle("Background Maps", keyPath: \.areBackgroundMapsOn)
                    Group {
                        settingToggle("Satellite Imagery", keyPath: \.isSatelliteImageryOn)
                        settingToggle("USGS Hillshade", keyPath: \.isShadedReliefOn)
                        settingToggle("Open Street Map", keyPath: \.isOpenStreetMapOn)
                    }
                    .disabled(!enabled)
                }

                Section("Open Street Map") {
                    if session.isLoadingStyles && session.styles.isEmpty {
                        ProgressView("Loading…")
                    }
                    Picker("Style", selection: Binding(
                        get: { session.settings.osmStyle },
                        set: { session.settings.osmStyle = $0 })) {
                        ForEach(session.styles) { style in
                            Text(style.name).tag(style.id)
                        }
                        if !session.settings.osmStyle.isEmpty && selectedStyle == nil {
                            Text(session.settings.osmStyle).tag(session.settings.osmStyle)
                        }
                    }
                    HStack {
                        Text("Information Density")
                        Spacer(minLength: 10)
                        Slider(value: Binding(
                            get: { Double(session.settings.density) },
                            set: { session.settings.density = Int($0.rounded()) }),
                            in: -1...5, step: 1)
                        Text("\(session.settings.density)").monospacedDigit().frame(width: 24)
                    }
                    Toggle("Show Labels", isOn: Binding(
                        get: { session.settings.showLabels },
                        set: { session.settings.showLabels = $0 }))
                    if let error = session.styleError {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .disabled(!enabled || !session.settings.isOpenStreetMapOn)

                Section("Satellite Imagery") {
                    HStack {
                        Text("Opacity")
                        Slider(value: Binding(
                            get: { session.settings.satelliteOpacity },
                            set: { session.settings.satelliteOpacity = $0 }), in: 0...1)
                        Text(session.settings.satelliteOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!enabled || !session.settings.isSatelliteImageryOn)

                Section("Velocity") {
                    genericToggle("Draw Velocity Arrows", route: "Map_ArrowSettings_IsEnabled")
                    genericToggle("Draw Particle Tracing", route: "Map_ParticleSettings_IsEnabled")
                    Button("Particle Settings…") {
                        editor.set("RasBackgroundMaps/Map_ParticleSettings_IsEnabled", "true")
                        particleSettings = true
                    }
                    .popover(isPresented: $particleSettings) {
                        SourceForm(page: .form("Particle Settings", "ParticleSettingsMenu"),
                            session: editor, store: store)
                            .frame(width: 420, height: 370)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 330, idealWidth: 420, maxWidth: 540)
            .disabled(!editor.canEdit || !store.canEditBackgroundMaps(mapID: mapID, session: session))

            VStack(alignment: .leading, spacing: 16) {
                Text("Style Preview").font(.headline)
                if let style = selectedStyle {
                    if let data = style.preview, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 300)
                            .accessibilityLabel(style.name)
                    } else {
                        ContentUnavailableView("No preview available", systemImage: "map")
                            .frame(minHeight: 160)
                    }
                    Text(style.name).font(.title3)
                    if !style.description.isEmpty {
                        Text(style.description).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    ContentUnavailableView("No style selected", systemImage: "map")
                        .frame(minHeight: 180)
                }

                sourceStatus

                if let error = session.error {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }

                Spacer(minLength: 0)
                cacheControls
                if let attribution = session.snapshot?.render.sources.first(where: {
                    $0.id == "osm" && $0.state != "disabled"
                })?.attribution {
                    Text(attribution).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(minWidth: 330, maxWidth: .infinity)
        }
        .task {
            session.refreshStyles()
            session.refreshCache()
        }
    }

    private var sourceStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
                if session.isLoading { ProgressView("Loading…") }
            ForEach(session.snapshot?.render.sources ?? []) { source in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(for: source.state))
                        .foregroundStyle(source.state == "failed" ? Color.red : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceName(source.id)).font(.caption.weight(.semibold))
                        if let message = source.message, !message.isEmpty {
                            Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cacheControls: some View {
        GroupBox("Disk Cache") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Size", value: session.cache.map {
                    ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)
                } ?? "—")
                if let directory = session.cache?.directory {
                    Text(directory).font(.caption).textSelection(.enabled)
                }
                if let error = session.cacheError {
                    Text(L10n.text(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Open Cache Folder") {
                        guard let path = session.cache?.directory else { return }
                        store.system.reveal(URL(fileURLWithPath: path, isDirectory: true))
                    }
                    .disabled(session.cache?.canClear != true)
                    Spacer()
                    Button("Clear Cache", role: .destructive) {
                        session.clearCache()
                    }
                    .disabled(session.cache?.canClear != true || session.isClearingCache)
                }
            }
            .padding(8)
        }
    }

    private func settingToggle(_ title: String, keyPath: WritableKeyPath<BackgroundMapSettings, Bool>) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { session.settings[keyPath: keyPath] },
            set: { session.settings[keyPath: keyPath] = $0 }))
    }

    private func genericToggle(_ title: String, route: String) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { editor.fields["RasBackgroundMaps/" + route] == "true" },
            set: { editor.set("RasBackgroundMaps/" + route, String($0)) }))
    }

    private func sourceName(_ id: String) -> String {
        switch id {
        case "osm": L10n.text("Open Street Map")
        case "satellite": L10n.text("Satellite Imagery")
        case "shadedRelief": L10n.text("USGS Hillshade")
        default: id
        }
    }

    private func symbol(for state: String) -> String {
        switch state {
        case "available": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "outsideCoverage": "location.slash"
        default: "circle"
        }
    }
}
