import SwiftUI

/// Source-backed debug surfaces are shown only for a process launched with
/// the retained `-debug` option. Reflection starts from the current live
/// ProjectDocument; an unopened project remains an empty state.
struct WorkspaceDebugToolsView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Group {
            if store.launchDebugEnabled {
                TabView {
                    launchAndSwitches
                        .tabItem { Label("Runtime", systemImage: "slider.horizontal.3") }
                    SharedVisualReflectionTreeControl(
                        rootProvider: { store.document },
                        rootTitle: "Current Project",
                        maxDepth: 4)
                        .tabItem { Label("Reflection Tree", systemImage: "point.3.connected.trianglepath.dotted") }
                    SharedVisualTriStateToggleTestControl()
                        .tabItem { Label("Tri-State Toggle", systemImage: "switch.2") }
                }
                .padding(14)
            } else {
                ContentUnavailableView("Developer Tools Are Disabled", systemImage: "hammer",
                    description: Text("Relaunch with the source debug option to open these tools."))
            }
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    private var launchAndSwitches: some View {
        Form {
            Section("Launch Options") {
                LabeledContent("Debug Mode", value: flagValue(store.launchConfiguration.debugMode))
                LabeledContent("Safe Mode", value: flagValue(store.launchConfiguration.safeMode))
                LabeledContent("First Launch", value: flagValue(store.launchConfiguration.testFirstLaunch))
                LabeledContent("Post-Crash Launch", value: flagValue(store.launchConfiguration.postCrashLaunch))
                LabeledContent("Stream Mode", value: store.launchConfiguration.streamPipeName ?? L10n.text("Off"))
                LabeledContent("Initial Project", value: store.launchConfiguration.initialProjectURL?.path ?? L10n.text("None"))
                    .textSelection(.enabled)
            }
            Section("Application Identity") {
                LabeledContent("Application UID", value: store.applicationUID)
                    .textSelection(.enabled)
                LabeledContent("Application Data I/O", value: L10n.text(
                    store.suppressesAppDataIO ? "Suppressed for this launch" : "Enabled"))
            }
        }
        .formStyle(.grouped)
    }

    private func flagValue(_ isEnabled: Bool) -> String {
        L10n.text(isEnabled ? "On" : "Off")
    }
}
