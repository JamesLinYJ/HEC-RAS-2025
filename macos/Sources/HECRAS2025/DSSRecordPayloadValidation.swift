import Foundation

enum DSSRecordPayloadValidationError: Error, LocalizedError, Equatable {
    case unknownKind(path: String, kind: String)
    case mismatchedKindPayload(path: String)
    case invalidTimeSeries(path: String)
    case invalidTimeSeriesQualities(path: String)
    case invalidPairedData(path: String)
    case invalidLocation(path: String)

    nonisolated var errorDescription: String? {
        switch self {
        case .unknownKind(let path, let kind):
            return "DSS record \(path) returned an unknown result kind: \(kind)"
        case .mismatchedKindPayload(let path):
            return "DSS record \(path) returned a payload that does not match its result kind."
        case .invalidTimeSeries(let path):
            return "DSS time series \(path) has mismatched samples, invalid timestamps, or non-finite values."
        case .invalidTimeSeriesQualities(let path):
            return "DSS time series \(path) has quality data that does not match its sample count."
        case .invalidPairedData(let path):
            return "DSS paired data \(path) has mismatched arrays or non-finite values."
        case .invalidLocation(let path):
            return "DSS location \(path) contains non-finite coordinates."
        }
    }

    @MainActor var localizedMessage: String {
        switch self {
        case .unknownKind(let path, let kind):
            return L10n.format("DSS record %@ returned an unknown result kind: %@", path, kind)
        case .mismatchedKindPayload(let path):
            return L10n.format("DSS record %@ returned a payload that does not match its result kind.", path)
        case .invalidTimeSeries(let path):
            return L10n.format("DSS time series %@ has mismatched samples, invalid timestamps, or non-finite values.", path)
        case .invalidTimeSeriesQualities(let path):
            return L10n.format("DSS time series %@ has quality data that does not match its sample count.", path)
        case .invalidPairedData(let path):
            return L10n.format("DSS paired data %@ has mismatched arrays or non-finite values.", path)
        case .invalidLocation(let path):
            return L10n.format("DSS location %@ contains non-finite coordinates.", path)
        }
    }
}

enum DSSRecordPayloadValidator {
    static func validate(_ records: [DSSRecordReadResult]) throws {
        for record in records {
            try validate(record)
        }
    }

    static func validate(_ record: DSSRecordReadResult) throws {
        guard !record.path.isEmpty else {
            throw DSSRecordPayloadValidationError.mismatchedKindPayload(path: record.path)
        }

        switch record.kind {
        case "timeSeries":
            guard let series = record.timeSeries, record.pairedData == nil else {
                throw DSSRecordPayloadValidationError.mismatchedKindPayload(path: record.path)
            }
            guard series.times.count == series.values.count,
                  series.times.allSatisfy({ DSSWallClockPosition.scalar($0) != nil }),
                  series.values.allSatisfy({ $0?.isFinite ?? true }) else {
                throw DSSRecordPayloadValidationError.invalidTimeSeries(path: record.path)
            }
            if let qualities = series.qualities, !qualities.isEmpty,
               (series.values.isEmpty || qualities.count % series.values.count != 0) {
                throw DSSRecordPayloadValidationError.invalidTimeSeriesQualities(path: record.path)
            }
            try validate(location: record.location, path: record.path)

        case "pairedData":
            guard let paired = record.pairedData, record.timeSeries == nil else {
                throw DSSRecordPayloadValidationError.mismatchedKindPayload(path: record.path)
            }
            guard paired.ordinates.allSatisfy({ $0?.isFinite ?? true }),
                  paired.curves.allSatisfy({ curve in
                      curve.values.count == paired.ordinates.count
                          && curve.values.allSatisfy({ $0?.isFinite ?? true })
                  }) else {
                throw DSSRecordPayloadValidationError.invalidPairedData(path: record.path)
            }
            try validate(location: record.location, path: record.path)

        case "location":
            guard record.timeSeries == nil, record.pairedData == nil, let location = record.location else {
                throw DSSRecordPayloadValidationError.mismatchedKindPayload(path: record.path)
            }
            try validate(location: location, path: record.path)

        case "unsupported", "error":
            guard record.timeSeries == nil, record.pairedData == nil, record.location == nil else {
                throw DSSRecordPayloadValidationError.mismatchedKindPayload(path: record.path)
            }

        default:
            throw DSSRecordPayloadValidationError.unknownKind(path: record.path, kind: record.kind)
        }
    }

    private static func validate(location: DSSRecordReadResult.Location?, path: String) throws {
        guard let location else { return }
        guard [location.x, location.y, location.z].allSatisfy({ $0?.isFinite ?? true }) else {
            throw DSSRecordPayloadValidationError.invalidLocation(path: path)
        }
    }
}

enum DSSWallClockPosition {
    /// Converts an ISO civil timestamp without a timezone suffix into a scalar.
    /// The result uses only source date/time components; no timezone is inferred.
    static func scalar(_ value: String) -> Double? {
        let fields = value.split(separator: "T", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }

        let dateFields = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        let clockFields = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateFields.count == 3, clockFields.count == 3,
              dateFields[0].count == 4, dateFields[1].count == 2, dateFields[2].count == 2,
              clockFields[0].count == 2, clockFields[1].count == 2,
              dateFields.allSatisfy(Self.isASCIIDigits),
              clockFields[0].utf8.allSatisfy(Self.isASCIIDigit),
              clockFields[1].utf8.allSatisfy(Self.isASCIIDigit) else { return nil }

        let secondFields = clockFields[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondFields.count),
              secondFields[0].count == 2,
              secondFields.allSatisfy(Self.isASCIIDigits),
              secondFields.count == 1 || !secondFields[1].isEmpty,
              let year = Int(dateFields[0]), let month = Int(dateFields[1]),
              let day = Int(dateFields[2]), let hour = Int(clockFields[0]),
              let minute = Int(clockFields[1]), let seconds = Double(String(clockFields[2])),
              year > 0, (1...12).contains(month), (0...23).contains(hour),
              (0...59).contains(minute), (0..<60).contains(seconds),
              day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }

        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra
        return Double(days) * 86_400 + Double(hour) * 3_600 + Double(minute) * 60 + seconds
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    private static func isASCIIDigits(_ value: Substring) -> Bool { value.utf8.allSatisfy(isASCIIDigit) }
}

enum DSSTimeSeriesTableProjection {
    static func rowCount(timesCount: Int, valuesCount: Int) -> Int {
        max(timesCount, valuesCount)
    }

    static func qualityText(qualities: [Int]?, sampleCount: Int, sampleIndex: Int) -> String {
        guard let qualities, !qualities.isEmpty, sampleCount > 0,
              qualities.count.isMultiple(of: sampleCount), (0..<sampleCount).contains(sampleIndex) else {
            return "—"
        }
        let stride = qualities.count / sampleCount
        let start = sampleIndex * stride
        let words = qualities[start..<(start + stride)]
        guard words.count > 1 else { return words.first.map { String($0) } ?? "—" }
        return words.map { String($0) }.joined(separator: ", ")
    }
}
