import SwiftUI
import RASWorkspaceCore

// CatalogFilePathControl uses a path action. Resolve foreign Windows paths
// through the same explicit project mappings as the rest of the native UI.
struct CatalogFilePath: View {
    let title: String
    let path: String
    @ObservedObject var store: WorkspaceStore
    private var file: URL? {
        guard let directory = store.document?.directory, !path.isEmpty else { return nil }
        return try? PlatformPaths.resolve(path, relativeTo: directory, mappings: store.pathMappings)
    }
    var body: some View {
        LabeledContent(LocalizedStringKey(title)) {
            HStack {
                Text(verbatim: path.isEmpty ? "—" : path).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                Button { if let file { store.system.reveal(file) } } label: { Label("Show in Finder", systemImage: "folder") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(file == nil).help("Show in Finder")
            }
        }
    }
}

// Original RadioButtonInputTextPropertyItem binds a shared enum string and
// displays the associated input only when that radio option is selected.
struct RadioInputGroup: View {
    let fields: [SourceEditorField]
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var route: String { fields.first.map { $0.scoped($0.radioBinding?.route ?? "") } ?? "" }
    private var selection: Binding<String> {
        Binding(
            get: { hasMixedInput ? "" : (session.fields[route] ?? "") },
            set: { value in
                session.set(route, value)
                fields.forEach { session.clearMixedFlag($0.mixedBy.map($0.scoped)) }
            }
        )
    }
    private var hasMixedInput: Bool {
        fields.contains { field in
            field.mixedBy.flatMap { session.fields[field.scoped($0)] }?.lowercased() == "true"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Size Function", selection: selection) {
                ForEach(fields) { field in
                    Text(LocalizedStringKey(field.title)).tag(field.radioBinding?.value ?? "")
                }
            }.pickerStyle(.radioGroup)
                .disabled(!session.canEdit || session.isBusy || session.loadingSelection || store.isSavingAll)
                .accessibilityLabel(Text("Size Function"))
            ForEach(fields.filter { $0.radioBinding?.value == selection.wrappedValue }) { field in
                SourceField(field: field, session: session, store: store)
            }
            if selection.wrappedValue.isEmpty || hasMixedInput {
                Text("Mixed values").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// Preserve the source's Default -> Editing -> Default interaction using
// native text controls. Changes remain live, as in the original two-way Text.
struct DoubleClickText: View {
    let title: String
    @Binding var text: String
    let prompt: Text
    var suggestions: [String] = []
    var showsLabel = true
    var isMixed = false
    var onValueChange: ((String) -> Void)? = nil
    @State private var editing = false
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?
    private var editingBinding: Binding<String> {
        Binding(get: { text }, set: { value in
            text = value
            onValueChange?(value)
        })
    }
    var body: some View {
        Group {
            if showsLabel { LabeledContent(LocalizedStringKey(title)) { editor } }
            else { editor }
        }.onChange(of: editing) { _, active in focused = active }
    }
    @ViewBuilder private var editor: some View {
        if editing {
            TextField(LocalizedStringKey(title), text: editingBinding, selection: $selection, prompt: prompt)
                .labelsHidden().focused($focused)
                .textInputSuggestions {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in Text(verbatim: suggestion).textInputCompletion(suggestion) }
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard editing, focused, !Task.isCancelled else { return }
                    selection = TextSelection(range: text.startIndex..<text.endIndex)
                }
                .onSubmit { endEditing() }
                .onExitCommand { endEditing() }
                .onChange(of: focused) { _, active in if !active { editing = false } }
        } else {
            Group {
                if isMixed {
                    Text(L10n.text("Mixed values"))
                } else {
                    Text(verbatim: text.isEmpty ? "—" : text)
                }
            }
                .foregroundStyle(isMixed ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: showsLabel ? .trailing : .leading)
                .contentShape(Rectangle()).onTapGesture(count: 2, perform: beginEditing)
                .contextMenu { Button("Rename", action: beginEditing) }
                .accessibilityHint(Text("Double-click to edit"))
                .accessibilityAction(.default, beginEditing)
        }
    }
    private func beginEditing() { editing = true }
    private func endEditing() { focused = false; editing = false; selection = nil }
}
