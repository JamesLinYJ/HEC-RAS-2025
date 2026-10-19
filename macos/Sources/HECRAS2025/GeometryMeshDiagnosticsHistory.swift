import Foundation
import SwiftUI
import RASWorkspaceCore

struct GeometryMeshDiagnosticsScope: Equatable, Sendable {
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let geometryName: String
    let assetID: String
    let visualizationRevision: String?
}

struct GeometryMeshDiagnosticsPreferencesCapture: Sendable {
    let operationID: UUID
    let generation: Int
    let scope: GeometryMeshDiagnosticsScope
    let settings: MeshDiagnosticsVisualSettings
}

struct GeometryMeshDiagnosticsHistoryEntry: Identifiable, Sendable {
    let id: String
    let assetID: String
    let geometryName: String
    let createdAt: Date
    let result: Bool
    let messages: [GeometryMeshDiagnosticMessage]
    let topology: GeometryTopologyMapData
}

/// The original MeshDiagnostics control is a singleton with a transient
/// newest-first history. This mirrors its three-entry lifetime in memory and
/// does not persist diagnostics into either HDF or the visualization file.
@MainActor
final class GeometryMeshDiagnosticsHistory: ObservableObject {
    static let shared = GeometryMeshDiagnosticsHistory()

    @Published private(set) var entries: [GeometryMeshDiagnosticsHistoryEntry] = []
    @Published private(set) var selectedEntryID: String?

    var selectedEntry: GeometryMeshDiagnosticsHistoryEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    private init() {}

    func record(_ event: GeometryMeshDiagnosticHistoryEvent, assetID: String, geometryName: String) {
        guard !event.messages.isEmpty else {
            clear()
            return
        }
        guard !entries.contains(where: { $0.id == event.operationID }) else { return }
        entries.insert(GeometryMeshDiagnosticsHistoryEntry(
            id: event.operationID,
            assetID: assetID,
            geometryName: geometryName,
            createdAt: .now,
            result: event.result,
            messages: event.messages,
            topology: event.topology), at: 0)
        if entries.count > 3 { entries.removeLast(entries.count - 3) }
        selectedEntryID = event.operationID
    }

    func select(_ id: String?) {
        guard id == nil || entries.contains(where: { $0.id == id }) else { return }
        selectedEntryID = id
    }

    func clear() {
        entries.removeAll()
        selectedEntryID = nil
    }
}

/// Historical source coordinates and topology are intentionally shown from
/// the selected OperationResult snapshot. They remain meaningful when the
/// active geometry has since changed. Paths are stroked only, so region holes
/// remain empty and no fill is inferred from topology rings.
struct GeometryMeshDiagnosticHistoryMap: View {
    let topology: GeometryTopologyMapData
    let selectedValues: [GeometryMeshDiagnosticValue]

