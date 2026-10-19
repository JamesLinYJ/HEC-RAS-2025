import AppKit
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

private func samePlanAnalysisPath(_ lhs: String, _ rhs: String) -> Bool {
    SourceFilePaths.canonical(URL(fileURLWithPath: lhs)) ==
        SourceFilePaths.canonical(URL(fileURLWithPath: rhs))
}

struct PlanAnalysisProjectCapture: Codable, Hashable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXml: String
    let projectXmlFingerprint: String
    var coreLayerContext: CoreLayerRequestContext? = nil

    @MainActor
    static func capture(store: WorkspaceStore) -> (projectSessionID: UUID, capture: Self)? {
        guard let document = store.document, let url = document.url,
              let revision = document.sourceRevision else { return nil }
        let xml = document.editorXML(overridingDescription: store.descriptionDraft)
        return (store.projectSessionID, .init(projectPath: SourceFilePaths.canonical(url),
            projectRevision: revision, projectXml: xml, projectXmlFingerprint: fingerprint(xml),
            coreLayerContext: store.captureCoreLayerRequestContext()))
    }

    static func fingerprint(_ xml: String) -> String {
        SHA256.hash(data: Data(xml.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func isCurrent(in store: WorkspaceStore, projectSessionID: UUID) -> Bool {
        guard store.projectSessionID == projectSessionID,
              let document = store.document, let url = document.url,
              let revision = document.sourceRevision,
              samePlanAnalysisPath(SourceFilePaths.canonical(url), projectPath),
              revision.caseInsensitiveCompare(projectRevision) == .orderedSame else { return false }
        let currentXML = document.editorXML(overridingDescription: store.descriptionDraft)
        return currentXML == projectXml &&
            store.captureCoreLayerRequestContext()?.identityToken == coreLayerContext?.identityToken &&
            Self.fingerprint(currentXML).caseInsensitiveCompare(
            projectXmlFingerprint) == .orderedSame
    }
}

/// Captures one exact Plan editor. The ordered time-window edits remain ordered
/// through JSON serialization; they are never flattened into field setters.
struct PlanAnalysisPlanDraft: Codable, Equatable, Hashable, Sendable {
    let assetPath: String
    let revision: String
    let fields: [String: String]
    let sourceState: String?
    let planTimeWindowEdits: [PlanTimeWindowEdit]
    let editorID: UUID
    let ownerContextID: String

    @MainActor
    static func capture(session: ModelEditorSession) -> Self? {
        guard let context = session.currentPlanComputeContext(),
              context.asset.section == .plans,
              let revision = context.edits.sourceRevision,
              !revision.isEmpty else { return nil }
        return .init(assetPath: SourceFilePaths.canonical(context.asset.url), revision: revision,
            fields: context.edits.fields, sourceState: context.edits.sourceState,
            planTimeWindowEdits: context.edits.planTimeWindowEdits,
            editorID: session.id, ownerContextID: context.id)
    }

    @MainActor
    func isCurrent(in store: WorkspaceStore) -> Bool {
        guard let session = store.editorSession(editorID),
              let context = session.currentPlanComputeContext(),
              context.id == ownerContextID,
              context.asset.section == .plans,
              samePlanAnalysisPath(SourceFilePaths.canonical(context.asset.url), assetPath),
              let revision = context.edits.sourceRevision,
              revision.caseInsensitiveCompare(self.revision) == .orderedSame else { return false }
        return context.edits.fields == fields && context.edits.sourceState == sourceState
            && context.edits.planTimeWindowEdits == planTimeWindowEdits
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(assetPath); hasher.combine(revision); hasher.combine(sourceState)
        hasher.combine(editorID); hasher.combine(ownerContextID)
        for edit in planTimeWindowEdits {
            hasher.combine(edit.id); hasher.combine(edit.fieldID); hasher.combine(edit.value)
        }
        for key in fields.keys.sorted() { hasher.combine(key); hasher.combine(fields[key]) }
    }
}

struct PlanDiffWindowRoute: Codable, Hashable, Identifiable {
    let id: UUID
    let projectSessionID: UUID
    let capture: PlanAnalysisProjectCapture
    let planDrafts: [PlanAnalysisPlanDraft]
    var initialLeftOptionID: String? = nil
    var initialRightOptionID: String? = nil

    init(id: UUID = UUID(), projectSessionID: UUID, capture: PlanAnalysisProjectCapture,
         planDrafts: [PlanAnalysisPlanDraft] = [], initialLeftOptionID: String? = nil,
         initialRightOptionID: String? = nil) {
        self.id = id; self.projectSessionID = projectSessionID; self.capture = capture
        self.planDrafts = planDrafts; self.initialLeftOptionID = initialLeftOptionID
        self.initialRightOptionID = initialRightOptionID
    }
}

struct ReadyToRunMatrixWindowRoute: Codable, Hashable, Identifiable {
    let id: UUID
    let projectSessionID: UUID
    let capture: PlanAnalysisProjectCapture
    let planDrafts: [PlanAnalysisPlanDraft]
    let initialPlanPath: String

    init(id: UUID = UUID(), projectSessionID: UUID, capture: PlanAnalysisProjectCapture,
         planDrafts: [PlanAnalysisPlanDraft] = [], initialPlanPath: String) {
        self.id = id; self.projectSessionID = projectSessionID; self.capture = capture
        self.planDrafts = planDrafts
        self.initialPlanPath = SourceFilePaths.canonical(URL(fileURLWithPath: initialPlanPath))
    }
}

private struct PlanAnalysisDiffOptionsRequest: Encodable, Sendable { let capture: PlanAnalysisProjectCapture }
private struct PlanAnalysisDiffOption: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let planPath: String
    let planRevision: String
    let resultPath: String?
    let resultRevision: String?
    let displayName: String
    let headerName: String
    let isResult: Bool
}
private struct PlanAnalysisDiffOptionsResponse: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let options: [PlanAnalysisDiffOption]
}
private struct PlanAnalysisDiffRequest: Encodable, Sendable {
    let capture: PlanAnalysisProjectCapture
    let leftOptionID: String
    let rightOptionID: String
    let planDrafts: [PlanAnalysisPlanDraft]
}
private struct PlanAnalysisDiffRow: Decodable, Identifiable, Equatable, Sendable {
    let key: String
    let leftValue: String
    let rightValue: String
    let differs: Bool
    var id: String { key }
}
private struct PlanAnalysisDiffResponse: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let left: PlanAnalysisDiffOption
    let right: PlanAnalysisDiffOption
    let rows: [PlanAnalysisDiffRow]
}

