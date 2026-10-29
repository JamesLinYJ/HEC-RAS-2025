import SwiftUI

struct StreamModeTinOptionsView: View {
    @ObservedObject var session: StreamModeTinRenderSession
    let availableProfileIndices: [Int]
    @Binding var selectedProfileIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.text("TIN Plot Options"))
                    .font(.headline)
                Spacer()
                if case .loadingOptions = session.state {
                    ProgressView().controlSize(.small)
                } else if case .rendering = session.state {
                    ProgressView().controlSize(.small)
                }
            }

            if session.pendingCleanupCount > 0 {
                HStack(spacing: 6) {
                    Label(String(format: L10n.text("%lld TIN cleanup actions are pending"),
                        Int64(session.pendingCleanupCount)), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(L10n.text("Retry cleanup")) {
                        Task { await session.retryPendingReleases() }
                    }
                    .controlSize(.small)
                }
            }

            if session.asset == nil {
                Text(L10n.text("Select a streamed TIN profile to edit its source plot options."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = session.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if availableProfileIndices.count > 1 {
                Picker(L10n.text("TIN Profile"), selection: $selectedProfileIndex) {
                    ForEach(availableProfileIndices, id: \.self) { index in
                        Text(String(format: L10n.text("TIN profile %lld"), Int64(index)))
                            .tag(index)
                    }
                }
                .help(L10n.text("Choose a visible profile from the retained source Banded TIN layer."))
            }

            ForEach(session.options) { option in
                optionControl(option)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func optionControl(_ option: StreamModeTinOptionDescriptor) -> some View {
        if option.valueKind == "boolean" {
            Toggle(L10n.text(option.label), isOn: Binding(
                get: { option.currentValue == "true" },
                set: { session.setBooleanOption(option.name, isOn: $0) }))
                .disabled(!option.isEnabled || session.asset == nil)
                .help(L10n.text(option.description))
                .toggleStyle(.checkbox)
        } else if option.valueKind == "enum" {
            Picker(L10n.text(option.label), selection: Binding(
                get: { option.currentValue },
                set: { session.setEnumOption(option.name, value: $0) })) {
                    ForEach(option.enumValues, id: \.self) { value in
                        Text(L10n.text(value)).tag(value)
                    }
                }
                .disabled(!option.isEnabled || session.asset == nil)
                .help(L10n.text(option.description))
        }

        switch option.sourceEffect {
        case "storedWithoutSurfacePaint":
            Text(L10n.text("The retained source stores this option but does not paint the streamed TIN surface."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        case "sourceReportsNotImplemented":
            Text(L10n.text("The retained source renderer does not implement this label."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        default:
            EmptyView()
        }
    }
}
