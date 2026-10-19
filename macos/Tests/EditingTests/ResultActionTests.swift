import Foundation
import Testing
@testable import HECRAS2025

struct ResultActionTests {
    @Test func resultLayerErrorMapsSourceSeverityMessageAndNamedValues() throws {
        let sourcePayload = Data(
            """
            {
              "code": "Result_NeedsMigration",
              "severity": "Warning",
              "evaluatedMessage": "Result run-01 needs migration to V1 format",
              "logData": [
                { "key": "ResultName", "value": "run-01" },
                { "key": "OptionalDetail", "value": null }
              ]
            }
            """.utf8
        )

        let error = try JSONDecoder().decode(ResultInspectorLayerError.self, from: sourcePayload)
        let presentation = error.presentation(index: 0)

        #expect(error.code == "Result_NeedsMigration")
        #expect(error.severity == "Warning")
        #expect(error.evaluatedMessage == "Result run-01 needs migration to V1 format")
        #expect(error.logData.map(\.key) == ["ResultName", "OptionalDetail"])
        #expect(error.logData[1].value == nil)
        #expect(presentation.severity == .warning)
        #expect(presentation.code == error.code)
        #expect(presentation.text == error.evaluatedMessage)
        #expect(presentation.context.map(\.key) == ["ResultName", "OptionalDetail"])
        #expect(presentation.context.map(\.value) == ["run-01", "—"])
        #expect(presentation.timestamp == nil)
    }

    @Test func deletePreparationMatchesCanonicalSourceAndRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResultActionTests-\(UUID().uuidString)", isDirectory: true)
        let alias = root.deletingLastPathComponent()
            .appendingPathComponent("ResultActionAlias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: root)
        }

        let project = root.appendingPathComponent("model.ras")
        let result = root.appendingPathComponent("results/run.h5")
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("project".utf8).write(to: project)
        try Data("result".utf8).write(to: result)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        let preparation = ResultDeletePreparation(
            projectPath: project.standardizedFileURL.resolvingSymlinksInPath().path,
            resultPath: result.standardizedFileURL.resolvingSymlinksInPath().path,
            name: "run",
            revision: "current-source-sha"
        )
        let aliasProject = alias.appendingPathComponent("model.ras")
        let aliasResult = alias.appendingPathComponent("results/run.h5")

        #expect(preparation.matches(projectPath: aliasProject, resultPath: aliasResult,
                                    revision: "current-source-sha"))
        #expect(!preparation.matches(projectPath: aliasProject, resultPath: aliasResult,
                                     revision: "stale-source-sha"))
        #expect(!preparation.matches(projectPath: aliasProject, resultPath: project,
                                     revision: "current-source-sha"))
    }
}