@MainActor
private final class PlanDiffWindowModel: ObservableObject {
    @Published var options: [PlanAnalysisDiffOption] = []
    @Published var selectedLeftID: String?
    @Published var selectedRightID: String?
    @Published var differencesOnly = false
    @Published private(set) var response: PlanAnalysisDiffResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let store: WorkspaceStore
    let route: PlanDiffWindowRoute
    private let client: BackendProcessClient
    private var generation = 0

    init(store: WorkspaceStore, client: BackendProcessClient, route: PlanDiffWindowRoute) {
        self.store = store; self.client = client; self.route = route
    }

    var isCurrent: Bool {
        route.capture.isCurrent(in: store, projectSessionID: route.projectSessionID)
            && store.arePlanAnalysisDraftsCurrent(route.planDrafts)
    }
    var canRead: Bool { isCurrent && !store.isRunningProjectTool && !store.isSavingAll
        && !store.isOpeningProject && !store.isClosingTab && !store.hasBusyModelEditors }
    var rows: [PlanAnalysisDiffRow] {
        guard let response else { return [] }
        return differencesOnly ? response.rows.filter(\.differs) : response.rows
    }

    func load() async {
        generation += 1; let requestedGeneration = generation
        guard canRead else { errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window."); return }
        isLoading = true; errorMessage = nil; response = nil
        do {
            let loaded = try await client.request("plan.analysis.diffOptions",
                parameters: PlanAnalysisDiffOptionsRequest(capture: route.capture),
                as: PlanAnalysisDiffOptionsResponse.self)
            guard requestedGeneration == generation, canRead,
                  loaded.projectXmlFingerprint.caseInsensitiveCompare(route.capture.projectXmlFingerprint) == .orderedSame else {
                if requestedGeneration == generation { isLoading = false; errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window.") }
                return
            }
            options = loaded.options
            selectedLeftID = route.initialLeftOptionID.flatMap { id in options.contains(where: { $0.id == id }) ? id : nil }
                ?? options.first?.id
            selectedRightID = route.initialRightOptionID.flatMap { id in options.contains(where: { $0.id == id }) ? id : nil }
                ?? options.dropFirst().first?.id ?? options.first?.id
            isLoading = false
            await compare()
        } catch {
            guard requestedGeneration == generation else { return }
            isLoading = false; errorMessage = L10n.text(error.localizedDescription)
        }
    }

    func compare() async {
        generation += 1; let requestedGeneration = generation
        guard canRead, let left = selectedLeftID, let right = selectedRightID else {
            response = nil
            if options.count >= 2 && !canRead { errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window.") }
            return
        }
        isLoading = true; errorMessage = nil; response = nil
        do {
            let compared = try await client.request("plan.analysis.diff",
                parameters: PlanAnalysisDiffRequest(capture: route.capture,
                    leftOptionID: left, rightOptionID: right, planDrafts: route.planDrafts),
                as: PlanAnalysisDiffResponse.self)
            guard requestedGeneration == generation, canRead,
                  compared.left.id == left, compared.right.id == right else {
                if requestedGeneration == generation { isLoading = false; errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window.") }
                return
            }
            response = compared; isLoading = false
        } catch {
            guard requestedGeneration == generation else { return }
            isLoading = false; errorMessage = L10n.text(error.localizedDescription)
        }
    }
}

@MainActor
struct PlanDiffWindow: View {
    @ObservedObject var store: WorkspaceStore
    let client: BackendProcessClient
    let route: PlanDiffWindowRoute?
    @StateObject private var model: PlanDiffWindowModel

    init(store: WorkspaceStore, client: BackendProcessClient, route: PlanDiffWindowRoute?) {
        self.store = store; self.client = client; self.route = route
        _model = StateObject(wrappedValue: PlanDiffWindowModel(store: store, client: client,
            route: route ?? PlanDiffWindowRoute(projectSessionID: store.projectSessionID,
                capture: PlanAnalysisProjectCapture(projectPath: "", projectRevision: "", projectXml: "", projectXmlFingerprint: ""))))
    }

    var body: some View {
        Group {
            if let route, route.projectSessionID == store.projectSessionID {
                content
            } else {
                ContentUnavailableView(L10n.text("Plan comparison is unavailable"),
                    systemImage: "arrow.left.arrow.right",
                    description: Text(L10n.text("Open the owning project and Plan editor again.")))
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: route?.id) { await model.load() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                optionPicker(title: "Left Plan", selection: $model.selectedLeftID)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                optionPicker(title: "Right Plan", selection: $model.selectedRightID)
                Toggle(L10n.text("Differences only"), isOn: $model.differencesOnly)
                    .toggleStyle(.checkbox)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if model.isLoading {
                ProgressView(L10n.text("Comparing Plan properties…"))
            }
            if let response = model.response {
                HStack {
                    Text(L10n.text("Property")).font(.caption.weight(.semibold)).frame(width: 190, alignment: .leading)
                    Text(response.left.headerName).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(response.right.headerName).font(.caption.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 8)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            HStack(alignment: .top, spacing: 0) {
                                Text(row.key).font(.system(.body, design: .monospaced))
                                    .frame(width: 190, alignment: .leading)
                                valueCell(row.leftValue, differs: row.differs)
                                valueCell(row.rightValue, differs: row.differs)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
                .overlay {
                    if model.rows.isEmpty {
                        ContentUnavailableView(L10n.text("No differences"), systemImage: "checkmark.circle")
                    }
                }
            } else if model.options.count < 2 && !model.isLoading && model.errorMessage == nil {
                ContentUnavailableView(L10n.text("At least two Plan options are required"),
                    systemImage: "arrow.left.arrow.right", description: Text(L10n.text("No comparable Plan and Result-backed Plan choices are available.")))
            }
        }
        .padding(14)
        .onChange(of: model.selectedLeftID) { _, _ in Task { await model.compare() } }
        .onChange(of: model.selectedRightID) { _, _ in Task { await model.compare() } }
    }

    private func optionPicker(title: String, selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text(title), selection: selection) {
                ForEach(model.options) { option in Text(option.displayName).tag(Optional(option.id)) }
            }
            .labelsHidden().frame(minWidth: 185)
            .disabled(model.options.isEmpty || model.isLoading)
        }
    }

    private func valueCell(_ value: String, differs: Bool) -> some View {
        Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(differs ? Color.accentColor.opacity(0.13) : Color.clear)
    }
}

private struct PlanMatrixOptionsRequest: Encodable, Sendable {
    let capture: PlanAnalysisProjectCapture
    let selectedPlanPath: String?
    let planDraft: PlanAnalysisPlanDraft?
}
private struct PlanMatrixPlanChoice: Decodable, Identifiable, Equatable, Sendable {
    let planPath: String
    let revision: String
    let name: String
    var id: String { planPath }
}
private struct PlanMatrixValueChoice: Decodable, Identifiable, Equatable, Sendable {
    let value: String
    let label: String
    let selected: Bool
    let removable: Bool
    var id: String { value }
}
private struct PlanMatrixProperty: Decodable, Identifiable, Equatable, Sendable {
    let propertyName: String
    let displayName: String
    let valueType: String
    let inputHint: String
    let isClosedSet: Bool
    let initialValues: [PlanMatrixValueChoice]
    var id: String { propertyName }
}
private struct PlanMatrixRule: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let reason: String
    var enabled: Bool
    var id: String { name }
}
private struct PlanMatrixOptionsResponse: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let plans: [PlanMatrixPlanChoice]
    let selectedPlanPath: String?
    let outputDirectory: String?
    let properties: [PlanMatrixProperty]
    let rules: [PlanMatrixRule]
}
private struct PlanMatrixAxisSelection: Codable, Equatable, Sendable {
    let propertyName: String
    let values: [String]
}
private struct PlanMatrixPreviewRequest: Encodable, Sendable {
    let capture: PlanAnalysisProjectCapture
    let planPath: String
    let planRevision: String
    let planDraft: PlanAnalysisPlanDraft?
    let axes: [PlanMatrixAxisSelection]
    let enabledRuleNames: [String]
    let collapseIrrelevant: Bool
    let outputDirectory: String?
}
private struct PlanMatrixAssignment: Decodable, Identifiable, Sendable {
    let propertyName: String
    let displayName: String
    let value: String
    let isRelevant: Bool
    let irrelevantReason: String?
    var id: String { propertyName }
}
private struct PlanMatrixCombination: Decodable, Identifiable, Sendable {
    let index: Int
    let label: String
    let filename: String
    let isExcluded: Bool
    let isCollapsed: Bool
    let exclusionReason: String?
    let assignments: [PlanMatrixAssignment]
    var id: Int { index }
}
private struct PlanMatrixPreviewResponse: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let planPath: String
    let planRevision: String
    let inspectionID: String
    let outputDirectory: String
    let writeCount: Int
    let summary: String
    let hint: String
    let combinations: [PlanMatrixCombination]
}
private struct PlanMatrixEmitRequest: Encodable, Sendable {
    let preview: PlanMatrixPreviewRequest
    let inspectionID: String
    let overwrite: Bool
    let nameEmbeddedPlan: Bool
    let writeManifest: Bool
}
private struct PlanMatrixEmitFile: Decodable, Identifiable, Sendable {
    let filename: String
    let status: String
    let filePath: String?
    let fileSizeBytes: Int64
    let message: String?
    var id: String { filename }
}
private struct PlanMatrixEmitResponse: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let planPath: String
    let planRevision: String
    let inspectionID: String
    let outputDirectory: String
    let state: String
    let written: Int
    let skipped: Int
    let failed: Int
    let excluded: Int
    let wasCancelled: Bool
    let wasAborted: Bool
    let abortReason: String?
    let manifestPath: String?
    let sourcesStillCurrent: Bool
    let files: [PlanMatrixEmitFile]
}
private struct PlanMatrixCancelControl: Encodable, Sendable { let type = "cancel" }

@MainActor
private func localizedPlanMatrixError(_ source: String) -> String {
    let axisPrefix = "Axis \""
    let axisSuffix = "\" has no values selected."
    if source.hasPrefix(axisPrefix), source.hasSuffix(axisSuffix) {
        let start = source.index(source.startIndex, offsetBy: axisPrefix.count)
        let end = source.index(source.endIndex, offsetBy: -axisSuffix.count)
        return L10n.format("Axis \"%@\" has no values selected.", L10n.text(String(source[start..<end])))
    }
    guard let separator = source.range(of: ": ") else { return L10n.text(source) }
    let property = String(source[..<separator.lowerBound])
    let detail = String(source[separator.upperBound...])
    guard !property.isEmpty else { return L10n.text(source) }
    return L10n.text(property) + ": " + localizedPlanMatrixErrorDetail(detail)
}

@MainActor
private func localizedPlanMatrixErrorDetail(_ source: String) -> String {
    let prefix = "Allowed values: "
    guard source.hasPrefix(prefix) else { return L10n.text(source) }
    let values = source.dropFirst(prefix.count)
    let hasPeriod = values.hasSuffix(".")
    let body = String(hasPeriod ? values.dropLast() : values)
    let localizedValues = body.split(separator: ",").map {
        L10n.text(String($0).trimmingCharacters(in: .whitespaces))
    }.joined(separator: ", ")
    return L10n.text("Allowed values:") + " " + localizedValues + (hasPeriod ? "." : "")
}

@MainActor
private final class ReadyToRunMatrixWindowModel: ObservableObject {
    @Published var options: PlanMatrixOptionsResponse?
    @Published var selectedPlanPath: String?
    @Published var outputDirectory = ""
    @Published var selectedPropertyName: String?
    @Published var pendingValue = ""
    @Published var pendingValuePropertyName: String?
    @Published var selectedValues: [String: [String]] = [:]
    @Published var rules: [PlanMatrixRule] = []
    @Published var collapseIrrelevant = true
    @Published var overwrite = false
    @Published var nameEmbeddedPlan = true
    @Published var writeManifest = true
    @Published private(set) var preview: PlanMatrixPreviewResponse?
    @Published private(set) var previewRequest: PlanMatrixPreviewRequest?
    @Published private(set) var emitResponse: PlanMatrixEmitResponse?
    @Published private(set) var progress: BackendProgressUpdate?
    @Published private(set) var isLoading = false
    @Published private(set) var isEmitting = false
    @Published private(set) var isCancelRequested = false
    @Published private(set) var errorMessage: String?

