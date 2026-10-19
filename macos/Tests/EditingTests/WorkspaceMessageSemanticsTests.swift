import Foundation
import Testing
@testable import HECRAS2025

struct WorkspaceMessageSemanticsTests {
    @Test
    func allRetainedSeverityLevelsReachToastPresentation() {
        let cases: [(WorkspaceMessageSeverity, SharedVisualMessageSeverity, Bool)] = [
            (.information, .information, false),
            (.trace, .trace, false),
            (.debug, .debug, false),
            (.warning, .warning, false),
            (.error, .error, true)
        ]

        for (severity, visualSeverity, isError) in cases {
            let message = WorkspaceMessage(
                id: UUID(),
                time: Date(timeIntervalSince1970: 1_700_000_000),
                operation: "Map",
                text: "Source message",
                severity: severity
            )

            #expect(severity.rawValue == severity.localizationKey)
            #expect(severity.visualSeverity == visualSeverity)
            #expect(message.notificationSeverity == visualSeverity)
            #expect(message.isError == isError)
            #expect(message.sharedVisualToastMessage.severity == visualSeverity)
            #expect(message.sharedVisualLiveMessage.severity == severity)
            #expect(message.sharedVisualLiveMessage.severityTitleKey == severity.localizationKey)
        }
    }

    @Test
    func actionIdentityAndTimestampSurviveMessagePresentation() {
        let messageID = UUID(uuidString: "A7DCC75D-0C54-4448-B314-3ECBF4AA2A74")!
        let projectSessionID = UUID(uuidString: "770994E7-BD3B-4D5B-8A3E-2F9D3E023D16")!
        let mapID = UUID(uuidString: "43EA061D-50E1-4784-9CB0-CF8A78494A2A")!
        let time = Date(timeIntervalSince1970: 1_700_000_123)
        let action = WorkspaceMessageDefaultAction.openMap(projectSessionID: projectSessionID, mapID: mapID)
        let message = WorkspaceMessage(
            id: messageID,
            time: time,
            operation: "Map",
            text: "Map is ready",
            severity: .warning,
            defaultAction: action
        )

        #expect(message.id == messageID)
        #expect(message.time == time)
        #expect(message.defaultAction == action)
        #expect(action.titleKey == "Open Map")
        #expect(action.systemImage == "map")
        #expect(message.notificationSeverity == .warning)
    }

    @Test
    func legacyBooleanInitializerMapsOnlyToInformationAndError() {
        let information = WorkspaceMessage(operation: "Project", text: "Loaded", isError: false)
        let error = WorkspaceMessage(operation: "Project", text: "Failed", isError: true)

        #expect(information.severity == .information)
        #expect(information.isError == false)
        #expect(information.defaultAction == nil)
        #expect(error.severity == .error)
        #expect(error.isError)
    }

    @Test
    func actionTitlesReuseLocalizedWorkspaceActionLabels() {
        #expect(WorkspaceMessageDefaultAction.showMessages.titleKey == "Messages")
        #expect(WorkspaceMessageDefaultAction.openEditor(projectSessionID: UUID(), editorKind: "geometry", assetID: "/models/mesh.g01").titleKey == "Open Editor")
        #expect(WorkspaceMessageDefaultAction.openMap(projectSessionID: UUID(), mapID: UUID()).titleKey == "Open Map")
    }
}
