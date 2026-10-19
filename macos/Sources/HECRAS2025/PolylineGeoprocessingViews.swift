import SwiftUI

struct PolylineGeoprocessingSettingsView: View {
    @ObservedObject var session: PolylineMapEditingSession
    let operation: PolylineGeoprocessOperation
    @Environment(\.dismiss) private var dismiss
    @State private var epsilon = "1"
    @State private var windowSize = "3"
    @State private var iterations = "2"

    private var canApply: Bool {
        guard session.canEditSelectedLine, session.selectedLineSupportsXYGeoprocessing else { return false }
        switch operation {
        case .filter:
            guard let value = Double(epsilon) else { return false }
            return value.isFinite && value > 0
        case .smooth:
            guard let window = Int(windowSize), let passes = Int(iterations) else { return false }
            return (1...101).contains(window) && (0...20).contains(passes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(operation == .filter ? L10n.text("Filter Polyline") : L10n.text("Smooth Polyline"))
                .font(.title3.weight(.semibold))
            Form {
                switch operation {
                case .filter:
                    TextField(L10n.text("Tolerance (map units)"), text: $epsilon)
                        .monospacedDigit()
                    Text(L10n.text("Douglas-Peucker tolerance; larger values remove more intermediate vertices."))
                        .font(.caption).foregroundStyle(.secondary)
                case .smooth:
                    TextField(L10n.text("Window Size"), text: $windowSize).monospacedDigit()
                    TextField(L10n.text("Passes"), text: $iterations).monospacedDigit()
                    Text(L10n.text("The retained moving average keeps endpoints and adjusts the window to an odd value of at least 3."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !session.selectedLineSupportsXYGeoprocessing {
                    Label(L10n.text(session.selectedLineGeoprocessingRestriction ?? "Filter and Smooth require a finite, nonzero 2D line. Z/M lines are preserved unchanged."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isBusy)
                Button(operation == .filter ? L10n.text("Apply Filter") : L10n.text("Apply Smooth")) {
                    Task {
                        let succeeded: Bool
                        switch operation {
                        case .filter:
                            succeeded = await session.filterSelectedLine(epsilon: Double(epsilon) ?? .nan)
                        case .smooth:
                            succeeded = await session.smoothSelectedLine(windowSize: Int(windowSize) ?? 0,
                                iterations: Int(iterations) ?? -1)
                        }
                        if succeeded { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || session.isBusy)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(session.isBusy)
    }
}
