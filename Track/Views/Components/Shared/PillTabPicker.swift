//
//  PillTabPicker.swift
//  Track
//
//  A generic horizontal pill-style tab picker. Each tab shows an icon,
//  label, and optional badge count. The active tab fills with a provided
//  accent color; inactive tabs use a card background with a light border.
//
//  Designed to be reused anywhere a segmented-style picker is needed
//  (route detail sheet, settings, future screens).
//

import SwiftUI

// MARK: - Tab descriptor

/// Lightweight descriptor for a single tab pill.
struct PillTab: Identifiable {
    let id: String
    let label: String
    let icon: String
    /// Optional badge count. 0 = hidden, >99 shows "99+".
    var badgeCount: Int = 0
}

// MARK: - PillTabPicker

struct PillTabPicker: View {
    let tabs: [PillTab]
    @Binding var selectedId: String
    var accentColor: Color = AppTheme.Colors.mtaBlue

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    let isActive = selectedId == tab.id
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedId = tab.id
                        }
                    } label: {
                        pillLabel(tab: tab, isActive: isActive)
                    }
                    .sensoryFeedback(.selection, trigger: selectedId)
                    .accessibilityLabel("\(tab.label) tab")
                }
            }
            .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Pill label

    private func pillLabel(tab: PillTab, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isActive
                            ? AnyShapeStyle(AppTheme.Gradients.accent)
                            : AnyShapeStyle(AppTheme.Gradients.controlSurface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                isActive
                                    ? AppTheme.Colors.textOnColor.opacity(0.18)
                                    : AppTheme.Colors.borderSubtle,
                                lineWidth: 1
                            )
                    }

                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? .white : AppTheme.Colors.textSecondary)
            }
            .frame(width: 28, height: 28)

            Text(tab.label)
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .lineLimit(1)

            if tab.badgeCount > 0 {
                badgeView(count: tab.badgeCount, isActive: isActive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isActive
                        ? AppTheme.Colors.glassHighlight.opacity(0.07)
                        : AppTheme.Colors.cardBackground
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive ? AppTheme.Colors.borderSubtle : accentColor.opacity(0.10),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isActive ? accentColor.opacity(0.12) : .black.opacity(0.03),
            radius: isActive ? 8 : 3,
            x: 0, y: isActive ? 4 : 2
        )
    }

    // MARK: - Badge

    private func badgeView(count: Int, isActive: Bool) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.custom("Helvetica-Bold", size: 11))
            .foregroundColor(isActive ? accentColor : AppTheme.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isActive
                    ? AnyShapeStyle(accentColor.opacity(0.14))
                    : AnyShapeStyle(AppTheme.Gradients.controlSurface)
            )
            .clipShape(Capsule())
    }
}
