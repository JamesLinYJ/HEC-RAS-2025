import SwiftUI

struct BoundaryLineNameField: View {
    let line: BoundaryLinePresentation
    @ObservedObject var session: ModelEditorSession

    private var currentName: String { session.boundaryLineName(line) }
    private var activeHydraulicPayload: BoundaryPayloadPresentation? {
        line.payloads.first(where: { $0.isHydraulic && session.boundaryPayloadEnabled($0) })
            ?? line.activeHydraulicPayloadID.flatMap { id in line.payloads.first { $0.id == id && $0.isHydraulic } }
    }
    private var activeHydraulicIcon: String? {
        guard let activeHydraulicPayload,
              let variable = session.fields[activeHydraulicPayload.scope + "/PayloadDetails/Variable"] else { return nil }
        return switch variable {
        case "Stage": "water.waves"
        case "Flow": "chart.xyaxis.line"
        case "Normal Depth": "triangle"
        case "StageVelocityVelocity": "arrow.up.and.down"
        default: "water.waves"
        }
    }
    private var hasDuplicateName: Bool {
        session.boundaryLines?.lines.contains { other in
            other.id != line.id && session.boundaryLineName(other).caseInsensitiveCompare(currentName) == .orderedSame
        } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let nameField = line.nameField {
                HStack(spacing: 8) {
                    if let activeHydraulicIcon {
                        Image(systemName: activeHydraulicIcon)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("Active Hydraulic Condition"))
                    }
                    TextField(
                        L10n.text("Name"),
                        text: Binding(
                            get: { session.boundaryLineName(line) },
                            set: { session.set(nameField.storageID, $0) }
                        )
                    )
                    .disabled(!session.canEdit || session.isBusy)
                }
            }
            if hasDuplicateName {
                Label(
                    L10n.text("A boundary condition line already has this name."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BoundaryConditionLineQuickEditPicker: View {
    let line: BoundaryLinePresentation
    @ObservedObject var session: ModelEditorSession
    let onCreate: () -> Void
    let onViewPayload: (String) -> Void

    private var hydraulicPayloads: [BoundaryPayloadPresentation] {
        line.payloads.filter(\.isHydraulic)
    }

    private var activePayload: BoundaryPayloadPresentation? {
        hydraulicPayloads.first(where: { session.boundaryPayloadEnabled($0) })
            ?? line.activeHydraulicPayloadID.flatMap { id in hydraulicPayloads.first { $0.id == id } }
    }

    private var activePayloadSelection: Binding<String> {
        Binding(
            get: { activePayload?.id ?? "" },
            set: { id in
                guard let payload = hydraulicPayloads.first(where: { $0.id == id }) else { return }
                session.setBoundaryPayloadEnabled(true, lineID: line.id, payloadID: payload.id)
                session.selectBoundaryPayload(payload.id, lineID: line.id)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("Quick Edit"), systemImage: "slider.horizontal.3")
                .font(.headline)

            BoundaryLineNameField(line: line, session: session)

            Picker(L10n.text("Active Hydraulic Condition"), selection: activePayloadSelection) {
                Text(L10n.text("Select a hydraulic condition")).tag("")
                ForEach(hydraulicPayloads) { payload in
                    Text(session.boundaryPayloadName(payload)).tag(payload.id)
                }
            }
            .disabled(hydraulicPayloads.isEmpty || !session.canEdit || session.isBusy)

            if let activePayload {
                GroupBox(L10n.text("Active Payload")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.boundaryPayloadName(activePayload))
                            .font(.body.weight(.medium))
                        Text(L10n.text(activePayload.friendlyName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let variable = session.fields[activePayload.scope + "/PayloadDetails/Variable"] {
                            LabeledContent(L10n.text("Variable"), value: variable)
                        }
                        Button(L10n.text("View Payload")) {
                            onViewPayload(activePayload.id)
                        }
                        .disabled(session.isBusy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("No hydraulic conditions available"),
                    systemImage: "water.waves"
                )
                .frame(height: 100)
            }

            Button(action: onCreate) {
                Label(L10n.text("Add Payload"), systemImage: "plus")
            }
            .disabled(line.newPayload == nil || !session.canEdit || session.isBusy)
        }
        .padding(16)
        .frame(minWidth: 340, idealWidth: 380)
    }
}

struct FunctionalPayloadEditor: View {
    let payload: BoundaryPayloadPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(L10n.text("Formula")) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.text("Functional"), systemImage: "function")
                        .font(.headline)
                    Text(L10n.text("A function maps location and time to an output value."))
                        .foregroundStyle(.secondary)
                    Divider()
                    Label(
                        L10n.text("The original payload has no expression field or formula editor."),
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            LabeledContent(
                L10n.text("Status"),
                value: L10n.text("Functional payload evaluation is not implemented by the source model.")
            )
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("functional-payload-editor-\(payload.id)")
    }
}

struct FunctionalPayloadCreationNotice: View {
    var body: some View {
        GroupBox(L10n.text("Functional")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("A function maps location and time to an output value."))
                    .foregroundStyle(.secondary)
                Text(L10n.text("The original payload has no expression field or formula editor."))
                Text(L10n.text("Functional payload creation is not implemented by the source editor."))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
