import Foundation
import Testing
@testable import HECRAS2025

struct OriginalPropertyDateTimeStorageTests {
    @Test
    func dateEditsRetainSeparatorTimeAndOffsetWhileClearingSourceDroppedFractions() {
        let raw = "2024-02-03T04:05:06.1234567-07:30"

        #expect(OriginalPropertyDateTimeStorage.replacingDate("2025-06-07", in: raw)
            == "2025-06-07T04:05:06.0000000-07:30")
        #expect(OriginalPropertyDateTimeStorage.dateText(from: raw) == "2024-02-03")
    }

    @Test
    func timeEditsRetainDateSeparatorFractionAndOffset() {
        let raw = "2024-02-03 04:05:06.1234567+08:30"

        #expect(OriginalPropertyDateTimeStorage.replacingTime("21:43:09", in: raw)
            == "2024-02-03 21:43:09.1234567+08:30")
        #expect(OriginalPropertyDateTimeStorage.timeText(from: raw) == "04:05:06")
    }

    @Test
    func mergedEditsOnlyRewriteTouchedSegments() {
        let raw = "2024-02-03T04:05:06.1234567Z"

        #expect(OriginalPropertyDateTimeStorage.replacing(
            dateText: "2025-06-07", timeText: "21:43:09",
            dateTouched: false, timeTouched: true, in: raw
        ) == "2024-02-03T21:43:09.1234567Z")
        #expect(OriginalPropertyDateTimeStorage.replacing(
            dateText: "2025-06-07", timeText: "21:43:09",
            dateTouched: true, timeTouched: false, in: raw
        ) == "2025-06-07T04:05:06.0000000Z")
        #expect(OriginalPropertyDateTimeStorage.replacing(
            dateText: "2025-06-07", timeText: "21:43:09",
            dateTouched: true, timeTouched: true, in: raw
        ) == "2025-06-07T21:43:09.0000000Z")
    }

    @Test
    func combinedDateTimeBoxResetsSubsecondTicksWithoutChangingOffsetFormat() {
        let raw = "2024-02-03 04:05:06.1234567+08:30"

        #expect(OriginalPropertyDateTimeStorage.replacing(
            dateText: "2024-02-03", timeText: "21:43:09",
            dateTouched: false, timeTouched: true, in: raw,
            resetSubsecondPrecision: true
        ) == "2024-02-03 21:43:09.0000000+08:30")
    }

    @Test
    func timeEditAddsTimeToDateOnlyStorageWithoutInventingAnOffset() {
        #expect(OriginalPropertyDateTimeStorage.replacingTime("04:05:06", in: "2024-02-03")
            == "2024-02-03T04:05:06")
        #expect(OriginalPropertyDateTimeStorage.replacingTime("04:05:06", in: "")
            == "0001-01-01T04:05:06")
    }

    @Test
    func storedDateTimeParsesSourceWallClockInsteadOfShiftingItsOffset() throws {
        let raw = "2024-02-03T04:05:06-07:00"
        let value = try #require(OriginalDateTimeDraftCodec.parseStoredValue(raw))

        #expect(OriginalDateTimeDraftCodec.displayParts(of: value).date == "2024-02-03")
        #expect(OriginalDateTimeDraftCodec.displayParts(of: value).time == "04:05:06")
    }

    @Test
    func unknownSourceFormatIsRejectedInsteadOfNormalized() {
        let raw = "03/02/2024 04:05:06"

        #expect(OriginalDateTimeDraftCodec.parseStoredValue(raw) == nil)
        #expect(OriginalPropertyDateTimeStorage.replacingDate("2025-06-07", in: raw) == nil)
        #expect(OriginalPropertyDateTimeStorage.replacingTime("21:43:09", in: raw) == nil)
    }
}
