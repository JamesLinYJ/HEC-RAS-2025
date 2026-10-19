import Foundation
import Testing
@testable import HECRAS2025

struct ChatDisplayDataTests {
    @Test
    func itemColumnsPreserveSourceOrderAndIgnoreNestedKeys() throws {
        let message = ChatTableMessage(title: "中文结果", dataMode: "items", jsonItemsSource: #"[{"Z":2,"escaped\"name":"中文","nested":{"other":true},"A":null},{"A":4,"Z":3}]"#)
        let table = try message.table(objects: [:])
        #expect(table.columns.map(\.title) == ["Z", "escaped\"name", "nested", "A"])
        #expect(table.rows[0].values == ["2", "中文", #"{"other":true}"#, "null"])
        #expect(table.rows[1].values == ["3", "", "", "4"])
    }
    @Test
    func columnReferencesRetainReadonlyAndDifferentLengths() throws {
        let message = ChatTableMessage(title: "", dataMode: "columns", jsonColumnData: #"[{"header":"level","width":180,"data":"objectId:levels"},{"header":"label","data":["一","二"],"isReadOnly":false}]"#)
        let table = try message.table(objects: ["levels": .column(["1.5"])])
        #expect(table.columns[0].width == 180)
        #expect(!table.columns[0].editable)
        #expect(table.columns[1].editable)
        #expect(table.rows.map(\.values) == [["1.5", "一"], ["", "二"]])
        #expect(throws: DisplayError.unavailableObject) { try message.table(objects: [:]) }
    }
    @Test
    func rowHeadersUseOriginalDefinitionsAndPadShortRows() throws {
        let message = ChatTableMessage(title: "", dataMode: "rows", jsonRowData: #"[[1,"甲",true],[2],[3,"丙",false,"extra"]]"#, columnDefinitions: #"[{"header":"编号"}]"#)
        let table = try message.table(objects: [:])
        #expect(table.columns.count == 3)
        #expect(table.columns[0].title == "编号")
        #expect(table.columns[1].defaultTitleOrdinal == 2)
        #expect(table.rows[1].values == ["2", "", ""])
        #expect(table.rows[2].values == ["3", "丙", "false"])
    }
    @Test
    func xyDatasetsKeepSeparateSeriesAndRejectBooleanCoordinates() throws {
        let message = ChatChartMessage(title: "chart", chartType: "xy", jsonData: #"[{"name":"same","xData":[0,1],"yData":[2,3]},{"name":"same","xData":[0],"yData":[4]},{"xData":[0,1],"yData":[5]}]"#, isMultiSeries: true)
        let series = try message.series()
        #expect(series.map(\.id) == [0, 1])
        #expect(series.map(\.name) == ["same", "same"])
        #expect(series[1].points[0].y == 4)
        let invalid = ChatChartMessage(title: "", chartType: "xy", jsonData: #"[{"x":true,"y":1}]"#)
        #expect(throws: DisplayError.invalidChart) { try invalid.series() }
    }
    @Test
    func timeDatasetsRetainEachPairAndRejectUnparseableTime() throws {
        let message = ChatChartMessage(title: "flow", chartType: "datetime", jsonData: #"[{"time":"2026-10-15T01:00:00.125Z","value":1},{"time":"2026-10-15T01:00:01Z","value":2}]"#)
        let series = try message.series()
        #expect(series[0].points.map(\.y) == [1, 2])
        #expect(series[0].points.allSatisfy { $0.time != nil })
        #expect(abs(series[0].points[1].x - series[0].points[0].x - 0.875) < 0.00001)
        let invalid = ChatChartMessage(title: "", chartType: "datetime", jsonData: #"[{"time":"invalid","value":1},{"time":"2026-10-15T01:00:01Z","value":2}]"#)
        #expect(throws: DisplayError.invalidChart) { try invalid.series() }
    }
}