    private var selectedFeatureIDs: Set<String> {
        Set(selectedValues.compactMap(\.targetFeatureID))
    }
    private var selectedSelectionIDs: Set<String> {
        Set(selectedValues.flatMap(\.selectionIDs))
    }
    private var selectedCoordinates: [GeometryTopologyCoordinate] {
        selectedValues.compactMap(\.coordinate)
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let projection = GeometryMeshMapProjection(extent: topology.extent,
                    size: size, zoom: 1, pan: .zero) else { return }
                for feature in topology.features {
                    let isSelected = selectedFeatureIDs.contains(feature.id)
                        || feature.selectionIDs.contains(where: selectedSelectionIDs.contains)
                    let color: Color = isSelected ? .orange : feature.featureKind == "arc" ? .blue : .secondary
                    let width: CGFloat = isSelected ? 3 : 1
                    if feature.geometryType == "point" {
                        guard let point = feature.paths.first?.first else { continue }
                        let center = projection.project(point)
                        let dot = Path(ellipseIn: CGRect(x: center.x - (isSelected ? 5 : 3),
                            y: center.y - (isSelected ? 5 : 3), width: isSelected ? 10 : 6,
                            height: isSelected ? 10 : 6))
                        context.fill(dot, with: .color(color))
                    } else {
                        let path = GeometryMeshMapPath.make(paths: feature.paths,
                            projection: projection, close: feature.geometryType == "polygon")
                        context.stroke(path, with: .color(color), lineWidth: width)
                    }
                }
                for coordinate in selectedCoordinates {
                    let point = projection.project(coordinate)
                    var cross = Path()
                    cross.move(to: CGPoint(x: point.x - 7, y: point.y))
                    cross.addLine(to: CGPoint(x: point.x + 7, y: point.y))
                    cross.move(to: CGPoint(x: point.x, y: point.y - 7))
                    cross.addLine(to: CGPoint(x: point.x, y: point.y + 7))
                    context.stroke(cross, with: .color(.red), lineWidth: 2)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .overlay {
                if topology.extent == nil || topology.features.isEmpty {
                    ContentUnavailableView("No source geometry coordinates are available.",
                        systemImage: "map", description: Text("The source OperationResult has no drawable topology snapshot."))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(minHeight: 150, idealHeight: 190)
        .accessibilityLabel(L10n.text("Selected OperationResult source topology"))
    }
}

struct GeometryMeshDiagnosticsHistoryPanel: View {
    @ObservedObject var history: GeometryMeshDiagnosticsHistory
    @State private var selectedValueID: String?

    private var selection: Binding<String?> {
        Binding(get: { history.selectedEntryID }, set: { history.select($0) })
    }
    private var entry: GeometryMeshDiagnosticsHistoryEntry? { history.selectedEntry }
    private var selectedValues: [GeometryMeshDiagnosticValue] {
        guard let selectedValueID, let entry else { return [] }
        return entry.messages.flatMap(\.values).filter { $0.id == selectedValueID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Mesh diagnostics history"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text(history.entries.count.formatted())
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L10n.text("Clear history"), systemImage: "xmark.circle") { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if history.entries.isEmpty {
                ContentUnavailableView(L10n.text("No mesh diagnostic history yet."),
                    systemImage: "text.magnifyingglass",
                    description: Text(L10n.text("Generate a mesh to inspect the source OperationResult.")))
            } else {
                HSplitView {
                    List(selection: selection) {
                        ForEach(history.entries) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.geometryName).font(.headline).lineLimit(1)
                                HStack {
                                    Text(item.createdAt.formatted(date: .omitted, time: .standard))
                                    Text(L10n.format("%@ messages", item.messages.count.formatted()))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .tag(item.id)
                        }
                    }
                    .frame(minWidth: 175, idealWidth: 220, maxWidth: 270)

                    if let entry {
                        detail(entry)
                            .frame(minWidth: 340, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(L10n.text("Select a diagnostic result."),
                            systemImage: "cursorarrow.click")
                            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(.background)
        .onChange(of: history.selectedEntryID) { _, _ in selectedValueID = nil }
    }

    private func detail(_ entry: GeometryMeshDiagnosticsHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(L10n.text("Source OperationResult"),
                        systemImage: entry.result ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.result ? .green : .orange)
                        .font(.headline)
                    Spacer()
                    Text(entry.createdAt.formatted(date: .omitted, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(entry.geometryName).font(.title3.weight(.semibold))
                GeometryMeshDiagnosticHistoryMap(topology: entry.topology, selectedValues: selectedValues)

                ForEach(entry.messages) { message in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(message.severity.isEmpty ? L10n.text("Unknown severity") : L10n.text(message.severity))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            Text(message.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(message.evaluatedMessage)
                            .textSelection(.enabled)
                        if !message.values.isEmpty {
                            Divider()
                            Text(L10n.text("Named values")).font(.subheadline.weight(.medium))
                            ForEach(message.values) { value in
                                Button {
                                    selectedValueID = selectedValueID == value.id ? nil : value.id
                                } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(value.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        Spacer(minLength: 8)
                                        Text(valueDisplay(value)).font(.callout.monospacedDigit())
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                        if value.targetFeatureID != nil || value.coordinate != nil {
                                            Image(systemName: selectedValueID == value.id ? "scope" : "map")
                                                .foregroundStyle(selectedValueID == value.id ? .orange : .secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.text("Select this source value to highlight it on the history map."))
                                .disabled(value.targetFeatureID == nil && value.coordinate == nil)
                            }
                        }
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 1))
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func valueDisplay(_ value: GeometryMeshDiagnosticValue) -> String {
        if let coordinate = value.coordinate {
            return "\(coordinate.x.formatted()), \(coordinate.y.formatted())"
        }
        if !value.selectionIDs.isEmpty {
            return value.value + " · " + value.selectionIDs.joined(separator: ", ")
        }
        return value.value
    }
}