    let store: WorkspaceStore
    let route: ReadyToRunMatrixWindowRoute
    private let client: BackendProcessClient
    private var operation: BackendDuplexOperation<PlanMatrixCancelControl,
        BackendProgressUpdate, PlanMatrixEmitResponse>?
    private var emitLeaseID: UUID?
    private var generation = 0

    init(store: WorkspaceStore, client: BackendProcessClient, route: ReadyToRunMatrixWindowRoute) {
        self.store = store; self.client = client; self.route = route
    }

    var isCurrent: Bool {
        route.capture.isCurrent(in: store, projectSessionID: route.projectSessionID)
            && store.arePlanAnalysisDraftsCurrent(route.planDrafts)
    }
    var canRead: Bool { isCurrent && !store.isRunningProjectTool && !store.isSavingAll
        && !store.isOpeningProject && !store.isClosingTab && !store.hasBusyModelEditors }
    var selectedPlan: PlanMatrixPlanChoice? {
        options?.plans.first(where: { $0.planPath == selectedPlanPath })
    }
    var axisProperties: [PlanMatrixProperty] {
        guard let properties = options?.properties else { return [] }
        return properties.filter { selectedValues[$0.propertyName] != nil }
    }
    var availableProperties: [PlanMatrixProperty] {
        (options?.properties ?? []).filter { selectedValues[$0.propertyName] == nil }
    }

