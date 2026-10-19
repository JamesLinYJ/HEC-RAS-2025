import SwiftUI

// Keep the source collection and tabular surface visible when the model
// adapter has no collection metadata. The disabled controls reflect the
// original collection actions without pretending that they can mutate data.
struct BoundarySpatialInputPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Input Layers").font(.headline)
                Spacer()
                ControlGroup {
                    Button {} label: { Label("Import", systemImage: "plus") }
                    Button {} label: { Label("Move Up", systemImage: "arrow.up") }
                    Button {} label: { Label("Move Down", systemImage: "arrow.down") }
                    Button {} label: { Label("View All", systemImage: "eye") }
                }
                .labelStyle(.iconOnly)
                .disabled(true)
            }
            List {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Spatial input list is unavailable", systemImage: "square.3.layers.3d")
                    Text("The model source did not provide an editable input collection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            .listStyle(.inset)
        }
        .padding(12)
        .frame(minHeight: 140)
    }
}

private struct EmptyBoundarySpatialRow: Identifiable {
    let id = UUID()
}

struct BoundarySpatialPlaceholderTable: View {
    var body: some View {
        VStack(spacing: 0) {
            Table([EmptyBoundarySpatialRow]()) {
                TableColumn("Spatial Data") { _ in EmptyView() }
            }
            Label("The model source did not provide spatial table columns or rows.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }
}
