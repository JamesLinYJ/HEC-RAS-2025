import Foundation
import Testing
@testable import HECRAS2025

struct OriginalDateTimeCultureParsingTests {
    @Test func dateInputAcceptsTheActiveCultureAndNormalizesOnlyTheEditedSegment() throws {
        let us = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")

        #expect(OriginalDateTimeDraftCodec.canonicalDateText("12/31/2024", locale: us) == "2024-12-31")
        #expect(OriginalDateTimeDraftCodec.canonicalDateText("31.12.2024", locale: german) == "2024-12-31")
        #expect(OriginalDateTimeDraftCodec.canonicalDateText("02/31/2024", locale: us) == nil)
    }

    @Test func timeSpanInputUsesSourceComponentsAndCultureDecimalSeparator() throws {
        let german = Locale(identifier: "de_DE")
        let fractional = try #require(OriginalDateTimeDraftCodec.parseTime("12:34:56,5", locale: german))
        #expect(fractional.hour == 12)
        #expect(fractional.minute == 34)
        #expect(fractional.second == 56)

        let dayQualified = try #require(OriginalDateTimeDraftCodec.parseTime("1.02:03:04", locale: german))
        #expect(dayQualified.hour == 2)
        #expect(dayQualified.minute == 3)
        #expect(dayQualified.second == 4)

        #expect(OriginalDateTimeDraftCodec.canonicalTimeText("24:00", locale: german) == "00:00:00")
        #expect(OriginalDateTimeDraftCodec.canonicalTimeText("-1:00", locale: german) == nil)
    }
}
