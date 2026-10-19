import SwiftUI
import RASWorkspaceCore

// Native counterpart to the map result/analysis menu. Actions delegate to the
// existing tool routes so their real provider and save boundaries stay intact.
struct MapAnalysisMenu: View {
    @ObservedObject var store: WorkspaceStore

    private var resultAsset: ProjectAsset? {
        if let selected = store.selectedAsset, selected.section == .results { return selected }
        return store.assets.first { $0.section == .results }
    }

    var body: some View {
        Menu {
            Section("Results") {
                Button("Open Result Editor", systemImage: "chart.xyaxis.line") { openResults() }
                    .disabled(resultAsset == nil)
            }
            Section("Analysis") {
                tool(.rasterCalculator, symbol: "function")
                tool(.crossSection, symbol: "chart.xyaxis.line")
                tool(.arcPoints, symbol: "point.topleft.down.to.point.bottomright.curvepath")
            }
            Section("Map Display") {
                tool(.contours, symbol: "water.waves")
                tool(.hillshade, symbol: "sun.max")
                tool(.vectorLabels, symbol: "textformat")
            }
            Section("Symbology") {
                tool(.rasterSymbology, symbol: "paintpalette")
                tool(.vectorSymbology, symbol: "point.3.connected.trianglepath.dotted")
            }
        } label: {
            Label("Map Analysis", systemImage: "slider.horizontal.3")
        }
        .disabled(!store.hasProject)
    }

    @ViewBuilder private func tool(_ kind: ToolKind, symbol: String) -> some View {
        Button { store.activeTool = kind } label: {
            Label { Text(verbatim: kind.localizedTitle) } icon: { Image(systemName: symbol) }
        }
            .disabled(kind.requiresProject && !store.hasProject)
    }

    private func openResults() {
        guard let resultAsset else { return }
        store.openEditor(.result, assetID: resultAsset.id)
    }
}

// A compact inspector for the selected result context. It displays only
// properties supplied by the renamed source tree adapter.
struct MapAnalysisResultInspector: View {
    @ObservedObject var store: WorkspaceStore

    private var resultNode: LayerTreeNode? {
        guard let node = store.layerTreeSession.selectedNode,
              ["ResultNodeVM", "MultiResultNodeVM", "ResultNode", "MultiResultNode", "ObservableResult"].contains(node.sourceClass)
        else { return nil }
        return node
    }

    var body: some View {
        Group {
            if let resultNode {
                ResultLayerPropertiesView(node: resultNode)
            } else {
                ContentUnavailableView(
                    "Select a Result Layer",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Result details appear when the source result tree provides a selected result layer."))
            }
        }
    }
}

// The source profile slider selects an actual provider index. Playback buttons
// stay disabled when no profile provider is connected.
struct MapAnalysisProfileTimeline: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ProfileTimeline(mapState: store.activeMapState)
    }
}
