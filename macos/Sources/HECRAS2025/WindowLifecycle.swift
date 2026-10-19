import AppKit
import SwiftUI

@MainActor
final class WorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !terminationPending, !store.isSavingAll, !store.isClosingTab, !store.isRunningProjectTool, !store.hasBusyModelEditors else { return .terminateCancel }
        if store.globalSymbologySession.hasPendingGlobalChanges || store.attributeTableSessions.values.contains(where: { $0.modified || $0.isBusy }) {
            terminationPending = true
            Task {
                var saved = true
                for session in Array(store.attributeTableSessions.values) {
                    if !(await session.confirmClose(using: store.system)) { saved = false; break }
                }
                if saved { saved = await store.globalSymbologySession.flushGlobalChanges() }
                if saved, store.hasUnsavedChanges {
                    switch closeDecision(store) {
                    case .cancel: saved = false
                    case .discard: break
                    case .save: saved = await store.saveAll()
                    }
                }
                terminationPending = false; sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        guard store.hasUnsavedChanges else { return .terminateNow }
        switch closeDecision(store) {
        case .cancel: return .terminateCancel
        case .discard: return .terminateNow
        case .save:
            terminationPending = true
            Task {
                let saved = await store.saveAll()
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // The retained application releases its per-project .lock only when
        // the project is actually closing. AppKit reaches this callback after
        // the save/discard/cancel gate has allowed termination.
        store?.streamMode.cancel()
        store?.releaseProjectOpenLock()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store?.showWorkspace?(); return true
    }
}

@MainActor
private enum CloseDecision { case save, cancel, discard }
@MainActor
private func closeDecision(_ store: WorkspaceStore, name: String? = nil) -> CloseDecision {
    let alert = NSAlert()
    alert.messageText = L10n.format("Save changes to %@?", name ?? store.document?.name ?? L10n.text("Project"))
    alert.informativeText = L10n.text("Your unsaved edits will be lost if you close without saving.")
    alert.addButton(withTitle: L10n.text("Save")); alert.addButton(withTitle: L10n.text("Cancel")); alert.addButton(withTitle: L10n.text("Discard"))
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .save
    case .alertThirdButtonReturn: return .discard
    default: return .cancel
    }
}

struct WindowLifecycleGuard: NSViewRepresentable {
    let store: WorkspaceStore
    var session: ModelEditorSession? = nil
    var beforeClose: (@MainActor () async -> Bool)? = nil
    var guardsProjectChanges = true
    func makeCoordinator() -> Coordinator { Coordinator(store: store, session: session, beforeClose: beforeClose, guardsProjectChanges: guardsProjectChanges) }
    func makeNSView(context: Context) -> LifecycleView {
        let view = LifecycleView(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ view: LifecycleView, context: Context) {
        context.coordinator.beforeClose = beforeClose; context.coordinator.guardsProjectChanges = guardsProjectChanges
        view.installDelegate()
    }
    @MainActor final class LifecycleView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); installDelegate() }
        func installDelegate() {
            guard let window, let coordinator, window.delegate !== coordinator else { return }
            if let previous = window.delegate as? Coordinator {
                coordinator.originalDelegate = previous.originalDelegate
            } else { coordinator.originalDelegate = window.delegate }
            window.delegate = coordinator
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        weak var store: WorkspaceStore?
        weak var session: ModelEditorSession?
        // SwiftUI owns window lifecycle callbacks. Forward every callback except
        // the close guard, rather than replacing its delegate behavior.
        nonisolated(unsafe) var originalDelegate: (any NSWindowDelegate)?
        var beforeClose: (@MainActor () async -> Bool)?
        var guardsProjectChanges: Bool
        init(store: WorkspaceStore, session: ModelEditorSession?, beforeClose: (@MainActor () async -> Bool)?, guardsProjectChanges: Bool) {
            self.store = store; self.session = session; self.beforeClose = beforeClose; self.guardsProjectChanges = guardsProjectChanges
        }
        private var closePending = false
        private var allowNextClose = false
        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            originalDelegate?.responds(to: selector) == true ? originalDelegate : super.forwardingTarget(for: selector)
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowNextClose { allowNextClose = false; return originalDelegate?.windowShouldClose?(sender) ?? true }
            guard !closePending, store?.isSavingAll != true, store?.isClosingTab != true, store?.isRunningProjectTool != true else { return false }
            guard session?.isBusy != true,
                  !(session == nil && guardsProjectChanges && store?.hasBusyModelEditors == true) else { return false }
            if let beforeClose {
                closePending = true
                Task {
                    let saved = await beforeClose(); closePending = false
                    if saved { allowNextClose = true; sender.performClose(nil) }
                }
                return false
            }
            if guardsProjectChanges, let store, session?.hasUnsavedEditorChanges ?? store.hasUnsavedChanges {
                switch closeDecision(store, name: session?.modelName) {
                case .cancel: return false
                case .discard:
                    if let session {
                        session.discardEdits()
                        guard !session.hasUnsavedEditorChanges, !session.isBusy else { return false }
                    }
                    else { guard store.discardAllChanges() else { return false } }
                case .save:
                    closePending = true
                    Task {
                        let saved: Bool
                        if let session { saved = await session.saveLoadedModel() }
                        else { saved = await store.saveAll() }
                        closePending = false
                        if saved { allowNextClose = true; sender.performClose(nil) }
                    }
                    return false
                }
            }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            if let session { store?.unregisterEditor(session) }
            else if guardsProjectChanges { store?.cancelProjectOpening(); store?.streamMode.cancel() }
            originalDelegate?.windowWillClose?(notification)
        }
    }
}
