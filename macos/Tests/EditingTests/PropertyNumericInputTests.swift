import Testing
@testable import HECRAS2025

struct PropertyNumericInputTests {
    @Test func rejectsIncompleteAndNonFiniteNumberDrafts() {
        #expect(OriginalNumberInputValidator.evaluate("", minimum: 0, maximum: 10) == .empty)
        #expect(OriginalNumberInputValidator.evaluate("-", minimum: 0, maximum: 10) == .invalid)
        #expect(OriginalNumberInputValidator.evaluate("1e309", minimum: nil, maximum: nil) == .invalid)
    }

    @Test func acceptsInclusiveBoundsAndReportsOutOfRangeValues() {
        #expect(OriginalNumberInputValidator.evaluate("0", minimum: 0, maximum: 10) == .valid(0))
        #expect(OriginalNumberInputValidator.evaluate("10", minimum: 0, maximum: 10) == .valid(10))
        #expect(OriginalNumberInputValidator.evaluate("-0.1", minimum: 0, maximum: 10) == .belowMinimum(0))
        #expect(OriginalNumberInputValidator.evaluate("10.1", minimum: 0, maximum: 10) == .aboveMaximum(10))
    }
}
