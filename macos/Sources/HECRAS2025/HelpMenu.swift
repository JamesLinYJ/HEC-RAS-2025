import SwiftUI

struct HelpMenuContents: View {
    @ObservedObject var store: WorkspaceStore
    private let links: [(title: String, id: String)] = [
        ("HEC-RAS Website", "ras-2025-project"),
        ("Documentation", "ras-2025-docs-home"),
        ("Release Notes", "ras-2025-docs-releasenotes"),
        ("Announcements", "ras-2025-docs-announcements")
    ]
    var body: some View {
        ForEach(links, id: \.id) { link in
            Button(LocalizedStringKey(link.title)) {
                // Same HECFWLink IDs as renamed RasMenuBar; no guessed endpoints.
                if let url = URL(string: "https://www.hec.usace.army.mil/fwlink/?linkid=" + link.id) { store.system.openWebsite(url) }
            }
        }
        Divider()
        Button("Report Bug…") { store.requestReportIssue() }
        Button("Check for Updates…") { store.showUpdates = true }
        Divider()
        Button("Open Application Data Folder") {
            WorkspacePlatformActions.revealApplicationData(using: store.system)
        }
        Button("Open Application Log") {
            WorkspacePlatformActions.revealApplicationLog(using: store.system)
        }
    }
}
