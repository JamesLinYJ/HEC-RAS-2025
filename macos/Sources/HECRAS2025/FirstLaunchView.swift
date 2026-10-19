import SwiftUI

// FirstLaunchScreen.cs: project folder, three theme choices, then explorer.
struct FirstLaunchView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var folderInspection: WorkspaceDirectoryInspection?
    private let themes: [(name: String, symbol: String, subtitle: String)] = [
        ("System", "circle.lefthalf.filled", "Follow macOS appearance"),
        ("Light", "sun.max", "Use a light workspace"),
        ("Dark", "moon", "Use a dark workspace")
    ]

    var body: some View {
        ScrollView {
            HStack(alignment: .center, spacing: 56) {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "water.waves")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Welcome to HEC-RAS 2025")
                        .font(.largeTitle.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Choose a project folder and appearance before opening the project explorer.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Get Started", action: store.finishFirstLaunch)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(folderInspection?.isReady != true)
                        .padding(.top, 8)
                }
                .frame(maxWidth: 360, alignment: .leading)

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pick a Theme").font(.headline)
                        ForEach(themes, id: \.name) { theme in
                            WorkspaceDialogChoiceCard(
                                title: theme.name,
                                subtitle: theme.subtitle,
                                symbol: theme.symbol,
                                selected: store.theme == theme.name
                            ) { store.setTheme(theme.name) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default Project Folder").font(.headline)
                        Text(store.projectDirectory.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button("Choose Folder…", action: store.chooseProjectDirectory)
                        WorkspaceDirectoryPreflightView(
                            directory: store.projectDirectory,
                            successMessage: "Default project folder is ready.",
                            inspection: $folderInspection
                        )
                    }
                    Picker("Language", selection: Binding(get: { store.interfaceLanguage }, set: store.setLanguage)) {
                        Text("System").tag("System")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .frame(maxWidth: 440, alignment: .leading)
            }
            .padding(48)
            .frame(maxWidth: 980, minHeight: 700, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
