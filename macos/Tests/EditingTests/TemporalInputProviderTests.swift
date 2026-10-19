import Foundation
import Testing
@testable import HECRAS2025

struct TemporalInputProviderTests {
    @Test
    func decodesDateAndTimeSpanResultsFromTheBackendWireShape() throws {
        let dateJSON = #"{"operation":"date","isValid":true,"canonicalDate":"2024-03-04","canonicalTime":null,"timeSpanTicks":null,"timeSpanDays":null,"timeSpanHours":null,"timeSpanMinutes":null,"timeSpanSeconds":null,"canSetDateTime":true}"#
        let date = try JSONDecoder().decode(TemporalInputParseResult.self, from: Data(dateJSON.utf8))
        #expect(date.operation == "date")
        #expect(date.isValid)
        #expect(date.canonicalDate == "2024-03-04")
        #expect(date.canonicalTime == nil)

        let timeJSON = #"{"operation":"time","isValid":true,"canonicalDate":null,"canonicalTime":"02:03:04","timeSpanTicks":937841234567,"timeSpanDays":1,"timeSpanHours":2,"timeSpanMinutes":3,"timeSpanSeconds":4,"canSetDateTime":true}"#
        let time = try JSONDecoder().decode(TemporalInputParseResult.self, from: Data(timeJSON.utf8))
        #expect(time.operation == "time")
        #expect(time.timeSpanTicks == 937_841_234_567)
        #expect(time.timeSpanDays == 1)
        #expect(time.canonicalTime == "02:03:04")
    }

    @Test
    func cultureNameRetainsLanguageScriptAndRegionAndDropsFoundationExtensions() {
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "de_DE")) == "de-DE")
        // Foundation canonicalizes the redundant default Hans script away.
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "zh-Hans_CN")) == "zh-CN")
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "zh-Hant-CN")) == "zh-Hant-CN")
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "sr-Latn-RS")) == "sr-Latn-RS")
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "en_US_POSIX")) == "en-US")
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "en_US@calendar=gregorian")) == "en-US")
        #expect(OriginalTemporalCulture.name(for: Locale(identifier: "th-TH-u-nu-thai")) == "th-TH")
    }

    @Test
    func parseResultCanOnlyApplyToItsCapturedFieldEditorAndSourceValue() {
        let intent = OriginalTemporalInputParseIntent(
            operation: .date, text: "03/04/2024", locale: Locale(identifier: "en_US"),
            fieldID: "plan/start", editorIdentity: "editor-1", sourceValue: "2024-02-01T00:00:00+00:00",
            dateText: "03/04/2024", timeText: "00:00:00", dateTouched: true, timeTouched: false
        )
        let pending = OriginalDateTimeInputDraft(
            sourceValue: intent.sourceValue, dateText: intent.dateText, timeText: intent.timeText,
            dateTouched: true, timeTouched: false, issueKey: OriginalTemporalInputIssue.parsing
        )
        #expect(intent.isCurrent(activeID: intent.id, fieldID: "plan/start", editorIdentity: "editor-1",
            sourceValue: "2024-02-01T00:00:00+00:00", draft: pending))
        #expect(!intent.isCurrent(activeID: UUID(), fieldID: "plan/start", editorIdentity: "editor-1",
            sourceValue: "2024-02-01T00:00:00+00:00", draft: pending))
        #expect(!intent.isCurrent(activeID: intent.id, fieldID: "plan/end", editorIdentity: "editor-1",
            sourceValue: "2024-02-01T00:00:00+00:00", draft: pending))
        #expect(!intent.isCurrent(activeID: intent.id, fieldID: "plan/start", editorIdentity: "editor-2",
            sourceValue: "2024-02-01T00:00:00+00:00", draft: pending))
        #expect(!intent.isCurrent(activeID: intent.id, fieldID: "plan/start", editorIdentity: "editor-1",
            sourceValue: "2024-02-02T00:00:00+00:00", draft: pending))
        let changedDraft = OriginalDateTimeInputDraft(
            sourceValue: intent.sourceValue, dateText: "03/05/2024", timeText: intent.timeText,
            dateTouched: true, timeTouched: false, issueKey: OriginalTemporalInputIssue.parsing
        )
        #expect(!intent.isCurrent(activeID: intent.id, fieldID: "plan/start", editorIdentity: "editor-1",
            sourceValue: intent.sourceValue, draft: changedDraft))
    }
}
