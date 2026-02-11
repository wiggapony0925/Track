//
//  ThemePreviewView.swift
//  Track
//
//  A developer preview to visualize the AppTheme colors and typography.
//  Useful for checking accessibility contrast and Dynamic Type scaling.
//

import SwiftUI

struct ThemePreviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Typography Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Typography")
                        .font(.headline)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    
                    Group {
                        Text("Header Large")
                            .font(AppTheme.Typography.headerLarge)
                        Text("Section Header")
                            .font(AppTheme.Typography.sectionHeader)
                        Text("Route Label (M)")
                            .font(AppTheme.Typography.routeLabel)
                        Text("Body Text")
                            .font(AppTheme.Typography.body)
                    }
                    .foregroundColor(AppTheme.Colors.textPrimary)
                }
                
                Divider()
                
                // Colors Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Semantic Colors")
                        .font(.headline)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    
                    HStack {
                        ColorSwatch(name: "Background", color: AppTheme.Colors.background)
                            .border(Color.gray.opacity(0.2))
                        ColorSwatch(name: "Card", color: AppTheme.Colors.cardBackground)
                            .border(Color.gray.opacity(0.2))
                    }
                    
                    HStack {
                        ColorSwatch(name: "Primary", color: AppTheme.Colors.textPrimary)
                        ColorSwatch(name: "Secondary", color: AppTheme.Colors.textSecondary)
                    }
                    
                    HStack {
                        ColorSwatch(name: "MTA Blue", color: AppTheme.Colors.mtaBlue)
                        ColorSwatch(name: "Alert Red", color: AppTheme.Colors.alertRed)
                        ColorSwatch(name: "Success Green", color: AppTheme.Colors.successGreen)
                        ColorSwatch(name: "Go Green", color: AppTheme.Colors.goGreen)
                    }
                }
                
                Divider()
                
                // Subway Colors Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Subway Lines")
                        .font(.headline)
                        .foregroundColor(AppTheme.Colors.textSecondary)
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 12) {
                        ForEach(["1", "4", "7", "A", "B", "G", "J", "L", "N", "S"], id: \.self) { route in
                            ZStack {
                                Circle()
                                    .fill(AppTheme.SubwayColors.color(for: route))
                                    .frame(width: 40, height: 40)
                                Text(route)
                                    .font(AppTheme.Typography.routeLabel)
                                    .foregroundColor(AppTheme.SubwayColors.textColor(for: route))
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(AppTheme.Colors.background)
    }
}

private struct ColorSwatch: View {
    let name: String
    let color: Color
    
    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(height: 60)
            Text(name)
                .font(.caption)
                .foregroundColor(AppTheme.Colors.textSecondary)
        }
    }
}

#Preview {
    ThemePreviewView()
}
