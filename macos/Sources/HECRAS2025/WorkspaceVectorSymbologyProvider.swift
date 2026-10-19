import Combine
import Foundation
import RASWorkspaceCore

/// The exact saved `.vis` owner and vector source used by a local symbology
/// request. `settings.revision` is the complete visualization-file revision.
struct VectorSymbologyLayerSource {
    let context: VectorSymbologyContext
    let layer: MapVectorLayer
    let settings: VectorVisualSettingsSnapshot
    let defaults: [String: VectorStyleValues]
}

private enum VectorPlotExpectedSource {
    case geoJSON
    case shapefile(MapSourceFamilyCapture)
    case geodatabase

    var family: MapSourceFamilyCapture? {
        if case .shapefile(let family) = self { return family }
        return nil
    }
}

struct VectorPlotRenderFailure: Identifiable, Equatable, Sendable {
    let layerID: String
    let layerName: String
    let message: String
    var id: String { layerID }
}

/// Owns the two retained vector-style scopes: app-wide defaults and exact
/// persisted MapLayer settings. Attribute-table rules are only rendered when
/// both the retained reader and the native feature layer prove the same row
/// ordinal for every rendered source feature.
@MainActor
final class WorkspaceVectorSymbologyProvider: ObservableObject, VectorSymbologyProvider {
    private weak var store: WorkspaceStore?
    private let preferences: GlobalVectorStylePreferences
    private let client: BackendProcessClient?
    private var refreshGenerations: [UUID: UInt64] = [:]
    private var effectiveSettings: [EffectiveSettingsOwner: EffectiveSettingsEntry] = [:]
    private var plotGenerations: [UUID: UInt64] = [:]
    private var transientPlotOptions: [VectorPlotOptionsOwner: [String: String]] = [:]
    @Published private(set) var plotFrameCollections: [UUID: [String: VectorPlotRenderedLayer]] = [:]
    @Published private(set) var plotFrameFailures: [UUID: [String: VectorPlotRenderFailure]] = [:]

    private struct VectorPlotOptionsOwner: Hashable {
        let projectSessionID: UUID
        let mapID: UUID
        let layerID: String
        let sourcePath: String
        let sourceRevision: String
    }

    init(store: WorkspaceStore, preferences: GlobalVectorStylePreferences, client: BackendProcessClient?) {
        self.store = store
        self.preferences = preferences
        self.client = client
    }

