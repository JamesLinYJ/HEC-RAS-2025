import SwiftUI

/// Native window content for the retained DebugOpenStableChannelWindowAction.
/// The workspace owns the session so dirty state follows the project lifecycle
/// when this window is closed or reopened.
struct StableChannelDebugWindow: View {
    @ObservedObject var session: StableChannelDebugSession

    private let solveTargets = ["Depth", "Width", "Slope", "ParticleSize"]
    private let solutionMethods = ["Lane", "Shields", "UserDefinedMobility"]

    var body: some View {
        Group {
            if session.hasOpened {
                editor
            } else {
                VStack(spacing: 12) {
                    if session.isBusy {
                        ProgressView(L10n.text("Loading Stable Channel design…"))
                    } else {
                        ContentUnavailableView(L10n.text("Stable Channel design unavailable"),
                            systemImage: "water.waves",
                            description: Text(L10n.text(session.message ?? "Open a project before opening Stable Channel.")))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 680)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading,
                              spacing: 10) {
                        ForEach(StableChannelDebugField.mainInputs, id: \.self) { field in
                            numericField(field)
                        }
                    }
                    Picker(L10n.text("Solution Method"), selection: Binding(
                        get: { session.state?.solutionMethod ?? "Lane" },
                        set: session.setSolutionMethod
                    )) {
                        ForEach(solutionMethods, id: \.self) { method in
                            Text(L10n.text(method == "UserDefinedMobility" ? "User Defined Mobility" : method)).tag(method)
                        }
                    }
                    .disabled(session.isBusy)
                } header: {
                    Text(L10n.text("Tractive Force"))
                }

                ForEach(StableChannelDebugPart.allCases, id: \.self) { part in
                    partSection(part)
                }

                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading,
                              spacing: 8) {
                        ForEach(solveTargets, id: \.self) { target in
                            Toggle(L10n.text(target == "ParticleSize" ? "Particle Size" : target), isOn: Binding(
                                get: { session.selectedSolveFor.contains(target) },
                                set: { selected in
                                    guard selected != session.selectedSolveFor.contains(target) else { return }
                                    session.toggleSolveFor(target)
                                }
                            ))
                            .disabled(session.isBusy)
                        }
                    }
                    Text(L10n.text("Select exactly two variables to solve for."))
                        .font(.caption)
                        .foregroundStyle(session.selectedSolveFor.count == 2 ? Color.secondary : Color.orange)
                } header: {
                    Text(L10n.text("Solve For"))
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .navigationTitle(L10n.text("Stable Channel"))
    }

    private func partSection(_ part: StableChannelDebugPart) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading,
                      spacing: 10) {
                ForEach(StableChannelDebugField.numericInputs(for: part), id: \.self) { field in
                    numericField(field)
                }
            }
            TractiveForceEquationDropDown(
                equation: Binding(
                    get: { session.state?.partState(for: part)?.equation ?? "Strickler" },
                    set: { session.setEquation($0, for: part) }
                ),
                isEnabled: !session.isBusy
            )
        } header: {
            Text(L10n.text(part.titleKey))
        }
    }

    private func numericField(_ field: StableChannelDebugField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(L10n.text(field.titleKey), text: session.textBinding(for: field))
                .textFieldStyle(.roundedBorder)
                .disabled(session.isBusy)
                .accessibilityLabel(L10n.text(field.titleKey))
                .accessibilityIdentifier("stable-channel-\(field.rawValue)")
            if session.invalidFields.contains(field) {
                Text(L10n.text("Enter a finite number."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let source = session.source {
                HStack(spacing: 8) {
                    Image(systemName: source.inMemory ? "memorychip" : "internaldrive")
                    Text(L10n.text(source.inMemory ? "In-memory Stable Channel draft" : "Saved Stable Channel design"))
                    if let path = source.designPath {
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
            HStack {
                if let message = session.message {
                    Label(L10n.text(message), systemImage: session.messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(session.messageIsError ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button(L10n.text("Discard")) { session.discard() }
                    .disabled(session.isBusy || !session.isDirty)
                if session.source?.inMemory == false {
                    Button(L10n.text("Save")) { Task { _ = await session.save() } }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!session.canSave)
                }
                Button(L10n.text("Compute")) { Task { await session.compute() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!session.canCompute)
            }
        }
        .padding(14)
    }
}
