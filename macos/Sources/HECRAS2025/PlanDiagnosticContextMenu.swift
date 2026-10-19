import Foundation
import RASWorkspaceCore
import SwiftUI

/// Native counterpart to the source object's message flyout. Only model kinds
/// with a source-registered layer menu get catalog actions; flow-area and
/// boundary-line diagnostics retain their exact Open navigation only.
@MainActor
struct PlanDiagnosticContextMenuItems: View {
    @ObservedObject var store: WorkspaceStore
    let target: PlanDiagnosticTarget
    let isTargetCurrent: @MainActor (PlanDiagnosticTarget) -> Bool
    let onNavigate: @MainActor (PlanDiagnosticTarget) -> Bool
    let onCompute: (@MainActor (PlanDiagnosticTarget) async -> Bool)?

    private var managedKind: CatalogManagedModelKind? {
        switch target.kind {
        case "plan": .plan
        case "geometry": .geometry
        case "boundaryCondition": .boundaryCondition
        default: nil
        }
    }

    private var modelAsset: ProjectAsset? {
        guard let managedKind,
              let expectedPath = CatalogModelActionTarget.canonicalPath(target.assetPath) else { return nil }
        let matches = store.assets.filter { asset in
            asset.isModelFile && asset.section == managedKind.projectSection
                && CatalogModelActionTarget.canonicalPath(asset.url.path) == expectedPath
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private var canStartCatalogAction: Bool {
        store.document?.url != nil
            && store.modelProvider is BackendModelProvider
            && modelAsset != nil
            && isTargetCurrent(target)
            && !store.isRunningProjectTool
            && !store.isSavingAll
            && !store.isClosingTab
            && !store.isOpeningProject
            && !store.hasBusyModelEditors
    }

    private var canFocus: Bool {
        modelAsset != nil && isTargetCurrent(target)
            && !store.isClosingTab && !store.isOpeningProject
    }

    var body: some View {
        Button(L10n.text(openTitle), systemImage: "arrow.up.right.square") {
            _ = onNavigate(target)
        }

        if target.kind == "plan" || target.kind == "geometry" {
            Button(L10n.text("Focus"), systemImage: "scope") {
                Task { await focusExactModel() }
            }
            .disabled(!canFocus)
        }

        if target.kind == "plan" || target.kind == "geometry" {
            Button(L10n.text(target.kind == "plan" ? "Compute" : "Compute Property Tables"),
                   systemImage: target.kind == "plan" ? "play.fill" : "tablecells") {
                guard let onCompute else { return }
                Task { _ = await onCompute(target) }
            }
            .disabled(!canStartCatalogAction || onCompute == nil)
        }

        if target.kind == "geometry" {
            Button(L10n.text("View Prepare Log"), systemImage: "doc.text.magnifyingglass") {
                _ = onNavigate(target)
            }
            .disabled(!canFocus)
        }

        if target.kind == "plan" {
            Button(L10n.text("Export Plan…"), systemImage: "square.and.arrow.up") {
                Task { await exportExactPlan() }
            }
            .disabled(!canStartCatalogAction)
        }

        if managedKind != nil {
            Divider()
            if target.kind == "boundaryCondition" {
                Button(L10n.text("Clone"), systemImage: "plus.square.on.square") {
                    Task { await present(.clone) }
                }
                .disabled(!canStartCatalogAction)
            } else {
                Button(L10n.text("Duplicate"), systemImage: "plus.square.on.square") {
                    Task { await present(.duplicate) }
                }
                .disabled(!canStartCatalogAction)
            }
            Button(L10n.text("Rename…"), systemImage: "pencil") {
                Task { await present(.rename) }
            }
            .disabled(!canStartCatalogAction)
        }
    }

    private var openTitle: String {
        switch target.kind {
        case "plan": "Open Plan"
        case "geometry": "Open Geometry"
        case "flowArea": "Open 2D Flow Area"
        case "boundaryCondition": "Open Boundary Conditions"
        case "boundaryConditionLine": "Open Boundary Condition Line"
        default: "Open"
        }
    }

    private func focusExactModel() async {
        guard canFocus, let asset = modelAsset,
              await PlanDiagnosticFileFingerprint.matches(target),
              canFocus,
              store.assets.first(where: { $0.id == asset.id }) == asset else {
            reportStaleTarget()
            return
        }
        let previousError = store.errorMessage
        let opened: Bool
        switch target.kind {
        case "plan": opened = await runPlanFocusInNewView(assetID: asset.id, store: store)
        case "geometry": opened = await runGeometryFocusInNewView(assetID: asset.id, store: store)
        default: opened = false
        }
        if !opened, store.errorMessage == previousError { reportStaleTarget() }
    }

    private func exportExactPlan() async {
        guard target.kind == "plan", canStartCatalogAction, let asset = modelAsset,
              await PlanDiagnosticFileFingerprint.matches(target),
              canStartCatalogAction,
              store.assets.first(where: { $0.id == asset.id }) == asset else {
            reportStaleTarget()
            return
        }
        store.select(asset)
        store.activeTool = .planExport
    }

    private func present(_ intent: CatalogModelActionIntent) async {
        guard let kind = managedKind, canStartCatalogAction, let asset = modelAsset,
              await PlanDiagnosticFileFingerprint.matches(target),
              canStartCatalogAction,
              store.assets.first(where: { $0.id == asset.id }) == asset,
              let presentation = CatalogModelActionPresentation.make(asset: asset,
                  kind: kind, intent: intent, caller: .inspector, store: store,
                  expectedAssetRevision: target.assetRevision) else {
            reportStaleTarget()
            return
        }
        store.catalogModelActionPresentation = presentation
    }

    private func reportStaleTarget() {
        store.errorMessage = L10n.text("The diagnostic source file changed. Refresh the diagnostic and try again.")
    }
}
