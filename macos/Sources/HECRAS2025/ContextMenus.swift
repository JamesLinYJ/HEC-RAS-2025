import SwiftUI

// Presentation of the original ContextCollection tree. Source adapters supply
// its ordered elements after MakesSense/visibility evaluation, including the
// original flatten/separator/header flags and CanExecute state.
struct ContextMenuEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        case action
        case toggle(Bool)
        case group([ContextMenuEntry], flatten: Bool, separate: Bool, showHeader: Bool)
        case separator
    }
    struct Prompt: Sendable {
        let title: String
        let message: String
        let label: String
        var initialValue = ""
        var allowsEmpty = false
    }
    let id: String
    let title: String
    let kind: Kind
    var localizeTitle = true
    var enabled = true
    var help = ""
    var destructive = false
    var prompt: Prompt? = nil
    var confirmation: String? = nil
    @MainActor var displayTitle: String { localizeTitle ? L10n.text(title) : title }
}
enum ContextMenuValue: Sendable { case text(String), toggle(Bool) }

struct ContextMenuContents: View {
    let entries: [ContextMenuEntry]
    let invoke: (ContextMenuEntry, ContextMenuValue?) -> Void
    var body: some View {
        ForEach(entries) { item in
            switch item.kind {
            case .separator: Divider()
            case .action:
                Button(item.displayTitle, role: item.destructive ? .destructive : nil) { invoke(item, nil) }
                    .disabled(!item.enabled).help(L10n.text(item.help))
            case .toggle(let checked):
                Toggle(item.displayTitle, isOn: Binding(get: { checked }, set: { invoke(item, .toggle($0)) }))
                    .disabled(!item.enabled).help(L10n.text(item.help))
            case .group(let children, let flatten, let separate, let showHeader):
                if flatten {
                    if separate { Divider() }
                    if showHeader {
                        Section(item.displayTitle) { ContextMenuContents(entries: children, invoke: invoke) }.disabled(!item.enabled)
                    } else { ContextMenuContents(entries: children, invoke: invoke).disabled(!item.enabled) }
                } else {
                    Menu(item.displayTitle) { ContextMenuContents(entries: children, invoke: invoke) }.disabled(!item.enabled)
                }
            }
        }
    }
}
