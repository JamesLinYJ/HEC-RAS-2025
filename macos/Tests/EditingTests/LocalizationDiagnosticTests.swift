import Foundation
import Testing
@testable import HECRAS2025

struct LocalizationDiagnosticTests {
    @Test @MainActor
    func knownBackendValidationHeadingsTranslateWithoutChangingSourceIdentifiers() {
        let original = L10n.language
        L10n.language = "zh-Hans"
        defer { L10n.language = original }
        let heading = "The selected map feature identity does not match the profile line."
        let localized = L10n.text(heading)
        #expect(localized != heading)
        #expect(L10n.text(heading + " (Parameter 'Feature')") == localized + " (参数 'Feature')")
        let incompleteSuffix = heading + " (Parameter ')"
        #expect(L10n.text(incompleteSuffix) == incompleteSuffix)
        let unknown = "Source diagnostic /模型/Plan (Parameter 'UserField')"
        #expect(L10n.text(unknown) == unknown)
        let path = "/模型/地图 (Parameter 'data').geojson"
        #expect(L10n.text(heading + "\n" + path) == localized + "\n" + path)
        L10n.language = "en"
        #expect(L10n.text(heading + " (Parameter 'Feature')") == heading + " (Parameter 'Feature')")
    }
}
