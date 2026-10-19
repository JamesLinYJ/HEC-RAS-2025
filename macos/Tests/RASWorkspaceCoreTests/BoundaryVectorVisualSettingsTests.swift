import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class BoundaryVectorVisualSettingsTests: XCTestCase {
    private let lineID = "BC_Line_Symbology"
    private let vertexID = "BC_Line_Vertex_Symbology"

    func testReadsAndWritesEverySupportedMapRootAndExactResultPath() throws {
        struct BoundaryCase {
            let mapType: String
            let rootName: String
            let mapName: String
            let boundaryPath: [Int]
            let boundaryName: String
            let initialWidth: Double
        }

        let duplicateBoundaries = root("Boundary Conditions",
            boundary("River", width: 2) + boundary("River", width: 3) + boundary("Other", width: 4))
        let buildableLayers = root("Layers", boundary("River", width: 5))
        let geometryLayers = root("Layers", boundary("River", width: 6))
        let focusedPlans = root("Focused Plans",
            "<Node Type=\"Plan\" Name=\"Plan A\"><Node Type=\"Geometry\" Name=\"Reach A\">\(boundary("River", width: 7))</Node></Node>")
        let planMatching = root("Focused Plans", "") + root("Matching Layers", boundary("River", width: 8))
        let projectResult = root("Results", result("River", width: 9))
        let buildableResult = root("Layers", result("River", width: 10))
        let geometryMultiResult = root("Layers", multiResult("River", width: 11))
        let planResult = root("Focused Plans",
            "<Node Type=\"Plan\" Name=\"Plan A\"><Node Type=\"MultiResult\" Name=\"Plan A Results\"><Node Type=\"Plan\" Name=\"Plan A\"><Node Type=\"Geometry\" Name=\"Reach A\">\(boundary("River", width: 12))</Node></Node></Node></Node>")

        let maps = [
            map(name: "Repeated map name", type: "Project", roots: duplicateBoundaries),
            map(name: "Repeated map name", type: "Buildable", roots: buildableLayers),
            map(name: "Geometry view", type: "Geometry", roots: geometryLayers),
            map(name: "Plan view", type: "Plan", roots: focusedPlans),
            map(name: "Plan view", type: "Plan", roots: planMatching),
            map(name: "Result view", type: "Project", roots: projectResult),
            map(name: "Result view", type: "Buildable", roots: buildableResult),
            map(name: "Result view", type: "Geometry", roots: geometryMultiResult),
            map(name: "Plan result view", type: "Plan", roots: planResult)
        ]
        let cases = [
            BoundaryCase(mapType: "Project", rootName: "Boundary Conditions", mapName: "Repeated map name",
                boundaryPath: [0, 1], boundaryName: "River", initialWidth: 3),
            BoundaryCase(mapType: "Buildable", rootName: "Layers", mapName: "Repeated map name",
                boundaryPath: [0, 0], boundaryName: "River", initialWidth: 5),
            BoundaryCase(mapType: "Geometry", rootName: "Layers", mapName: "Geometry view",
                boundaryPath: [0, 0], boundaryName: "River", initialWidth: 6),
            BoundaryCase(mapType: "Plan", rootName: "Focused Plans", mapName: "Plan view",
                boundaryPath: [0, 0, 0, 0], boundaryName: "River", initialWidth: 7),
            BoundaryCase(mapType: "Plan", rootName: "Matching Layers", mapName: "Plan view",
                boundaryPath: [1, 0], boundaryName: "River", initialWidth: 8),
            BoundaryCase(mapType: "Project", rootName: "Results", mapName: "Result view",
                boundaryPath: [0, 0, 0, 0, 0], boundaryName: "River", initialWidth: 9),
            BoundaryCase(mapType: "Buildable", rootName: "Layers", mapName: "Result view",
                boundaryPath: [0, 0, 0, 0, 0], boundaryName: "River", initialWidth: 10),
            BoundaryCase(mapType: "Geometry", rootName: "Layers", mapName: "Result view",
                boundaryPath: [0, 0, 0, 0, 0], boundaryName: "River", initialWidth: 11),
            BoundaryCase(mapType: "Plan", rootName: "Focused Plans", mapName: "Plan result view",
                boundaryPath: [0, 0, 0, 0, 0, 0], boundaryName: "River", initialWidth: 12)
        ]
        let (directory, project, _) = try makeFixture(maps: maps)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let defaults = try boundaryDefaults()

        for (mapIndex, item) in cases.enumerated() {
            let identity = boundaryIdentity(mapIndex: mapIndex, mapName: item.mapName,
                mapType: item.mapType, rootName: item.rootName, boundaryPath: item.boundaryPath,
                boundaryName: item.boundaryName, linePath: item.boundaryPath + [0])
            let snapshot = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
            let currentLine = try XCTUnwrap(snapshot.options[lineID])
            XCTAssertEqual(currentLine.values.penWidth, item.initialWidth, "map index \(mapIndex)")

            var changed = currentLine
            changed.values.penWidth = item.initialWidth + 20
            try document.saveBoundaryVectorVisualSettings(identity: identity, options: [lineID: changed],
                defaults: defaults, expectedRevision: snapshot.revision)

            let reopened = try VisualizationDocument(projectURL: project)
            let saved = try reopened.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
            XCTAssertEqual(saved.options[lineID]?.values.penWidth, item.initialWidth + 20,
                "map index \(mapIndex)")
        }

        let reopened = try VisualizationDocument(projectURL: project)
        let firstDuplicate = boundaryIdentity(mapIndex: 0, mapName: "Repeated map name", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: [0, 0, 0])
        XCTAssertEqual(try reopened.boundaryVectorVisualSettings(identity: firstDuplicate,
            defaults: defaults).options[lineID]?.values.penWidth, 2)
    }

    func testRepeatedNamesAreResolvedByExactPathAndWrongPathIsRejected() throws {
        let rootNode = root("Boundary Conditions",
            boundary("River", width: 2) + boundary("River", width: 3) + boundary("Other", width: 4))
        let (directory, project, visual) = try makeFixture(
            maps: [map(name: "Same", type: "Project", roots: rootNode),
                   map(name: "Same", type: "Project", roots: rootNode)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let defaults = try boundaryDefaults()
        let secondRow = boundaryIdentity(mapIndex: 0, mapName: "Same", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 1], boundaryName: "River", linePath: [0, 1, 0])
        XCTAssertEqual(try document.boundaryVectorVisualSettings(identity: secondRow,
            defaults: defaults).options[lineID]?.values.penWidth, 3)

        let before = try Data(contentsOf: visual)
        let wrongPath = boundaryIdentity(mapIndex: 0, mapName: "Same", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 2], boundaryName: "River", linePath: [0, 2, 0])
        XCTAssertThrowsError(try document.boundaryVectorVisualSettings(identity: wrongPath, defaults: defaults))
        let wrongMap = boundaryIdentity(mapIndex: 1, mapName: "Same", mapType: "Buildable",
            rootName: "Boundary Conditions", boundaryPath: [0, 1], boundaryName: "River", linePath: [0, 1, 0])
        XCTAssertThrowsError(try document.boundaryVectorVisualSettings(identity: wrongMap, defaults: defaults))
        XCTAssertEqual(try Data(contentsOf: visual), before)
    }

    func testNilLinePathMaterializesOnlyUnderAnExistingBoundaryRow() throws {
        let rootNode = root("Boundary Conditions",
            "<Node Type=\"BoundaryCondition\" Name=\"River\"/>" + boundary("Elsewhere", width: 6))
        let (directory, project, visual) = try makeFixture(maps: [map(name: "M", type: "Project", roots: rootNode)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let defaults = try boundaryDefaults()
        let identity = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: nil)
        let snapshot = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(snapshot.options[lineID]?.values, defaults[lineID])
        var line = try XCTUnwrap(snapshot.options[lineID])
        line.values.penWidth = 14
        try document.saveBoundaryVectorVisualSettings(identity: identity, options: [lineID: line],
            defaults: defaults, expectedRevision: snapshot.revision)

        let saved = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        XCTAssertEqual(try saved.nodes(forXPath:
            "/Ras/Maps/Map/Tree/Nodes/Node[@Name='Boundary Conditions']/Node[@Name='River']/Node[@Type='BoundaryConditionLineLayer']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath:
            "/Ras/Maps/Map/Tree/Nodes/Node[@Name='Boundary Conditions']/Node[@Type='BoundaryCondition']").count, 2)
        XCTAssertEqual(try saved.nodes(forXPath:
            "/Ras/Maps/Map/Tree/Nodes/Node[@Name='Boundary Conditions']/Node[@Name='Elsewhere']/Node[@Type='BoundaryConditionLineLayer']").count, 1)

        let afterMaterialization = try Data(contentsOf: visual)
        let absentBoundary = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 2], boundaryName: "Missing", linePath: nil)
        XCTAssertThrowsError(try document.boundaryVectorVisualSettings(identity: absentBoundary, defaults: defaults))
        var absentOptions = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults).options
        var absentLine = try XCTUnwrap(absentOptions[lineID])
        absentLine.values.penWidth = 15
        absentOptions[lineID] = absentLine
        XCTAssertThrowsError(try document.saveBoundaryVectorVisualSettings(identity: absentBoundary,
            options: absentOptions, defaults: defaults, expectedRevision: document.sourceRevision))
        XCTAssertEqual(try Data(contentsOf: visual), afterMaterialization)
    }

    func testDuplicateImmediateLineChildrenAreRejectedWithoutWriting() throws {
        let duplicatedLine = """
        <Node Type="BoundaryCondition" Name="River">
          <Node Type="BoundaryConditionLineLayer" Name="Boundary Condition Lines"/>
          <Node Type="BoundaryConditionLineLayer" Name="Boundary Condition Lines"/>
        </Node>
        """
        let rootNode = root("Boundary Conditions", duplicatedLine)
        let (directory, project, visual) = try makeFixture(maps: [map(name: "M", type: "Project", roots: rootNode)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let defaults = try boundaryDefaults()
        let identity = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: [0, 0, 0])
        let before = try Data(contentsOf: visual)
        XCTAssertThrowsError(try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults))
        let changed = VectorVisualSettingsOptions(values: try XCTUnwrap(defaults[lineID]))
        XCTAssertThrowsError(try document.saveBoundaryVectorVisualSettings(identity: identity,
            options: [lineID: changed], defaults: defaults, expectedRevision: document.sourceRevision))
        XCTAssertEqual(try Data(contentsOf: visual), before)
    }

    func testApplyPreservesAllConditionGroupsUnknownXMLAndPendingViews() throws {
        let defaults = try boundaryDefaults()
        let line = try XCTUnwrap(defaults[lineID])
        let vertex = try XCTUnwrap(defaults[vertexID])
        let styles = fullSymbology(id: lineID, values: line, isVertex: false)
            + fullSymbology(id: vertexID, values: vertex, isVertex: true)
        let lineChild = "<Node Type=\"BoundaryConditionLineLayer\" Name=\"Boundary Condition Lines\">\(styles)</Node>"
        let rootNode = root("Boundary Conditions", "<Node Type=\"BoundaryCondition\" Name=\"River\">\(lineChild)</Node>")
        let (directory, project, visual) = try makeFixture(
            maps: [map(name: "M", type: "Project", roots: rootNode)],
            extra: "<Views><View Keep=\"original\"><Name>Original</Name><Extent Left=\"0\" Top=\"2\" Right=\"2\" Bottom=\"0\"/></View></Views><UML Keep=\"yes\"/>")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let identity = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: [0, 0, 0])
        let snapshot = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        var options = snapshot.options
        var changedLine = try XCTUnwrap(options[lineID])
        changedLine.values.penWidth += 2.5
        options[lineID] = changedLine
        var changedVertex = try XCTUnwrap(options[vertexID])
        changedVertex.values.pointSize += 2
        options[vertexID] = changedVertex
        try document.add(SavedMapView(name: "Pending", lowerLeft: MapPoint(x: 1, y: 1),
            upperRight: MapPoint(x: 3, y: 3)))

        try document.saveBoundaryVectorVisualSettings(identity: identity, options: options,
            defaults: defaults, expectedRevision: snapshot.revision)

        let saved = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        for id in [lineID, vertexID] {
            for name in ["PenColorConditions", "PenWidthConditions", "FillColorConditions", "PointSizeConditions"] {
                XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/\(name)/Condition").count, 1,
                    "\(id) / \(name)")
                XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/\(name)/@FutureGroup").first?.stringValue,
                    "keep-\(name)")
            }
            XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/@FutureStyle").first?.stringValue, "keep-\(id)")
            XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/UnknownStyle[@Keep='yes']").count, 1)
        }
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology/*/Condition/@FutureCondition").count, 8)
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/UML[@Keep='yes']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Views/View[@Keep='original']").count, 1)
        XCTAssertTrue(try saved.nodes(forXPath: "/Ras/Views/View[Name='Pending']").isEmpty)
        XCTAssertEqual(document.views.map(\.name), ["Original", "Pending"])

        try document.save()
        let savedWithPendingView = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        XCTAssertEqual(try savedWithPendingView.nodes(forXPath: "/Ras/Views/View[Name='Pending']").count, 1)
    }

    func testGlobalDefaultsAreInheritedAndRegularApplyClearsLocalOverrides() throws {
        let defaults = try boundaryDefaults()
        let rootNode = root("Boundary Conditions", boundary("River", width: nil))
        let (directory, project, visual) = try makeFixture(maps: [map(name: "M", type: "Project", roots: rootNode)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let identity = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: [0, 0, 0])

        let inherited = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(inherited.options[lineID]?.values, defaults[lineID])
        XCTAssertEqual(inherited.options[vertexID]?.values, defaults[vertexID])
        XCTAssertTrue(try XMLDocument(data: Data(contentsOf: visual)).nodes(forXPath: "//Symbology").isEmpty)

        var local = inherited.options
        var localLine = try XCTUnwrap(local[lineID])
        localLine.values.penWidth += 6
        local[lineID] = localLine
        var localVertex = try XCTUnwrap(local[vertexID])
        localVertex.values.fillColor = "#FFABCDEF"
        local[vertexID] = localVertex
        try document.saveBoundaryVectorVisualSettings(identity: identity, options: local,
            defaults: defaults, expectedRevision: inherited.revision)

        let edited = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(edited.options[lineID]?.values.penWidth, localLine.values.penWidth)
        XCTAssertEqual(edited.options[vertexID]?.values.fillColor, "#FFABCDEF")
        var backToDefaults = edited.options
        var defaultLine = try XCTUnwrap(backToDefaults[lineID])
        defaultLine.values = try XCTUnwrap(defaults[lineID])
        backToDefaults[lineID] = defaultLine
        var defaultVertex = try XCTUnwrap(backToDefaults[vertexID])
        defaultVertex.values = try XCTUnwrap(defaults[vertexID])
        backToDefaults[vertexID] = defaultVertex
        try document.saveBoundaryVectorVisualSettings(identity: identity, options: backToDefaults,
            defaults: defaults, expectedRevision: edited.revision)

        let cleared = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        XCTAssertTrue(try cleared.nodes(forXPath: "//Symbology[@ID='\(lineID)']/@PenColor").isEmpty)
        XCTAssertTrue(try cleared.nodes(forXPath: "//Symbology[@ID='\(lineID)']/@PenWidth").isEmpty)
        for attribute in ["PenColor", "PenWidth", "FillColor", "PointSize"] {
            XCTAssertTrue(try cleared.nodes(forXPath: "//Symbology[@ID='\(vertexID)']/@\(attribute)").isEmpty)
        }
        let reopened = try VisualizationDocument(projectURL: project)
        let inheritedAgain = try reopened.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(inheritedAgain.options[lineID]?.values, defaults[lineID])
        XCTAssertEqual(inheritedAgain.options[vertexID]?.values, defaults[vertexID])
    }

    func testExplicitResetClearsRedundantDefaultAttributesWithoutChangingConditions() throws {
        let defaults = try boundaryDefaults()
        let line = try XCTUnwrap(defaults[lineID])
        let vertex = try XCTUnwrap(defaults[vertexID])
        let styles = fullSymbology(id: lineID, values: line, isVertex: false)
            + fullSymbology(id: vertexID, values: vertex, isVertex: true)
        let rootNode = root("Boundary Conditions", "<Node Type=\"BoundaryCondition\" Name=\"River\"><Node Type=\"BoundaryConditionLineLayer\" Name=\"Boundary Condition Lines\">\(styles)</Node></Node>")
        let (directory, project, visual) = try makeFixture(maps: [map(name: "M", type: "Project", roots: rootNode)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let identity = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: [0, 0, 0])
        let snapshot = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(snapshot.options[lineID]?.values, defaults[lineID])
        XCTAssertEqual(snapshot.options[vertexID]?.values, defaults[vertexID])
        let original = try Data(contentsOf: visual)

        var invalidReset = snapshot.options
        var invalidLine = try XCTUnwrap(invalidReset[lineID])
        invalidLine.values.haloColor = "#FF998877"
        invalidReset[lineID] = invalidLine
        XCTAssertThrowsError(try document.saveBoundaryVectorVisualSettings(identity: identity,
            options: invalidReset, defaults: defaults, expectedRevision: snapshot.revision, resetToDefaults: true))
        XCTAssertEqual(try Data(contentsOf: visual), original)

        try document.saveBoundaryVectorVisualSettings(identity: identity, options: snapshot.options,
            defaults: defaults, expectedRevision: snapshot.revision, resetToDefaults: true)
        let saved = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        XCTAssertEqual(try saved.nodes(forXPath: "//Node[@Type='BoundaryCondition' and @Name='River']/Node[@Type='BoundaryConditionLineLayer']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(lineID)']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(vertexID)']").count, 1)
        XCTAssertTrue(try saved.nodes(forXPath: "//Symbology[@ID='\(lineID)']/@PenColor").isEmpty)
        XCTAssertTrue(try saved.nodes(forXPath: "//Symbology[@ID='\(lineID)']/@PenWidth").isEmpty)
        for attribute in ["PenColor", "PenWidth", "FillColor", "PointSize"] {
            XCTAssertTrue(try saved.nodes(forXPath: "//Symbology[@ID='\(vertexID)']/@\(attribute)").isEmpty)
        }
        for id in [lineID, vertexID] {
            XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/@FutureStyle").first?.stringValue,
                "keep-\(id)")
            XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/UnknownStyle[@Keep='yes']").count, 1)
            for group in ["PenColorConditions", "PenWidthConditions", "FillColorConditions", "PointSizeConditions"] {
                XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='\(id)']/\(group)/Condition").count, 1)
            }
        }
        let reopened = try VisualizationDocument(projectURL: project)
        let resetSnapshot = try reopened.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(resetSnapshot.options[lineID]?.values, defaults[lineID])
        XCTAssertEqual(resetSnapshot.options[vertexID]?.values, defaults[vertexID])
        XCTAssertEqual(resetSnapshot.options[lineID]?.rules(for: .penColor).count, 1)
        XCTAssertEqual(resetSnapshot.options[lineID]?.rules(for: .penWidth).count, 1)
        XCTAssertEqual(resetSnapshot.options[lineID]?.rules(for: .fillColor).count, 1)
        XCTAssertEqual(resetSnapshot.options[lineID]?.rules(for: .pointSize).count, 1)
        XCTAssertEqual(resetSnapshot.options[vertexID]?.rules(for: .penColor).count, 1)
        XCTAssertEqual(resetSnapshot.options[vertexID]?.rules(for: .penWidth).count, 1)
        XCTAssertEqual(resetSnapshot.options[vertexID]?.rules(for: .fillColor).count, 1)
        XCTAssertEqual(resetSnapshot.options[vertexID]?.rules(for: .pointSize).count, 1)
    }

    func testStaleRevisionAndExternalSourceChangesAreRejected() throws {
        let defaults = try boundaryDefaults()
        let rootNode = root("Boundary Conditions", boundary("River", width: 2))
        let (directory, project, visual) = try makeFixture(maps: [map(name: "M", type: "Project", roots: rootNode)])
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let identity = boundaryIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Boundary Conditions", boundaryPath: [0, 0], boundaryName: "River", linePath: [0, 0, 0])
        let snapshot = try document.boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        var option = try XCTUnwrap(snapshot.options[lineID])
        option.values.penWidth += 1
        let before = try Data(contentsOf: visual)
        XCTAssertThrowsError(try document.saveBoundaryVectorVisualSettings(identity: identity,
            options: [lineID: option], defaults: defaults, expectedRevision: "stale"))
        XCTAssertEqual(try Data(contentsOf: visual), before)

        let beforeText = String(decoding: before, as: UTF8.self)
        let externalText = beforeText.replacingOccurrences(of: "PenWidth=\"2.0\"", with: "PenWidth=\"22.0\"")
        XCTAssertNotEqual(externalText, beforeText)
        try Data(externalText.utf8).write(to: visual)
        let externalBytes = try Data(contentsOf: visual)
        XCTAssertThrowsError(try document.saveBoundaryVectorVisualSettings(identity: identity,
            options: [lineID: option], defaults: defaults, expectedRevision: snapshot.revision))
        XCTAssertEqual(try Data(contentsOf: visual), externalBytes)
    }

    private func boundaryDefaults() throws -> [String: VectorStyleValues] {
        var result: [String: VectorStyleValues] = [:]
        for id in [lineID, vertexID] {
            result[id] = try XCTUnwrap(SourceVectorStyleCatalog.definition(for: id)).defaultStyle
        }
        return result
    }

    private func boundaryIdentity(mapIndex: Int, mapName: String, mapType: String,
        rootName: String, boundaryPath: [Int], boundaryName: String, linePath: [Int]?) -> BoundaryVectorVisualNodeIdentity {
        BoundaryVectorVisualNodeIdentity(mapIndex: mapIndex, mapName: mapName, mapType: mapType,
            rootName: rootName, boundaryNodePath: boundaryPath, boundaryName: boundaryName,
            lineNodePath: linePath, lineNodeName: "Boundary Condition Lines")
    }

    private func boundary(_ name: String, width: Double?) -> String {
        let lineStyle = width.map { "<Symbology ID=\"\(lineID)\" PenColor=\"#FF123456\" PenWidth=\"\($0)\"/>" } ?? ""
        let vertexStyle = width.map { "<Symbology ID=\"\(vertexID)\" PenColor=\"#FF010203\" PenWidth=\"\($0)\" FillColor=\"#80010203\" PointSize=\"4\"/>" } ?? ""
        return "<Node Type=\"BoundaryCondition\" Name=\"\(name)\"><Node Type=\"BoundaryConditionLineLayer\" Name=\"Boundary Condition Lines\">\(lineStyle)\(vertexStyle)</Node></Node>"
    }

    private func result(_ boundaryName: String, width: Double) -> String {
        "<Node Type=\"Result\" Name=\"Stored Result\"><Node Type=\"Plan\" Name=\"Plan A\"><Node Type=\"Geometry\" Name=\"Reach A\">\(boundary(boundaryName, width: width))</Node></Node></Node>"
    }

    private func multiResult(_ boundaryName: String, width: Double) -> String {
        "<Node Type=\"MultiResult\" Name=\"Plan A Results\"><Node Type=\"Plan\" Name=\"Plan A\"><Node Type=\"Geometry\" Name=\"Reach A\">\(boundary(boundaryName, width: width))</Node></Node></Node>"
    }

    private func root(_ name: String, _ children: String) -> String {
        "<Node Type=\"Root\" Name=\"\(name)\">\(children)</Node>"
    }

    private func map(name: String, type: String, roots: String) -> String {
        "<Map Name=\"\(name)\" Type=\"\(type)\"><Tree><Nodes>\(roots)</Nodes></Tree></Map>"
    }

    private func fullSymbology(id: String, values: VectorStyleValues, isVertex: Bool) -> String {
        let baseAttributes = isVertex
            ? " PenColor=\"\(values.penColor)\" PenWidth=\"\(values.penWidth)\" FillColor=\"\(values.fillColor)\" PointSize=\"\(values.pointSize)\""
            : " PenColor=\"\(values.penColor)\" PenWidth=\"\(values.penWidth)\""
        let groups: [(name: String, result: String, marker: String)] = [
            ("PenColorConditions", "#FF010203", "color"),
            ("PenWidthConditions", "4.5", "width"),
            ("FillColorConditions", "#FF040506", "fill"),
            ("PointSizeConditions", "7", "point")
        ]
        let serializedGroups = groups.map { group in
            "<\(group.name) FutureGroup=\"keep-\(group.name)\"><Condition Column=\"FID\" Operator=\"Equal\" Threshold=\"1\" Result=\"\(group.result)\" FutureCondition=\"\(group.marker)\"/></\(group.name)>"
        }.joined()
        return "<Symbology ID=\"\(id)\" FutureStyle=\"keep-\(id)\"\(baseAttributes)>\(serializedGroups)<UnknownStyle Keep=\"yes\"/></Symbology>"
    }

    private func makeFixture(maps: [String], extra: String = "") throws -> (URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = directory.appendingPathComponent("Boundary.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        let xml = "<Ras><Maps>\(maps.joined())</Maps>\(extra)</Ras>"
        try Data(xml.utf8).write(to: visual)
        return (directory, project, visual)
    }
}
