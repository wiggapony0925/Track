// Standalone weather badge displayed in the dashboard alongside the
// Favorites section header. Shows current temperature + condition icon
// in a compact pill, sourced from the existing WeatherSnapshot model.
//
// Usage:
//   WeatherBadge(snapshot: viewModel.weatherSnapshot)

import SwiftUI

struct WeatherBadge: View {
    let snapshot: WeatherSnapshot

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.conditionSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(iconColor)
                .symbolRenderingMode(.multicolor)

            Text(snapshot.temperatureFormatted)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(AppTheme.Colors.cardInset)
                .overlay {
                    Capsule()
                        .strokeBorder(AppTheme.Colors.borderSubtle, lineWidth: 0.5)
                }
        }
    }

    private var iconColor: Color {
        let symbol = snapshot.conditionSymbol
        if symbol.contains("sun") || symbol.contains("clear") {
            return .orange
        } else if symbol.contains("snow") || symbol.contains("sleet") {
            return .cyan
        } else if symbol.contains("rain") || symbol.contains("drizzle") {
            return .blue
        } else {
            return AppTheme.Colors.textSecondary
        }
    }
}
