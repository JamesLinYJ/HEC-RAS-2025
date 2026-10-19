import Testing
@testable import HECRAS2025

@Suite(.serialized)
@MainActor
struct LocalizationDiagnosticTests {
    @Test
    func translatesKnownVectorImportTemplatesAndPreservesDynamicValues() {
        withLanguage("zh-Hans") {
            #expect(L10n.text("'north route's.shp' contains no line or polygon features to import.") ==
                "文件“north route's.shp”不包含可导入的线或面要素。")
            #expect(L10n.text("Shapefile feature 37 contains a non-finite coordinate.") ==
                "Shapefile 要素 37 含有非有限坐标。")
        }
    }

    @Test
    func translatesOnlyKnownEmptyShapefileFamilyTypes() {
        withLanguage("zh-Hans") {
            #expect(L10n.text("The retained Shapefile writer could not create an empty Polyline family.") ==
                "现有 Shapefile 写入器无法创建空的 Polyline 文件组。")
            let unsupported = "The retained Shapefile writer could not create an empty MultiPatch family."
            #expect(L10n.text(unsupported) == unsupported)
        }
    }

    @Test
    func mapsKnownWriterAndRollbackHeadingsWithoutChangingPathsOrDetails() {
        withLanguage("zh-Hans") {
            let details = "/tmp/output %1.shp (permission denied)"
            #expect(L10n.text("The retained shapefile writer failed: \(details)") ==
                "现有 Shapefile 写入器失败：\(details)")

            let cleanup = "/tmp/out/file.shx (busy), /tmp/out/file.dbf (busy)"
            let composite = "rename failed. The incomplete shapefile family could not be rolled back: \(cleanup)"
            #expect(L10n.text(composite) ==
                "rename failed. 无法回滚不完整的 Shapefile 文件组：\(cleanup)")
        }
    }

    @Test
    func leavesUnknownMessagesAndMalformedDynamicTemplatesUntouched() {
        withLanguage("zh-Hans") {
            let unknown = "backend.protocol.v2: raw value /tmp/project.ras"
            #expect(L10n.text(unknown) == unknown)

            let malformedOrdinal = "Shapefile feature xyz contains a non-finite coordinate."
            #expect(L10n.text(malformedOrdinal) == malformedOrdinal)
        }
    }

    @Test
    func englishTemplatesRetainTheirSourceWording() {
        withLanguage("en") {
            let source = "Shapefile feature 37 contains a non-finite coordinate."
            #expect(L10n.text(source) == source)
        }
    }

    @Test
    func localizesKnownSpatialGridProgressAndPreservesUnknownSourceText() {
        withLanguage("zh-Hans") {
            #expect(SpatialGridProgressLocalization.taskName("Grid import") == "格网导入")
            #expect(SpatialGridProgressLocalization.taskName(nil) == "正在导入格网…")
            #expect(SpatialGridProgressLocalization.message("Reading selected DSS grid records...") ==
                "正在读取所选 DSS 格网记录…")
            #expect(SpatialGridProgressLocalization.message("Grid data and boundary edits were saved.") ==
                "格网数据和边界修改已保存。")
            let warning = "The grid data and boundary model were saved, but the editor could not refresh its snapshot. Reload the boundary model before continuing."
            #expect(SpatialGridProgressLocalization.message(warning) ==
                "栅格数据和边界模型已保存，但编辑器未能刷新快照。请重新加载边界模型后继续。")
            #expect(L10n.text("A DSS import uses one source file.") == "DSS 导入一次只能使用一个源文件。")
            #expect(L10n.text("No valid frames") == "没有有效的时间帧")

            let unknown = "DSS task 91: raw source detail /tmp/source.dss"
            #expect(SpatialGridProgressLocalization.taskName("Unknown DSS task") == "Unknown DSS task")
            #expect(SpatialGridProgressLocalization.message(unknown) == unknown)
        }
        withLanguage("en") {
            #expect(SpatialGridProgressLocalization.taskName("Grid import") == "Grid import")
            #expect(SpatialGridProgressLocalization.message("Reading selected DSS grid records...") ==
                "Reading selected DSS grid records...")
        }
    }

    @Test
    func localizesSeriesTableClipboardMessagesAndCounts() {
        withLanguage("zh-Hans") {
            #expect(L10n.text("Select a current cell or range before pasting.") ==
                "粘贴前，请先选择当前单元格或范围。")
            #expect(L10n.text("The clipboard does not contain valid table text.") ==
                "剪贴板中不包含有效的表格文本。")
            #expect(L10n.text("The table selection changed. Select a current range and paste again.") ==
                "表格选择已变化。请重新选择当前范围后再粘贴。")
            #expect(L10n.text("The pasted range exceeds the available table cells; no cells were changed.") ==
                "粘贴范围超出表格可用单元格，未更改单元格。")
            #expect(L10n.format("Pasted %d cell edits.", 3) == "已粘贴 3 项单元格修改。")
            #expect(L10n.format("Skipped %d read-only cells.", 2) == "已跳过 2 个只读单元格。")
            #expect(L10n.format("Skipped %d invalid cells.", 1) == "已跳过 1 个无效单元格。")
            #expect(L10n.format("Kept %d invalid numeric entries as drafts; correct them before saving.", 4) ==
                "已将 4 个无效数值保留为草稿，请在保存前修正。")
        }
        withLanguage("en") {
            #expect(L10n.text("Select a current cell or range before pasting.") ==
                "Select a current cell or range before pasting.")
            #expect(L10n.text("The clipboard does not contain valid table text.") ==
                "The clipboard does not contain valid table text.")
            #expect(L10n.text("The table selection changed. Select a current range and paste again.") ==
                "The table selection changed. Select a current range and paste again.")
            #expect(L10n.text("The pasted range exceeds the available table cells; no cells were changed.") ==
                "The pasted range exceeds the available table cells; no cells were changed.")
            #expect(L10n.format("Pasted %d cell edits.", 3) == "Pasted 3 cell edits.")
            #expect(L10n.format("Skipped %d read-only cells.", 2) == "Skipped 2 read-only cells.")
            #expect(L10n.format("Skipped %d invalid cells.", 1) == "Skipped 1 invalid cells.")
            #expect(L10n.format("Kept %d invalid numeric entries as drafts; correct them before saving.", 4) ==
                "Kept 4 invalid numeric entries as drafts; correct them before saving.")
        }
    }

    private func withLanguage(_ language: String, perform body: () -> Void) {
        let previousLanguage = L10n.language
        L10n.language = language
        defer { L10n.language = previousLanguage }
        body()
    }
}
