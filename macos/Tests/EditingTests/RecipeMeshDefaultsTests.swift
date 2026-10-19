import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct RecipeMeshDefaultsTests {
    private var commands: [RecipeCommand] { RecipeLibrary.commands }

    @Test func quadDefaultExpandsToSourceIngredients() throws {
        let steps = try RecipeDocument.parse("Default()", commands: commands, meshType: "Quad")
        #expect(steps.map(\.command) == ["Smooth", "Split"])
        #expect(steps[0].values["count"] == "10")
        #expect(steps[0].values["scaled"] == "True")
        #expect(steps[0].values["sliding"] == "True")
        #expect(steps[1].values["threshold"] == "0.4")
    }

    @Test func trianglePaverAndCartesianDefaultsRetainSourceOrderAndValues() throws {
        let triangle = try RecipeDocument.parse("Default()", commands: commands, meshType: "TrianglePaver")
        #expect(triangle.map(\.command) == ["SwapEdges", "Smooth", "RemoveFaces", "Smooth", "Split"])
        #expect(triangle[2].values["threshold"] == "0")
        #expect(triangle[4].values["threshold"] == "0.1")

        let cartesian = try RecipeDocument.parse("Default()", commands: commands, meshType: "Cartesian")
        #expect(cartesian.map(\.command) == ["SwapEdges"])
    }

    @Test func emptyPatchDefaultsExpandToNoStages() throws {
        for meshType in ["OneD", "Empty"] {
            #expect(try RecipeDocument.parse("Default()", commands: commands, meshType: meshType).isEmpty)
        }
    }

    @Test func defaultWithoutMeshContextAndExplicitCustomRecipeRemainUntouched() throws {
        #expect(try RecipeDocument.parse("Default()", commands: commands).map(\.command) == ["Default"])

        let custom = "Smooth(count=4, scaled=false, sliding=true)\nSplit(threshold=0.25)"
        let baseline = try RecipeDocument.parse(custom, commands: commands)
        for meshType in ["Quad", "TrianglePaver", "Cartesian"] {
            let steps = try RecipeDocument.parse(custom, commands: commands, meshType: meshType)
            #expect(steps.map(\.command) == baseline.map(\.command))
            #expect(steps.map(\.values) == baseline.map(\.values))
        }
    }

    @Test func unsupportedPatchTypeDoesNotInventARecipe() {
        #expect(throws: (any Error).self) {
            try RecipeDocument.parse("Default()", commands: commands, meshType: "UnknownPatch")
        }
    }
}
