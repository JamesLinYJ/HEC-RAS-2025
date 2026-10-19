import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct WorkspaceFirstLaunchTests {
    @Test
    func firstLaunchUsesTransientIdentityAndPreferencesWithoutResettingSavedData() throws {
        let suite = "HECRAS2025.FirstLaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("retained-user-identity", forKey: "UID")
        defaults.set("Dark", forKey: "SystemTheme")
        defaults.set("zh-Hans", forKey: "UILanguage")
        defaults.set(true, forKey: "HasSeenFirstLaunch")
        defaults.set(["/tmp/retained-history.ras"], forKey: "RecentProjects")
        let storedStyle = Data("retained style payload".utf8)
        defaults.set(storedStyle, forKey: GlobalVectorStylePreferences.storageKey)
        defaults.set("https://retained-testing.invalid", forKey: BackendTestingProvider.utilityURLDefaultsKey)
        let before = try #require(defaults.persistentDomain(forName: suite)) as NSDictionary
        let configuration = WorkspaceLaunchConfiguration(arguments: ["HECRAS2025", "--first-launch"])
        let first = WorkspaceStore(globalVectorStylePreferences: GlobalVectorStylePreferences(defaults: defaults),
            launchConfiguration: configuration, applicationDefaults: defaults)
        let second = WorkspaceStore(launchConfiguration: configuration, applicationDefaults: defaults)
        #expect(first.isFirstLaunch)
        #expect(first.theme == "System")
        #expect(first.interfaceLanguage == "System")
        #expect(first.recentProjectHistory.isEmpty)
        #expect(first.applicationUID.count == 10)
        #expect(first.applicationUID != second.applicationUID)
        #expect(first.applicationUID != "retained-user-identity")
        #expect(first.testingUtilityBaseURL == BackendTestingProvider.sourceDefaultUtilityURL)
        try first.setTestingUtilityBaseURL("http://localhost:8123")
        #expect(first.testingUtilityBaseURL == "http://localhost:8123")
        #expect(second.testingUtilityBaseURL == BackendTestingProvider.sourceDefaultUtilityURL)
        try first.developerCredentialStore.save(.init(accessKey: "fixture-id", secretKey: "fixture-value"))
        #expect(first.developerCredentialStore.load()?.accessKey == "fixture-id")
        #expect(second.developerCredentialStore.load() == nil)
        try first.developerCredentialStore.delete()
        #expect(first.developerCredentialStore.load() == nil)
        first.setTheme("Light")
        first.setLanguage("en")
        first.finishFirstLaunch()
        first.resetDirectories()
        first.clearRecentProjects()
        first.globalVectorStylePreferences.resetAll()
        try first.globalVectorStylePreferences.setOverrides([:])
        #expect(!first.isFirstLaunch)
        #expect(first.globalVectorStylePreferences.loadOverrides().isEmpty)
        let after = try #require(defaults.persistentDomain(forName: suite)) as NSDictionary
        #expect(before == after)
        #expect(defaults.data(forKey: GlobalVectorStylePreferences.storageKey) == storedStyle)
    }

    @Test
    func ordinaryLaunchRetainsTheStoredUIDAndLoadsTheActualPreferenceDomain() throws {
        let suite = "HECRAS2025.NormalLaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("source-uid", forKey: "UID")
        defaults.set("Dark", forKey: "SystemTheme")
        defaults.set(true, forKey: "HasSeenFirstLaunch")
        let store = WorkspaceStore(applicationDefaults: defaults)
        #expect(store.applicationUID == "source-uid")
        #expect(store.theme == "Dark")
        #expect(!store.isFirstLaunch)
        store.setTheme("Light")
        #expect(defaults.string(forKey: "SystemTheme") == "Light")
        #expect(defaults.string(forKey: "UID") == "source-uid")
        try store.setTestingUtilityBaseURL(" https://testing.invalid/api ")
        #expect(store.testingUtilityBaseURL == "https://testing.invalid/api")
        #expect(defaults.string(forKey: BackendTestingProvider.utilityURLDefaultsKey) == "https://testing.invalid/api")
        #expect(throws: ProjectFileError.self) { try store.setTestingUtilityBaseURL("not a URL") }
        #expect(store.testingUtilityBaseURL == "https://testing.invalid/api")
        #expect(WorkspaceStore(applicationDefaults: defaults).testingUtilityBaseURL == "https://testing.invalid/api")
    }
}
