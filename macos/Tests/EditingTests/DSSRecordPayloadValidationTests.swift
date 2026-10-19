import Testing
@testable import HECRAS2025

struct DSSRecordPayloadValidationTests {
    @Test func wallClockParserAcceptsCivilTimesAndRejectsInvalidDatesOrZones() throws {
        let start = try #require(DSSWallClockPosition.scalar("2024-12-31T23:59:40.0000000"))
        let nextDay = try #require(DSSWallClockPosition.scalar("2025-01-01T00:00:35.0000000"))
        #expect(nextDay - start == 55)
        #expect(DSSWallClockPosition.scalar("2024-02-29T12:00:00.0000000") != nil)
        #expect(DSSWallClockPosition.scalar("2025-02-29T12:00:00.0000000") == nil)
        #expect(DSSWallClockPosition.scalar("2025-01-01T00:00:00Z") == nil)
        #expect(DSSWallClockPosition.scalar("2025-01-01T00:00:60.0000000") == nil)
    }

    @Test func timeSeriesPayloadRequiresMatchingValidFiniteSamplesAndQualityStride() throws {
        let valid = timeSeries(
            times: ["2025-01-01T00:00:00.0000000", "2025-01-01T01:00:00.0000000"],
            values: [1, nil], qualities: [10, 11, 20, 21])
        try DSSRecordPayloadValidator.validate(valid)

        let mismatchedSamples = timeSeries(times: ["2025-01-01T00:00:00.0000000"], values: [1, 2])
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(mismatchedSamples)
        }
        let badTimestamp = timeSeries(times: ["2025-02-29T00:00:00.0000000"], values: [1])
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(badTimestamp)
        }
        let nonFinite = timeSeries(times: ["2025-01-01T00:00:00.0000000"], values: [.infinity])
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(nonFinite)
        }
        let malformedQualities = timeSeries(
            times: ["2025-01-01T00:00:00.0000000", "2025-01-01T01:00:00.0000000"],
            values: [1, 2], qualities: [10, 11, 12])
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(malformedQualities)
        }
        let qualitiesWithoutSamples = timeSeries(times: [], values: [], qualities: [10])
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(qualitiesWithoutSamples)
        }
    }

    @Test func tableProjectionKeepsRowsTiedToSamplesAndShowsEveryQualityWord() {
        let qualities = [10, 11, 20, 21, 30, 31]
        #expect(DSSTimeSeriesTableProjection.rowCount(timesCount: 3, valuesCount: 3) == 3)
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: qualities, sampleCount: 3, sampleIndex: 0) == "10, 11")
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: qualities, sampleCount: 3, sampleIndex: 2) == "30, 31")
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: [7, 8], sampleCount: 2, sampleIndex: 1) == "8")
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: nil, sampleCount: 3, sampleIndex: 1) == "—")
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: qualities, sampleCount: 2, sampleIndex: 0) == "10, 11, 20")
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: qualities, sampleCount: 4, sampleIndex: 0) == "—")
        #expect(DSSTimeSeriesTableProjection.qualityText(
            qualities: qualities, sampleCount: 3, sampleIndex: 3) == "—")
    }

    @Test func unionPayloadAndPairedArrayShapesAreValidated() {
        let paired = DSSRecordReadResult.PairedData(
            ordinates: [0, 1],
            curves: [.init(label: "A", values: [2])],
            independentUnits: "m", dependentUnits: "s",
            independentType: "STAGE", dependentType: "FLOW")
        let invalidPaired = record(kind: "pairedData", pairedData: paired)
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(invalidPaired)
        }

        let location = DSSRecordReadResult.Location(
            x: .infinity, y: nil, z: nil, coordinateSystem: "", coordinateID: 0,
            horizontalUnits: 0, horizontalDatum: 0, verticalUnits: 0, verticalDatum: 0,
            timeZoneName: "", supplemental: "")
        let invalidLocation = record(kind: "location", location: location)
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(invalidLocation)
        }

        let unexpectedPayload = record(kind: "unsupported", timeSeries: .init(
            times: ["2025-01-01T00:00:00.0000000"], values: [1], qualities: nil,
            units: "CFS", dataType: "INST-VAL"))
        #expect(throws: DSSRecordPayloadValidationError.self) {
            try DSSRecordPayloadValidator.validate(unexpectedPayload)
        }
    }

    private func timeSeries(times: [String], values: [Double?], qualities: [Int]? = nil) -> DSSRecordReadResult {
        record(kind: "timeSeries", timeSeries: .init(times: times, values: values, qualities: qualities,
                                                      units: "CFS", dataType: "INST-VAL"))
    }

    private func record(kind: String, timeSeries: DSSRecordReadResult.TimeSeries? = nil,
                        pairedData: DSSRecordReadResult.PairedData? = nil,
                        location: DSSRecordReadResult.Location? = nil) -> DSSRecordReadResult {
        .init(path: "/A/B/C/D/E/F/", recordType: kind, kind: kind, error: nil,
              timeSeries: timeSeries, pairedData: pairedData, location: location)
    }
}
