// Reusable text field styled for origin/destination input.
// Used in the PlanView for "My location" and "Set destination" fields.

import SwiftUI

struct PlanLocationField: View {
    let icon: String
    let iconColor: Color
    let placeholder: String
    let value: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Dot indicator
                Circle()
                    .fill(iconColor)
                    .frame(width: 10, height: 10)

                // Label
                Text(value ?? placeholder)
                    .font(AppTheme.Typography.body)
                    .foregroundColor(
                        value != nil
                        ? AppTheme.Colors.textPrimary
                        : AppTheme.Colors.textTertiary
                    )
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value ?? placeholder)
        .accessibilityHint("Tap to change location")
    }
}

#Preview {
    VStack(spacing: 8) {
        PlanLocationField(
            icon: "location.fill",
            iconColor: .blue,
            placeholder: "My location",
            value: "My location",
            onTap: {}
        )
        PlanLocationField(
            icon: "mappin",
            iconColor: AppTheme.Colors.textTertiary,
            placeholder: "Set destination",
            value: nil,
            onTap: {}
        )
    }
    .padding()
    .background(Color.black)
}
