import SwiftUI

struct PreflightStatusRow: View {
    let result: PreflightCheckResult
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(operatorPreflightTitle(result.id, locale: locale)).font(.headline)
                    Spacer()
                    Text(operatorPreflightStatusName(result.status, locale: locale))
                        .font(.caption)
                        .foregroundStyle(iconColor)
                }
                Text(operatorPreflightDetail(result, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.checkedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch result.status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .notRun: return "questionmark.circle"
        case .skipped: return "minus.circle"
        }
    }

    private var iconColor: Color {
        switch result.status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .running: return .blue
        case .notRun, .skipped: return .secondary
        }
    }
}
