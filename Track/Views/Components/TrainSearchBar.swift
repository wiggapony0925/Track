//
//  TrainSearchBar.swift
//  Track
//
//  Reusable search bar component for filtering transit results.
//  Styled to match the Track design system with glassmorphism
//  and rounded corners. Displays a magnifying glass icon, a text
//  field, and an optional clear button.
//

import SwiftUI

struct TrainSearchBar: View {
    /// Binding to the search query text managed by the parent view.
    @Binding var text: String

    /// Placeholder string shown when the search field is empty.
    var placeholder: String = "Search trains, buses, stations…"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppTheme.Colors.textSecondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(AppTheme.Colors.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            // Clear button — shown only when there is text to clear
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(AppTheme.Colors.textSecondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
    }
}

#Preview {
    TrainSearchBar(text: .constant(""))
        .padding(.top, 20)
        .background(AppTheme.Colors.background)
}
