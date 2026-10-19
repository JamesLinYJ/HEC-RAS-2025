import Foundation
import Testing
@testable import HECRAS2025

struct MapShapefileSelectedFeatureExporterTests {
    @Test
    func selectedSubsetKeepsRawPolygonHolesXYZMDbfAndProjection() throws {
        let first = polygonZRecord(offset: 0)
        let second = polygonZRecord(offset: 100)
        let source = shapeFiles(records: [first, second])
        let projection = Data("source CRS definition\r\n".utf8)

        let output = try MapShapefileSelectedFeatureExporter.filter(
            shapefile: source.shp, index: source.shx, attributes: source.dbf,
            projection: projection, recordOrdinals: [1])

        #expect(readUInt32LE(output.shapefile, 32) == 15)
        #expect(readUInt32BE(output.shapefile, 24) == UInt32(output.shapefile.count / 2))
        #expect(readUInt32BE(output.index, 24) == UInt32(output.index.count / 2))
        #expect(readUInt32LE(output.attributes, 4) == 1)
        #expect(output.projection == projection)

        let contentLength = Int(try #require(readUInt32BE(output.shapefile, 104))) * 2
        let retainedGeometry = output.shapefile.subdata(in: 108..<(108 + contentLength))
        #expect(retainedGeometry == second)
        #expect(readUInt32LE(retainedGeometry, 0) == 15)
        #expect(readUInt32LE(retainedGeometry, 36) == 2) // two rings: shell and hole
        #expect(readUInt32LE(retainedGeometry, 40) == 10)
        #expect(readDoubleLE(retainedGeometry, retainedGeometry.count - 8) == 209)

        let retainedDBF = output.attributes.subdata(in: 97..<(97 + 13))
        #expect(retainedDBF == source.dbf.subdata(in: (97 + 13)..<(97 + 26)))
        #expect(output.attributes.last == 0x1A)
        #expect(readUInt32BE(output.index, 100) == 50)
        #expect(readUInt32BE(output.index, 104) == UInt32(second.count / 2))
        #expect(readDoubleLE(output.shapefile, 36) == 100)
        #expect(readDoubleLE(output.shapefile, 52) == 110)
        #expect(readDoubleLE(output.shapefile, 68) == 101)
        #expect(readDoubleLE(output.shapefile, 76) == 110)
        #expect(readDoubleLE(output.shapefile, 84) == 200)
        #expect(readDoubleLE(output.shapefile, 92) == 209)
    }

    @Test
    func requestedOrdinalsAreSortedToKeepShapeAndDBFRecordsAligned() throws {
        let first = polygonZRecord(offset: 0)
        let second = polygonZRecord(offset: 100)
        let source = shapeFiles(records: [first, second])
        let output = try MapShapefileSelectedFeatureExporter.filter(
            shapefile: source.shp, index: source.shx, attributes: source.dbf,
            projection: nil, recordOrdinals: [1, 0])

        #expect(readUInt32LE(output.attributes, 4) == 2)
        let firstOutput = recordContent(output.shapefile, ordinal: 0)
        let secondOutput = recordContent(output.shapefile, ordinal: 1)
        #expect(firstOutput == first)
        #expect(secondOutput == second)
        #expect(output.attributes.subdata(in: 97..<(97 + 13)) == source.dbf.subdata(in: 97..<(97 + 13)))
        #expect(output.attributes.subdata(in: (97 + 13)..<(97 + 26)) == source.dbf.subdata(in: (97 + 13)..<(97 + 26)))
    }

    @Test
    func mismatchedIndexAndRepeatedRecordSelectionAreRejected() {
        let source = shapeFiles(records: [polygonZRecord(offset: 0), polygonZRecord(offset: 100)])
        var wrongIndex = source.shx
        writeUInt32BE(51, at: 100, in: &wrongIndex)
        #expect(throws: MapVectorFeatureExportError.self) {
            try MapShapefileSelectedFeatureExporter.filter(
                shapefile: source.shp, index: wrongIndex, attributes: source.dbf,
                projection: nil, recordOrdinals: [0])
        }
        #expect(throws: MapVectorFeatureExportError.self) {
            try MapShapefileSelectedFeatureExporter.filter(
                shapefile: source.shp, index: source.shx, attributes: source.dbf,
                projection: nil, recordOrdinals: [0, 0])
        }
    }

    @Test
    func selectedMultiPointZMRecordKeepsEveryPointAndRebuildsOrdinateExtents() throws {
        let record = multiPointZRecord(points: [
            (x: 4.0, y: 7.0, z: 12.0, m: 30.0),
            (x: 8.0, y: 3.0, z: 16.0, m: 34.0)
        ])
        let source = shapeFiles(records: [record], shapeType: 18)
        let output = try MapShapefileSelectedFeatureExporter.filter(
            shapefile: source.shp, index: source.shx, attributes: source.dbf,
            projection: nil, recordOrdinals: [0])

        #expect(readUInt32LE(output.shapefile, 32) == 18)
        #expect(recordContent(output.shapefile, ordinal: 0) == record)
        #expect(readUInt32LE(record, 36) == 2)
        #expect(readDoubleLE(output.shapefile, 36) == 4)
        #expect(readDoubleLE(output.shapefile, 44) == 3)
        #expect(readDoubleLE(output.shapefile, 52) == 8)
        #expect(readDoubleLE(output.shapefile, 60) == 7)
        #expect(readDoubleLE(output.shapefile, 68) == 12)
        #expect(readDoubleLE(output.shapefile, 76) == 16)
        #expect(readDoubleLE(output.shapefile, 84) == 30)
        #expect(readDoubleLE(output.shapefile, 92) == 34)
    }

    private struct ShapeFiles {
        let shp: Data
        let shx: Data
        let dbf: Data
    }

    private func shapeFiles(records: [Data], shapeType: UInt32 = 15) -> ShapeFiles {
        var shp = fileHeader(shapeType: shapeType, lengthWords: 50)
        var offsets: [UInt32] = []
        for (index, record) in records.enumerated() {
            offsets.append(UInt32(shp.count / 2))
            appendUInt32BE(UInt32(index + 1), to: &shp)
            appendUInt32BE(UInt32(record.count / 2), to: &shp)
            shp.append(record)
        }
        writeUInt32BE(UInt32(shp.count / 2), at: 24, in: &shp)
        writeDoubleLE(0, at: 36, in: &shp); writeDoubleLE(0, at: 44, in: &shp)
        writeDoubleLE(110, at: 52, in: &shp); writeDoubleLE(10, at: 60, in: &shp)
        writeDoubleLE(1, at: 68, in: &shp); writeDoubleLE(15, at: 76, in: &shp)
        writeDoubleLE(100, at: 84, in: &shp); writeDoubleLE(200, at: 92, in: &shp)

        var shx = fileHeader(shapeType: shapeType, lengthWords: UInt32((100 + records.count * 8) / 2))
        for (offset, record) in zip(offsets, records) {
            appendUInt32BE(offset, to: &shx)
            appendUInt32BE(UInt32(record.count / 2), to: &shx)
        }
        return ShapeFiles(shp: shp, shx: shx, dbf: attributeTable(recordCount: records.count))
    }

    private func fileHeader(shapeType: UInt32, lengthWords: UInt32) -> Data {
        var header = Data(repeating: 0, count: 100)
        writeUInt32BE(9994, at: 0, in: &header)
        writeUInt32BE(lengthWords, at: 24, in: &header)
        writeUInt32LE(1000, at: 28, in: &header)
        writeUInt32LE(shapeType, at: 32, in: &header)
        return header
    }

    /// A polygon-Z record with two closed rings and aligned Z/M arrays. Copying
    /// the bytes exercises holes and four-dimensional coordinates together.
    private func polygonZRecord(offset: Double) -> Data {
        var content = Data()
        appendUInt32LE(15, to: &content)
        appendDoubleLE(offset, to: &content); appendDoubleLE(0, to: &content)
        appendDoubleLE(offset + 10, to: &content); appendDoubleLE(10, to: &content)
        appendUInt32LE(2, to: &content); appendUInt32LE(10, to: &content)
        appendUInt32LE(0, to: &content); appendUInt32LE(5, to: &content)
        let points: [(Double, Double)] = [
            (offset, 0), (offset + 10, 0), (offset + 10, 10), (offset, 10), (offset, 0),
            (offset + 2, 2), (offset + 2, 4), (offset + 4, 4), (offset + 4, 2), (offset + 2, 2)
        ]
        for (x, y) in points { appendDoubleLE(x, to: &content); appendDoubleLE(y, to: &content) }
        appendDoubleLE(offset + 1, to: &content); appendDoubleLE(offset + 10, to: &content)
        for value in 1...10 { appendDoubleLE(offset + Double(value), to: &content) }
        appendDoubleLE(offset + 100, to: &content); appendDoubleLE(offset + 109, to: &content)
        for value in 0..<10 { appendDoubleLE(offset + 100 + Double(value), to: &content) }
        return content
    }

    private func multiPointZRecord(points: [(x: Double, y: Double, z: Double, m: Double)]) -> Data {
        var content = Data()
        appendUInt32LE(18, to: &content)
        appendDoubleLE(points.map(\.x).min() ?? 0, to: &content)
        appendDoubleLE(points.map(\.y).min() ?? 0, to: &content)
        appendDoubleLE(points.map(\.x).max() ?? 0, to: &content)
        appendDoubleLE(points.map(\.y).max() ?? 0, to: &content)
        appendUInt32LE(UInt32(points.count), to: &content)
        for point in points { appendDoubleLE(point.x, to: &content); appendDoubleLE(point.y, to: &content) }
        appendDoubleLE(points.map(\.z).min() ?? 0, to: &content)
        appendDoubleLE(points.map(\.z).max() ?? 0, to: &content)
        for point in points { appendDoubleLE(point.z, to: &content) }
        appendDoubleLE(points.map(\.m).min() ?? 0, to: &content)
        appendDoubleLE(points.map(\.m).max() ?? 0, to: &content)
        for point in points { appendDoubleLE(point.m, to: &content) }
        return content
    }

    private func attributeTable(recordCount: Int) -> Data {
        let headerLength = 97
        let recordLength = 13
        var result = Data(repeating: 0, count: 32)
        result[0] = 0x03
        writeUInt32LE(UInt32(recordCount), at: 4, in: &result)
        writeUInt16LE(UInt16(headerLength), at: 8, in: &result)
        writeUInt16LE(UInt16(recordLength), at: 10, in: &result)
        result.append(field(name: "NAME", type: 67, length: 8))
        result.append(field(name: "VALUE", type: 78, length: 4))
        result.append(0x0D)
        for index in 0..<recordCount {
            let name = index == 0 ? "FIRST" : (index == 1 ? "SECOND" : "RECORD\(index + 1)")
            result.append(0x20)
            result.append(Data(String(name.prefix(8)).padding(toLength: 8, withPad: " ", startingAt: 0).utf8))
            result.append(Data(String(format: "%04d", index + 1).utf8))
        }
        result.append(0x1A)
        return result
    }

    private func field(name: String, type: UInt8, length: UInt8) -> Data {
        var descriptor = Data(repeating: 0, count: 32)
        let nameBytes = Array(name.utf8.prefix(11))
        for (index, byte) in nameBytes.enumerated() { descriptor[index] = byte }
        descriptor[11] = type
        descriptor[16] = length
        return descriptor
    }

    private func recordContent(_ data: Data, ordinal: Int) -> Data {
        var cursor = 100
        for index in 0...ordinal {
            let length = Int(readUInt32BE(data, cursor + 4) ?? 0) * 2
            if index == ordinal { return data.subdata(in: (cursor + 8)..<(cursor + 8 + length)) }
            cursor += 8 + length
        }
        return Data()
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF)); data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF)); data.append(UInt8((value >> 24) & 0xFF))
    }
    private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF)); data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF)); data.append(UInt8(value & 0xFF))
    }
    private func appendDoubleLE(_ value: Double, to data: inout Data) {
        let bits = value.bitPattern
        for index in 0..<8 { data.append(UInt8((bits >> UInt64(index * 8)) & 0xFF)) }
    }
    private func writeUInt16LE(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(value & 0xFF); data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
    private func writeUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xFF) }
    }
    private func writeUInt32BE(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[offset] = UInt8((value >> 24) & 0xFF); data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF); data[offset + 3] = UInt8(value & 0xFF)
    }
    private func writeDoubleLE(_ value: Double, at offset: Int, in data: inout Data) {
        let bits = value.bitPattern
        for index in 0..<8 { data[offset + index] = UInt8((bits >> UInt64(index * 8)) & 0xFF) }
    }
    private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
    private func readDoubleLE(_ data: Data, _ offset: Int) -> Double? {
        guard offset + 8 <= data.count else { return nil }
        var bits: UInt64 = 0
        for index in 0..<8 { bits |= UInt64(data[offset + index]) << UInt64(index * 8) }
        return Double(bitPattern: bits)
    }
}