    func loadOptions(_ path: String? = nil) async {
        generation += 1; let requestedGeneration = generation
        guard canRead else { errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window."); return }
        isLoading = true; errorMessage = nil; emitResponse = nil; invalidatePreview()
        let requestedPath = path ?? selectedPlanPath ?? route.initialPlanPath
        let draft = draft(for: requestedPath)
        guard draft == nil || draft?.isCurrent(in: store) == true else {
            isLoading = false; errorMessage = L10n.text("The Plan editor changed. Reopen this analysis window."); return
        }
        do {
            let loaded = try await client.request("plan.r2rMatrix.options",
                parameters: PlanMatrixOptionsRequest(capture: route.capture,
                    selectedPlanPath: requestedPath, planDraft: draft), as: PlanMatrixOptionsResponse.self)
            guard requestedGeneration == generation, canRead,
                  loaded.projectXmlFingerprint.caseInsensitiveCompare(route.capture.projectXmlFingerprint) == .orderedSame else {
                if requestedGeneration == generation { isLoading = false; errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window.") }
                return
            }
            options = loaded
            selectedPlanPath = loaded.selectedPlanPath
            outputDirectory = loaded.outputDirectory ?? ""
            let ruleStates = Dictionary(rules.map { ($0.name, $0.enabled) },
                                        uniquingKeysWith: { _, latest in latest })
            rules = loaded.rules.map { rule in
                PlanMatrixRule(name: rule.name, reason: rule.reason,
                    enabled: ruleStates[rule.name] ?? rule.enabled)
            }
            let availablePropertyNames = Set(loaded.properties.map(\.propertyName))
            selectedValues = selectedValues.filter { availablePropertyNames.contains($0.key) }
            isLoading = false
        } catch {
            guard requestedGeneration == generation else { return }
            isLoading = false; errorMessage = localizedPlanMatrixError(error.localizedDescription)
        }
    }

    func selectPlan(_ path: String) { selectedPlanPath = path; Task { await loadOptions(path) } }
    func addAxis(_ property: PlanMatrixProperty) {
        guard selectedValues[property.propertyName] == nil else { return }
        selectedValues[property.propertyName] = property.initialValues.filter(\.selected).map(\.value)
        selectedPropertyName = nil; pendingValue = ""; pendingValuePropertyName = nil; invalidatePreview()
    }
    func removeAxis(_ name: String) { selectedValues.removeValue(forKey: name); invalidatePreview() }
    func setValue(_ value: String, for name: String, enabled: Bool) {
        var values = selectedValues[name] ?? []
        if enabled {
            if !values.contains(value) { values.append(value) }
        } else { values.removeAll { $0 == value } }
        selectedValues[name] = values; invalidatePreview()
    }
    func addPendingValue() {
        guard let name = axisProperties.first(where: { $0.propertyName == pendingValuePropertyName })?.propertyName,
              let property = options?.properties.first(where: { $0.propertyName == name }), !property.isClosedSet else { return }
        let text = pendingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let values = property.valueType == "String" ? [text] :
            text.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for value in values { setValue(value, for: name, enabled: true) }
        pendingValue = ""
    }
    func setRule(_ name: String, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.name == name }) else { return }
        rules[index].enabled = enabled; invalidatePreview()
    }
    func setOutputDirectory(_ value: String) { outputDirectory = value; invalidatePreview() }
    func invalidatePreview() { preview = nil; previewRequest = nil }
    func toggleCollapse(_ value: Bool) { collapseIrrelevant = value; invalidatePreview() }
    func toggleOverwrite(_ value: Bool) { overwrite = value }
    func toggleNameEmbeddedPlan(_ value: Bool) { nameEmbeddedPlan = value }
    func toggleManifest(_ value: Bool) { writeManifest = value }
    func reportDirectoryOpenError(_ error: Error) { errorMessage = localizedPlanMatrixError(error.localizedDescription) }

