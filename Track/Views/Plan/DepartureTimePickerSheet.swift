// Departure time picker — detent-aware sheet with
// mode cards, quick-pick chips & graphical calendar.

import SwiftUI

struct DepartureTimePickerSheet: View {
    @Bindable var viewModel: PlanViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: Int = 0   // 0 = Depart at, 1 = Arrive by
    @State private var pickedDate = Date()

    private let modeIcons   = ["clock.fill", "flag.checkered"]
    private let modeLabels  = ["Depart at", "Arrive by"]
    private let modeColors: [Color] = [
        AppTheme.Colors.accent,                        // purple
        Color(red: 1.0, green: 0.48, blue: 0.12),     // vivid orange
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            dragHandle

            modeSelector
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)

            Divider()
                .overlay(AppTheme.Colors.borderSubtle.opacity(0.4))

            timePickerContent
                .transition(.opacity.combined(with: .move(edge: .bottom)))

            Spacer(minLength: 0)

            confirmButton
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
        }
        .background(AppTheme.Colors.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(32)
        .onAppear(perform: syncFromViewModel)
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Capsule()
            .fill(AppTheme.Colors.textTertiary.opacity(0.25))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
    }

    // MARK: - Mode Selector (2 toggle pills)

    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(0..<2) { i in
                let active = selectedMode == i
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        selectedMode = i
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: modeIcons[i])
                            .font(.system(size: 14, weight: .bold))
                        Text(modeLabels[i])
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(active ? .white : AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(
                                active
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [modeColors[i], modeColors[i].opacity(0.70)],
                                            startPoint: .leading, endPoint: .trailing
                                        ))
                                    : AnyShapeStyle(.clear)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            Capsule()
                .fill(AppTheme.Colors.cardInset)
        )
    }

    // MARK: - Time Picker Content (always full)

    private var timePickerContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                quickPickRow
                    .padding(.top, 16)

                selectedTimeBadge

                // Graphical calendar
                DatePicker(
                    "",
                    selection: $pickedDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .tint(modeColors[selectedMode])
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Quick Pick Row

    private var quickPickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickChip("+15 min",  offset: 15 * 60)
                quickChip("+30 min",  offset: 30 * 60)
                quickChip("+1 hour",  offset: 3600)
                quickChip("+2 hours", offset: 7200)
                quickChip("Tom 8 AM", date: tomorrowMorning)
            }
            .padding(.horizontal, 16)
        }
    }

    private func quickChip(_ label: String, offset: TimeInterval? = nil, date: Date? = nil) -> some View {
        let chipDate = date ?? Date().addingTimeInterval(offset ?? 0)
        let isActive = abs(pickedDate.timeIntervalSince(chipDate)) < 60

        return Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                pickedDate = chipDate
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isActive ? .white : AppTheme.Colors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(
                            isActive
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [modeColors[selectedMode], modeColors[selectedMode].opacity(0.65)],
                                        startPoint: .leading, endPoint: .trailing
                                    ))
                                : AnyShapeStyle(AppTheme.Colors.cardBackground)
                        )
                        .shadow(
                            color: isActive ? modeColors[selectedMode].opacity(0.35) : .black.opacity(0.06),
                            radius: 6, y: 2
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selected Time Badge

    private var selectedTimeBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: modeIcons[selectedMode])
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(modeColors[selectedMode])

            Text(formattedPickedDate)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(modeColors[selectedMode].opacity(0.08))
                .overlay(
                    Capsule().strokeBorder(modeColors[selectedMode].opacity(0.20), lineWidth: 1.5)
                )
        )
    }

    // MARK: - Confirm Button

    private var confirmButton: some View {
        Button {
            switch selectedMode {
            case 0:  viewModel.setDepartAt(pickedDate)
            case 1:  viewModel.setArriveBy(pickedDate)
            default: break
            }
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                Text("Confirm \(modeLabels[selectedMode])")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [modeColors[selectedMode], modeColors[selectedMode].opacity(0.60)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: modeColors[selectedMode].opacity(0.40), radius: 14, y: 6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func syncFromViewModel() {
        switch viewModel.departureOption {
        case .leaveNow:
            selectedMode = 0
            pickedDate = Date().addingTimeInterval(15 * 60) // default +15m
        case .departAt(let d):
            selectedMode = 0
            pickedDate = d
        case .arriveBy(let d):
            selectedMode = 1
            pickedDate = d
        }
    }

    private var tomorrowMorning: Date {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()),
              let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        else { return Date().addingTimeInterval(12 * 3600) }
        return morning
    }

    private var formattedPickedDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return f.string(from: pickedDate)
    }
}

#Preview {
    DepartureTimePickerSheet(viewModel: PlanViewModel())
        .preferredColorScheme(.dark)
}
