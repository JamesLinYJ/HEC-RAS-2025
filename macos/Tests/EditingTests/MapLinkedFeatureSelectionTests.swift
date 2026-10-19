import Foundation
import Testing
@testable import HECRAS2025

@MainActor
struct MapLinkedFeatureSelectionTests {
    @Test
    func dynamicLinkTracksSelectionThenKeepsTheCurrentOwnerWhenPinned() {
        let session = MapLinkedFeatureSelectionSession()
        let first = context(feature: "feature-1", revision: "REV-A")
        let second = context(feature: "feature-2", revision: "REV-A")

        session.reconcile(selectedContext: first, ownerIsValid: { _ in true })
        #expect(session.context == first)
        #expect(session.isDynamicallyLinked)

        session.setDynamicallyLinked(false, selectedContext: second,
            ownerIsValid: { _ in true })
        session.reconcile(selectedContext: second, ownerIsValid: { _ in true })
        #expect(session.context == first)

        session.setDynamicallyLinked(true, selectedContext: second,
            ownerIsValid: { _ in true })
        #expect(session.context == second)
    }

    @Test
    func sourceOwnerInvalidationClearsAPinnedContext() {
        let session = MapLinkedFeatureSelectionSession()
        let pinned = context(feature: "feature-1", revision: "REV-A")
        session.reconcile(selectedContext: pinned, ownerIsValid: { _ in true })
        session.setDynamicallyLinked(false, selectedContext: nil,
            ownerIsValid: { _ in true })

        session.reconcile(selectedContext: nil, ownerIsValid: { _ in false })
        #expect(session.context == nil)
    }

    @Test
    func featureReferenceIdentityRetainsSourceRevisionAndFeatureIdentity() {
        let first = context(feature: "feature-1", revision: "REV-A")
        let changedFeature = context(feature: "feature-2", revision: "REV-A")
        let changedSource = context(feature: "feature-1", revision: "REV-B")

        #expect(first.referenceIdentity != changedFeature.referenceIdentity)
        #expect(first.referenceIdentity != changedSource.referenceIdentity)
    }

    private func context(feature: String, revision: String)
        -> MapLinkedFeatureSelectionContext {
        MapLinkedFeatureSelectionContext(projectSessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            mapWorkflowIdentity: "workflow", mapID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            ownerKind: .vector, sourceContextIdentity: "map|source-row",
            sourceOwnerIdentity: "owner|layer|/fixture/source.geojson|\(revision)",
            sourceNodeID: "source-node", sourceKind: "MapLayer", sourceName: "Source",
            layerID: "layer-id", featureIdentity: feature, featureLabel: feature,
            featureOrdinal: 1, sourcePath: "/fixture/source.geojson", sourceRevision: revision)
    }
}
