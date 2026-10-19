import CryptoKit
import Foundation
import RASWorkspaceCore

enum MapVectorFeatureExportError: LocalizedError {
    case staleSource
    case unsupportedSidecar
    case malformedSource
    case invalidSelection
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .staleSource: "The Shapefile source changed after it was loaded. Reload the map layer before exporting selected features."
        case .unsupportedSidecar: "This Shapefile uses an uncaptured encoding or memo sidecar and cannot be exported safely."
        case .malformedSource: "The Shapefile family is incomplete or malformed."
        case .invalidSelection: "The selected features no longer match the source record identities."
        case .destinationUnavailable: "Choose an unused Shapefile name in a writable folder."
        }
    }
}

/// Exports an exact record subset from the captured Shapefile family. Geometry
/// and DBF records are copied byte-for-byte; only record numbers, file lengths,
/// the DBF record count, and SHX offsets are rewritten for the new family.
enum MapShapefileSelectedFeatureExporter {
    struct OutputFamily: Equatable {
        let shapefile: Data
        let index: Data
        let attributes: Data
        let projection: Data?
    }

    private struct ShapeRecord {
        let offset: Int
        let contentLength: Int
        let content: Data
    }

    private struct DatabaseTable {
        let headerLength: Int
        let recordLength: Int
        let recordCount: Int
        let header: Data
        let records: [Data]
        let trailer: Data
    }

    private struct CoordinateArrayLayout {
        let pointCount: Int
        let end: Int
    }

    private struct NumericRange {
        let minimum: Double
        let maximum: Double
    }

    @MainActor
    @discardableResult
    static func export(_ context: MapVectorFeatureContextSnapshot,
                       family capturedFamily: MapSourceFamilyCapture?,
                       using system: any WorkspaceSystemServices) async throws -> URL? {
        guard context.isShapefile, let sourceRevision = context.sourceRevision,
              let capturedFamily else { throw MapVectorFeatureExportError.staleSource }
        let family = try MapShapefileVectorConverter.validateFamily(capturedFamily,
            sourcePath: context.canonicalSourcePath, sourceRevision: sourceRevision)

        guard let destination = system.chooseExportDestination(
            name: URL(filePath: context.canonicalSourcePath).deletingPathExtension().lastPathComponent + "-selected.shp",
            extensions: ["shp"], title: L10n.text("Export Selected Features")) else { return nil }
        guard destination.pathExtension.lowercased() == "shp",
              SourceFilePaths.canonical(URL(filePath: context.canonicalSourcePath))
                != SourceFilePaths.canonical(destination),
              system.authorizeExternalFolders([
                URL(filePath: context.canonicalSourcePath).deletingLastPathComponent(),
                destination.deletingLastPathComponent()
              ]) else { return nil }

        let sourceFiles = try readAndVerify(family)
        try rejectUncapturedSidecars(for: URL(filePath: context.canonicalSourcePath))
        let ordinals = try selectedRecordOrdinals(context, shapefile: sourceFiles["source"]!)
        let output = try filter(shapefile: sourceFiles["source"]!, index: sourceFiles["shx"]!,
            attributes: sourceFiles["dbf"]!, projection: sourceFiles["prj"], recordOrdinals: ordinals)

        // Re-read the family before publishing. A source replacement during
        // preparation cannot be mistaken for the data that was selected.
        let secondCapture = try readAndVerify(family)
        guard secondCapture == sourceFiles else { throw MapVectorFeatureExportError.staleSource }
        try publish(output, at: destination)
        return destination
    }

    static func filter(shapefile: Data, index: Data, attributes: Data,
                       projection: Data?, recordOrdinals: [Int]) throws -> OutputFamily {
        let records = try parseShapeFile(shapefile)
        let database = try parseDatabase(attributes)
        guard let shapeType = readUInt32LE(shapefile, 32) else { throw MapVectorFeatureExportError.malformedSource }
        try validateIndex(index, shapeType: shapeType, records: records)
        guard database.recordCount == records.count,
              !recordOrdinals.isEmpty,
              Set(recordOrdinals).count == recordOrdinals.count,
              recordOrdinals.allSatisfy(records.indices.contains) else {
            throw MapVectorFeatureExportError.invalidSelection
        }

        let orderedOrdinals = recordOrdinals.sorted()
        let selected = orderedOrdinals.map { records[$0] }
        let outputShape = try rebuildShapeFile(from: shapefile, records: selected)
        let outputIndex = try rebuildIndex(from: index, shapeHeader: outputShape.subdata(in: 0..<100), records: selected)
        let outputDatabase = try rebuildDatabase(database, ordinals: orderedOrdinals)
        return OutputFamily(shapefile: outputShape, index: outputIndex,
            attributes: outputDatabase, projection: projection)
    }

