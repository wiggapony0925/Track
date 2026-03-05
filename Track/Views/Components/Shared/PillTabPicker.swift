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
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .white : accentColor)

            Text(tab.label)
                .font(.custom("Helvetica-Bold", size: 13))
                .foregroundColor(isActive ? .white : AppTheme.Colors.textPrimary)
                .lineLimit(1)

            if tab.badgeCount > 0 {
                badgeView(count: tab.badgeCount, isActive: isActive)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? accentColor : AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive ? Color.clear : accentColor.opacity(0.25),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isActive ? accentColor.opacity(0.3) : .black.opacity(0.04),
            radius: isActive ? 4 : 2,
            x: 0, y: isActive ? 2 : 1
        )
    }

    // MARK: - Badge

    private func badgeView(count: Int, isActive: Bool) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.custom("Helvetica-Bold", size: 11))
            .foregroundColor(isActive ? accentColor : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isActive ? Color.white.opacity(0.9) : accentColor)
            .clipShape(Capsule())
    }
}
