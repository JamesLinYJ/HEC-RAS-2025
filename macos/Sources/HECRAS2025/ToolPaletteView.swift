import SwiftUI

// ToolRichFlyoutControl shows each original face/name/description and a
// separate options cog. Groups retain their last selected descendant face.
struct ToolPaletteView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: ToolPaletteSession
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Map Tools").font(.headline); Spacer(); if session.busy { ProgressView().controlSize(.small) } }.padding(16)
            if let error = session.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            HStack {
                Button { session.chooseNavigation("select"); close() } label: { Label("Select", systemImage: "cursorarrow") }
                Button { session.chooseNavigation("Map.Pan"); close() } label: { Label("Pan", systemImage: "hand.draw") }
                Spacer()
            }.buttonStyle(.bordered).padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(session.nodes) { node in
                        PaletteNodeView(node: node, session: session, picked: close)
                    }
                }.padding(12)
            }
            Divider()
            HStack {
                Button { Task { await store.undoMapEdit() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(store.mapInteractionProvider == nil)
                Button { Task { await store.redoMapEdit() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(store.mapInteractionProvider == nil)
                Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.padding(12)
        }.frame(width: 430, height: 570).controlSize(.regular).labelStyle(.titleAndIcon)
            .disabled(session.busy)
    }
}

private struct PaletteNodeView: View {
    let node: MapToolNode
    @ObservedObject var session: ToolPaletteSession
    let picked: () -> Void
    @State private var expanded = true
    @State private var optionsOpen = false
    private var face: PaletteToolDescriptor? { session.face(node) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let children = node.children {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children) { child in PaletteNodeView(node: child, session: session, picked: picked) }
                } label: {
                    HStack {
                        Button {
                            if let face { Task { await session.activate(face); if session.currentToolID == face.id { picked() } } }
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: face?.symbol ?? "square.stack.3d.up").frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.text(node.title ?? face?.name ?? "Map Tools")).font(.subheadline.weight(.semibold))
                                    if let description = face?.description, !description.isEmpty {
                                        Text(MapToolText.help(description)).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                if let face, session.currentToolID == face.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!node.available || face == nil)
                        Spacer()
                        if node.experimental { Text("Experimental").font(.caption).foregroundStyle(.orange) }
                        if let face, !face.optionIDs.isEmpty { cog(face) }
                    }
                }.padding(8)
            } else if let face {
                HStack(alignment: .top, spacing: 8) {
                    Button { Task { await session.activate(face); if session.currentToolID == face.id { picked() } } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: face.symbol).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.text(face.name)).font(.subheadline.weight(.medium))
                                Text(MapToolText.help(face.description)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if session.currentToolID == face.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!node.available)
                    if !face.optionIDs.isEmpty { cog(face) }
                }.padding(8)
            }
        }
        .popover(isPresented: $optionsOpen, arrowEdge: .trailing) {
            if let face { ToolOptionsView(tool: face, session: session) }
        }
    }
    private func cog(_ tool: PaletteToolDescriptor) -> some View {
        Button { optionsOpen.toggle() } label: { Label("Tool Options", systemImage: "gearshape") }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help(L10n.text("Tool Options") + " · " + L10n.text(tool.name))
    }
}

struct ToolOptionsView: View {
    let tool: PaletteToolDescriptor
    @ObservedObject var session: ToolPaletteSession
    private var options: [ToolOptionDefinition] { tool.optionIDs.compactMap(session.option) }
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.text(tool.name)).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider()
            Form {
                ForEach(options) { definition in ToolOptionField(definition: definition, session: session) }
            }.formStyle(.grouped)
        }.frame(width: 380, height: min(max(CGFloat(options.count) * 74 + 60, 170), 600))
            .controlSize(.regular).labelStyle(.titleAndIcon)
    }
}

private struct ToolOptionField: View {
    let definition: ToolOptionDefinition
    @ObservedObject var session: ToolPaletteSession
    @FocusState private var editingTextField: Bool
    @State private var draft = ""
    @State private var invalid = false
    private var value: String { session.value(definition) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch definition.kind {
            case "bool":
                Toggle(L10n.text(definition.label), isOn: Binding(get: { value == "true" }, set: { session.set(definition, raw: String($0)) }))
            case "enum":
                Picker(L10n.text(definition.label), selection: Binding(get: { value }, set: { session.set(definition, raw: $0) })) {
                    ForEach(definition.choices) { choice in Text(L10n.text(choice.title)).tag(choice.id) }
                }
            case "int":
                HStack {
                    TextField(L10n.text(definition.label), text: $draft).focused($editingTextField).onSubmit(commit)
                    Stepper(L10n.text(definition.label), value: Binding(get: { Int(value) ?? 0 }, set: { session.set(definition, raw: String($0)); draft = value }), in: Int(Int32.min)...Int(Int32.max))
                        .labelsHidden().fixedSize()
                }
            default: TextField(L10n.text(definition.label), text: $draft).focused($editingTextField).onSubmit(commit)
            }
            if invalid { Text(definition.kind == "int" ? L10n.text("Enter a 32-bit integer.") : L10n.text("Enter a finite number.")).font(.caption).foregroundStyle(.red) }
        }
        .help(MapToolText.help(definition.description))
        .onAppear { draft = value }
        .onChange(of: draft) { _, _ in if !["bool", "enum"].contains(definition.kind) { commit() } }
        .onChange(of: value) { _, newValue in
            if !editingTextField { draft = newValue; invalid = false }
        }
        .onChange(of: editingTextField) { _, focused in
            if !focused, invalid { draft = value; invalid = false }
        }
    }
    private func commit() { invalid = !session.set(definition, raw: draft) }
}