    private func draft(for path: String) -> PlanAnalysisPlanDraft? {
        route.planDrafts.first { samePlanAnalysisPath($0.assetPath, path) }
    }

    private func makePreviewRequest() -> PlanMatrixPreviewRequest? {
        guard let selected = selectedPlan else { return nil }
        let axes = axisProperties.map { PlanMatrixAxisSelection(propertyName: $0.propertyName,
            values: selectedValues[$0.propertyName] ?? []) }
        return .init(capture: route.capture, planPath: selected.planPath,
            planRevision: selected.revision, planDraft: draft(for: selected.planPath), axes: axes,
            enabledRuleNames: rules.filter(\.enabled).map(\.name),
            collapseIrrelevant: collapseIrrelevant,
            outputDirectory: outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : outputDirectory)
    }

    func buildPreview() async {
        generation += 1; let requestedGeneration = generation
        guard canRead, let request = makePreviewRequest() else {
            errorMessage = L10n.text("The project, Plan, or editor is no longer current."); return
        }
        guard request.planDraft == nil || request.planDraft?.isCurrent(in: store) == true else {
            errorMessage = L10n.text("The Plan editor changed. Reopen this analysis window."); return
        }
        isLoading = true; errorMessage = nil; emitResponse = nil; invalidatePreview()
        do {
            let result = try await client.request("plan.r2rMatrix.preview", parameters: request,
                as: PlanMatrixPreviewResponse.self)
            guard requestedGeneration == generation, canRead,
                  result.inspectionID.count == 64,
                  samePlanAnalysisPath(result.planPath, request.planPath),
                  result.planRevision.caseInsensitiveCompare(request.planRevision) == .orderedSame,
                  result.projectXmlFingerprint.caseInsensitiveCompare(route.capture.projectXmlFingerprint) == .orderedSame else {
                if requestedGeneration == generation { isLoading = false; errorMessage = L10n.text("The project or Plan editor changed. Reopen this analysis window.") }
                return
            }
            previewRequest = request; preview = result; isLoading = false
        } catch {
            guard requestedGeneration == generation else { return }
            isLoading = false; errorMessage = localizedPlanMatrixError(error.localizedDescription)
        }
    }

