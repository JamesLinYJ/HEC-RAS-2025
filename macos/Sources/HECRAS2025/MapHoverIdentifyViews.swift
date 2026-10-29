import SwiftUI

struct MapHoverIdentifyTooltip: View {
    let entries: [MapHoverIdentifyEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.prefix(6))) { entry in
                Text(displayLabel(for: entry))
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entries.count > 6 {
                Text("+\(entries.count - 6)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 270, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func displayLabel(for entry: MapHoverIdentifyEntry) -> String {
        if entry.kind == "modelVector", entry.valueType == "boundaryConditionLine",
           let ordinal = entry.elementIndex {
            return L10n.format("BCL: %d", ordinal)
        }
        guard entry.kind == "mesh", let valueType = entry.valueType,
              let elementIndex = entry.elementIndex else { return entry.label }
        let elementName: String
        switch valueType {
        case "Cell": elementName = L10n.text("Cell")
        case "Face": elementName = L10n.text("Face")
        case "FacePoint": elementName = L10n.text("Node")
        default: return entry.label
        }
        return "\(elementName)[\(elementIndex)]"
    }
}

struct MapHoverIdentifyOverlay: View {
    @ObservedObject var session: MapHoverIdentifySession

    var body: some View {
        GeometryReader { proxy in
            if !session.entries.isEmpty,
               let point = session.screenPoint {
                let width: CGFloat = 270
                let estimatedHeight = min(190, CGFloat(session.entries.prefix(6).count) * 29 + 20)
                let x = min(max(8, point.x + 15), max(8, proxy.size.width - width - 8))
                let y = min(max(8, point.y + 15), max(8, proxy.size.height - estimatedHeight - 8))
                MapHoverIdentifyTooltip(entries: session.entries)
                    .position(x: x + width / 2, y: y + estimatedHeight / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(false)
    }
}
