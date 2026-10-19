import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class VectorSymbologyFixtureProvider: VectorSymbologyProvider {
    let defaults = VectorSymbologyStyle(penColor: "#FF0000FF", penWidth: 1, fillColor: "#8000FF80", pointSize: 3, haloColor: "#00000000", haloThickness: 0, textEmphasis: 0)
    private(set) var applyCount = 0
    func snapshot(_ context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot? {
        var changed = defaults; changed.penWidth = 4
        let rule = VectorCondition(column: "名称", comparison: "contains", threshold: "河道", resultValue: "#FF0000")
        return .init(options: [
            .init(id: "first", name: "First", type: .line, style: changed, defaultStyle: defaults, columns: [.init(id: "名称", name: "名称", kind: .string)], conditions: [.penColor: [rule]]),
            .init(id: "second", name: "Second", type: .point, style: changed, defaultStyle: defaults, columns: [])
        ], additionalOptions: [.init(id: "locked", title: "Locked", isBoolean: true, value: "false", choices: [], isEnabled: false)], canEdit: true)
    }
    func apply(options: [VectorStyleOption], additionalOptions: [VectorPlotOption], context: VectorSymbologyContext) async throws -> MapUpdate {
        applyCount += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}

@MainActor
private final class SuspendedVectorSymbologyProvider: VectorSymbologyProvider {
    private(set) var applyStarted = false
    private(set) var applyCount = 0
    private(set) var snapshotContexts: [VectorSymbologyContext] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private let style = VectorSymbologyStyle(penColor: "#FF000000", penWidth: 1, fillColor: "#800000FF")
    private let rejectsApply: Bool

    init(rejectsApply: Bool = false) {
        self.rejectsApply = rejectsApply
    }

    func snapshot(_ context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot? {
        snapshotContexts.append(context)
        return .init(options: [
            .init(id: "first", name: "First", type: .line, style: style, defaultStyle: style, columns: [])
        ], additionalOptions: [], canEdit: true)
    }

    func apply(options: [VectorStyleOption], additionalOptions: [VectorPlotOption], context: VectorSymbologyContext) async throws -> MapUpdate {
        applyStarted = true
        applyCount += 1
        await withCheckedContinuation { continuation = $0 }
        if rejectsApply { throw CocoaError(.fileWriteNoPermission) }
        return MapUpdate(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil, selectedFeatureID: nil)
    }

    func resumeApply() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendedGlobalVectorSymbologyProvider: VectorSymbologyProvider {
    private(set) var applyStarted = false
    private var continuation: CheckedContinuation<MapUpdate, Never>?
    private let style = VectorSymbologyStyle(penColor: "#FF000000", penWidth: 4, fillColor: "#800000FF")

    func snapshot(_ context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot? {
        return .init(options: [
            .init(id: "line", name: "Line", type: .line, style: style, defaultStyle: style, columns: [])
        ], additionalOptions: [], canEdit: true)
    }

    func apply(options: [VectorStyleOption], additionalOptions: [VectorPlotOption], context: VectorSymbologyContext) async throws -> MapUpdate {
        applyStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resumeApply() {
        continuation?.resume(returning: MapUpdate(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil, selectedFeatureID: nil))
        continuation = nil
    }
}

struct VectorSymbologyTests {
    @Test @MainActor func resettingOneOptionKeepsConditionsAndOtherOptions() async throws {
        let provider = VectorSymbologyFixtureProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: "vector"), provider: provider)
        let before = try #require(session.options.first?.conditions[.penColor])
        session.reset("first")
        #expect(session.options[0].style == provider.defaults)
        #expect(session.options[0].conditions[.penColor] == before)
        #expect(session.options[0].resetRequested)
        #expect(session.options[1].style.penWidth == 4)
        #expect(!session.options[1].resetRequested)
        #expect(session.options[0].operators(for: "名称") == ["equals", "not equals", "contains", "starts with", "ends with"])
        #expect(session.options[0].operators(for: "unknown").isEmpty)
        session.setAdditional("locked", value: "true")
        #expect(session.additionalOptions[0].value == "false")
    }
    @Test @MainActor func failedApplyKeepsVectorColorAndConditionDrafts() async throws {
        let provider = VectorSymbologyFixtureProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: "vector"), provider: provider)
        session.edit("first") { $0.style.penColor = "#FF00FFFF"; $0.conditions[.penColor]?[0].threshold = "本地编辑" }
        #expect(await session.apply(provider: provider) == nil)
        #expect(session.options[0].style.penColor == "#FF00FFFF")
        #expect(session.options[0].conditions[.penColor]?.first?.threshold == "本地编辑")
        #expect(session.error != nil)
        #expect(!session.busy)
    }

    @Test @MainActor func invalidNumberDraftBlocksApplyWithoutReplacingTheLastValidStyle() async throws {
        let provider = VectorSymbologyFixtureProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: "vector"), provider: provider)
        session.setNumericInputText("12x", optionID: "first", field: .penWidth)
        #expect(session.options[0].style.penWidth == 4)
        #expect(session.numericInputText(optionID: "first", field: .penWidth) == "12x")
        #expect(session.validationIssue == VectorSymbologyValidation.invalidNumberDraft)
        #expect(await session.apply(provider: provider) == nil)
        #expect(provider.applyCount == 0)

        session.setNumericInputText("12.5", optionID: "first", field: .penWidth)
        #expect(session.options[0].style.penWidth == 12.5)
        #expect(session.validationIssue == nil)
    }

    @Test @MainActor func pointSizeDraftMustFitTheSourceInt32Type() async throws {
        let provider = VectorSymbologyFixtureProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: "vector"), provider: provider)
        session.setNumericInputText("2147483648", optionID: "second", field: .pointSize)
        #expect(session.options[1].style.pointSize == 3)
        #expect(session.validationIssue == VectorSymbologyValidation.invalidNumberDraft)
        session.setNumericInputText("2147483647", optionID: "second", field: .pointSize)
        #expect(session.options[1].style.pointSize == Int(Int32.max))
        #expect(session.validationIssue == nil)
    }

    @Test @MainActor func invalidGlobalNumberDraftBlocksSettingsCloseFlush() async throws {
        let provider = VectorSymbologyFixtureProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: nil, scope: .global), provider: provider)
        session.setNumericInputText("-", optionID: "first", field: .penWidth)
        #expect(session.hasPendingGlobalChanges)
        #expect(await session.flushGlobalChanges() == false)
        #expect(provider.applyCount == 0)
        #expect(session.numericInputText(optionID: "first", field: .penWidth) == "-")
    }

    @Test @MainActor func invalidNumberDraftSurvivesSameTargetReloadDuringGlobalPersistence() async throws {
        let provider = SuspendedGlobalVectorSymbologyProvider(), session = VectorSymbologySession()
        let context = VectorSymbologyContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, scope: .global)
        await session.load(context: context, provider: provider)

        session.setNumericInputText("12.5", optionID: "line", field: .penWidth)
        while !provider.applyStarted { await Task.yield() }
        session.setNumericInputText("12.5x", optionID: "line", field: .penWidth)

        await session.load(context: context, provider: provider)
        #expect(session.numericInputText(optionID: "line", field: .penWidth) == "12.5x")
        #expect(session.validationIssue == VectorSymbologyValidation.invalidNumberDraft)
        #expect(session.hasPendingGlobalChanges)
        #expect(await session.flushGlobalChanges() == false)

        provider.resumeApply()
        await Task.yield()
        #expect(session.numericInputText(optionID: "line", field: .penWidth) == "12.5x")
        #expect(session.options[0].style.penWidth == 4)
    }

    @Test func typedColumnsOfferOnlySourceOperators() {
        let style = VectorSymbologyStyle()
        let option = VectorStyleOption(
            id: "typed", name: "Typed", type: .line, style: style, defaultStyle: style,
            columns: [
                .init(id: "name", name: "Name", kind: .string),
                .init(id: "small", name: "Small", kind: .int32),
                .init(id: "large", name: "Large", kind: .int64),
                .init(id: "single", name: "Single", kind: .float32),
                .init(id: "double", name: "Double", kind: .float64),
                .init(id: "opaque", name: "Opaque", kind: .unsupported, sourceTypeName: "Decimal")
            ]
        )
        #expect(option.operators(for: "Name") == ["equals", "not equals", "contains", "starts with", "ends with"])
        #expect(option.operators(for: "Small") == ["==", "!=", ">", ">=", "<", "<="])
        #expect(option.operators(for: "Large") == option.operators(for: "Small"))
        #expect(option.operators(for: "Single") == option.operators(for: "Small"))
        #expect(option.operators(for: "Double") == option.operators(for: "Small"))
        #expect(option.operators(for: "Opaque").isEmpty)
        #expect(option.operators(for: "Missing").isEmpty)
        #expect(VectorAttributeColumn(id: "legacy", name: "Legacy", isString: false).kind == .unsupported)
    }

    @Test func sourceEditorPropertiesMatchTheOriginalGeometryEditors() {
        let style = VectorSymbologyStyle()
        func option(_ type: VectorType) -> VectorStyleOption {
            .init(id: UUID().uuidString, name: "Geometry", type: type, style: style, defaultStyle: style, columns: [])
        }
        #expect(option(.point).properties == [.penColor, .penWidth, .fillColor, .pointSize])
        #expect(option(.line).properties == [.penColor, .penWidth])
        #expect(option(.polygon).properties == [.penColor, .penWidth, .fillColor])
        #expect(option(.segment).properties.isEmpty)
        #expect(option(.complexPolygon).properties.isEmpty)
        #expect(option(.text).properties.isEmpty)
    }

    @Test func typedRulesRejectUnexecutableCompleteValuesButAllowSourceIncompleteRows() {
        let style = VectorSymbologyStyle()
        let base = VectorStyleOption(
            id: "line", name: "Line", type: .line, style: style, defaultStyle: style,
            columns: [.init(id: "count", name: "Count", kind: .int32)]
        )
        var option = base
        option.conditions[.penWidth] = [.init(column: "Count", comparison: ">", threshold: "1.5", resultValue: "2.0")]
        #expect(VectorSymbologyValidation.issueKey(options: [option], scope: .layer) == VectorSymbologyValidation.invalidThreshold)

        option.conditions[.penWidth] = [.init(column: "Count", comparison: ">", threshold: "2", resultValue: "not-a-number")]
        #expect(VectorSymbologyValidation.issueKey(options: [option], scope: .layer) == VectorSymbologyValidation.invalidResult)

        option.conditions[.penWidth] = [.init(column: "Count", comparison: ">", threshold: "", resultValue: "")]
        #expect(VectorSymbologyValidation.issueKey(options: [option], scope: .layer) == nil)

        option.conditions[.penWidth] = [.init(column: "Unknown", comparison: ">", threshold: "2", resultValue: "2")]
        #expect(VectorSymbologyValidation.issueKey(options: [option], scope: .layer) == VectorSymbologyValidation.invalidColumn)
    }

    @Test @MainActor func conditionReorderingPreservesRuleIdentityAndOrder() async {
        let provider = VectorSymbologyFixtureProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: "vector"), provider: provider)
        let first = VectorCondition(column: "名称", comparison: "contains", threshold: "a", resultValue: "#000000")
        let second = VectorCondition(column: "名称", comparison: "contains", threshold: "b", resultValue: "#FFFFFF")
        session.edit("first") { $0.conditions[.penColor] = [first, second] }
        session.moveCondition(optionID: "first", property: .penColor, conditionID: second.id, offset: -1)
        #expect(session.options[0].conditions[.penColor] == [second, first])
    }

    @Test func contextKeepsItsTargetAcrossRevisionButNotAcrossNodes() throws {
        let nodeA = VectorVisualNodeIdentity(
            mapIndex: 0, mapName: "Map", mapType: "Buildable", nodePath: [0],
            nodeName: "Layer A", mapLayerType: "Polygon", filename: "layer.shp",
            filenameRelative: "layer.shp", assetID: "asset-a"
        )
        let nodeB = VectorVisualNodeIdentity(
            mapIndex: 0, mapName: "Map", mapType: "Buildable", nodePath: [1],
            nodeName: "Layer B", mapLayerType: "Polygon", filename: "layer.shp",
            filenameRelative: "layer.shp", assetID: "asset-a"
        )
        let projectID = UUID(), mapID = UUID()
        let before = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "asset-a", layerID: "/layer.shp", visualizationRevision: "one", visualNode: nodeA)
        let refreshed = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "asset-a", layerID: "/layer.shp", visualizationRevision: "two", visualNode: nodeA)
        let anotherNode = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "asset-a", layerID: "/layer.shp", visualizationRevision: "two", visualNode: nodeB)
        #expect(before.hasSameVisualTarget(as: refreshed))
        #expect(before != refreshed)
        #expect(!before.hasSameVisualTarget(as: anotherNode))
    }

    @Test @MainActor func sameTargetRevisionRefreshDuringApplyPreservesAndAcceptsSubmittedCandidate() async throws {
        let provider = SuspendedVectorSymbologyProvider(), session = VectorSymbologySession()
        let projectID = UUID(), mapID = UUID()
        let original = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "vector", visualizationRevision: "one")
        let changed = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "vector", visualizationRevision: "two")
        await session.load(context: original, provider: provider)
        session.edit("first") { $0.style.penColor = "#FF00FFFF" }
        let applyTask = Task { await session.apply(provider: provider) }
        while !provider.applyStarted { await Task.yield() }
        await session.load(context: changed, provider: provider)
        #expect(session.options[0].style.penColor == "#FF00FFFF")
        provider.resumeApply()
        #expect(await applyTask.value != nil)
        #expect(provider.applyCount == 1)
        #expect(provider.snapshotContexts == [original])
        #expect(session.options.count == 1)
        #expect(session.options[0].style.penColor == "#FF00FFFF")
        #expect(!session.busy)
        #expect(session.error == nil)
    }

    @Test @MainActor func sameTargetRevisionRefreshPreservesCandidateAndShowsApplyRejection() async throws {
        let provider = SuspendedVectorSymbologyProvider(rejectsApply: true), session = VectorSymbologySession()
        let projectID = UUID(), mapID = UUID()
        let original = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "vector", visualizationRevision: "one")
        let changed = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "vector", visualizationRevision: "two")
        await session.load(context: original, provider: provider)
        session.edit("first") { $0.style.penColor = "#FF00FFFF" }
        let applyTask = Task { await session.apply(provider: provider) }
        while !provider.applyStarted { await Task.yield() }

        await session.load(context: changed, provider: provider)
        provider.resumeApply()

        #expect(await applyTask.value == nil)
        #expect(session.options[0].style.penColor == "#FF00FFFF")
        #expect(session.error != nil)
        #expect(!session.busy)
        #expect(provider.snapshotContexts == [original])
    }

    @Test @MainActor func differentTargetLoadInvalidatesInFlightApply() async throws {
        let provider = SuspendedVectorSymbologyProvider(), session = VectorSymbologySession()
        let projectID = UUID(), mapID = UUID()
        let original = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "vector-a", visualizationRevision: "one")
        let anotherTarget = VectorSymbologyContext(projectSessionID: projectID, mapID: mapID, assetID: "vector-b", visualizationRevision: "one")
        await session.load(context: original, provider: provider)
        session.edit("first") { $0.style.penColor = "#FF00FFFF" }
        let applyTask = Task { await session.apply(provider: provider) }
        while !provider.applyStarted { await Task.yield() }

        await session.load(context: anotherTarget, provider: provider)
        provider.resumeApply()

        #expect(await applyTask.value == nil)
        #expect(provider.snapshotContexts == [original, anotherTarget])
        #expect(session.options[0].style.penColor == "#FF000000")
        #expect(!session.busy)
        #expect(session.error == nil)
    }
}