    func emit() {
        guard !isEmitting, canRead, let request = previewRequest, let preview else {
            errorMessage = L10n.text("Preview the current matrix before writing files."); return
        }
        guard preview.inspectionID.count == 64, preview.writeCount > 0 else {
            errorMessage = L10n.text("The current matrix has no files to write."); return
        }
        guard let lease = store.beginPlanMatrixEmit(projectSessionID: route.projectSessionID,
                captureID: preview.inspectionID) else {
            errorMessage = L10n.text("Another project operation is in progress."); return
        }
        let emitRequest = PlanMatrixEmitRequest(preview: request, inspectionID: preview.inspectionID,
            overwrite: overwrite, nameEmbeddedPlan: nameEmbeddedPlan, writeManifest: writeManifest)
        do {
            let started = try client.startDuplex("plan.r2rMatrix.emit", parameters: emitRequest,
                control: PlanMatrixCancelControl.self, event: BackendProgressUpdate.self,
                as: PlanMatrixEmitResponse.self)
            operation = started; emitLeaseID = lease; isEmitting = true
            isCancelRequested = false; errorMessage = nil; emitResponse = nil; progress = nil
            Task { [self] in await drainEmit(started, request: emitRequest, leaseID: lease) }
        } catch {
            store.endPlanMatrixEmit(leaseID: lease)
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    func cancelEmit() {
        guard isEmitting, !isCancelRequested, let operation else { return }
        isCancelRequested = true
        if !operation.requestSourceCancellation() {
            errorMessage = L10n.text("The cancellation request could not be delivered; waiting for the source operation to finish.")
        }
    }

    private func drainEmit(_ operation: BackendDuplexOperation<PlanMatrixCancelControl,
                        BackendProgressUpdate, PlanMatrixEmitResponse>,
                           request: PlanMatrixEmitRequest, leaseID: UUID) async {
        var eventFailure: Error?
        do {
            var iterator = operation.events.makeAsyncIterator()
            while let event = try await iterator.next() {
                acceptProgress(event, leaseID: leaseID)
                if !emitOwnerIsCurrent(leaseID: leaseID, inspectionID: request.inspectionID), !isCancelRequested {
                    isCancelRequested = true
                    _ = operation.requestSourceCancellation()
                }
            }
        } catch {
            eventFailure = error
        }

        // Even if the progress stream failed, wait for the invocation's
        // completion task before releasing the Store lease. The terminal
        // response (or process-exit failure) is the writer's completion edge.
        do {
            let result = try await operation.value()
            if store.isPlanMatrixEmitCurrent(leaseID: leaseID,
                projectSessionID: route.projectSessionID, captureID: request.inspectionID) {
                emitResponse = result
                if !result.sourcesStillCurrent { errorMessage = L10n.text("The source project or Plan changed while the matrix was being written.") }
            }
        } catch {
            if !isCancelRequested && store.isPlanMatrixEmitCurrent(leaseID: leaseID,
                projectSessionID: route.projectSessionID, captureID: request.inspectionID) {
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
        if let eventFailure, !isCancelRequested, errorMessage == nil,
           store.isPlanMatrixEmitCurrent(leaseID: leaseID,
            projectSessionID: route.projectSessionID, captureID: request.inspectionID) {
            errorMessage = L10n.text(eventFailure.localizedDescription)
        }
        finishEmit(leaseID: leaseID)
    }

    private func acceptProgress(_ event: BackendProgressUpdate, leaseID: UUID) {
        guard store.isPlanMatrixEmitCurrent(leaseID: leaseID,
            projectSessionID: route.projectSessionID, captureID: preview?.inspectionID ?? "") else { return }
        progress = event
    }

    private func emitOwnerIsCurrent(leaseID: UUID, inspectionID: String) -> Bool {
        store.isPlanMatrixEmitCurrent(leaseID: leaseID,
            projectSessionID: route.projectSessionID, captureID: inspectionID)
            && route.capture.isCurrent(in: store, projectSessionID: route.projectSessionID)
    }

    private func finishEmit(leaseID: UUID) {
        store.endPlanMatrixEmit(leaseID: leaseID)
        if emitLeaseID == leaseID {
            emitLeaseID = nil; operation = nil; isEmitting = false
            if isCancelRequested { isCancelRequested = false }
        }
    }
}

@MainActor
struct ReadyToRunMatrixWindow: View {
    @ObservedObject var store: WorkspaceStore
    let client: BackendProcessClient
    let route: ReadyToRunMatrixWindowRoute?
    @StateObject private var model: ReadyToRunMatrixWindowModel

    init(store: WorkspaceStore, client: BackendProcessClient, route: ReadyToRunMatrixWindowRoute?) {
        self.store = store; self.client = client; self.route = route
        _model = StateObject(wrappedValue: ReadyToRunMatrixWindowModel(store: store, client: client,
            route: route ?? ReadyToRunMatrixWindowRoute(projectSessionID: store.projectSessionID,
                capture: PlanAnalysisProjectCapture(projectPath: "", projectRevision: "", projectXml: "", projectXmlFingerprint: ""),
                initialPlanPath: "")))
    }

    var body: some View {
        Group {
            if let route, route.projectSessionID == store.projectSessionID {
                content
            } else {
                ContentUnavailableView(L10n.text("Ready-to-run matrix is unavailable"),
                    systemImage: "square.grid.3x3", description: Text(L10n.text("Open the owning project and Plan editor again.")))
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .task(id: route?.id) { await model.loadOptions() }
    }

    private var content: some View {
        VStack(spacing: 10) {
            if model.isEmitting { progressPanel }
            HStack(alignment: .top, spacing: 12) {
                configuration.frame(width: 380)
                Divider()
                previewPanel
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(14)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Source Plan")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.text("Source Plan"), selection: Binding(get: { model.selectedPlanPath }, set: { value in
                    if let value { model.selectPlan(value) }
                })) {
                    ForEach(model.options?.plans ?? []) { plan in Text(plan.name).tag(Optional(plan.planPath)) }
                }.labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Output directory")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L10n.text("Choose an output directory"), text: Binding(get: { model.outputDirectory }, set: model.setOutputDirectory))
                    Button(L10n.text("Open")) { openOutputDirectory() }
                        .disabled(model.outputDirectory.isEmpty)
                }
            }
            Divider()
            HStack {
                Text(L10n.text("Sweep axes")).font(.headline)
                Spacer()
                Picker(L10n.text("Add property"), selection: $model.selectedPropertyName) {
                    Text(L10n.text("Add property…")).tag(String?.none)
                    ForEach(model.availableProperties) { property in
                        Text(L10n.text(property.displayName)).tag(Optional(property.propertyName))
                    }
                }.frame(maxWidth: 175)
                Button(L10n.text("Add")) { addSelectedAxis() }
                    .disabled(model.availableProperties.first(where: { $0.propertyName == model.selectedPropertyName }) == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.axisProperties) { property in axisEditor(property) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.axisProperties.isEmpty {
                Text(L10n.text("No sweep axes selected; the matrix contains the current Plan once."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(L10n.text("Combination rules")).font(.headline)
            ForEach(model.rules) { rule in
                Toggle(isOn: Binding(get: { model.rules.first(where: { $0.name == rule.name })?.enabled ?? false },
                                     set: { model.setRule(rule.name, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text(rule.name))
                        Text(L10n.text(rule.reason)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Toggle(L10n.text("Collapse irrelevant combinations"), isOn: Binding(get: { model.collapseIrrelevant }, set: model.toggleCollapse))
                .toggleStyle(.checkbox)
        }
        .disabled(model.isLoading || model.isEmitting)
    }

    @ViewBuilder private func axisEditor(_ property: PlanMatrixProperty) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text(property.displayName)).font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive) { model.removeAxis(property.propertyName) } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.plain).help(L10n.text("Remove axis"))
            }
            if property.isClosedSet {
                ForEach(property.initialValues) { value in
                    Toggle(L10n.text(value.label), isOn: Binding(get: {
                        model.selectedValues[property.propertyName, default: []].contains(value.value)
                    }, set: { model.setValue(value.value, for: property.propertyName, enabled: $0) }))
                    .toggleStyle(.checkbox)
                }
            } else {
                ForEach(model.selectedValues[property.propertyName, default: []], id: \.self) { value in
                    HStack {
                        Text(value).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) { model.setValue(value, for: property.propertyName, enabled: false) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField(property.inputHint.isEmpty ? L10n.text("Add a value") : L10n.text(property.inputHint),
                        text: Binding(get: { model.pendingValuePropertyName == property.propertyName ? model.pendingValue : "" },
                                      set: { model.pendingValuePropertyName = property.propertyName; model.pendingValue = $0 }))
                    Button(L10n.text("Add value")) { model.addPendingValue() }
                        .disabled(model.pendingValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Matrix preview")).font(.headline)
                    if let preview = model.preview { Text(previewSummary(preview)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(L10n.text("Preview")) { Task { await model.buildPreview() } }
                    .disabled(model.isLoading || model.isEmitting || !model.canRead)
            }
            if let preview = model.preview {
                if !preview.hint.isEmpty {
                    Label(previewHint(preview.hint), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(preview.combinations) { combination in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(combination.index)").foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                                    Text(combination.label).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(combination.filename).font(.system(.caption, design: .monospaced))
                                    if combination.isExcluded { Label(L10n.text("Excluded"), systemImage: "xmark.circle").foregroundStyle(.orange) }
                                    else if combination.isCollapsed { Label(L10n.text("Collapsed"), systemImage: "arrow.down.right.and.arrow.up.left").foregroundStyle(.secondary) }
                                }
                if !combination.assignments.isEmpty {
                    Text(combination.assignments.map { "\(L10n.text($0.displayName)): \($0.value)" }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let reason = combination.exclusionReason, !reason.isEmpty {
                                    Text(L10n.text(reason)).font(.caption).foregroundStyle(.orange)
                                }
                if let file = model.emitResponse?.files.first(where: { $0.filename == combination.filename }) {
                    HStack(spacing: 6) {
                        Label(L10n.text(file.status), systemImage: statusSymbol(file.status))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(file.status == "Failed" ? .orange : .secondary)
                        if let path = file.filePath { Text(path).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
                        if let message = file.message, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                } else if model.progress?.values?["filename"] == combination.filename,
                          model.progress?.values?["phase"] == "fileCompleted" {
                    Label(L10n.text(model.progress?.values?["status"] ?? "Completed"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.isEmitting, model.progress?.values?["filename"] == combination.filename {
                    Label(L10n.text("Writing"), systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                            }
                            .padding(.vertical, 7).padding(.horizontal, 8)
                            Divider()
                        }
                    }
                }
                Toggle(L10n.text("Overwrite existing files"), isOn: Binding(get: { model.overwrite }, set: model.toggleOverwrite))
                    .toggleStyle(.checkbox)
                Toggle(L10n.text("Name the embedded Plan for each combination"), isOn: Binding(get: { model.nameEmbeddedPlan }, set: model.toggleNameEmbeddedPlan))
                    .toggleStyle(.checkbox)
                Toggle(L10n.text("Write matrix manifest"), isOn: Binding(get: { model.writeManifest }, set: model.toggleManifest))
                    .toggleStyle(.checkbox)
            } else if model.isLoading {
                ProgressView(L10n.text("Building the matrix from the current Plan draft…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.text("Preview the sweep axes"), systemImage: "square.grid.3x3",
                    description: Text(L10n.text("The preview validates values and reports illegal or irrelevant combinations before writing.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.progress?.taskName.map(L10n.text) ?? L10n.text("Writing ready-to-run plans…"))
                Spacer()
                Button(L10n.text("Cancel"), role: .destructive) { model.cancelEmit() }
                    .disabled(model.isCancelRequested)
            }
            if let fraction = model.progress?.fraction { ProgressView(value: fraction) }
            else { ProgressView() }
            if let message = model.progress?.message {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            if let result = model.emitResponse {
                Label(L10n.format("%lld written · %lld skipped · %lld failed",
                    Int64(result.written), Int64(result.skipped), Int64(result.failed)),
                    systemImage: result.state == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(result.failed > 0 || result.state == "failed" ? .orange : .secondary)
                if result.wasCancelled { Text(L10n.text("Cancelled")).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(L10n.text("Open output directory")) { openOutputDirectory() }
                .disabled(model.outputDirectory.isEmpty || model.isEmitting)
            Button(L10n.text("Emit matrix")) { model.emit() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isEmitting || model.isLoading || model.preview == nil || !model.canRead)
        }
    }

    private func addSelectedAxis() {
        guard let property = model.availableProperties.first(where: { $0.propertyName == model.selectedPropertyName }) else { return }
        model.addAxis(property)
    }
    private func openOutputDirectory() {
        let path = model.preview?.outputDirectory ?? model.outputDirectory
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            model.reportDirectoryOpenError(error)
        }
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "Written": "checkmark.circle.fill"
        case "Skipped": "forward.end.circle"
        case "Failed": "xmark.octagon.fill"
        case "Cancelled": "stop.circle"
        case "Excluded": "xmark.circle"
        default: "circle.dashed"
        }
    }

    private func previewSummary(_ preview: PlanMatrixPreviewResponse) -> String {
        let excluded = preview.combinations.filter { $0.isExcluded && !$0.isCollapsed }.count
        let collapsed = preview.combinations.filter(\.isCollapsed).count
        var parts = [L10n.format("%lld combinations", Int64(preview.combinations.count)),
                     L10n.format("%lld files", Int64(preview.writeCount))]
        if excluded > 0 { parts.append(L10n.format("%lld illegal", Int64(excluded))) }
        if collapsed > 0 { parts.append(L10n.format("%lld collapsed", Int64(collapsed))) }
        return parts.joined(separator: " · ")
    }

    private func previewHint(_ hint: String) -> String {
        let prefix = "Ignored by every combination, so it produces no extra files: "
        let suffix = ". Add the switch that enables it as an axis, or turn it on in the plan."
        guard hint.hasPrefix(prefix), hint.hasSuffix(suffix) else { return hint }
        let body = hint.dropFirst(prefix.count).dropLast(suffix.count)
        let localizedEntries = String(body).components(separatedBy: "; ").map { entry -> String in
            guard let opening = entry.lastIndex(of: "("), entry.last == ")" else { return L10n.text(entry) }
            let name = String(entry[..<opening]).trimmingCharacters(in: .whitespaces)
            let reasonStart = entry.index(after: opening)
            let reasonEnd = entry.index(before: entry.endIndex)
            return L10n.text(name) + " (" + L10n.text(String(entry[reasonStart..<reasonEnd])) + ")"
        }
        return L10n.text("Ignored by every combination, so it produces no extra files:") + " "
            + localizedEntries.joined(separator: "; ")
            + L10n.text(". Add the switch that enables it as an axis, or turn it on in the plan.")
    }
}
