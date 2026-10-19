import Foundation
import SwiftUI

struct ProjectOpening: Identifiable {
    let id = UUID()
    let url: URL
}

// ProgressDialog / ProgressDialogWithText use system progress indicators and
// text. No percentage is inferred when the source has not reported one.
struct OperationProgressView: View {
    let title: String
    var message = ""
    var fraction: Double?
    var cancelling = false
    var cancel: (() -> Void)?
    private var progress: Double? { fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Spacer()
                if let progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary) }
            }
            ProgressView(value: progress).accessibilityLabel(LocalizedStringKey(title))
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if cancelling { Label("Cancelling…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary) }
            if let cancel {
                HStack { Spacer(); Button("Cancel", action: cancel).disabled(cancelling).keyboardShortcut(.cancelAction) }
            }
        }
    }
}

struct ProjectOpeningView: View {
    let project: ProjectOpening
    let cancel: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Label(project.url.deletingPathExtension().lastPathComponent, systemImage: "folder").font(.title2).lineLimit(2)
                OperationProgressView(title: "Opening Project…", message: L10n.text("Reading the project and its file catalog…"), cancel: cancel)
                Text(project.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            }
            .padding(24).frame(width: 430)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityAddTraits(.isModal)
    }
}