    private static func selectedRecordOrdinals(_ context: MapVectorFeatureContextSnapshot,
                                                shapefile: Data) throws -> [Int] {
        let records = try parseShapeFile(shapefile)
        let allFeatures = context.layer.features
        let sourceOrdinals = allFeatures.compactMap(\.sourceFeatureIndex)
        guard allFeatures.count == records.count,
              sourceOrdinals.count == allFeatures.count,
              Set(sourceOrdinals).count == sourceOrdinals.count,
              Set(sourceOrdinals) == Set(records.indices),
              !context.selectedFeatures.isEmpty,
              context.selectedFeatureIdentities.count == context.selectedFeatures.count,
              Set(context.selectedFeatureIdentities).count == context.selectedFeatureIdentities.count else {
            throw MapVectorFeatureExportError.invalidSelection
        }
        let grouped = Dictionary(grouping: allFeatures, by: \.stableIdentity)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw MapVectorFeatureExportError.invalidSelection
        }
        let currentByIdentity = Dictionary(uniqueKeysWithValues: allFeatures.map { ($0.stableIdentity, $0) })
        let selected = context.selectedFeatures.compactMap { feature -> Int? in
            guard let current = currentByIdentity[feature.stableIdentity],
                  current.sourceFeatureIndex == feature.sourceFeatureIndex,
                  context.selectedFeatureIdentities.contains(feature.stableIdentity),
                  let ordinal = feature.sourceFeatureIndex else { return nil }
            return ordinal
        }
        guard selected.count == context.selectedFeatures.count,
              Set(selected).count == selected.count,
              context.sourceRevision.map({ revision in
                  context.selectedFeatures.allSatisfy { feature in
                      !feature.stableIdentity.isEmpty &&
                      (feature.stableIdentity.hasPrefix("shapefile-record:")
                        ? feature.stableIdentity == "shapefile-record:\(feature.sourceFeatureIndex ?? -1):sha256:\(revision.uppercased())"
                        : true)
                  }
              }) == true else { throw MapVectorFeatureExportError.invalidSelection }
        return selected
    }

    private static func readAndVerify(_ family: MapSourceFamilyCapture) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in family.files {
            guard file.inputPath.hasPrefix("/"), file.path.hasPrefix("/"),
                  SourceFilePaths.canonical(URL(filePath: file.inputPath))
                    == SourceFilePaths.canonical(URL(filePath: file.path)),
                  file.exists == (file.revision != nil) else { throw MapVectorFeatureExportError.staleSource }
            let url = URL(filePath: file.path)
            guard file.exists else { continue }
            let bytes: Data
            do { bytes = try Data(contentsOf: url, options: [.mappedIfSafe]) }
            catch { throw MapVectorFeatureExportError.staleSource }
            guard let revision = file.revision,
                  sha256(bytes).caseInsensitiveCompare(revision) == .orderedSame else {
                throw MapVectorFeatureExportError.staleSource
            }
            result[file.role] = bytes
        }
        guard result["source"] != nil, result["shx"] != nil, result["dbf"] != nil else {
            throw MapVectorFeatureExportError.staleSource
        }
        return result
    }

    private static func rejectUncapturedSidecars(for sourceURL: URL) throws {
        let directory = sourceURL.deletingLastPathComponent()
        let sourceBase = sourceURL.deletingPathExtension().lastPathComponent
        let uncapturedExtensions: Set<String> = ["cpg", "qpj", "dbt", "fpt"]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        } catch { throw MapVectorFeatureExportError.staleSource }
        for entry in entries where entry.deletingPathExtension().lastPathComponent
            .caseInsensitiveCompare(sourceBase) == .orderedSame {
            if uncapturedExtensions.contains(entry.pathExtension.lowercased()) {
                throw MapVectorFeatureExportError.unsupportedSidecar
            }
        }
    }

    private static func parseShapeFile(_ data: Data) throws -> [ShapeRecord] {
        guard data.count >= 100, readUInt32BE(data, 0) == 9994,
              readUInt32LE(data, 28) == 1000,
              let declaredWords = readUInt32BE(data, 24),
              Int(declaredWords) * 2 == data.count,
              let headerShape = readUInt32LE(data, 32),
              [1, 8, 11, 13, 15, 18, 21, 23, 25, 28, 3, 5].contains(headerShape) else {
            throw MapVectorFeatureExportError.malformedSource
        }
        var cursor = 100
        var result: [ShapeRecord] = []
        while cursor < data.count {
            guard cursor + 8 <= data.count,
                  readUInt32BE(data, cursor) == UInt32(result.count + 1),
                  let words = readUInt32BE(data, cursor + 4),
                  words > 0, Int(words) <= (Int.max - 8) / 2 else {
                throw MapVectorFeatureExportError.malformedSource
            }
            let contentLength = Int(words) * 2
            let contentOffset = cursor + 8
            guard contentLength <= data.count - contentOffset,
                  let recordShape = readUInt32LE(data, contentOffset),
                  recordShape == 0 || recordShape == headerShape,
                  [0, 1, 8, 11, 13, 15, 18, 21, 23, 25, 28, 3, 5].contains(recordShape) else {
                throw MapVectorFeatureExportError.malformedSource
            }
            let content = data.subdata(in: contentOffset..<(contentOffset + contentLength))
            guard validateShapeRecord(content, type: recordShape) else {
                throw MapVectorFeatureExportError.malformedSource
            }
            result.append(ShapeRecord(offset: cursor, contentLength: contentLength, content: content))
            cursor = contentOffset + contentLength
        }
        guard cursor == data.count else { throw MapVectorFeatureExportError.malformedSource }
        return result
    }

    private static func parseDatabase(_ data: Data) throws -> DatabaseTable {
        guard data.count >= 33,
              let count = readUInt32LE(data, 4),
              let headerLengthValue = readUInt16LE(data, 8),
              let recordLengthValue = readUInt16LE(data, 10) else {
            throw MapVectorFeatureExportError.malformedSource
        }
        let headerLength = Int(headerLengthValue)
        let recordLength = Int(recordLengthValue)
        let recordCount = Int(count)
        guard headerLength >= 33, headerLength <= data.count,
              recordLength > 0, recordCount <= (data.count - headerLength) / recordLength,
              data[headerLength - 1] == 0x0D else { throw MapVectorFeatureExportError.malformedSource }
        var descriptor = 32
        var fieldByteCount = 1
        while descriptor < headerLength - 1 {
            guard descriptor + 32 <= headerLength - 1 else { throw MapVectorFeatureExportError.malformedSource }
            let type = data[descriptor + 11]
            if [UInt8(ascii: "M"), UInt8(ascii: "G"), UInt8(ascii: "P"), UInt8(ascii: "B")].contains(type) {
                throw MapVectorFeatureExportError.unsupportedSidecar
            }
            let fieldLength = Int(data[descriptor + 16])
            guard fieldLength > 0, fieldByteCount <= Int.max - fieldLength else {
                throw MapVectorFeatureExportError.malformedSource
            }
            fieldByteCount += fieldLength
            descriptor += 32
        }
        guard descriptor == headerLength - 1, fieldByteCount == recordLength else {
            throw MapVectorFeatureExportError.malformedSource
        }
        let end = headerLength + recordCount * recordLength
        let records = (0..<recordCount).map { index in
            data.subdata(in: (headerLength + index * recordLength)..<(headerLength + (index + 1) * recordLength))
        }
        return DatabaseTable(headerLength: headerLength, recordLength: recordLength,
            recordCount: recordCount, header: data.subdata(in: 0..<headerLength),
            records: records, trailer: data.subdata(in: end..<data.count))
    }

    private static func validateIndex(_ index: Data, shapeType: UInt32, records: [ShapeRecord]) throws {
        guard index.count >= 100, readUInt32BE(index, 0) == 9994,
              readUInt32LE(index, 28) == 1000,
              readUInt32LE(index, 32) == shapeType,
              let words = readUInt32BE(index, 24), Int(words) * 2 == index.count,
              (index.count - 100) % 8 == 0,
              (index.count - 100) / 8 == records.count else { throw MapVectorFeatureExportError.malformedSource }
        for (ordinal, record) in records.enumerated() {
            let entry = 100 + ordinal * 8
            guard readUInt32BE(index, entry) == UInt32(record.offset / 2),
                  readUInt32BE(index, entry + 4) == UInt32(record.contentLength / 2) else {
                throw MapVectorFeatureExportError.malformedSource
            }
        }
    }

    private static func validateShapeRecord(_ content: Data, type: UInt32) -> Bool {
        guard content.count >= 4, readUInt32LE(content, 0) == type else { return false }
        if type == 0 { return content.count == 4 }
        switch type {
        case 1:
            return content.count == 20 && readDoubleLE(content, 4) != nil
                && readDoubleLE(content, 12) != nil
        case 11:
            guard content.count == 28 || content.count == 36 else { return false }
            return readDoubleLE(content, 4) != nil && readDoubleLE(content, 12) != nil
                && readDoubleLE(content, 20) != nil
                && (content.count == 28 || readDoubleLE(content, 28) != nil)
        case 21:
            return content.count == 28 && readDoubleLE(content, 4) != nil
                && readDoubleLE(content, 12) != nil && readDoubleLE(content, 20) != nil
        default:
            guard let layout = coordinateArrayLayout(content, type: type) else { return false }
            switch type {
            case 3, 5, 8:
                return content.count == layout.end
            case 13, 15, 18:
                guard let zBytes = dimensionalArrayEnd(start: layout.end, count: layout.pointCount),
                      zBytes <= content.count,
                      rangeValuesAreFinite(content, start: layout.end, count: 2 + layout.pointCount) else { return false }
                if zBytes == content.count { return true }
                guard let mBytes = dimensionalArrayEnd(start: zBytes, count: layout.pointCount) else { return false }
                return content.count == mBytes
                    && rangeValuesAreFinite(content, start: zBytes, count: 2 + layout.pointCount)
            case 23, 25, 28:
                guard let mBytes = dimensionalArrayEnd(start: layout.end, count: layout.pointCount) else { return false }
                return content.count == mBytes
                    && rangeValuesAreFinite(content, start: layout.end, count: 2 + layout.pointCount)
            default:
                return false
            }
        }
    }

    private static func coordinateArrayLayout(_ content: Data, type: UInt32) -> CoordinateArrayLayout? {
        let pointCount: Int
        let pointsStart: Int
        if [8, 18, 28].contains(type) {
            guard let rawCount = readUInt32LE(content, 36) else { return nil }
            pointCount = Int(rawCount)
            pointsStart = 40
        } else if [3, 5, 13, 15, 23, 25].contains(type) {
            guard let rawPartCount = readUInt32LE(content, 36),
                  let rawPointCount = readUInt32LE(content, 40) else { return nil }
            let partCount = Int(rawPartCount)
            pointCount = Int(rawPointCount)
            guard partCount > 0, pointCount > 0,
                  partCount <= (Int.max - 44) / 4 else { return nil }
            pointsStart = 44 + partCount * 4
            var previous = -1
            for part in 0..<partCount {
                guard let rawStart = readUInt32LE(content, 44 + part * 4) else { return nil }
                let start = Int(rawStart)
                guard start < pointCount, start > previous else { return nil }
                previous = start
            }
        } else {
            return nil
        }
        guard let minimumX = readDoubleLE(content, 4), let minimumY = readDoubleLE(content, 12),
              let maximumX = readDoubleLE(content, 20), let maximumY = readDoubleLE(content, 28),
              minimumX <= maximumX, minimumY <= maximumY else { return nil }
        guard pointCount > 0, pointCount <= (Int.max - pointsStart) / 16 else { return nil }
        let end = pointsStart + pointCount * 16
        guard end <= content.count else { return nil }
        for point in 0..<pointCount {
            let offset = pointsStart + point * 16
            guard readDoubleLE(content, offset) != nil, readDoubleLE(content, offset + 8) != nil else { return nil }
        }
        return CoordinateArrayLayout(pointCount: pointCount, end: end)
    }

    private static func dimensionalArrayEnd(start: Int, count: Int) -> Int? {
        guard start >= 0, count >= 0, count <= (Int.max - start - 16) / 8 else { return nil }
        return start + 16 + count * 8
    }

    private static func rangeValuesAreFinite(_ data: Data, start: Int, count: Int) -> Bool {
        guard count >= 0, count <= (Int.max - start) / 8 else { return false }
        return (0..<count).allSatisfy { readDoubleLE(data, start + $0 * 8) != nil }
    }

    private static func ordinateRanges(_ record: ShapeRecord) -> (z: NumericRange?, m: NumericRange?) {
        guard let type = readUInt32LE(record.content, 0) else { return (nil, nil) }
        if type == 11 {
            let z = numericRange([readDoubleLE(record.content, 20)].compactMap { $0 })
            let m = record.content.count >= 36
                ? numericRange([readDoubleLE(record.content, 28)].compactMap { $0 }, measure: true) : nil
            return (z, m)
        }
        if type == 21 {
            return (nil, numericRange([readDoubleLE(record.content, 20)].compactMap { $0 }, measure: true))
        }
        guard let layout = coordinateArrayLayout(record.content, type: type) else { return (nil, nil) }
        if [13, 15, 18].contains(type) {
            let zStart = layout.end + 16
            let z = numericRange((0..<layout.pointCount).compactMap {
                readDoubleLE(record.content, zStart + $0 * 8)
            })
            let mStart = zStart + layout.pointCount * 8 + 16
            let hasMeasures = record.content.count >= mStart + layout.pointCount * 8
            let m = hasMeasures ? numericRange((0..<layout.pointCount).compactMap {
                readDoubleLE(record.content, mStart + $0 * 8)
            }, measure: true) : nil
            return (z, m)
        }
        if [23, 25, 28].contains(type) {
            let mStart = layout.end + 16
            return (nil, numericRange((0..<layout.pointCount).compactMap {
                readDoubleLE(record.content, mStart + $0 * 8)
            }, measure: true))
        }
        return (nil, nil)
    }

    private static func numericRange(_ values: [Double], measure: Bool = false) -> NumericRange? {
        let applicable = values.filter { $0.isFinite && (!measure || $0 >= -1e38) }
        guard let minimum = applicable.min(), let maximum = applicable.max() else { return nil }
        return NumericRange(minimum: minimum, maximum: maximum)
    }

    private static func rebuildShapeFile(from source: Data, records: [ShapeRecord]) throws -> Data {
        var output = source.subdata(in: 0..<100)
        for (index, record) in records.enumerated() {
            guard record.contentLength % 2 == 0 else { throw MapVectorFeatureExportError.malformedSource }
            appendUInt32BE(UInt32(index + 1), to: &output)
            appendUInt32BE(UInt32(record.contentLength / 2), to: &output)
            output.append(record.content)
        }
        let wordLength = output.count / 2
        guard output.count % 2 == 0, wordLength <= Int(UInt32.max) else { throw MapVectorFeatureExportError.malformedSource }
        writeUInt32BE(UInt32(wordLength), at: 24, in: &output)
        updateXYExtent(in: &output, records: records)
        updateZExtent(in: &output, records: records)
        updateMExtent(in: &output, records: records)
        return output
    }

    private static func rebuildIndex(from source: Data, shapeHeader: Data,
                                     records: [ShapeRecord]) throws -> Data {
        guard shapeHeader.count == 100 else { throw MapVectorFeatureExportError.malformedSource }
        var output = shapeHeader
        for record in records {
            let offsetWords = output.count / 2
            guard offsetWords <= Int(UInt32.max), record.contentLength % 2 == 0 else {
                throw MapVectorFeatureExportError.malformedSource
            }
            appendUInt32BE(UInt32(offsetWords), to: &output)
            appendUInt32BE(UInt32(record.contentLength / 2), to: &output)
        }
        guard output.count % 2 == 0, output.count / 2 <= Int(UInt32.max) else {
            throw MapVectorFeatureExportError.malformedSource
        }
        writeUInt32BE(UInt32(output.count / 2), at: 24, in: &output)
        return output
    }

    private static func rebuildDatabase(_ database: DatabaseTable, ordinals: [Int]) throws -> Data {
        guard ordinals.allSatisfy(database.records.indices.contains) else { throw MapVectorFeatureExportError.invalidSelection }
        var output = database.header
        guard ordinals.count <= Int(UInt32.max) else { throw MapVectorFeatureExportError.malformedSource }
        writeUInt32LE(UInt32(ordinals.count), at: 4, in: &output)
        for ordinal in ordinals { output.append(database.records[ordinal]) }
        output.append(database.trailer)
        return output
    }

    private static func updateXYExtent(in shapefile: inout Data, records: [ShapeRecord]) {
        let extents = records.compactMap(shapeExtent)
        guard let minX = extents.map(\.minX).min(), let minY = extents.map(\.minY).min(),
              let maxX = extents.map(\.maxX).max(), let maxY = extents.map(\.maxY).max() else {
            for offset in stride(from: 36, through: 60, by: 8) { writeDoubleLE(0, at: offset, in: &shapefile) }
            return
        }
        writeDoubleLE(minX, at: 36, in: &shapefile); writeDoubleLE(minY, at: 44, in: &shapefile)
        writeDoubleLE(maxX, at: 52, in: &shapefile); writeDoubleLE(maxY, at: 60, in: &shapefile)
    }

    private static func updateZExtent(in shapefile: inout Data, records: [ShapeRecord]) {
        updateOrdinateExtent(in: &shapefile, ranges: records.compactMap { ordinateRanges($0).z },
            minimumOffset: 68, maximumOffset: 76)
    }

    private static func updateMExtent(in shapefile: inout Data, records: [ShapeRecord]) {
        updateOrdinateExtent(in: &shapefile, ranges: records.compactMap { ordinateRanges($0).m },
            minimumOffset: 84, maximumOffset: 92)
    }

    private static func updateOrdinateExtent(in shapefile: inout Data, ranges: [NumericRange],
                                             minimumOffset: Int, maximumOffset: Int) {
        guard let minimum = ranges.map(\.minimum).min(), let maximum = ranges.map(\.maximum).max() else {
            writeDoubleLE(0, at: minimumOffset, in: &shapefile)
            writeDoubleLE(0, at: maximumOffset, in: &shapefile)
            return
        }
        writeDoubleLE(minimum, at: minimumOffset, in: &shapefile)
        writeDoubleLE(maximum, at: maximumOffset, in: &shapefile)
    }

    private struct XYExtent { let minX: Double; let minY: Double; let maxX: Double; let maxY: Double }
    private static func shapeExtent(_ record: ShapeRecord) -> XYExtent? {
        guard let code = readUInt32LE(record.content, 0), code != 0 else { return nil }
        if [1, 11, 21].contains(code), record.content.count >= 20,
           let x = readDoubleLE(record.content, 4), let y = readDoubleLE(record.content, 12) {
            return XYExtent(minX: x, minY: y, maxX: x, maxY: y)
        }
        guard [3, 8, 13, 15, 18, 23, 25, 28, 5].contains(code), record.content.count >= 36,
              let minX = readDoubleLE(record.content, 4), let minY = readDoubleLE(record.content, 12),
              let maxX = readDoubleLE(record.content, 20), let maxY = readDoubleLE(record.content, 28) else { return nil }
        return XYExtent(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private static func publish(_ family: OutputFamily, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        let outputFiles: [(String, Data)] = [
            ("shp", family.shapefile), ("shx", family.index), ("dbf", family.attributes)
        ] + (family.projection.map { [("prj", $0)] } ?? [])
        let destinations = outputFiles.map { directory.appendingPathComponent(base).appendingPathExtension($0.0) }
        guard !destinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MapVectorFeatureExportError.destinationUnavailable
        }
        let staging = directory.appendingPathComponent(".hecras-selected-features-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = try outputFiles.enumerated().map { index, item -> URL in
            let url = staging.appendingPathComponent("\(index).\(item.0)")
            try item.1.write(to: url, options: .atomic)
            return url
        }
        var published: [URL] = []
        do {
            for (source, target) in zip(staged, destinations) {
                try FileManager.default.moveItem(at: source, to: target)
                published.append(target)
            }
        } catch {
            for url in published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
    private static func readDoubleLE(_ data: Data, _ offset: Int) -> Double? {
        guard let bits = readUInt64LE(data, offset) else { return nil }
        let value = Double(bitPattern: bits)
        return value.isFinite ? value : nil
    }
    private static func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }
    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF)); data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF)); data.append(UInt8(value & 0xFF))
    }
    private static func writeUInt32BE(_ value: UInt32, at offset: Int, in data: inout Data) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        data[offset] = UInt8((value >> 24) & 0xFF); data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF); data[offset + 3] = UInt8(value & 0xFF)
    }
    private static func writeUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        data[offset] = UInt8(value & 0xFF); data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF); data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
    private static func writeDoubleLE(_ value: Double, at offset: Int, in data: inout Data) {
        let bits = value.bitPattern
        for index in 0..<8 { data[offset + index] = UInt8((bits >> UInt64(index * 8)) & 0xFF) }
    }
}
