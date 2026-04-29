// Premium departure time control — "Leave now" capsule
// with the app accent fill and a refined ±15 min stepper.

import SwiftUI

struct DepartureTimeControl: View {
    @Binding var departureOption: DepartureOption
    let onPickerTap: () -> Void
    let onStep: (Bool) -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            // Leave now / time label button
            HStack(spacing: 0) {
                Button(action: onPickerTap) {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(
                                    isLeaveNow
                                        ? .white.opacity(0.2)
                                        : AppTheme.Colors.accent.opacity(0.12)
                                )
                                .frame(width: 24, height: 24)
                            Image(systemName: timeIcon)
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text(departureOption.label)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(isLeaveNow ? .white : AppTheme.Colors.textPrimary)
                    .padding(.leading, 8)
                    .padding(.trailing, isLeaveNow ? 16 : 6)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                // X button to clear back to "Leave now"
                if !isLeaveNow {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            onClear?()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AppTheme.Colors.textTertiary)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(AppTheme.Colors.cardInset)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .background(
                Capsule()
                    .fill(
                        isLeaveNow
                            ? AnyShapeStyle(AppTheme.Colors.accent)
                            : AnyShapeStyle(AppTheme.Colors.cardBackground)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isLeaveNow
                                    ? .white.opacity(0.12)
                                    : AppTheme.Colors.borderSubtle.opacity(0.15),
                                lineWidth: 0.5
                            )
                    )
            )
            .shadow(
                color: isLeaveNow ? AppTheme.Colors.accent.opacity(0.25) : .black.opacity(0.04),
                radius: 8, y: 3
            )

            Spacer()

            // ±15 min stepper
            HStack(spacing: 0) {
                stepperButton(icon: "minus") { onStep(false) }

                Text("15m")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 36)

                stepperButton(icon: "plus") { onStep(true) }
            }
            .background(
                Capsule()
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.15), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
    }

    private func stepperButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 36, height: 36)
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
