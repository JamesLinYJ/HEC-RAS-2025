import Testing
@testable import HECRAS2025

struct ProjectDescriptionLimitTests {
    @Test
    func newProjectDescriptionUsesSourceUTF16LimitAndPreservesWholeSurrogates() {
        let limit = NewProjectDescriptionLimit.maximumUTF16Length
        let exact = String(repeating: "a", count: limit)
        #expect(NewProjectDescriptionLimit.bounded(exact) == exact)

        let fittingEmoji = String(repeating: "a", count: limit - 2) + "😀" + "tail"
        let boundedFittingEmoji = NewProjectDescriptionLimit.bounded(fittingEmoji)
        #expect(boundedFittingEmoji.utf16.count == limit)
        #expect(boundedFittingEmoji.hasSuffix("😀"))
        #expect(!boundedFittingEmoji.contains("\u{FFFD}"))

        let nonFittingEmoji = String(repeating: "a", count: limit - 1) + "😀"
        let boundedNonFittingEmoji = NewProjectDescriptionLimit.bounded(nonFittingEmoji)
        #expect(boundedNonFittingEmoji == String(repeating: "a", count: limit - 1))
        #expect(boundedNonFittingEmoji.utf16.count <= limit)
        #expect(!boundedNonFittingEmoji.contains("\u{FFFD}"))
    }
}
