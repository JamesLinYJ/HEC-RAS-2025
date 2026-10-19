import SwiftUI

struct GlobalSymbologyPage: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: VectorSymbologySession
    private struct Group: Identifiable {
        let id: String
        let title: String
        var options: [VectorStyleOption]
    }
    private var groups: [Group] {
        var result: [Group] = []
        for option in session.options {
            let name = option.layerName ?? "Symbology Settings"
            var copy = option; copy.conditionsEnabled = false
            if let index = result.firstIndex(where: { $0.id == name }) { result[index].options.append(copy) }
            else { result.append(Group(id: name, title: name, options: [copy])) }
        }
        return result
    }
    private var context: VectorSymbologyContext {
        .init(projectSessionID: store.globalSymbologySessionID, mapID: MapState.projectMapID, assetID: nil, scope: .global)
    }
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 400), alignment: .top), count: geometry.size.width >= 820 ? 2 : 1), alignment: .leading, spacing: 16) {
                        ForEach(groups) { group in
                            GroupBox {
                                VStack(spacing: 12) { ForEach(group.options) { VectorPropertyRow(option: $0, session: session) } }.padding(8)
                            } label: { Text(L10n.text(group.title)) }
                        }
                    }.padding(16)
                }.overlay {
                    if session.busy { ProgressView() }
                    else if store.vectorSymbologyProvider == nil {
                        ContentUnavailableView(L10n.text("Vector Symbology Unavailable"), systemImage: "exclamationmark.icloud", description: Text(L10n.text("The source vector symbology provider is not connected.")))
                    }
                    else if groups.isEmpty { ContentUnavailableView(L10n.text("No Style Definitions"), systemImage: "paintpalette") }
                }
            }
            Divider()
            HStack {
                if let issue = session.validationIssue { Text(L10n.text(issue)).foregroundStyle(.red).font(.caption) }
                else if let error = session.error { Text(VectorSymbologyErrorPresentation.text(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                else if !session.canEdit && !groups.isEmpty { Label(L10n.text("Read Only"), systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.text("Reset All Defaults")) { session.resetAllGlobalDefaults() }.disabled(!session.canEdit || session.busy || session.validationIssue != nil)
            }.padding(12)
        }
        .disabled(session.busy || !session.canEdit)
        .task {
            // Settings owns one cached session so switching tabs or closing the
            // window cannot cancel an already submitted global preference edit.
            if session.options.isEmpty && !session.hasPendingGlobalChanges {
                await session.load(context: context, provider: store.vectorSymbologyProvider)
            }
            session.didUpdate = { _, _ in store.mapRevision += 1 }
        }
    }
}
