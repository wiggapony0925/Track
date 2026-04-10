// Premium departure time control — glassmorphic "Leave now" capsule
// with gradient fill, and a refined ±15 min stepper with layered depth.

import SwiftUI

struct DepartureTimeControl: View {
    @Binding var departureOption: DepartureOption
    let onPickerTap: () -> Void
    let onStep: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Leave now / time label button
            Button(action: onPickerTap) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(
                                isLeaveNow
                                    ? .white.opacity(0.2)
                                    : AppTheme.Colors.accent.opacity(0.12)
                            )
                            .frame(width: 22, height: 22)
                        Image(systemName: timeIcon)
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(departureOption.label)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(isLeaveNow ? .white : AppTheme.Colors.textPrimary)
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(
                            isLeaveNow
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                : AnyShapeStyle(AppTheme.Colors.cardInset)
                        )
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .white.opacity(isLeaveNow ? 0.18 : 0.04), location: 0),
                                            .init(color: .clear, location: 0.5),
                                        ],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isLeaveNow
                                        ? .white.opacity(0.15)
                                        : AppTheme.Colors.borderSubtle.opacity(0.15),
                                    lineWidth: 0.5
                                )
                        )
                )
                .shadow(
                    color: isLeaveNow ? AppTheme.Colors.accent.opacity(0.2) : .clear,
                    radius: 6, y: 2
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // ±15 min stepper
            HStack(spacing: 0) {
                stepperButton(icon: "minus") { onStep(false) }

                Text("15m")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 34)

                stepperButton(icon: "plus") { onStep(true) }
            }
            .background(
                Capsule()
                    .fill(AppTheme.Colors.cardInset)
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.03), location: 0),
                                        .init(color: .clear, location: 0.5),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                    )
            )
        }
    }

    private func stepperButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    private var isLeaveNow: Bool {
        if case .leaveNow = departureOption { return true }
        return false
    }

    private var timeIcon: String {
        switch departureOption {
        case .leaveNow:  return "clock.fill"
        case .departAt:  return "arrow.right.circle.fill"
        case .arriveBy:  return "flag.checkered"
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        DepartureTimeControl(
            departureOption: .constant(.leaveNow),
            onPickerTap: {},
            onStep: { _ in }
        )
        DepartureTimeControl(
            departureOption: .constant(.departAt(Date())),
            onPickerTap: {},
            onStep: { _ in }
        )
    }
    .padding()
    .background(Color.black)
}
