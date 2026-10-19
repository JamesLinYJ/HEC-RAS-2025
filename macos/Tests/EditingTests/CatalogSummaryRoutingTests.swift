import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct CatalogSummaryRoutingTests {
    @Test
    func externalConnectionNodesResolveByTreeIdentityInsteadOfDisplayName() {
        let first = ProjectConnection(
            id: "first", name: "Shared name", type: "File",
            relativePath: "Inputs/first.dss", absolutePath: "/project/Inputs/first.dss",
            description: "First file"
        )
        let second = ProjectConnection(
            id: "second", name: "Shared name", type: "File",
            relativePath: "Inputs/second.dss", absolutePath: "/project/Inputs/second.dss",
            description: "Second file"
        )
        let node = LayerTreeNode(
            id: "connection:1",
            sourceClass: "ExternalFileConnectionCatalogNode",
            name: "Shared name",
            properties: [
                .init(id: "Type", label: "Type", value: "File"),
                .init(id: "Description", label: "Description", value: "Second file"),
                .init(id: "RelativePath", label: "Relative Path", value: "Inputs/second.dss"),
                .init(id: "AbsolutePath", label: "Absolute Path", value: "/project/Inputs/second.dss")
            ]
        )

        #expect(CatalogConnectionNodeRoute.connection(for: node, in: [first, second]) == second)
        #expect(CatalogConnectionNodeRoute.connection(for: node, in: [first]) == nil)
    }

    @Test
    func fileAndDirectoryConnectionNodesRequireTheirSourceKind() {
        let directory = ProjectConnection(
            id: "directory", name: "Shared name", type: "Directory",
            relativePath: "Inputs", absolutePath: "/project/Inputs",
            searchPattern: "*.dss", recurse: true
        )
        let node = LayerTreeNode(
            id: "connection:0",
            sourceClass: "ExternalConnectionCatalogNode",
            name: "Shared name",
            properties: [
                .init(id: "Type", label: "Type", value: "Directory"),
                .init(id: "Description", label: "Description", value: ""),
                .init(id: "RelativePath", label: "Relative Path", value: "Inputs"),
                .init(id: "AbsolutePath", label: "Absolute Path", value: "/project/Inputs"),
                .init(id: "SearchPattern", label: "Filename Pattern", value: "*.dss"),
                .init(id: "Recurse", label: "Include Subfolders", value: "True")
            ]
        )

        #expect(CatalogConnectionNodeRoute.connection(for: node, in: [directory]) == directory)
        let staleNode = LayerTreeNode(
            id: node.id,
            sourceClass: "ExternalFileConnectionCatalogNode",
            name: node.name,
            properties: node.properties
        )
        #expect(CatalogConnectionNodeRoute.connection(for: staleNode, in: [directory]) == nil)
    }
}
