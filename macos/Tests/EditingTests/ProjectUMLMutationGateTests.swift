import Testing
@testable import HECRAS2025

struct ProjectUMLMutationGateTests {
    @Test @MainActor
    func umlAndRasterStyleWritesCannotOverlapOrReenterTheSharedVisualizationLease() {
        let store = WorkspaceStore()
        #expect(store.beginAssociatedRasterStyleMutation())
        #expect(!store.beginProjectUMLMutation())
        store.endAssociatedRasterStyleMutation()
        #expect(store.beginProjectUMLMutation())
        #expect(!store.beginProjectUMLMutation())
        #expect(!store.beginAssociatedRasterStyleMutation())
        store.endProjectUMLMutation()
        #expect(store.beginAssociatedRasterStyleMutation())
        store.endAssociatedRasterStyleMutation()
    }
}
