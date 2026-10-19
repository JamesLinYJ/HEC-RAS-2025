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

    private func withLanguage(_ language: String, perform body: () -> Void) {
        let previousLanguage = L10n.language
        L10n.language = language
        defer { L10n.language = previousLanguage }
        body()
    }
}
