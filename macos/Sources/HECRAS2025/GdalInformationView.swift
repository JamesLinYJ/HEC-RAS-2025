import RASWorkspaceCore
import SwiftUI

/// Runtime information returned by the retained GDALSetup service.
struct GdalRuntimeInformation: Decodable, Sendable {
    let directory: String
    let version: String
    let releaseName: String
    let dataDirectory: String
    let expectedLocations: [String]
}

private struct GdalInformationRequest: Encodable, Sendable {}

@MainActor
final class GdalInformationSession: ObservableObject {
    @Published private(set) var information: GdalRuntimeInformation?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private var requestRevision = 0

    func refresh(using client: BackendProcessClient?) async {
        requestRevision += 1
        let revision = requestRevision
        isLoading = true
        information = nil
        errorMessage = nil
        defer {
            if revision == requestRevision { isLoading = false }
        }

        guard let client else {
            errorMessage = L10n.text("Unable to load GDAL information")
            return
        }

        do {
            let response = try await client.request(
                "runtime.gdal",
                parameters: GdalInformationRequest(),
                as: GdalRuntimeInformation.self
            )
            guard revision == requestRevision, !Task.isCancelled else { return }
            information = response
        } catch {
            guard revision == requestRevision, !Task.isCancelled else { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    func cancel() {
        requestRevision += 1
        isLoading = false
    }
}

/// Read-only native replacement for RasMenuBar.GdalLoc_Click.
struct GdalInformationView: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = GdalInformationSession()
    @State private var refreshGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("GDAL Information"), systemImage: "globe.americas.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Refresh"), systemImage: "arrow.clockwise") {
                    refreshGeneration &+= 1
                }
                .disabled(session.isLoading)
            }

            Divider()

            if session.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = session.errorMessage {
                ContentUnavailableView {
                    Label(L10n.text("Unable to load GDAL information"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage).textSelection(.enabled)
                } actions: {
                    Button(L10n.text("Refresh"), systemImage: "arrow.clockwise") {
                        refreshGeneration &+= 1
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let information = session.information {
                informationDetails(information)
            }

            HStack {
                Link(L10n.text("GDAL documentation"), destination: URL(string: "https://gdal.org/en/stable/")!)
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 390, idealHeight: 450)
        .task(id: refreshGeneration) { await session.refresh(using: store.runtimeInfoClient) }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder
    private func informationDetails(_ information: GdalRuntimeInformation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OriginalPropertyItemListPropertyItem(
                    title: "Installed GDAL",
                    items: [
                        OriginalPropertyListEntry(label: "Directory", value: information.directory),
                        OriginalPropertyListEntry(label: "Version", value: information.version)
                    ]
                )

                LabeledContent(L10n.text("Data Directory")) {
                    Text(information.dataDirectory.isEmpty ? "—" : information.dataDirectory)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Expected Locations"))
                        .font(.headline)
                    if information.expectedLocations.isEmpty {
                        Text(L10n.text("No GDAL locations were reported."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(information.expectedLocations.enumerated()), id: \.offset) { _, location in
                            Text(location)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}
