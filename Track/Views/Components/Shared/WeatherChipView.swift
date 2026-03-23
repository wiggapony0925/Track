//
//  WeatherChipView.swift
//  Track
//
//  Reusable weather indicator with animated SF Symbol + temperature.
//  Two sizes: .compact (section headers) and .standard (route detail).
//
//  The SF Symbol comes directly from WeatherKit — Apple provides ~50
//  multicolor weather symbols (sun.max.fill, cloud.rain.fill, etc.)
//  that render with automatic color layers (sun=yellow, cloud=gray,
//  rain=blue) via .symbolRenderingMode(.multicolor).
//

import SwiftUI

// MARK: - Chip Variant

extension WeatherChipView {
    /// Display size for the weather chip.
    enum Style {
        /// Tiny inline pill for section headers (NearYouSectionHeader).
        /// 11pt icon, 11pt temp, minimal padding.
        case compact

        /// Standard pill for route detail, cards, etc.
        /// 14pt icon, 13pt temp, more prominent.
        case standard
    }
}

// MARK: - WeatherChipView

/// A small inline chip showing the current weather condition + temperature.
///
/// Usage:
/// ```swift
/// if let weather = viewModel.weatherSnapshot {
///     WeatherChipView(snapshot: weather)                 // .compact default
///     WeatherChipView(snapshot: weather, style: .standard)
/// }
/// ```
struct WeatherChipView: View {
    let snapshot: WeatherSnapshot
    var style: Style = .compact

    /// Controls the initial fade-in + symbol bounce.
    @State private var appeared = false

    var body: some View {
        HStack(spacing: iconTextSpacing) {
            // Animated weather symbol — WeatherKit provides the symbol name
            // (e.g. "cloud.rain.fill") and iOS renders it with multicolor
            // layers automatically. The .replace transition animates when
            // the condition changes (e.g. rain → clear).
            Image(systemName: snapshot.conditionSymbol)
                .font(.system(size: iconSize, weight: .semibold))
                .symbolRenderingMode(.multicolor)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(appeared ? 1.0 : 0.4)

            Text(snapshot.temperatureFormatted)
                .font(.system(size: textSize, weight: .bold, design: .rounded))
                .foregroundColor(AppTheme.Colors.textSecondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background {
            Capsule()
                .fill(chipBackground)
                .overlay {
                    Capsule()
                        .stroke(chipBorder, lineWidth: 0.5)
                }
        }
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.conditionDescription), \(snapshot.temperatureFormatted)")
    }

    // MARK: - Size Tokens

    private var iconSize: CGFloat {
        switch style {
        case .compact:  return 11
        case .standard: return 15
        }
    }

    private var textSize: CGFloat {
        switch style {
        case .compact:  return 11
        case .standard: return 13
        }
    }

    private var iconTextSpacing: CGFloat {
        switch style {
        case .compact:  return 3
        case .standard: return 5
        }
    }

    private var hPadding: CGFloat {
        switch style {
        case .compact:  return 7
        case .standard: return 10
        }
    }

    private var vPadding: CGFloat {
        switch style {
        case .compact:  return 3
        case .standard: return 5
        }
    }

    // MARK: - Appearance

    private var chipBackground: some ShapeStyle {
        switch style {
        case .compact:
            return AnyShapeStyle(AppTheme.Colors.cardInset.opacity(0.6))
        case .standard:
            return AnyShapeStyle(AppTheme.Colors.cardInset.opacity(0.45))
        }
    }

    private var chipBorder: some ShapeStyle {
        AppTheme.Colors.borderSubtle.opacity(0.5)
    }
}

// MARK: - Previews

#Preview("Compact — Clear") {
    WeatherChipView(snapshot: .preview(.clear), style: .compact)
        .padding()
        .background(AppTheme.Colors.background)
}

#Preview("Compact — Rain") {
    WeatherChipView(snapshot: .preview(.rain), style: .compact)
        .padding()
        .background(AppTheme.Colors.background)
}

#Preview("Standard — Snow") {
    WeatherChipView(snapshot: .preview(.snow), style: .standard)
        .padding()
        .background(AppTheme.Colors.background)
}

#Preview("Standard — Clear") {
    WeatherChipView(snapshot: .preview(.clear), style: .standard)
        .padding()
        .background(AppTheme.Colors.background)
}

#Preview("All Variants") {
    VStack(spacing: 16) {
        ForEach(WeatherCondition.allCases, id: \.self) { condition in
            HStack(spacing: 12) {
                WeatherChipView(snapshot: .preview(condition), style: .compact)
                WeatherChipView(snapshot: .preview(condition), style: .standard)
            }
        }
    }
    .padding()
    .background(AppTheme.Colors.background)
}

// MARK: - Preview Helper

extension WeatherSnapshot {
    /// Convenience initializer for SwiftUI Previews.
    static func preview(_ condition: WeatherCondition) -> WeatherSnapshot {
        switch condition {
        case .clear:
            return WeatherSnapshot(
                temperature: 22.0,
                temperatureFormatted: "72°F",
                conditionSymbol: "sun.max.fill",
                conditionDescription: "Clear",
                category: .clear,
                fetchedAt: Date()
            )
        case .rain:
            return WeatherSnapshot(
                temperature: 13.0,
                temperatureFormatted: "55°F",
                conditionSymbol: "cloud.rain.fill",
                conditionDescription: "Rain",
                category: .rain,
                fetchedAt: Date()
            )
        case .snow:
            return WeatherSnapshot(
                temperature: -2.0,
                temperatureFormatted: "28°F",
                conditionSymbol: "cloud.snow.fill",
                conditionDescription: "Snow",
                category: .snow,
                fetchedAt: Date()
            )
        }
    }
}
