// Premium departure time picker sheet — pill selector,
// animated date picker, and gradient confirm button.

import SwiftUI

struct DepartureTimePickerSheet: View {
    @Bindable var viewModel: PlanViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: Int = 0
    @State private var pickedDate = Date()

    private let options: [(String, String)] = [
        ("clock.fill", "Leave now"),
        ("arrow.right.circle.fill", "Depart at"),
        ("flag.checkered", "Arrive by"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            // Handle
            Capsule()
                .fill(AppTheme.Colors.textTertiary.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            // Title
            VStack(spacing: 6) {
                Text("When do you want to travel?")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(AppTheme.Colors.textPrimary)

                Text("Choose your departure preference")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppTheme.Colors.textTertiary)
            }

            // Custom segmented control
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedMode = index
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: options[index].0)
                                .font(.system(size: 10, weight: .bold))
                            Text(options[index].1)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(
                            selectedMode == index ? .white : AppTheme.Colors.textSecondary
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            Group {
                                if selectedMode == index {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                                startPoint: .leading, endPoint: .trailing
                                            )
                                        )
                                        .shadow(color: AppTheme.Colors.accent.opacity(0.25), radius: 6, y: 2)
                                } else {
                                    Capsule()
                                        .fill(AppTheme.Colors.cardInset)
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(AppTheme.Colors.borderSubtle.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 16)

            // Date picker
            if selectedMode != 0 {
                DatePicker(
                    "",
                    selection: $pickedDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()

            // Confirm button
            Button {
                switch selectedMode {
                case 0:  viewModel.setLeaveNow()
                case 1:  viewModel.setDepartAt(pickedDate)
                case 2:  viewModel.setArriveBy(pickedDate)
                default: break
                }
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Set Time")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.Colors.accent, AppTheme.Colors.accentDeep],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.15), location: 0),
                                        .init(color: .clear, location: 0.45),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    .shadow(color: AppTheme.Colors.accent.opacity(0.35), radius: 14, y: 5)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(AppTheme.Colors.background)
        .onAppear {
            switch viewModel.departureOption {
            case .leaveNow:
                selectedMode = 0
                pickedDate = Date()
            case .departAt(let date):
                selectedMode = 1
                pickedDate = date
            case .arriveBy(let date):
                selectedMode = 2
                pickedDate = date
            }
        }
    }
}

#Preview {
    DepartureTimePickerSheet(viewModel: PlanViewModel())
        .preferredColorScheme(.dark)
}
