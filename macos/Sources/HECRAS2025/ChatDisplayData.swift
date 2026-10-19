import CoreFoundation
import Foundation

struct MessageTable: Hashable, Sendable {
    struct Column: Identifiable, Hashable, Sendable {
        let id: Int
        let key: String
        let title: String
        let width: Double
        let editable: Bool
        var defaultTitleOrdinal: Int? = nil
    }
    struct Row: Identifiable, Hashable, Sendable { let id: Int; var values: [String] }
    let columns: [Column]
    var rows: [Row]
}
enum ChatDisplayObject: Hashable, Sendable {
    case items(MessageTable), column([String])
}
struct ChatTableMessage: Hashable, Sendable {
    let title: String
    let dataMode: String
    var jsonItemsSource = ""
    var itemsSourceObjectID = ""
    var jsonColumnData = ""
    var jsonRowData = ""
    var columnDefinitions = ""
    var timestamp: Date? = nil
    func table(objects: [String: ChatDisplayObject]) throws -> MessageTable {
        switch dataMode.lowercased() {
        case "items":
            if !itemsSourceObjectID.isEmpty {
                guard case .items(let table) = objects[DisplayJSON.objectID(itemsSourceObjectID)] else { throw DisplayError.unavailableObject }
                if columnDefinitions.isEmpty {
                    return MessageTable(columns: table.columns.map { .init(id: $0.id, key: $0.key, title: $0.title, width: $0.width, editable: false) }, rows: table.rows)
                }
                let definitions = try DisplayJSON.objects(columnDefinitions)
                let columns = definitions.enumerated().map { index, definition in
                    MessageTable.Column(id: index, key: definition["fieldName"] as? String ?? "", title: definition["header"] as? String ?? "", width: DisplayJSON.width(definition), editable: false)
                }
                return MessageTable(columns: columns, rows: table.rows.map { row in
                    MessageTable.Row(id: row.id, values: columns.map { column in
                        table.columns.firstIndex(where: { $0.key == column.key }).flatMap { row.values.indices.contains($0) ? row.values[$0] : nil } ?? ""
                    })
                })
            }
            if jsonItemsSource.isEmpty { return MessageTable(columns: [], rows: []) }
            return try DisplayJSON.itemTable(jsonItemsSource, labels: nil, editable: true)
        case "columns":
            if jsonColumnData.isEmpty { return MessageTable(columns: [], rows: []) }
            var columns: [MessageTable.Column] = [], data: [[String]] = []
            for definition in try DisplayJSON.objects(jsonColumnData) {
                guard let header = definition["header"] as? String else { throw DisplayError.invalidTable }
                var values: [String]?, editable = !(definition["isReadOnly"] as? Bool ?? false)
                if let reference = definition["data"] as? String, reference.hasPrefix("objectId:") {
                    guard case .column(let contents) = objects[DisplayJSON.objectID(reference)] else { throw DisplayError.unavailableObject }
                    values = contents; editable = false
                } else if let contents = definition["data"] as? [Any] { values = try contents.map(DisplayJSON.cell) }
                guard let values else { continue }
                columns.append(.init(id: columns.count, key: header, title: header, width: DisplayJSON.width(definition), editable: editable))
                data.append(values)
            }
            let count = data.map(\.count).max() ?? 0
            return MessageTable(columns: columns, rows: (0..<count).map { row in .init(id: row, values: data.map { row < $0.count ? $0[row] : "" }) })
        case "rows":
            if jsonRowData.isEmpty { return MessageTable(columns: [], rows: []) }
            guard let rows = try DisplayJSON.root(jsonRowData) as? [[Any]] else { throw DisplayError.invalidTable }
            let count = rows.first?.count ?? 0
            let definitions = columnDefinitions.isEmpty ? [] : try DisplayJSON.objects(columnDefinitions)
            let columns = (0..<count).map { index in
                let title = index < definitions.count ? definitions[index]["header"] as? String : nil
                return MessageTable.Column(id: index, key: String(index), title: title ?? "Column \(index + 1)", width: 100, editable: true, defaultTitleOrdinal: title == nil ? index + 1 : nil)
            }
            return MessageTable(columns: columns, rows: try rows.enumerated().map { index, row in
                .init(id: index, values: try (0..<count).map { $0 < row.count ? try DisplayJSON.cell(row[$0]) : "" })
            })
        default: throw DisplayError.invalidTableMode
        }
    }
}
struct MessageSeries: Identifiable, Hashable, Sendable {
    struct Point: Identifiable, Hashable, Sendable { let id: Int; let x: Double; let y: Double; let time: Date? }
    let id: Int
    let name: String
    let points: [Point]
    var defaultName = false
}
struct ChatChartMessage: Hashable, Sendable {
    let title: String
    let chartType: String
    var jsonData = ""
    var isMultiSeries = false
    var columns = ""
    var xLabel: String? = nil
    var yLabel: String? = nil
    var xDataArray: [Double]? = nil
    var yDataArray: [Double]? = nil
    var timestamp: Date? = nil
    func series() throws -> [MessageSeries] {
        switch chartType.lowercased() {
        case "xy":
            if isMultiSeries && !jsonData.isEmpty {
                var result: [MessageSeries] = []
                for item in try DisplayJSON.objects(jsonData) {
                    guard let xs = item["xData"] as? [Any], let ys = item["yData"] as? [Any], xs.count == ys.count else { continue }
                    result.append(.init(id: result.count, name: item["name"] as? String ?? "Series", points: try zip(xs, ys).enumerated().map { index, pair in .init(id: index, x: try DisplayJSON.number(pair.0), y: try DisplayJSON.number(pair.1), time: nil) }, defaultName: item["name"] == nil))
                }
                return result
            }
            if let xs = xDataArray, let ys = yDataArray {
                guard xs.count == ys.count, xs.allSatisfy(\.isFinite), ys.allSatisfy(\.isFinite) else { throw DisplayError.invalidChart }
                return [.init(id: 0, name: title.isEmpty ? "Data" : title, points: zip(xs, ys).enumerated().map { .init(id: $0.offset, x: $0.element.0, y: $0.element.1, time: nil) }, defaultName: title.isEmpty)]
            }
            if jsonData.isEmpty { return [] }
            let points = try DisplayJSON.objects(jsonData).enumerated().map { index, item in
                MessageSeries.Point(id: index, x: try DisplayJSON.number(item["x"]), y: try DisplayJSON.number(item["y"]), time: nil)
            }
            return [.init(id: 0, name: title.isEmpty ? "Data" : title, points: points, defaultName: title.isEmpty)]
        case "datetime":
            if jsonData.isEmpty { return [] }
            let items = try DisplayJSON.objects(jsonData)
            if isMultiSeries {
                return try items.enumerated().map { index, item in
                    guard let values = item["data"] as? [[String: Any]] else { throw DisplayError.invalidChart }
                    return .init(id: index, name: item["name"] as? String ?? "Series", points: try DisplayJSON.timePoints(values), defaultName: item["name"] == nil)
                }
            }
            return [.init(id: 0, name: title.isEmpty ? "Data" : title, points: try DisplayJSON.timePoints(items), defaultName: title.isEmpty)]
        default: throw DisplayError.invalidChart
        }
    }
    func table() throws -> MessageTable {
        let labels: [(key: String, title: String)]?
        if columns.isEmpty { labels = nil }
        else { labels = try DisplayJSON.objects(columns).map { item in
            guard let key = item["key"] as? String, let title = item["label"] as? String else { throw DisplayError.invalidTable }
            return (key, title)
        } }
        return try DisplayJSON.itemTable(jsonData, labels: labels, editable: false)
    }
}
enum ChatDisplayPayload: Hashable, Sendable {
    case table(ChatTableMessage), chart(ChatChartMessage)
    var title: String { switch self { case .table(let value): value.title; case .chart(let value): value.title } }
    var timestamp: Date? { switch self { case .table(let value): value.timestamp; case .chart(let value): value.timestamp } }
    @MainActor var displayTitle: String { title.isEmpty ? L10n.text(symbol == "tablecells" ? "Table" : "Chart") : title }
    var symbol: String { switch self { case .table: "tablecells"; case .chart(let value): value.chartType.lowercased() == "table" ? "tablecells" : "chart.xyaxis.line" } }
}
enum DisplayError: String, Error, LocalizedError {
    case invalidTable = "Invalid table data."
    case invalidTableMode = "Invalid table data mode."
    case invalidChart = "Invalid chart data."
    case unavailableObject = "Referenced display data is unavailable."
    var errorDescription: String? { rawValue }
}
private enum DisplayJSON {
    static func root(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
    static func objects(_ text: String) throws -> [[String: Any]] {
        guard let values = try root(text) as? [[String: Any]] else { throw DisplayError.invalidTable }
        return values
    }
    static func objectID(_ value: String) -> String { value.hasPrefix("objectId:") ? String(value.dropFirst(9)) : value }
    static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw DisplayError.invalidChart }
        return value.doubleValue
    }
    static func cell(_ value: Any) throws -> String {
        if let value = value as? String { return value }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    static func width(_ definition: [String: Any]) -> Double {
        (try? number(definition["width"])).map { min(max($0, 24), 2000) } ?? 100
    }
    static func itemTable(_ json: String, labels: [(key: String, title: String)]?, editable: Bool) throws -> MessageTable {
        let items = try objects(json)
        guard !items.isEmpty else { return MessageTable(columns: [], rows: []) }
        let definitions = labels ?? firstObjectKeys(json).map { ($0, $0) }
        let columns = definitions.enumerated().map { MessageTable.Column(id: $0.offset, key: $0.element.key, title: $0.element.title, width: 100, editable: editable) }
        let rows = try items.enumerated().map { index, item in
            MessageTable.Row(id: index, values: try definitions.map { definition in try item[definition.key].map(cell) ?? "" })
        }
        return MessageTable(columns: columns, rows: rows)
    }
    // JSONSerialization validates the document but its dictionaries do not
    // retain property order. Read only the first row's top-level key tokens,
    // preserving the original JsonElement.EnumerateObject column ordering.
    static func firstObjectKeys(_ text: String) -> [String] {
        let chars = Array(text), whitespace: Set<Character> = [" ", "\n", "\r", "\t"]
        var depth = 0, index = 0, result: [String] = [], seenObject = false
        while index < chars.count {
            let char = chars[index]
            if char == "{" { depth += 1; seenObject = true }
            else if char == "}" { depth -= 1; if seenObject && depth == 0 { break } }
            else if char == "\"" {
                let start = index; index += 1
                while index < chars.count {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == "\"" { break }
                    index += 1
                }
                var next = index + 1
                while next < chars.count && whitespace.contains(chars[next]) { next += 1 }
                if depth == 1 && next < chars.count && chars[next] == ":",
                   let key = try? root(String(chars[start...index])) as? String, !result.contains(key) { result.append(key) }
            }
            index += 1
        }
        return result
    }
    static func timePoints(_ items: [[String: Any]]) throws -> [MessageSeries.Point] {
        try items.enumerated().map { index, item in
            guard let text = item["time"] as? String, let date = date(text) else { throw DisplayError.invalidChart }
            return .init(id: index, x: date.timeIntervalSince1970, y: try number(item["value"]), time: date)
        }
    }
    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let value = iso.date(from: text) { return value }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let value = iso.date(from: text) { return value }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let value = formatter.date(from: text) { return value }
        }
        return nil
    }
}
