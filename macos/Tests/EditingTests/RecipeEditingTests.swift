import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct RecipeEditingTests {
    @Test func displayedThresholdAndDeltaRetainOriginalWireMeaning() throws {
        let command = try #require(RecipeLibrary.commands.first { $0.id == "OptTopology" })
        let presentation = try #require(RecipePresentationLibrary.presentation(command.id))
        let threshold = try #require(presentation.parameters.first { $0.id == "Threshold" })
        let delta = try #require(presentation.parameters.first { $0.id == "DeltaThreshold" })
        #expect(threshold.isOutsideBounds("101"))
        #expect(!threshold.isOutsideBounds("100"))
        #expect(threshold.isOutsideRecommendedBounds("10"))
        #expect(!threshold.isOutsideRecommendedBounds("50"))
        #expect(delta.isOutsideBounds("1.1"))
        var step = RecipeStep(command: command)
        #expect(RecipeParameterEditing.display(threshold, in: step) == "50.0")
        #expect(RecipeParameterEditing.display(delta, in: step) == "0.1")
        RecipeParameterEditing.set("0.2", parameter: delta, in: &step)
        #expect(Double(step.values["deltaCost"] ?? "") == 0.1)
        RecipeParameterEditing.set("25", parameter: threshold, in: &step)
        #expect(Double(step.values["threshold"] ?? "") == 0.25)
        #expect(Double(step.values["deltaCost"] ?? "") == 0.05)
        RecipeParameterEditing.set("0", parameter: threshold, in: &step)
        RecipeParameterEditing.set("40", parameter: threshold, in: &step, deltaThreshold: "0.2")
        #expect(abs((Double(step.values["deltaCost"] ?? "") ?? 0) - 0.08) < 1e-12)
        let wire = try RecipeDocument.serialize([step], commands: RecipeLibrary.commands)
        let restored = try #require(RecipeDocument.parse(wire, commands: RecipeLibrary.commands).first)
        #expect(restored.values["count"] == "-1")
        RecipeParameterEditing.set("invalid", parameter: threshold, in: &step)
        #expect(step.values["threshold"] == "invalid")
        #expect(throws: (any Error).self) { try RecipeDocument.serialize([step], commands: RecipeLibrary.commands) }
        let orthogonalize = try #require(RecipeLibrary.commands.first { $0.id == "Orthogonalize" })
        let method = try #require(RecipePresentationLibrary.presentation(orthogonalize.id)?.parameters.first { $0.id == "SmoothMethod" })
        var orthogonalStep = RecipeStep(command: orthogonalize)
        RecipeParameterEditing.set("2", parameter: method, in: &orthogonalStep)
        let methodWire = try RecipeDocument.serialize([orthogonalStep], commands: RecipeLibrary.commands)
        #expect(methodWire.contains("smoothmethod=2"))
    }
    @Test func windowsAndMacCommentsRetainFollowingCommands() throws {
        let commands = RecipeLibrary.commands
        for newline in ["\n", "\r\n"] {
            let text = "# original comment" + newline + "smooth(count=3, scaled=yes, sliding=0); MERGE(threshold=.25)"
            let steps = try RecipeDocument.parse(text, commands: commands)
            #expect(steps.map(\.command) == ["Smooth", "RemoveFaces"])
            #expect(steps.first?.values["scaled"] == "True")
            #expect(steps.first?.values["sliding"] == "False")
            #expect(steps.last?.values["threshold"] == "0.25")
        }
    }
    @Test func originalDefaultsAndExtraParametersSurviveEditing() throws {
        let commands = RecipeLibrary.commands
        let steps = try RecipeDocument.parse("Orthogonalize(count=7, useArea=false, smoothmethod=2)\nOptTopology(count=-1, threshold=0.4, deltaCost=0.02)", commands: commands)
        let serialized = try RecipeDocument.serialize(steps, commands: commands)
        let restored = try RecipeDocument.parse(serialized, commands: commands)
        #expect(restored.map(\.values) == steps.map(\.values))
        #expect(restored.first?.values["alpha"] == "0.8")
        #expect(restored.last?.values["faceLength"] == "0.1")
    }
    @Test func unsupportedStepsAndMalformedValuesAreRejected() {
        let commands = RecipeLibrary.commands
        for text in ["Invented()", "Smooth(missing=2)", "Smooth(count=2.5)", "Smooth(sliding=maybe)", "Smooth(count=1e2)", "Smooth(count=)"] {
            #expect(throws: (any Error).self) { try RecipeDocument.parse(text, commands: commands) }
        }
    }
}
