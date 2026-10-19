import Foundation
import RASWorkspaceCore
import SwiftUI

/// Attaches one validated RAS result to the exact captured Boundary Condition
/// and saves both that model draft and the owning project connection.
@MainActor
struct BoundaryInitialConditionsWorkspace: View {
    @ObservedObject private var session: BoundaryInitialConditionsSession
    private let chooseResult: @MainActor () -> URL?
    private let onClose: (@MainActor () -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var resultPath = ""
    @State private var localError: String?

    init(session: BoundaryInitialConditionsSession,
         chooseResult: @escaping @MainActor () -> URL?,
         onClose: (@MainActor () -> Void)? = nil) {
        self.session = session
        self.chooseResult = chooseResult
        self.onClose = onClose
        _resultPath = State(initialValue: session.selectedResultURL?.path ?? "")
    }

    private var isBusy: Bool {
        session.isInspecting || session.isAttaching || session.isCheckingStatus
    }

    private var inputInspectionIsCurrent: Bool {
        guard let inspection = session.inspection,
              !resultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let path = URL(fileURLWithPath: resultPath).standardizedFileURL
        let inspectedPath = URL(fileURLWithPath: inspection.resultPath).standardizedFileURL
        return SourceFilePaths.canonical(path) == SourceFilePaths.canonical(inspectedPath)
              && inspection.timestamp == session.timestampText
    }

    private var canAttach: Bool {
        session.canAttach && inputInspectionIsCurrent && !isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Attach Initial Conditions"), systemImage: "link")
                    .font(.title2.weight(.semibold))
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                Button(L10n.text("Close"), systemImage: "xmark") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if let capture = session.capture {
                Form {
                    targetSection(capture)
                    resultSection
                    commitSection
                    if session.operationStatus != nil || session.pendingOperationID != nil {
                        operationSection
                    }
                    if let receipt = session.receipt {
                        receiptSection(receipt)
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 8)
            } else {
                ContentUnavailableView(
                    L10n.text("Choose a Boundary Condition to attach initial conditions."),
                    systemImage: "water.waves",
                    description: Text(L10n.text("This action uses the current Boundary Condition editor and project.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = localError ?? session.errorMessage {
                Label(L10n.text(message), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            if session.isInspecting {
                ProgressView(L10n.text("Validating the selected RAS result…"))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            } else if session.isAttaching {
                ProgressView(L10n.text("Saving the Boundary Condition and project…"))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            } else if session.isCheckingStatus {
                ProgressView(L10n.text("Checking the attach operation…"))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 500, idealHeight: 650, maxHeight: 900)
        .dropDestination(for: URL.self) { urls, _ in _ = acceptDroppedResults(urls) }
        .onDisappear { session.close() }
        .environment(\.locale, locale)
    }

    private func targetSection(_ capture: BoundaryInitialConditionsCapture) -> some View {
        Section(L10n.text("Boundary Condition target")) {
            LabeledContent(L10n.text("Boundary Condition"), value: capture.asset.name)
                .textSelection(.enabled)
            LabeledContent(L10n.text("Boundary Condition file"), value: capture.asset.url.path)
                .textSelection(.enabled)
            LabeledContent(L10n.text("Project file"), value: capture.projectPath)
                .textSelection(.enabled)
            LabeledContent(L10n.text("Saved project revision"), value: capture.projectRevision)
                .textSelection(.enabled)
        }
    }

    private var resultSection: some View {
        Section(L10n.text("RAS result")) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(L10n.text("Result file path"), text: $resultPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(inspectCurrentResult)
                    .disabled(isBusy || !session.canInspect || session.pendingOperationID != nil)
                Button {
                    guard let url = chooseResult() else { return }
                    selectResult(url)
                } label: {
                    Label(L10n.text("Choose RAS result…"), systemImage: "folder")
                }
                .disabled(isBusy || !session.canInspect || session.pendingOperationID != nil)
            }

            TextField(L10n.text("Timestamp (optional)"), text: $session.timestampText)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy || !session.canInspect || session.pendingOperationID != nil)
            Text(L10n.text("Leave the timestamp blank to use the source default. The original text is passed through unchanged."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !session.canInspect && !isBusy && session.pendingOperationID == nil {
                Label(L10n.text("The Boundary Condition or project changed. Close and reopen this action."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Label(L10n.text("Drop a RAS result file here"), systemImage: "arrow.down.doc")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    inspectCurrentResult()
                } label: {
                    Label(L10n.text("Validate result"), systemImage: "checkmark.shield")
                }
                .disabled(isBusy || !session.canInspect || resultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let inspection = session.inspection {
                LabeledContent(L10n.text("Inspected result"), value: inspection.resultPath)
                    .textSelection(.enabled)
                if let revision = inspection.resultRevision {
                    LabeledContent(L10n.text("Result revision"), value: revision)
                        .textSelection(.enabled)
                }
                if inspection.canAttach && inputInspectionIsCurrent {
                    Label(L10n.text("The selected file is a valid RAS result for this project."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let reason = inspection.errorMessage {
                    Label(L10n.text(reason), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if !inputInspectionIsCurrent {
                    Label(L10n.text("The result path or timestamp changed. Validate the current input again."), systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var commitSection: some View {
        Section(L10n.text("Attach and save")) {
            Text(L10n.text("This saves the current Boundary Condition edits and the project connection together. The result is recorded as a shared Stage and Velocity source; data ingestion happens during compute preparation."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { _ = await session.attach() }
            } label: {
                Label(L10n.text("Attach and Save Boundary Condition + Project"), systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAttach)
        }
    }

    private var operationSection: some View {
        Section(L10n.text("Attach operation")) {
            if let status = session.operationStatus {
                LabeledContent(L10n.text("Status"), value: statusTitle(status.state))
                if let message = status.errorMessage, !message.isEmpty {
                    Text(L10n.text(message)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let operationID = session.pendingOperationID {
                LabeledContent(L10n.text("Operation ID"), value: operationID)
                    .textSelection(.enabled)
            }
            if session.needsStatusRecovery {
                Label(L10n.text("The operation may have completed. Check its saved status before retrying."),
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if session.pendingOperationID != nil {
                    Button {
                        Task { _ = await session.refreshStatus() }
                    } label: {
                        Label(L10n.text("Refresh status"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                }
                if session.canRetry {
                    Button {
                        Task { _ = await session.retry() }
                    } label: {
                        Label(L10n.text("Retry attach safely"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                }
                if session.canCancelUnstartedOperation {
                    Button(role: .destructive) {
                        localError = nil
                        _ = session.cancelUnstartedOperation()
                    } label: {
                        Label(L10n.text("Cancel Unstarted Operation"), systemImage: "xmark.circle")
                    }
                }
            }
        }
    }

    private func receiptSection(_ receipt: BoundaryInitialConditionsReceipt) -> some View {
        Section(L10n.text("Saved attachment")) {
            Label(L10n.text(receipt.alreadyCommitted
                ? "This attachment was already committed and its receipt was recovered."
                : "The Boundary Condition and project save completed."),
                systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L10n.text("Shared connection"), value: receipt.connectionName)
                .textSelection(.enabled)
            LabeledContent(L10n.text("RAS result"), value: receipt.resultPath)
                .textSelection(.enabled)
            if let timestamp = receipt.timestamp {
                LabeledContent(L10n.text("Attached timestamp"), value: timestamp)
                    .textSelection(.enabled)
            }
            LabeledContent(L10n.text("Saved Boundary Condition revision"), value: receipt.model.revision)
                .textSelection(.enabled)
            LabeledContent(L10n.text("Saved project revision"), value: receipt.projectRevision)
                .textSelection(.enabled)
        }
    }

    private func inspectCurrentResult() {
        guard !resultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localError = L10n.text("Choose a RAS result file.")
            return
        }
        guard session.canInspect else {
            localError = L10n.text("The Boundary Condition or project changed. Close and reopen this action.")
            return
        }
        let url = URL(fileURLWithPath: resultPath)
        guard url.isFileURL else {
            localError = L10n.text("Choose a local RAS result file.")
            return
        }
        localError = nil
        session.numberCulture = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let rawTimestamp = session.timestampText.isEmpty ? nil : session.timestampText
        let numberCulture = session.numberCulture
        Task {
            _ = await session.inspect(resultURL: url,
                timestamp: rawTimestamp,
                numberCulture: numberCulture)
        }
    }

    private func selectResult(_ url: URL) {
        guard url.isFileURL else {
            localError = L10n.text("Choose a local RAS result file.")
            return
        }
        guard session.canInspect else { return }
        resultPath = url.path
        localError = nil
        session.numberCulture = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let rawTimestamp = session.timestampText.isEmpty ? nil : session.timestampText
        let numberCulture = session.numberCulture
        Task {
            _ = await session.inspect(resultURL: url,
                timestamp: rawTimestamp,
                numberCulture: numberCulture)
        }
    }

    private func acceptDroppedResults(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            localError = L10n.text("Drop one RAS result file at a time.")
            return false
        }
        guard session.pendingOperationID == nil else {
            localError = L10n.text("Check or finish the current attach operation before choosing another result.")
            return false
        }
        guard !isBusy else {
            localError = L10n.text("Wait for the current operation to finish before choosing another result.")
            return false
        }
        guard session.canInspect else {
            localError = L10n.text("The Boundary Condition or project changed. Close and reopen this action.")
            return false
        }
        selectResult(url)
        return true
    }

    private func statusTitle(_ state: BoundaryInitialConditionsOperationState) -> String {
        switch state {
        case .notFound: L10n.text("Not found")
        case .prepared: L10n.text("Prepared; recovery is pending")
        case .committed: L10n.text("Committed")
        case .rolledBack: L10n.text("Rolled back")
        case .conflict: L10n.text("Conflict")
        }
    }

    private func close() {
        session.close()
        if let onClose { onClose() } else { dismiss() }
    }
}
