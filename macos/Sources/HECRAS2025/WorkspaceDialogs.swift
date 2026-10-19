import SwiftUI

struct WorkspaceDialogHeader: View {
    let title: String
    let subtitle: String?
    var symbol = "water.waves"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title)).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(LocalizedStringKey(subtitle)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceDialogChoiceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 34)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(title)).font(.headline)
                    Text(LocalizedStringKey(subtitle)).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.20), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct WorkspaceDialogActionBar: View {
    let cancelTitle: String
    let actionTitle: String
    var actionEnabled = true
    let onCancel: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(LocalizedStringKey(cancelTitle), role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(LocalizedStringKey(actionTitle), action: onAction)
                .keyboardShortcut(.defaultAction)
                .disabled(!actionEnabled)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct WorkspaceDialogNotice: View {
    let message: String
    var isError = false

    var body: some View {
        Label(L10n.text(message), systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.callout)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isError ? Color.red.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