    func snapshot(_ context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot? {
        guard let store else { return nil }
        if context.scope == .global {
            guard context.projectSessionID == store.globalSymbologySessionID,
                  context.mapID == MapState.projectMapID else { throw ProjectFileError.modifiedExternally }
            return globalSnapshot()
        }
        if context.specializedNode != nil {
            return try specializedSnapshot(context, store: store)
        }

        guard let source = try resolvedLayerSource(context, store: store),
              let identity = context.visualNode,
              let definitionIDs = identity.supportedStyleDefinitionIDs else { return nil }

        let bucketInspection: VectorSymbologyInspection?
        do {
            bucketInspection = try await inspect(source.layer)
        } catch {
            // Base styles remain useful even when the retained attribute-table
            // reader cannot inspect this source. The condition editor is
            // returned disabled and persisted rules remain intact.
            bucketInspection = nil
        }

        guard !Task.isCancelled,
              let current = try resolvedLayerSource(context, store: store),
              current.settings.revision == source.settings.revision,
              current.layer.sourceRevision == source.layer.sourceRevision,
              current.defaults == source.defaults else { throw ProjectFileError.modifiedExternally }

        let draftBlocksConditions = hasUnsavedGeometryDraft(source.layer, mapID: context.mapID, store: store)
        let canInspectRules = identity.mapLayerType != "GdbVectorLayer"
            && bucketInspection.map({ inspectionSupportsMapType($0, identity: identity, layer: source.layer) }) == true

        let options = try definitionIDs.map { definitionID -> VectorStyleOption in
            guard let setting = source.settings.options[definitionID],
                  let baseline = source.defaults[definitionID],
                  let variant = variant(for: definitionID, identity: identity),
                  let definition = SourceVectorStyleCatalog.definition(for: definitionID) else {
                throw ProjectFileError.modifiedExternally
            }
            let bucket = bucketInspection.flatMap { bucket(for: $0, identity: identity) }
            let columns = canInspectRules ? (bucket?.columns ?? []).map { column in
                VectorAttributeColumn(
                    id: column.id,
                    name: column.name,
                    kind: VectorAttributeColumnKind(rawValue: column.type) ?? .unsupported,
                    sourceTypeName: column.type
                )
            } : []
            let reason: String?
            if draftBlocksConditions {
                reason = Self.unsavedDraftReason
            } else if identity.mapLayerType == "GdbVectorLayer" || definition.conditionCapability != .attributeTable {
                reason = Self.unsupportedConditionsReason
            } else if bucketInspection == nil || bucket == nil {
                reason = Self.unavailableConditionsReason
            } else if bucket?.hasAttributeTable != true || bucket?.columns.isEmpty != false {
                reason = Self.noAttributeTableReason
            } else if !columnsHaveUniqueNames(bucket?.columns.map {
                VectorAttributeColumn(id: $0.id, name: $0.name,
                    kind: VectorAttributeColumnKind(rawValue: $0.type) ?? .unsupported,
                    sourceTypeName: $0.type)
            } ?? []) {
                reason = Self.ambiguousColumnReason
            } else if !canInspectRules {
                reason = Self.unavailableConditionsReason
            } else {
                reason = nil
            }
            let conditions = Dictionary(uniqueKeysWithValues: setting.conditionGroups.map { ($0.field, $0.rules) })
            return VectorStyleOption(
                id: definitionID,
                name: variant.name,
                layerName: variant.layerName,
                type: Self.vectorType(variant.type),
                style: setting.values,
                defaultStyle: baseline,
                columns: columns,
                conditions: conditions,
                conditionsEnabled: true,
                conditionCapability: definition.conditionCapability,
                conditionCapabilityReason: reason
            )
        }
        let plotOptions: [VectorPlotOption]
        do {
            plotOptions = try await inspectPlotOptions(context, source: source, store: store)
        } catch {
            // A broken/unsupported renderer must not prevent editing a valid
            // persisted .vis style. Canvas keeps its native source draw until
            // a later refresh can produce a source-rendered replacement.
            plotOptions = []
        }
        return VectorSymbologySnapshot(options: options, additionalOptions: plotOptions, canEdit: true)
    }

    func apply(options: [VectorStyleOption], additionalOptions: [VectorPlotOption],
               context: VectorSymbologyContext) async throws -> MapUpdate {
        guard let store else { throw ProjectFileError.modifiedExternally }
        if context.scope == .global {
            guard context.projectSessionID == store.globalSymbologySessionID,
                  context.mapID == MapState.projectMapID, additionalOptions.isEmpty else {
                throw ProjectFileError.modifiedExternally
            }
            try applyGlobal(options, context: context, store: store)
            for state in store.loadedVectorStyleMapStates() {
                await refresh(mapID: state.id)
            }
            return styleOnlyUpdate(mapID: context.mapID, store: store)
        }
        if context.specializedNode != nil {
            return try await applySpecialized(options: options, context: context, store: store)
        }

        guard let source = try resolvedLayerSource(context, store: store),
              let identity = context.visualNode,
              let definitionIDs = identity.supportedStyleDefinitionIDs,
              Set(options.map(\.id)).count == options.count,
              Set(options.map(\.id)) == Set(definitionIDs) else {
            throw ProjectFileError.modifiedExternally
        }
        let selectedPlotOptions = try await validatedPlotOptions(
            additionalOptions, context: context, source: source, store: store)
        guard let capturedRevision = source.settings.revision,
              capturedRevision.caseInsensitiveCompare(context.visualizationRevision ?? "") == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let hasUnsavedDraft = hasUnsavedGeometryDraft(source.layer, mapID: context.mapID, store: store)
        let inspection: VectorSymbologyInspection?
        if options.contains(where: { option in
            let baseline = source.settings.options[option.id]
            return baseline.map { !Self.conditionGroupsEqual($0.conditionGroups, groups(from: option)) } ?? true
        }), !hasUnsavedDraft {
            inspection = try await inspect(source.layer)
        } else {
            inspection = nil
        }
        try Task.checkCancellation()
        guard let current = try resolvedLayerSource(context, store: store),
              current.settings.revision == capturedRevision,
              current.layer.sourceRevision == source.layer.sourceRevision,
              current.defaults == source.defaults,
              !hasUnsavedGeometryDraft(current.layer, mapID: context.mapID, store: store) || hasUnsavedDraft else {
            throw ProjectFileError.modifiedExternally
        }

        var persisted: [String: VectorVisualSettingsOptions] = [:]
        for option in options {
            guard let baseline = source.settings.options[option.id],
                  let definition = SourceVectorStyleCatalog.definition(for: option.id),
                  option.style.validatedForPersistence() == option.style else {
                throw ProjectFileError.invalid(VectorSymbologyValidation.invalidStyle)
            }
            let candidateGroups = groups(from: option)
            let conditionsChanged = !Self.conditionGroupsEqual(baseline.conditionGroups, candidateGroups)
            if conditionsChanged {
                guard !hasUnsavedDraft,
                      identity.mapLayerType != "GdbVectorLayer",
                      definition.conditionCapability == .attributeTable,
                      let inspection,
                      inspectionSupportsMapType(inspection, identity: identity, layer: source.layer),
                      canValidateConditions(candidateGroups, option: option) else {
                    throw ProjectFileError.invalid(hasUnsavedDraft ? Self.unsavedDraftReason : Self.unavailableConditionsReason)
                }
                if Self.hasActiveConditions(candidateGroups) {
                    try await validateCandidateConditions(
                        candidateGroups,
                        definitionID: option.id,
                        option: option,
                        identity: identity,
                        layer: source.layer,
                        inspection: inspection
                    )
                }
            }
            persisted[option.id] = VectorVisualSettingsOptions(
                values: option.style,
                conditionGroups: conditionsChanged ? candidateGroups : baseline.conditionGroups
            )
        }

        guard store.beginVectorStyleMutation() else {
            throw ProjectFileError.invalid(Self.mutationUnavailableReason)
        }
        defer { store.endVectorStyleMutation() }
        guard let expectedSourceRevision = source.layer.sourceRevision,
              try await CatalogPreviewFileRevision.sha256(source.layer.url)
                .caseInsensitiveCompare(expectedSourceRevision) == .orderedSame,
              let current = try resolvedLayerSource(context, store: store),
              current.settings.revision == capturedRevision,
              current.layer.sourceRevision == expectedSourceRevision,
              current.defaults == source.defaults,
              !hasUnsavedGeometryDraft(current.layer, mapID: context.mapID, store: store) || hasUnsavedDraft else {
            throw ProjectFileError.invalid(Self.sourceChangedReason)
        }
        try Task.checkCancellation()
        try store.commitVectorStyleOptions(persisted, context: context, defaults: source.defaults)
        if let owner = plotOptionsOwner(context: context, layer: source.layer) {
            transientPlotOptions[owner] = selectedPlotOptions
        }
        invalidatePlotFrames(mapID: context.mapID)
        await store.refreshVectorSymbologyContexts(mapID: context.mapID)
        await refresh(mapID: context.mapID)
        return styleOnlyUpdate(mapID: context.mapID, store: store)
    }

    func resetAllDefaults(context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot {
        guard context.scope == .global, let store,
              context.projectSessionID == store.globalSymbologySessionID,
              context.mapID == MapState.projectMapID else { throw ProjectFileError.modifiedExternally }
        preferences.resetAll()
        store.vectorGlobalStylesDidChange()
        for state in store.loadedVectorStyleMapStates() {
            await refresh(mapID: state.id)
        }
        return globalSnapshot()
    }

    func plotFrames(mapID: UUID) -> [String: VectorPlotRenderedLayer] {
        plotFrameCollections[mapID] ?? [:]
    }

    func plotFailures(mapID: UUID) -> [VectorPlotRenderFailure] {
        (plotFrameFailures[mapID] ?? [:]).values.sorted { $0.layerName < $1.layerName }
    }

    /// Produces source CPU-renderer replacements for the exact currently
    /// visible persisted vector nodes. Missing or stale sources simply retain
    /// their native Canvas draw; no transient frame is allowed to outlive its
    /// map, viewport, source family, or visualization revision.
    func refreshPlotFrames(mapID: UUID) async {
        invalidatePlotFrames(mapID: mapID)
        plotFrameFailures[mapID] = [:]
        guard let store, let client,
              let state = store.existingMapState(for: mapID),
              store.loadedVectorStyleMapStates().contains(where: { $0 === state }),
              let map = store.mapIdentityRequest(for: mapID),
              let viewport = state.resultViewport,
              Self.viewportIsSupported(viewport),
              store.sourceMapTreeContext(mapID).resultSelectionError == nil else { return }

        let canvasPixelSize = state.canvasPixelSize
        let renderFactor = WorkspaceRenderScaling.shared.factor
        guard canvasPixelSize.width.isFinite, canvasPixelSize.width > 0,
              renderFactor.isFinite, renderFactor > 0 else { return }
        let renderScale = renderFactor * Double(viewport.pixelWidth) / Double(canvasPixelSize.width)
        guard renderScale.isFinite, renderScale > 0 else { return }

        let generation = (plotGenerations[mapID] ?? 0) &+ 1
        plotGenerations[mapID] = generation
        let projectSessionID = store.projectSessionID
        let workflow = store.mapSourceWorkflowIdentity(mapID)
        let contexts = store.vectorSymbologyContexts(mapID: mapID)
        let layers = state.visibleVectors(store.mapLayers)
        let signatures = Self.layerSignature(layers)
        let context = store.sourceMapTreeContext(mapID)
        let mapRequest = VectorPlotMapRequest(
            projectPath: map.projectPath,
            projectXml: map.projectXml,
            projectXmlSHA: map.projectXmlSHA,
            mapID: map.mapID,
            mapIndex: map.mapIndex,
            mapName: map.mapName,
            mapType: map.mapType,
            expectedVisualizationRevision: map.expectedVisualizationRevision,
            resultSelectionOverrides: context.resultSelectionOverrides,
            coreLayerContext: map.coreLayerContext
        )
        var accepted: [String: VectorPlotRenderedLayer] = [:]

        for layer in layers {
            guard generation == plotGenerations[mapID], !Task.isCancelled,
                  store.projectSessionID == projectSessionID,
                  store.mapIdentityRequest(for: mapID) == map,
                  store.mapSourceWorkflowIdentity(mapID) == workflow,
                  state.resultViewport == viewport,
                  state.canvasPixelSize == canvasPixelSize,
                  WorkspaceRenderScaling.shared.factor == renderFactor,
                  let sourceRevision = layer.sourceRevision,
                  Self.isSHA256(sourceRevision),
                  let identityContext = contexts.first(where: {
                      $0.layerID == layer.id && $0.visualNode != nil && $0.specializedNode == nil
                  }),
                  contexts.filter({ $0.layerID == layer.id && $0.visualNode != nil && $0.specializedNode == nil }).count == 1,
                  let identity = identityContext.visualNode,
                  identity.mapIndex == map.mapIndex,
                  identity.mapName == map.mapName,
                  identity.mapType == map.mapType,
                  identity.assetID == SourceFilePaths.canonical(layer.url),
                  let locator = Self.locator(for: identity),
                  let expectedSource = expectedSource(for: layer, identity: identity,
                      mapID: mapID, store: store),
                  identityContext.visualizationRevision?.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
                  state.vectors(store.mapLayers).contains(where: {
                      $0.id == layer.id && SourceFilePaths.canonical($0.url) == identity.assetID
                          && $0.sourceRevision?.caseInsensitiveCompare(sourceRevision) == .orderedSame
                  }) else { continue }

            let optionsOwner = VectorPlotOptionsOwner(projectSessionID: projectSessionID,
                mapID: mapID, layerID: layer.id, sourcePath: SourceFilePaths.canonical(layer.url),
                sourceRevision: sourceRevision.uppercased())
            let requestedOptions = transientPlotOptions[optionsOwner] ?? [:]
            do {
                let optionRequest = VectorPlotOptionsRequest(map: mapRequest, node: locator,
                    layerID: layer.id, expectedFamily: expectedSource.family, sourceRevision: sourceRevision,
                    plotOptions: requestedOptions)
                let inspected: VectorPlotOptionsResponse = try await client.request(
                    "map.vector.plotOptions.inspect", parameters: optionRequest,
                    as: VectorPlotOptionsResponse.self)
                guard generation == plotGenerations[mapID], !Task.isCancelled,
                      store.projectSessionID == projectSessionID,
                      store.mapIdentityRequest(for: mapID) == map,
                      store.mapSourceWorkflowIdentity(mapID) == workflow,
                      state.resultViewport == viewport,
                      state.canvasPixelSize == canvasPixelSize,
                      WorkspaceRenderScaling.shared.factor == renderFactor,
                      Self.layerSignature(state.visibleVectors(store.mapLayers)) == signatures,
                      store.vectorSymbologyContexts(mapID: mapID) == contexts else { continue }
                guard Self.responseMatches(inspected, mapID: mapID, layer: layer, map: map,
                                      locator: locator, expectedOptions: requestedOptions) else {
                    throw BackendServiceError(code: "plotOptionsIdentityMismatch",
                        message: "The source renderer returned options for a different map layer or revision.")
                }
                let descriptors = inspected.plotOptions
                let renderOptions = Self.enabledOptions(requestedOptions, descriptors: descriptors)
                let styles = try plotStyles(identity: identity, source: identityContext,
                    presentation: state.vectorStyles[layer.id])
                let renderRequest = VectorPlotRenderRequest(map: mapRequest, node: locator,
                    layerID: layer.id, expectedFamily: expectedSource.family, sourceRevision: sourceRevision,
                    viewport: viewport, plotOptions: renderOptions, styles: styles,
                    renderScale: renderScale)
                let rendered: VectorPlotRenderResponse = try await client.request(
                    "map.vector.plot.render", parameters: renderRequest,
                    as: VectorPlotRenderResponse.self)
                guard Self.responseMatches(rendered, mapID: mapID, layer: layer, map: map,
                                      locator: locator, viewport: viewport,
                                      expectedOptions: renderOptions,
                                      expectedRenderScale: renderScale) else {
                    throw BackendServiceError(code: "plotFrameIdentityMismatch",
                        message: "The source renderer returned pixels for a different map layer, style, or viewport.")
                }
                guard rendered.pixelWidth == viewport.pixelWidth,
                      rendered.pixelHeight == viewport.pixelHeight,
                      rendered.rgba.count == viewport.pixelWidth * viewport.pixelHeight * 4,
                      rendered.labels.allSatisfy(Self.validLabel) else {
                    throw BackendServiceError(code: "invalidPlotFrame",
                        message: "The source renderer returned an invalid pixel frame or label.")
                }
                guard generation == plotGenerations[mapID], !Task.isCancelled,
                      store.projectSessionID == projectSessionID,
                      store.mapIdentityRequest(for: mapID) == map,
                      store.mapSourceWorkflowIdentity(mapID) == workflow,
                      state.resultViewport == viewport,
                      state.canvasPixelSize == canvasPixelSize,
                      WorkspaceRenderScaling.shared.factor == renderFactor,
                      Self.layerSignature(state.visibleVectors(store.mapLayers)) == signatures,
                      store.vectorSymbologyContexts(mapID: mapID) == contexts else { continue }
                accepted[layer.id] = try VectorPlotRenderedLayer(
                    mapID: mapID, sourceLayerID: layer.id,
                    sourceRevision: rendered.sourceRevision,
                    visualizationRevision: rendered.visualizationRevision,
                    viewport: MapVectorPlotViewport(viewport),
                    pixelWidth: rendered.pixelWidth, pixelHeight: rendered.pixelHeight,
                    rgba: rendered.rgba, labels: rendered.labels)
            } catch {
                // A failed source render is not a style-save failure. The
                // previous frame was removed before this request, so Canvas
                // safely draws the same source layer with native SwiftUI.
                guard !requestedOptions.isEmpty,
                      !Task.isCancelled,
                      generation == plotGenerations[mapID],
                      !Self.isStalePlotFailure(error),
                      store.projectSessionID == projectSessionID,
                      store.mapIdentityRequest(for: mapID) == map,
                      store.mapSourceWorkflowIdentity(mapID) == workflow,
                      state.resultViewport == viewport,
                      state.canvasPixelSize == canvasPixelSize,
                      WorkspaceRenderScaling.shared.factor == renderFactor,
                      Self.layerSignature(state.visibleVectors(store.mapLayers)) == signatures,
                      store.vectorSymbologyContexts(mapID: mapID) == contexts,
                      state.vectors(store.mapLayers).contains(where: {
                          $0.id == layer.id && $0.sourceRevision?.caseInsensitiveCompare(sourceRevision) == .orderedSame
                      }) else { continue }
                plotFrameFailures[mapID, default: [:]][layer.id] = VectorPlotRenderFailure(
                    layerID: layer.id, layerName: layer.name,
                    message: error.localizedDescription)
                continue
            }
        }

        guard generation == plotGenerations[mapID], !Task.isCancelled,
              store.projectSessionID == projectSessionID,
              store.existingMapState(for: mapID) === state,
              store.mapIdentityRequest(for: mapID) == map,
              store.mapSourceWorkflowIdentity(mapID) == workflow,
              state.resultViewport == viewport,
              state.canvasPixelSize == canvasPixelSize,
              WorkspaceRenderScaling.shared.factor == renderFactor,
              Self.layerSignature(state.visibleVectors(store.mapLayers)) == signatures,
              store.vectorSymbologyContexts(mapID: mapID) == contexts else { return }
        plotFrameCollections[mapID] = accepted
    }

    private static func isStalePlotFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let projectError = error as? ProjectFileError,
           case .modifiedExternally = projectError { return true }
        if let service = error as? BackendServiceError {
            return ["sourceChanged", "notFound", "cancelled", "canceled", "stale"].contains(service.code)
        }
        return false
    }

    private struct VectorPlotCapture {
        let map: MapTreeMapIdentity
        let requestMap: VectorPlotMapRequest
        let locator: CatalogTreeNodeLocator
        let family: MapSourceFamilyCapture?
        let owner: VectorPlotOptionsOwner
        let sourceRevision: String
    }

    private func inspectPlotOptions(_ context: VectorSymbologyContext,
                                    source: VectorSymbologyLayerSource,
                                    store: WorkspaceStore) async throws -> [VectorPlotOption] {
        guard let client else { throw ProjectFileError.invalid(Self.unavailableConditionsReason) }
        let capture = try plotCapture(context, source: source, store: store)
        let workflow = store.mapSourceWorkflowIdentity(context.mapID)
        let values = transientPlotOptions[capture.owner] ?? [:]
        let response: VectorPlotOptionsResponse = try await client.request(
            "map.vector.plotOptions.inspect",
            parameters: VectorPlotOptionsRequest(map: capture.requestMap,
                node: capture.locator, layerID: source.layer.id,
                expectedFamily: capture.family, sourceRevision: capture.sourceRevision,
                plotOptions: values),
            as: VectorPlotOptionsResponse.self)
        guard Self.responseMatches(response, mapID: context.mapID, layer: source.layer,
                              map: capture.map, locator: capture.locator,
                              expectedOptions: values),
              store.projectSessionID == context.projectSessionID,
              store.mapIdentityRequest(for: context.mapID) == capture.map,
              store.mapSourceWorkflowIdentity(context.mapID) == workflow,
              store.vectorSymbologyContexts(mapID: context.mapID).contains(context),
              let current = try resolvedLayerSource(context, store: store),
              current.settings.revision == source.settings.revision,
              current.layer.sourceRevision == source.layer.sourceRevision else {
            throw ProjectFileError.modifiedExternally
        }
        return try response.plotOptions.map { descriptor in
            guard descriptor.kind == "bool" || descriptor.kind == "enum",
                  descriptor.kind != "bool" || descriptor.enumValues.isEmpty,
                  descriptor.kind != "enum" || !descriptor.enumValues.isEmpty,
                  descriptor.kind != "enum" || descriptor.enumValues.contains(where: { $0.value == descriptor.value }) else {
                throw ProjectFileError.invalid("The source vector renderer returned an unsupported PlotOption contract.")
            }
            return VectorPlotOption(id: descriptor.propertyName, title: descriptor.label,
                isBoolean: descriptor.kind == "bool", value: descriptor.value,
                choices: descriptor.enumValues.map {
                    EditorChoice(id: $0.value, title: $0.label)
                }, isEnabled: descriptor.isEnabled, description: descriptor.description)
        }
    }

    private func validatedPlotOptions(_ submitted: [VectorPlotOption],
                                     context: VectorSymbologyContext,
                                     source: VectorSymbologyLayerSource,
                                     store: WorkspaceStore) async throws -> [String: String] {
        guard let client else {
            if submitted.isEmpty { return [:] }
            throw ProjectFileError.invalid("The retained vector PlotOption service is unavailable.")
        }
        let capture = try plotCapture(context, source: source, store: store)
        guard Set(submitted.map(\.id)).count == submitted.count else {
            throw ProjectFileError.invalid("Vector PlotOption properties must be unique.")
        }
        let previous = transientPlotOptions[capture.owner] ?? [:]
        // A renderer-inspection failure hides these controls. Applying only
        // the ordinary .vis editor must then preserve any last accepted
        // transient values instead of silently resetting them.
        if submitted.isEmpty { return previous }

        let baseline: VectorPlotOptionsResponse = try await client.request(
            "map.vector.plotOptions.inspect",
            parameters: VectorPlotOptionsRequest(map: capture.requestMap,
                node: capture.locator, layerID: source.layer.id,
                expectedFamily: capture.family, sourceRevision: capture.sourceRevision,
                plotOptions: previous),
            as: VectorPlotOptionsResponse.self)
        guard Self.responseMatches(baseline, mapID: context.mapID, layer: source.layer,
                              map: capture.map, locator: capture.locator, expectedOptions: previous) else {
            throw ProjectFileError.modifiedExternally
        }
        let descriptors = Dictionary(baseline.plotOptions.map { ($0.propertyName, $0) },
                                     uniquingKeysWith: { first, _ in first })
        guard descriptors.count == baseline.plotOptions.count,
              Set(descriptors.keys) == Set(submitted.map(\.id)) else {
            throw ProjectFileError.modifiedExternally
        }
        var valuesToApply: [String: String] = [:]
        for option in submitted {
            guard let descriptor = descriptors[option.id] else { throw ProjectFileError.modifiedExternally }
            if descriptor.kind == "bool" {
                guard option.isBoolean, option.choices.isEmpty,
                      option.value == "true" || option.value == "false" else {
                    throw ProjectFileError.invalid("A vector PlotOption value does not match its source type.")
                }
            } else if descriptor.kind == "enum" {
                guard !option.isBoolean,
                      descriptor.enumValues.contains(where: { $0.value == option.value }) else {
                    throw ProjectFileError.invalid("A vector PlotOption value is not one of the source choices.")
                }
            } else {
                throw ProjectFileError.invalid("The source vector renderer returned an unsupported PlotOption type.")
            }
            if descriptor.isEnabled {
                valuesToApply[option.id] = option.value
            } else if option.value != descriptor.value {
                throw ProjectFileError.invalid("A disabled source PlotOption cannot be changed.")
            }
        }
        let validated: VectorPlotOptionsResponse = try await client.request(
            "map.vector.plotOptions.inspect",
            parameters: VectorPlotOptionsRequest(map: capture.requestMap,
                node: capture.locator, layerID: source.layer.id,
                expectedFamily: capture.family, sourceRevision: capture.sourceRevision,
                plotOptions: valuesToApply),
            as: VectorPlotOptionsResponse.self)
        guard Self.responseMatches(validated, mapID: context.mapID, layer: source.layer,
                              map: capture.map, locator: capture.locator,
                              expectedOptions: valuesToApply),
              validated.plotOptions.allSatisfy({ descriptor in
                  valuesToApply[descriptor.propertyName].map { $0 == descriptor.value } ?? true
              }) else {
            throw ProjectFileError.invalid("The source vector renderer rejected the selected PlotOption values.")
        }
        return valuesToApply
    }

    private func plotCapture(_ context: VectorSymbologyContext,
                             source: VectorSymbologyLayerSource,
                             store: WorkspaceStore) throws -> VectorPlotCapture {
        guard context.scope == .layer, context.projectSessionID == store.projectSessionID,
              source.context == context, source.layer.id == context.layerID,
              source.layer.sourceMapID == context.mapID,
              let identity = context.visualNode,
              let sourceRevision = source.layer.sourceRevision,
              Self.isSHA256(sourceRevision),
              let map = store.mapIdentityRequest(for: context.mapID),
              context.visualizationRevision?.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              identity.mapIndex == map.mapIndex, identity.mapName == map.mapName,
              identity.mapType == map.mapType,
              identity.mapLayerType == "PointsVector" || identity.mapLayerType == "PolylinesVector"
                  || identity.mapLayerType == "PolygonsVector" || identity.mapLayerType == "GdbVectorLayer",
              identity.assetID == SourceFilePaths.canonical(source.layer.url),
              let locator = Self.locator(for: identity) else {
            throw ProjectFileError.modifiedExternally
        }
        let requestContext = store.sourceMapTreeContext(context.mapID)
        guard requestContext.resultSelectionError == nil,
              let projectPath = requestContext.projectURL?.standardizedFileURL.path else {
            throw ProjectFileError.modifiedExternally
        }
        guard let expectedSource = expectedSource(for: source.layer, identity: identity,
                                                  mapID: context.mapID, store: store) else {
            throw ProjectFileError.invalid("The retained vector renderer does not support this source identity.")
        }
        let requestMap = VectorPlotMapRequest(projectPath: projectPath,
            projectXml: map.projectXml, projectXmlSHA: map.projectXmlSHA,
            mapID: map.mapID, mapIndex: map.mapIndex, mapName: map.mapName,
            mapType: map.mapType, expectedVisualizationRevision: map.expectedVisualizationRevision,
            resultSelectionOverrides: requestContext.resultSelectionOverrides,
            coreLayerContext: map.coreLayerContext)
        let owner = VectorPlotOptionsOwner(projectSessionID: context.projectSessionID,
            mapID: context.mapID, layerID: source.layer.id,
            sourcePath: SourceFilePaths.canonical(source.layer.url),
            sourceRevision: sourceRevision.uppercased())
        return VectorPlotCapture(map: map, requestMap: requestMap, locator: locator,
            family: expectedSource.family, owner: owner, sourceRevision: sourceRevision)
    }

    private func expectedSource(for layer: MapVectorLayer, identity: VectorVisualNodeIdentity,
                                mapID: UUID, store: WorkspaceStore) -> VectorPlotExpectedSource? {
        guard let revision = layer.sourceRevision, Self.isSHA256(revision),
              identity.assetID == SourceFilePaths.canonical(layer.url) else { return nil }
        if identity.mapLayerType == "GdbVectorLayer" {
            guard let layerName = identity.gdbLayerName, !layerName.isEmpty,
                  let vectorType = identity.gdbVectorType,
                  ["Point", "PointCollection", "Line", "LineCollection", "Polygon", "PolygonCollection"]
                    .contains(vectorType),
                  layer.url.pathExtension.lowercased() == "gdb" else { return nil }
            return .geodatabase
        }
        switch layer.url.pathExtension.lowercased() {
        case "shp":
            guard let captured = store.sourceMapVectorFamilyCaptures[mapID]?[SourceFilePaths.canonical(layer.url)],
                  captured.family == "shapefile",
                  SourceFilePaths.canonical(URL(fileURLWithPath: captured.sourcePath))
                    == SourceFilePaths.canonical(layer.url),
                  Self.primaryRevision(captured)?.caseInsensitiveCompare(revision) == .orderedSame else {
                return nil
            }
            return .shapefile(captured)
        case "json", "geojson":
            return .geoJSON
        default:
            return nil
        }
    }

    private static func locator(for identity: VectorVisualNodeIdentity) -> CatalogTreeNodeLocator? {
        let isSupportedNodeType = identity.mapLayerType == "GdbVectorLayer"
            ? identity.nodeType == "GdbVectorLayer"
            : identity.nodeType == "MapLayer"
        guard let rootName = identity.rootName, !rootName.isEmpty,
              !identity.nodePath.isEmpty, isSupportedNodeType,
              let filename = identity.filename, !filename.isEmpty,
              let filenameRelative = identity.filenameRelative, !filenameRelative.isEmpty,
              let assetID = identity.assetID, !assetID.isEmpty else { return nil }
        return CatalogTreeNodeLocator(rootName: rootName, nodeType: identity.nodeType,
            nodeName: identity.nodeName, nodePath: identity.nodePath, assetID: assetID,
            mapType: identity.mapLayerType, filename: filename, filenameRelative: filenameRelative)
    }

    private static func primaryRevision(_ family: MapSourceFamilyCapture) -> String? {
        let sources = family.files.filter { $0.role == "source" }
        guard sources.count == 1 else { return nil }
        return sources[0].revision
    }

    private static func responseMatches(_ response: VectorPlotOptionsResponse,
                                        mapID: UUID, layer: MapVectorLayer,
                                        map: MapTreeMapIdentity,
                                        locator: CatalogTreeNodeLocator,
                                        expectedOptions: [String: String]) -> Bool {
        guard response.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              response.layerID == layer.id,
              response.sourcePath == SourceFilePaths.canonical(layer.url),
              layer.sourceRevision?.caseInsensitiveCompare(response.sourceRevision) == .orderedSame,
              response.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              Set(response.plotOptions.map(\.propertyName)).count == response.plotOptions.count else { return false }
        let descriptors = Dictionary(response.plotOptions.map { ($0.propertyName, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return expectedOptions.allSatisfy { descriptors[$0.key]?.value == $0.value }
            && (locator.nodeType == "MapLayer" || locator.nodeType == "GdbVectorLayer")
    }

    private static func responseMatches(_ response: VectorPlotRenderResponse,
                                        mapID: UUID, layer: MapVectorLayer,
                                        map: MapTreeMapIdentity,
                                        locator: CatalogTreeNodeLocator,
                                        viewport: RasterMapViewExtent,
                                        expectedOptions: [String: String],
                                        expectedRenderScale: Double) -> Bool {
        guard response.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              response.layerID == layer.id,
              response.sourcePath == SourceFilePaths.canonical(layer.url),
              layer.sourceRevision?.caseInsensitiveCompare(response.sourceRevision) == .orderedSame,
              response.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              response.viewport == viewport,
              response.renderScale == expectedRenderScale,
              Set(response.plotOptions.map(\.propertyName)).count == response.plotOptions.count else { return false }
        let descriptors = Dictionary(response.plotOptions.map { ($0.propertyName, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return expectedOptions.allSatisfy { descriptors[$0.key]?.value == $0.value }
            && (locator.nodeType == "MapLayer" || locator.nodeType == "GdbVectorLayer")
    }

    private func plotStyles(identity: VectorVisualNodeIdentity,
                            source: VectorSymbologyContext,
                            presentation: MapVectorStylePresentation?) throws -> [VectorPlotStyle] {
        guard let store, let resolved = try resolvedLayerSource(source, store: store),
              let definitions = identity.supportedStyleDefinitionIDs else {
            throw ProjectFileError.modifiedExternally
        }
        return try definitions.map { definitionID in
            guard let base = presentation?.base[definitionID]
                    ?? resolved.settings.options[definitionID]?.values
                    ?? resolved.defaults[definitionID] else {
                throw ProjectFileError.modifiedExternally
            }
            let overrides = (presentation?.sourceFeatureOrdinalBindingVerified == true
                ? presentation?.perSourceFeatureOverrides ?? [:] : [:])
                .keys.sorted().compactMap { sourceIndex -> VectorPlotStyleOverride? in
                    guard let value = presentation?.perSourceFeatureOverrides[sourceIndex]?[definitionID] else { return nil }
                    return VectorPlotStyleOverride(sourceFeatureIndex: sourceIndex, values: value)
                }
            return VectorPlotStyle(definitionID: definitionID, base: base, sourceOverrides: overrides)
        }
    }

    private func plotOptionsOwner(context: VectorSymbologyContext,
                                  layer: MapVectorLayer) -> VectorPlotOptionsOwner? {
        guard let revision = layer.sourceRevision, Self.isSHA256(revision) else { return nil }
        return VectorPlotOptionsOwner(projectSessionID: context.projectSessionID,
            mapID: context.mapID, layerID: layer.id,
            sourcePath: SourceFilePaths.canonical(layer.url), sourceRevision: revision.uppercased())
    }

    private func invalidatePlotFrames(mapID: UUID) {
        plotGenerations[mapID] = (plotGenerations[mapID] ?? 0) &+ 1
        if plotFrameCollections[mapID] != nil { plotFrameCollections[mapID] = nil }
        if plotFrameFailures[mapID] != nil { plotFrameFailures[mapID] = [:] }
    }

    private static func enabledOptions(_ values: [String: String],
                                       descriptors: [VectorPlotOptionPayload]) -> [String: String] {
        let enabled = Set(descriptors.filter(\.isEnabled).map(\.propertyName))
        return values.filter { enabled.contains($0.key) }
    }

    private static func validLabel(_ label: MapVectorPlotLabel) -> Bool {
        !label.text.isEmpty && label.point.x.isFinite && label.point.y.isFinite
            && label.polyline.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    private static func viewportIsSupported(_ viewport: RasterMapViewExtent) -> Bool {
        viewport.minX.isFinite && viewport.minY.isFinite && viewport.maxX.isFinite && viewport.maxY.isFinite
            && viewport.minX < viewport.maxX && viewport.minY < viewport.maxY
            && viewport.pixelWidth > 0 && viewport.pixelHeight > 0
            && viewport.pixelWidth <= 4096 && viewport.pixelHeight <= 4096
            && viewport.pixelWidth <= 2_097_152 / viewport.pixelHeight
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private func resolvedLayerSource(_ context: VectorSymbologyContext,
                                     store: WorkspaceStore) throws -> VectorSymbologyLayerSource? {
        guard let raw = try store.vectorStyleLayerSource(context) else { return nil }
        guard let layerID = context.layerID,
              let identity = context.visualNode,
              raw.context == context,
              raw.layer.id == layerID,
              SourceFilePaths.canonical(raw.layer.url) == identity.assetID else {
            throw ProjectFileError.modifiedExternally
        }
        guard let revision = raw.settings.revision else { return raw }
        for key in Array(effectiveSettings.keys) where key.projectSessionID != context.projectSessionID {
            effectiveSettings.removeValue(forKey: key)
        }
        let owner = EffectiveSettingsOwner(context: context)
        let settings: VectorVisualSettingsSnapshot
        if let previous = effectiveSettings[owner], previous.revision == revision {
            if previous.defaults == raw.defaults {
                settings = previous.settings
            } else {
                settings = VectorVisualSettingsDefaultSync.resolve(
                    raw: raw.settings,
                    previous: previous.settings,
                    previousDefaults: previous.defaults,
                    newDefaults: raw.defaults
                )
                effectiveSettings[owner] = EffectiveSettingsEntry(
                    revision: revision, defaults: raw.defaults, settings: settings
                )
            }
        } else {
            settings = raw.settings
            effectiveSettings[owner] = EffectiveSettingsEntry(
                revision: revision, defaults: raw.defaults, settings: settings
            )
        }
        return VectorSymbologyLayerSource(
            context: raw.context,
            layer: raw.layer,
            settings: settings,
            defaults: raw.defaults
        )
    }

    /// Rebuilds the real map-layer style presentation. It never changes vector
    /// source files, draft geometry, selection, or map history.
    func refresh(mapID: UUID) async {
        guard let store else { return }
        // `.vis` and global-default revisions are separate from source SHA.
        // Remove a frame before any asynchronous style recomputation so a
        // previous render cannot remain visible under newly effective colors.
        invalidatePlotFrames(mapID: mapID)
        let generation = (refreshGenerations[mapID] ?? 0) &+ 1
        refreshGenerations[mapID] = generation
        guard let state = store.loadedVectorStyleMapStates().first(where: { $0.id == mapID }) else { return }

        let projectSessionID = store.projectSessionID
        let contexts = store.vectorSymbologyContexts(mapID: mapID)
        let globalOverrides = preferences.loadOverrides()
        let layers = state.vectors(store.mapLayers)
        let layerSignature = Self.layerSignature(layers)
        let draftSignature = Self.draftSignature(state)
        let capturedVisualizationRevision = contexts.first?.visualizationRevision
        let inspectionCache = InspectionCache()
        var presentations: [String: MapVectorStylePresentation] = [:]

        for layer in layers {
            var base = globalBase(for: layer)
            var candidates: [String: [LocalCandidate]] = [:]
            // A rendered instance is keyed by its exact visualization-node
            // identity. Sibling `.vis` nodes may share a file and source row
            // ordinals, but they own different local styles and presentations.
            let matchingContexts = contexts.filter { $0.visualNode != nil && $0.layerID == layer.id }
            for context in matchingContexts {
                guard generation == refreshGenerations[mapID], !Task.isCancelled,
                      store.projectSessionID == projectSessionID,
                      let source = try? resolvedLayerSource(context, store: store),
                      let identity = context.visualNode,
                      let definitionIDs = identity.supportedStyleDefinitionIDs else { continue }
                let draftIsDirty = hasUnsavedGeometryDraft(layer, mapID: mapID, store: store)
                for definitionID in definitionIDs {
                    guard let option = source.settings.options[definitionID],
                          let variant = variant(for: definitionID, identity: identity) else { continue }
                    for renderID in renderDefinitionIDs(definitionID, identity: identity) {
                        candidates[renderID, default: []].append(LocalCandidate(
                            sourceID: definitionID,
                            renderID: renderID,
                            option: option,
                            identity: identity,
                            variant: variant,
                            hasUnsavedDraft: draftIsDirty
                        ))
                    }
                }
            }

            var selected: [String: LocalCandidate] = [:]
            for (renderID, values) in candidates {
                // Exact instance IDs prevent sibling nodes from entering this
                // set. Keep the first source definition only if one visual
                // node aliases several definitions to the same renderer ID.
                if let candidate = values.first { selected[renderID] = candidate }
            }

            for (renderID, candidate) in selected {
                base[renderID] = candidate.option.values
            }

            var perFeature: [Int: [String: VectorStyleValues]] = [:]
            var bindingVerified = false
            if let client, let expectedRevision = layer.sourceRevision,
               !expectedRevision.isEmpty, let vectorPath = Self.backendPath(for: layer.url) {
                let conditionCandidates = selected.values.filter { candidate in
                    !candidate.hasUnsavedDraft
                        && candidate.identity.mapLayerType != "GdbVectorLayer"
                        && Self.hasActiveConditions(candidate.option.conditionGroups)
                }
                let grouped = Dictionary(grouping: conditionCandidates, by: { Self.geometryType(for: $0.identity) })
                for (geometryType, candidatesForGeometry) in grouped {
                    guard let geometryType,
                          let inspection = await cachedInspection(
                            client: client,
                            layer: layer,
                            vectorPath: vectorPath,
                            cache: inspectionCache
                          ),
                          generation == refreshGenerations[mapID],
                          Self.layerSignature(state.vectors(store.mapLayers)) == layerSignature,
                          Self.draftSignature(state) == draftSignature else { continue }
                    guard let bucket = inspection.buckets.first(where: { $0.geometryType == geometryType }),
                          candidatesForGeometry.allSatisfy({ candidate in
                              bucket.supportedDefinitionIDs.contains(candidate.sourceID)
                                  && inspectionSupportsBucket(bucket, identity: candidate.identity, layer: layer)
                          }) else { continue }

                    let properties = candidatesForGeometry.flatMap { candidate in
                        candidate.option.conditionGroups.compactMap { group -> WirePropertyConditions? in
                            let activeRules = group.rules.filter(Self.isComplete)
                            guard !activeRules.isEmpty,
                                  candidate.variant.supportedFields.contains(group.field) else { return nil }
                            return WirePropertyConditions(
                                definitionID: candidate.sourceID,
                                property: group.field.rawValue,
                                conditions: activeRules.map {
                                    WireCondition(column: $0.column, operator: $0.comparison,
                                                  threshold: $0.threshold, resultValue: $0.resultValue)
                                }
                            )
                        }
                    }
                    guard !properties.isEmpty,
                          let sourceIndices = VectorSymbologyOrdinalBinding.verifiedSourceIndices(
                              renderedFeatures: layer.features,
                              kind: Self.featureKind(for: geometryType),
                              sourceIndices: bucket.sourceFeatureIndices,
                              tableRowCount: bucket.tableRowCount,
                              renderFeatureCount: bucket.renderFeatureCount,
                              ordinalBindingProven: bucket.ordinalBindingProven
                          ) else { continue }
                    let request = WireEvaluationRequest(
                        vectorPath: vectorPath,
                        revision: expectedRevision,
                        geometryType: geometryType,
                        sourceFeatureIndices: sourceIndices,
                        properties: properties
                    )
                    do {
                        let result: WireEvaluation = try await client.request("vector.symbology.evaluate", parameters: request)
                        guard result.revision.caseInsensitiveCompare(expectedRevision) == .orderedSame,
                              generation == refreshGenerations[mapID],
                              store.projectSessionID == projectSessionID,
                              Self.layerSignature(state.vectors(store.mapLayers)) == layerSignature,
                              Self.draftSignature(state) == draftSignature else { continue }
                        let validated = try validatedOverrides(result, request: request)
                        for item in validated {
                            guard item.hasMatch,
                                  let candidate = candidatesForGeometry.first(where: {
                                      $0.sourceID == item.definitionID
                                  }) else { continue }
                            var style = perFeature[item.sourceFeatureIndex]?[candidate.renderID]
                                ?? candidate.option.values
                            try apply(item, to: &style)
                            perFeature[item.sourceFeatureIndex, default: [:]][candidate.renderID] = style
                        }
                        bindingVerified = true
                    } catch {
                        // A stale/malformed table response cannot turn into a
                        // partial style. Keep the source base styles for this
                        // layer and let a later explicit refresh retry.
                        continue
                    }
                }
            }

            presentations[layer.id] = MapVectorStylePresentation(
                base: base,
                perSourceFeatureOverrides: perFeature,
                sourceFeatureOrdinalBindingVerified: bindingVerified && !perFeature.isEmpty
            )
        }

        guard generation == refreshGenerations[mapID], !Task.isCancelled,
              store.projectSessionID == projectSessionID,
              store.loadedVectorStyleMapStates().contains(where: { $0 === state }),
              store.vectorSymbologyContexts(mapID: mapID) == contexts,
              preferences.loadOverrides() == globalOverrides,
              Self.layerSignature(state.vectors(store.mapLayers)) == layerSignature,
              Self.draftSignature(state) == draftSignature,
              contexts.first?.visualizationRevision == capturedVisualizationRevision else { return }
        let update = MapUpdate(
            vectors: nil,
            rasters: nil,
            preview: [],
            selectedLayerID: nil,
            selectedFeatureID: nil,
            vectorStyles: presentations,
            preserveInteractionState: true
        )
        store.installMapUpdate(update, mapID: mapID)
        await refreshPlotFrames(mapID: mapID)
    }

    private func globalSnapshot() -> VectorSymbologySnapshot {
        let options = SourceVectorStyleCatalog.definitions.map { definition in
            VectorStyleOption(
                id: definition.id,
                name: definition.name,
                layerName: definition.layerName,
                type: Self.vectorType(definition.type),
                style: preferences.style(for: definition.id) ?? definition.defaultStyle,
                defaultStyle: definition.defaultStyle,
                columns: [],
                conditions: [:],
                conditionsEnabled: false,
                conditionCapability: definition.conditionCapability
            )
        }
        return VectorSymbologySnapshot(options: options, additionalOptions: [], canEdit: true)
    }

    private func specializedSnapshot(_ context: VectorSymbologyContext,
                                     store: WorkspaceStore) throws -> VectorSymbologySnapshot? {
        guard context.scope == .layer, context.visualNode == nil,
              let identity = context.specializedNode,
              identity.geometryAssetID == context.assetID,
              let definitionIDs = identity.definitionIDs,
              let source = try store.specializedVectorStyleSource(context) else { return nil }
        guard source.context == context,
              source.settings.revision == context.visualizationRevision,
              Set(source.settings.options.keys) == Set(definitionIDs),
              Set(source.defaults.keys) == Set(definitionIDs) else {
            throw ProjectFileError.modifiedExternally
        }

        let options = try definitionIDs.map { definitionID -> VectorStyleOption in
            guard let settings = source.settings.options[definitionID],
                  let defaultStyle = source.defaults[definitionID],
                  let variant = specializedVariant(for: definitionID, identity: identity),
                  let definition = SourceVectorStyleCatalog.definition(for: definitionID) else {
                throw ProjectFileError.modifiedExternally
            }
            return VectorStyleOption(
                id: definitionID,
                name: variant.name,
                layerName: variant.layerName,
                type: Self.vectorType(variant.type),
                style: settings.values,
                defaultStyle: defaultStyle,
                columns: [],
                conditions: Dictionary(uniqueKeysWithValues: settings.conditionGroups.map { ($0.field, $0.rules) }),
                conditionsEnabled: false,
                conditionCapability: definition.conditionCapability,
                conditionCapabilityReason: Self.unavailableConditionsReason
            )
        }
        return VectorSymbologySnapshot(options: options, additionalOptions: [], canEdit: true)
    }

    private func applySpecialized(options: [VectorStyleOption],
                                  context: VectorSymbologyContext,
                                  store: WorkspaceStore) async throws -> MapUpdate {
        guard let identity = context.specializedNode,
              context.visualNode == nil,
              identity.geometryAssetID == context.assetID,
              let definitionIDs = identity.definitionIDs,
              let captured = try store.specializedVectorStyleSource(context),
              captured.context == context,
              captured.settings.revision == context.visualizationRevision,
              Set(captured.settings.options.keys) == Set(definitionIDs),
              Set(captured.defaults.keys) == Set(definitionIDs),
              Set(options.map(\.id)).count == options.count,
              Set(options.map(\.id)) == Set(definitionIDs) else {
            throw ProjectFileError.modifiedExternally
        }
        guard let capturedRevision = captured.settings.revision,
              capturedRevision.caseInsensitiveCompare(context.visualizationRevision ?? "") == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }

        var persisted: [String: VectorVisualSettingsOptions] = [:]
        for option in options {
            guard let baseline = captured.settings.options[option.id],
                  let definition = SourceVectorStyleCatalog.definition(for: option.id),
                  specializedVariant(for: option.id, identity: identity) != nil,
                  option.style.validatedForPersistence() == option.style else {
                throw ProjectFileError.invalid(VectorSymbologyValidation.invalidStyle)
            }
            guard Self.conditionGroupsEqual(baseline.conditionGroups, groups(from: option)) else {
                // Specialized rules require their original topology/mesh
                // context. This editor only changes source base styles and
                // must retain every stored rule exactly as loaded.
                throw ProjectFileError.invalid(Self.unavailableConditionsReason)
            }
            guard definition.type != "Text" else {
                throw ProjectFileError.invalid(VectorSymbologyValidation.invalidStyle)
            }
            persisted[option.id] = VectorVisualSettingsOptions(
                values: option.style,
                conditionGroups: baseline.conditionGroups
            )
        }

        guard store.beginVectorStyleMutation() else {
            throw ProjectFileError.invalid(Self.mutationUnavailableReason)
        }
        defer { store.endVectorStyleMutation() }
        guard let current = try store.specializedVectorStyleSource(context),
              current.context == context,
              current.settings.revision == capturedRevision,
              current.defaults == captured.defaults,
              Set(current.settings.options.keys) == Set(definitionIDs) else {
            throw ProjectFileError.modifiedExternally
        }
        for option in options {
            guard let baseline = current.settings.options[option.id],
                  Self.conditionGroupsEqual(baseline.conditionGroups, groups(from: option)) else {
                throw ProjectFileError.modifiedExternally
            }
        }
        try Task.checkCancellation()
        try store.commitSpecializedVectorStyleOptions(persisted, context: context, defaults: captured.defaults)
        await store.refreshVectorSymbologyContexts(mapID: context.mapID)
        await refresh(mapID: context.mapID)
        return styleOnlyUpdate(mapID: context.mapID, store: store)
    }

    private func specializedVariant(for definitionID: String,
                                    identity: SpecializedVectorVisualNodeIdentity) -> VectorStyleDefinitionVariant? {
        let expectedContext: String
        switch identity.nodeType {
        case "ConceptualMesh": expectedContext = "Ras.Visual.WinUI.Contexts.TopologyVisualContext"
        case "FlowAreaLayer": expectedContext = "Ras.Visual.WinUI.Contexts.FlowAreaLayerVisualContext"
        case "CulvertBarrelLayer": expectedContext = "Ras.Visual.WinUI.Contexts.CulvertBarrelLayerVisualContext"
        default: return nil
        }
        guard identity.definitionIDs?.contains(definitionID) == true else { return nil }
        return SourceVectorStyleCatalog.variants(for: definitionID).first {
            $0.sourceContext == expectedContext
        }
    }

    private func applyGlobal(_ options: [VectorStyleOption], context: VectorSymbologyContext,
                             store: WorkspaceStore) throws {
        let definitions = SourceVectorStyleCatalog.definitions
            guard context.projectSessionID == store.globalSymbologySessionID,
                  context.mapID == MapState.projectMapID,
              Set(options.map(\.id)).count == options.count,
              Set(options.map(\.id)) == Set(definitions.map(\.id)) else {
            throw ProjectFileError.invalid("The global vector style selection is incomplete or ambiguous.")
        }
        var overrides: [String: VectorStyleValues] = [:]
        for option in options {
            guard let validated = option.style.validatedForPersistence(), validated == option.style else {
                throw ProjectFileError.invalid(VectorSymbologyValidation.invalidStyle)
            }
            overrides[option.id] = validated
        }
        try preferences.setOverrides(overrides)
        store.vectorGlobalStylesDidChange()
    }

    private func validateCandidateConditions(_ groups: [VectorVisualConditionGroup],
                                             definitionID: String,
                                             option: VectorStyleOption,
                                             identity: VectorVisualNodeIdentity,
                                             layer: MapVectorLayer,
                                             inspection: VectorSymbologyInspection) async throws {
        guard let client, let revision = layer.sourceRevision,
              let path = Self.backendPath(for: layer.url),
              let geometryType = Self.geometryType(for: identity),
              let bucket = inspection.buckets.first(where: { $0.geometryType == geometryType }),
              bucket.supportedDefinitionIDs.contains(definitionID),
              inspectionSupportsBucket(bucket, identity: identity, layer: layer),
              let indices = VectorSymbologyOrdinalBinding.verifiedSourceIndices(
                  renderedFeatures: layer.features,
                  kind: Self.featureKind(for: geometryType),
                  sourceIndices: bucket.sourceFeatureIndices,
                  tableRowCount: bucket.tableRowCount,
                  renderFeatureCount: bucket.renderFeatureCount,
                  ordinalBindingProven: bucket.ordinalBindingProven
              ) else {
            throw ProjectFileError.invalid(Self.unavailableConditionsReason)
        }
        let properties = groups.compactMap { group -> WirePropertyConditions? in
            let activeRules = group.rules.filter(Self.isComplete)
            guard !activeRules.isEmpty, option.properties.contains(group.field) else { return nil }
            return WirePropertyConditions(
                definitionID: definitionID,
                property: group.field.rawValue,
                conditions: activeRules.map {
                    WireCondition(column: $0.column, operator: $0.comparison,
                                  threshold: $0.threshold, resultValue: $0.resultValue)
                }
            )
        }
        guard !properties.isEmpty else { return }
        let request = WireEvaluationRequest(vectorPath: path, revision: revision,
            geometryType: geometryType, sourceFeatureIndices: indices, properties: properties)
        let result: WireEvaluation = try await client.request("vector.symbology.evaluate", parameters: request)
        guard result.revision.caseInsensitiveCompare(revision) == .orderedSame else {
            throw ProjectFileError.invalid(Self.sourceChangedReason)
        }
        _ = try validatedOverrides(result, request: request)
    }

    private func inspect(_ layer: MapVectorLayer) async throws -> VectorSymbologyInspection {
        guard let client, let revision = layer.sourceRevision,
              let path = Self.backendPath(for: layer.url) else {
            throw ProjectFileError.invalid(Self.unavailableConditionsReason)
        }
        let request = WireInspectRequest(vectorPath: path, revision: revision)
        let result: WireInspection = try await client.request("vector.symbology.inspect", parameters: request)
        guard result.revision.caseInsensitiveCompare(revision) == .orderedSame,
              result.sourceFeatureCount >= 0,
              result.buckets.allSatisfy(Self.validBucketShape) else {
            throw ProjectFileError.invalid(Self.sourceChangedReason)
        }
        return result
    }

    private func cachedInspection(client: BackendProcessClient, layer: MapVectorLayer,
                                  vectorPath: String,
                                  cache: InspectionCache) async -> VectorSymbologyInspection? {
        guard let revision = layer.sourceRevision else { return nil }
        let key = vectorPath + "\n" + revision
        if let cached = cache.values[key] { return cached }
        do {
            let request = WireInspectRequest(vectorPath: vectorPath, revision: revision)
            let inspection: WireInspection = try await client.request("vector.symbology.inspect", parameters: request)
            guard inspection.revision.caseInsensitiveCompare(revision) == .orderedSame,
                  inspection.sourceFeatureCount >= 0,
                  inspection.buckets.allSatisfy(Self.validBucketShape) else { return nil }
            cache.values[key] = inspection
            return inspection
        } catch { return nil }
    }

    private func inspectionSupportsMapType(_ inspection: VectorSymbologyInspection,
                                          identity: VectorVisualNodeIdentity,
                                          layer: MapVectorLayer) -> Bool {
        guard let geometryType = Self.geometryType(for: identity),
              let bucket = inspection.buckets.first(where: { $0.geometryType == geometryType }) else { return false }
        return inspectionSupportsBucket(bucket, identity: identity, layer: layer)
    }

    private func inspectionSupportsBucket(_ bucket: WireBucket,
                                          identity: VectorVisualNodeIdentity,
                                          layer: MapVectorLayer) -> Bool {
        guard let geometryType = Self.geometryType(for: identity),
              identity.mapLayerType != "GdbVectorLayer",
              bucket.geometryType == geometryType,
              bucket.hasAttributeTable,
              !bucket.columns.isEmpty,
              columnsHaveUniqueNames(bucket.columns.map {
                  VectorAttributeColumn(id: $0.id, name: $0.name,
                      kind: VectorAttributeColumnKind(rawValue: $0.type) ?? .unsupported,
                      sourceTypeName: $0.type)
              }) else { return false }
        return VectorSymbologyOrdinalBinding.verifiedSourceIndices(
            renderedFeatures: layer.features,
            kind: Self.featureKind(for: geometryType),
            sourceIndices: bucket.sourceFeatureIndices,
            tableRowCount: bucket.tableRowCount,
            renderFeatureCount: bucket.renderFeatureCount,
            ordinalBindingProven: bucket.ordinalBindingProven
        ) != nil
    }

    private func bucket(for inspection: VectorSymbologyInspection,
                        identity: VectorVisualNodeIdentity) -> WireBucket? {
        guard let geometryType = Self.geometryType(for: identity) else { return nil }
        return inspection.buckets.first(where: { $0.geometryType == geometryType })
    }

    private func globalBase(for layer: MapVectorLayer) -> [String: VectorStyleValues] {
        var result: [String: VectorStyleValues] = [:]
        for feature in layer.features {
            let primary = MapVectorStyleDefinitionIDs.primaryDefinition(for: feature.kind)
            result[primary] = preferences.style(for: primary)
                ?? SourceVectorStyleCatalog.definition(for: primary)?.defaultStyle
                ?? SourceVectorStyleCatalog.fallbackStyle
            if let vertex = MapVectorStyleDefinitionIDs.vertexDefinition(for: feature.kind) {
                result[vertex] = preferences.style(for: vertex)
                    ?? SourceVectorStyleCatalog.definition(for: vertex)?.defaultStyle
                    ?? SourceVectorStyleCatalog.fallbackStyle
            }
        }
        return result
    }

    private func variant(for definitionID: String,
                         identity: VectorVisualNodeIdentity) -> VectorStyleDefinitionVariant? {
        SourceVectorStyleCatalog.variants(for: definitionID).first { variant in
            switch identity.mapLayerType {
            case "PointsVector": variant.sourceContext == "Visual.Mapping.Observables.PointMapLayerVisualContext"
            case "PolylinesVector": variant.sourceContext == "Visual.Mapping.Observables.PolylineMapLayerVisualContext"
            case "PolygonsVector": variant.sourceContext == "Visual.Mapping.Observables.PolygonMapLayerVisualContext"
            case "GdbVectorLayer": variant.sourceContext == "Visual.Mapping.Observables.GdbVectorLayerVisualContext"
            default: false
            }
        }
    }

    private func renderDefinitionIDs(_ definitionID: String,
                                     identity: VectorVisualNodeIdentity) -> [String] {
        guard identity.mapLayerType == "GdbVectorLayer" else { return [definitionID] }
        return switch definitionID {
        case "Gdb_Point_Symbology": [MapVectorStyleDefinitionIDs.point]
        case "Gdb_Line_Symbology": [MapVectorStyleDefinitionIDs.polylineLine]
        case "Gdb_Line_Vertex_Symbology": [MapVectorStyleDefinitionIDs.polylineVertex]
        case "Gdb_Polygon_Symbology": [MapVectorStyleDefinitionIDs.polygonShape]
        case "Gdb_Polygon_Vertex_Symbology": [MapVectorStyleDefinitionIDs.polygonVertex]
        default: []
        }
    }

    private func hasUnsavedGeometryDraft(_ layer: MapVectorLayer, mapID: UUID,
                                         store: WorkspaceStore) -> Bool {
        guard let state = store.loadedVectorStyleMapStates().first(where: { $0.id == mapID }),
              state.polylineEditor.hasUnsavedChanges,
              let path = state.polylineEditor.currentScope?.canonicalPath else { return false }
        return SourceFilePaths.canonical(URL(fileURLWithPath: path)) == SourceFilePaths.canonical(layer.url)
    }

    private func styleOnlyUpdate(mapID: UUID, store: WorkspaceStore) -> MapUpdate {
        let state = store.loadedVectorStyleMapStates().first(where: { $0.id == mapID })
        return MapUpdate(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil,
            selectedFeatureID: nil, vectorStyles: state?.vectorStyles ?? [:], preserveInteractionState: true)
    }

    private func groups(from option: VectorStyleOption) -> [VectorVisualConditionGroup] {
        VectorStyleField.allCases.map { field in
            VectorVisualConditionGroup(field: field, rules: option.conditions[field] ?? [])
        }
    }

    private func canValidateConditions(_ groups: [VectorVisualConditionGroup],
                                      option: VectorStyleOption) -> Bool {
        guard groups.map(\.field) == VectorStyleField.allCases else { return false }
        for group in groups {
            for rule in group.rules where Self.isComplete(rule) {
                guard let column = option.columns.first(where: { $0.name == rule.column }),
                      column.kind.supportsConditions,
                      option.operators(for: column.name).contains(rule.comparison) else { return false }
                switch group.field {
                case .penColor, .fillColor:
                    // Conditional results use the source ColorTranslator,
                    // which also accepts RGB and named HTML colors. The
                    // retained evaluator below validates and canonicalizes
                    // them; base style ARGB rules are a separate contract.
                    break
                case .penWidth:
                    guard let value = Double(rule.resultValue), value.isFinite else { return false }
                case .pointSize:
                    guard Int32(rule.resultValue) != nil else { return false }
                }
            }
        }
        return true
    }

    private func columnsHaveUniqueNames(_ columns: [VectorAttributeColumn]) -> Bool {
        let names = columns.map(\.name)
        return names.allSatisfy { !$0.isEmpty } && Set(names).count == names.count
    }

    private func validatedOverrides(_ evaluation: WireEvaluation,
                                    request: WireEvaluationRequest) throws -> [ValidatedOverride] {
        guard evaluation.revision.caseInsensitiveCompare(request.revision) == .orderedSame else {
            throw ProjectFileError.invalid(Self.sourceChangedReason)
        }
        let expected = Set(request.properties.flatMap { property in
            request.sourceFeatureIndices.map { "\($0)|\(property.definitionID)|\(property.property)" }
        })
        guard evaluation.overrides.count == expected.count else {
            throw ProjectFileError.invalid(Self.invalidEvaluationReason)
        }
        var seen = Set<String>()
        return try evaluation.overrides.map { value in
            let key = "\(value.sourceFeatureIndex)|\(value.definitionID)|\(value.property)"
            guard expected.contains(key), seen.insert(key).inserted,
                  let field = VectorStyleField(rawValue: value.property) else {
                throw ProjectFileError.invalid(Self.invalidEvaluationReason)
            }
            switch field {
            case .penColor, .fillColor:
                if value.hasMatch {
                    guard let color = value.colorValue,
                          VectorStyleValues(penColor: color).validatedForPersistence() != nil,
                          value.numberValue == nil, value.integerValue == nil else {
                        throw ProjectFileError.invalid(Self.invalidEvaluationReason)
                    }
                } else if value.colorValue != nil || value.numberValue != nil || value.integerValue != nil {
                    throw ProjectFileError.invalid(Self.invalidEvaluationReason)
                }
            case .penWidth:
                if value.hasMatch {
                    guard let number = value.numberValue, number.isFinite,
                          value.colorValue == nil, value.integerValue == nil else {
                        throw ProjectFileError.invalid(Self.invalidEvaluationReason)
                    }
                } else if value.colorValue != nil || value.numberValue != nil || value.integerValue != nil {
                    throw ProjectFileError.invalid(Self.invalidEvaluationReason)
                }
            case .pointSize:
                if value.hasMatch {
                    guard value.integerValue.map({ Int32(exactly: $0) != nil }) == true,
                          value.colorValue == nil, value.numberValue == nil else {
                        throw ProjectFileError.invalid(Self.invalidEvaluationReason)
                    }
                } else if value.colorValue != nil || value.numberValue != nil || value.integerValue != nil {
                    throw ProjectFileError.invalid(Self.invalidEvaluationReason)
                }
            }
            return ValidatedOverride(sourceFeatureIndex: value.sourceFeatureIndex,
                definitionID: value.definitionID,
                field: field, hasMatch: value.hasMatch, color: value.colorValue,
                number: value.numberValue, integer: value.integerValue)
        }
    }

    private func apply(_ override: ValidatedOverride, to style: inout VectorStyleValues) throws {
        switch override.field {
        case .penColor:
            guard let color = override.color else { throw ProjectFileError.invalid(Self.invalidEvaluationReason) }
            style.penColor = color
        case .penWidth:
            guard let number = override.number else { throw ProjectFileError.invalid(Self.invalidEvaluationReason) }
            style.penWidth = number
        case .fillColor:
            guard let color = override.color else { throw ProjectFileError.invalid(Self.invalidEvaluationReason) }
            style.fillColor = color
        case .pointSize:
            guard let integer = override.integer else { throw ProjectFileError.invalid(Self.invalidEvaluationReason) }
            style.pointSize = integer
        }
    }

    private static func validBucketShape(_ bucket: WireBucket) -> Bool {
        guard ["point", "line", "polygon"].contains(bucket.geometryType),
              bucket.renderFeatureCount >= 0,
              bucket.tableRowCount >= 0,
              bucket.sourceFeatureIndices.allSatisfy({ $0 >= 0 }),
              Set(bucket.sourceFeatureIndices).count == bucket.sourceFeatureIndices.count,
              bucket.columns.allSatisfy({ column in
                  column.ordinal >= 0 && column.id == "column/\(column.ordinal)" && !column.name.isEmpty
              }),
              Set(bucket.columns.map(\.ordinal)).count == bucket.columns.count else { return false }
        return true
    }

    private static func conditionGroupsEqual(_ left: [VectorVisualConditionGroup],
                                             _ right: [VectorVisualConditionGroup]) -> Bool {
        guard left.map(\.field) == right.map(\.field) else { return false }
        return zip(left, right).allSatisfy { lhs, rhs in
            lhs.rules.map(ruleSignature) == rhs.rules.map(ruleSignature)
        }
    }

    private static func ruleSignature(_ rule: VectorStyleRule) -> [String] {
        [rule.column, rule.comparison, rule.threshold, rule.resultValue]
    }

    private static func hasActiveConditions(_ groups: [VectorVisualConditionGroup]) -> Bool {
        groups.contains { group in group.rules.contains(where: isComplete) }
    }

    private static func isComplete(_ rule: VectorStyleRule) -> Bool {
        !rule.column.isEmpty && !rule.comparison.isEmpty && !rule.threshold.isEmpty && !rule.resultValue.isEmpty
    }

    private static func backendPath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        guard let presentationURL = try? PlatformPaths.resolvePresentationPath(url.path,
            relativeTo: url.deletingLastPathComponent()) else { return nil }
        let extensionName = presentationURL.pathExtension.lowercased()
        guard ["geojson", "json"].contains(extensionName),
              presentationURL.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: presentationURL.path) else { return nil }

        // Keep the logical suffix for the retained GeoJSON reader (the source
        // may be a .geojson symlink to a differently named backing file), but
        // require that path to resolve to the same physical source used by the
        // map-layer and visualization-owner checks.
        let physicalPath = SourceFilePaths.canonical(url)
        guard physicalPath.hasPrefix("/"),
              SourceFilePaths.canonical(presentationURL) == physicalPath else { return nil }
        return presentationURL.path
    }

    private static func geometryType(for identity: VectorVisualNodeIdentity) -> String? {
        switch identity.mapLayerType {
        case "PointsVector": "point"
        case "PolylinesVector": "line"
        case "PolygonsVector": "polygon"
        default: nil
        }
    }

    private static func featureKind(for geometryType: String) -> MapFeature.Kind {
        switch geometryType {
        case "point": .point
        case "polygon": .polygon
        default: .line
        }
    }

    private static func vectorType(_ value: String) -> VectorType {
        switch value {
        case "Point": .point
        case "Line": .line
        case "Polygon": .polygon
        case "Text": .text
        default: .segment
        }
    }

    private static func layerSignature(_ layers: [MapVectorLayer]) -> [LayerSignature] {
        layers.map { layer in
            LayerSignature(
                id: layer.id,
                visualIdentity: layer.visualIdentity,
                visualName: layer.visualName,
                isSourceVisible: layer.isSourceVisible,
                path: SourceFilePaths.canonical(layer.url),
                revision: layer.sourceRevision,
                sourceMapID: layer.sourceMapID,
                features: layer.features.map { feature in
                    FeatureSignature(kind: Self.kindName(feature.kind), sourceIndex: feature.sourceFeatureIndex,
                        identities: feature.pathStableIdentities, paths: feature.paths)
                }
            )
        }
    }

    private static func draftSignature(_ state: MapState) -> DraftSignature {
        DraftSignature(
            generation: state.polylineEditor.draftGeneration,
            sourceRevision: state.polylineEditor.currentSourceRevision,
            sourcePath: state.polylineEditor.currentScope?.canonicalPath,
            hasUnsavedChanges: state.polylineEditor.hasUnsavedChanges,
            isBusy: state.polylineEditor.isBusy
        )
    }

    private static func kindName(_ kind: MapFeature.Kind) -> String {
        switch kind { case .point: "point"; case .line: "line"; case .polygon: "polygon" }
    }

    private static let noAttributeTableReason = "Conditional rules require a source attribute table."
    private static let unavailableConditionsReason = "Conditional rules are unavailable for this source."
    private static let unsupportedConditionsReason = "Conditional rules are not supported for this layer."
    private static let ambiguousColumnReason = "The source contains duplicate attribute column names."
    private static let unsavedDraftReason = "Conditional rules are disabled while this layer has unsaved geometry edits."
    private static let mutationUnavailableReason = "Wait for the current project operation to finish before changing vector styles."
    private static let sourceChangedReason = "The source vector file changed before conditional styles could be applied."
    private static let invalidEvaluationReason = "The source returned conditional styles that do not match the requested rows."

    private struct LocalCandidate {
        let sourceID: String
        let renderID: String
        let option: VectorVisualSettingsOptions
        let identity: VectorVisualNodeIdentity
        let variant: VectorStyleDefinitionVariant
        let hasUnsavedDraft: Bool
    }

    private final class InspectionCache {
        var values: [String: VectorSymbologyInspection] = [:]
    }

    private struct EffectiveSettingsOwner: Hashable {
        let projectSessionID: UUID
        let mapID: UUID
        let assetID: String?
        let layerID: String?
        let visualNode: VectorVisualNodeIdentity?

        init(context: VectorSymbologyContext) {
            projectSessionID = context.projectSessionID
            mapID = context.mapID
            assetID = context.assetID
            layerID = context.layerID
            visualNode = context.visualNode
        }
    }

    private struct EffectiveSettingsEntry {
        let revision: String
        let defaults: [String: VectorStyleValues]
        let settings: VectorVisualSettingsSnapshot
    }

    private struct LayerSignature: Equatable {
        let id: String
        let visualIdentity: String?
        let visualName: String?
        let isSourceVisible: Bool
        let path: String
        let revision: String?
        let sourceMapID: UUID?
        let features: [FeatureSignature]
    }

    private struct FeatureSignature: Equatable {
        let kind: String
        let sourceIndex: Int?
        let identities: [String]
        let paths: [[MapPoint]]
    }

    private struct DraftSignature: Equatable {
        let generation: String
        let sourceRevision: String?
        let sourcePath: String?
        let hasUnsavedChanges: Bool
        let isBusy: Bool
    }

    private struct ValidatedOverride {
        let sourceFeatureIndex: Int
        let definitionID: String
        let field: VectorStyleField
        let hasMatch: Bool
        let color: String?
        let number: Double?
        let integer: Int?
    }

    private struct WireInspectRequest: Encodable, Sendable {
        let vectorPath: String
        let revision: String
    }
    private struct WireInspection: Decodable, Sendable {
        let revision: String
        let sourceFeatureCount: Int
        let buckets: [WireBucket]
    }
    private typealias VectorSymbologyInspection = WireInspection

    private struct WireBucket: Decodable, Sendable {
        let geometryType: String
        let renderFeatureCount: Int
        let tableRowCount: Int
        let ordinalBindingProven: Bool
        let sourceFeatureIndices: [Int]
        let supportedDefinitionIDs: [String]
        let columns: [WireColumn]
        let hasAttributeTable: Bool
    }
    private struct WireColumn: Decodable, Sendable {
        let id: String
        let name: String
        let type: String
        let ordinal: Int
    }
    private struct WireEvaluationRequest: Encodable, Sendable {
        let vectorPath: String
        let revision: String
        let geometryType: String
        let sourceFeatureIndices: [Int]
        let properties: [WirePropertyConditions]
    }
    private struct WirePropertyConditions: Encodable, Sendable {
        let definitionID: String
        let property: String
        let conditions: [WireCondition]
    }
    private struct WireCondition: Encodable, Sendable {
        let column: String
        let `operator`: String
        let threshold: String
        let resultValue: String
    }
    private struct WireEvaluation: Decodable, Sendable {
        let revision: String
        let overrides: [WireOverride]
    }
    private struct WireOverride: Decodable, Sendable {
        let sourceFeatureIndex: Int
        let definitionID: String
        let property: String
        let hasMatch: Bool
        let colorValue: String?
        let numberValue: Double?
        let integerValue: Int?
    }
}

/// The map renderer carries the original source-row ordinal on each feature.
/// MultiPoint/MultiPolygon and other expanded components may repeat that
/// ordinal; they are safe only when the retained table proves a unique source
/// row set and every native component maps back into that exact set.
enum VectorSymbologyOrdinalBinding {
    static func verifiedSourceIndices(renderedFeatures: [MapFeature], kind: MapFeature.Kind,
                                      sourceIndices: [Int], tableRowCount: Int,
                                      renderFeatureCount: Int,
                                      ordinalBindingProven: Bool) -> [Int]? {
        guard ordinalBindingProven,
              sourceIndices.count == renderFeatureCount,
              sourceIndices.count == tableRowCount,
              !sourceIndices.isEmpty,
              sourceIndices.allSatisfy({ $0 >= 0 }),
              Set(sourceIndices).count == sourceIndices.count else { return nil }
        let featureIndices = renderedFeatures.compactMap { feature -> Int? in
            guard feature.kind == kind else { return nil }
            return feature.sourceFeatureIndex
        }
        guard featureIndices.count == renderedFeatures.filter({ $0.kind == kind }).count,
              !featureIndices.isEmpty,
              featureIndices.allSatisfy({ $0 >= 0 }),
              Set(featureIndices) == Set(sourceIndices) else { return nil }
        return sourceIndices
    }
}

enum VectorVisualSettingsDefaultSync {
    static func resolve(raw: VectorVisualSettingsSnapshot,
                        previous: VectorVisualSettingsSnapshot,
                        previousDefaults: [String: VectorStyleValues],
                        newDefaults: [String: VectorStyleValues]) -> VectorVisualSettingsSnapshot {
        var options = raw.options
        for (definitionID, oldOption) in previous.options {
            guard let sourceOption = raw.options[definitionID],
                  let oldDefault = previousDefaults[definitionID],
                  let newDefault = newDefaults[definitionID] else { continue }
            let type = SourceVectorStyleCatalog.definition(for: definitionID)?.type
            let effectiveValues = sourceValuesEqual(oldOption.values, oldDefault, type: type)
                ? newDefault : oldOption.values
            options[definitionID] = VectorVisualSettingsOptions(
                values: effectiveValues,
                conditionGroups: sourceOption.conditionGroups
            )
        }
        return VectorVisualSettingsSnapshot(options: options, revision: raw.revision)
    }

    private static func sourceValuesEqual(_ lhs: VectorStyleValues, _ rhs: VectorStyleValues,
                                          type: String?) -> Bool {
        switch type ?? "" {
        case "Line":
            lhs.penColor.caseInsensitiveCompare(rhs.penColor) == .orderedSame
                && lhs.penWidth == rhs.penWidth
        case "Polygon":
            lhs.penColor.caseInsensitiveCompare(rhs.penColor) == .orderedSame
                && lhs.penWidth == rhs.penWidth
                && lhs.fillColor.caseInsensitiveCompare(rhs.fillColor) == .orderedSame
        case "Point":
            lhs.penColor.caseInsensitiveCompare(rhs.penColor) == .orderedSame
                && lhs.penWidth == rhs.penWidth
                && lhs.fillColor.caseInsensitiveCompare(rhs.fillColor) == .orderedSame
                && lhs.pointSize == rhs.pointSize
        default:
            lhs == rhs
        }
    }
}
