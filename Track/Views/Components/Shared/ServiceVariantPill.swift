// Reusable service-variant pill.
//
// Renders a compact pill (icon + short label) describing the
// variant of service running on a given arrival — Express, Limited,
// SBS, Super Express, Shuttle.  Local arrivals render nothing
// (every line is local by default; pinning "Local" everywhere is
// noise).
//
// Used inline beside arrival rows in:
//   - RouteDetailSheet (per-arrival chip in the departures list)
//   - GroupedRouteRow (compact pill on the home dashboard)
//   - Live-activity / widget arrival rows (when capacity allows)

import SwiftUI

struct ServiceVariantPill: View {
    let variant: ServiceVariant
    /// Optional override label.  When `nil`, falls back to
    /// `variant.displayLabel`.  Used for backend overrides like
    /// "Super Express via Madison Av".
    var customLabel: String? = nil
    /// Fallback color used when the variant has no semantic tint
    /// (e.g. `.local` would tint with this — though `.local` doesn't
    /// render at all).  Pass the route's brand color.
    var routeColor: Color = AppTheme.Colors.mtaBlue
    /// Compact mode hides the icon to save horizontal space; used in
    /// dense list rows.
    var isCompact: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if variant.showsPill {
            content
        }
    }

    private var content: some View {
        let tint = variant.tintColor(routeColor: routeColor)
        let label = customLabel ?? variant.displayLabel
        return HStack(spacing: 3) {
            if !isCompact && !variant.iconName.isEmpty {
                Image(systemName: variant.iconName)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityLabel(Text(variant.accessibilityLabel))
    }
}

#Preview("Variants") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(ServiceVariant.allCases, id: \.self) { variant in
            HStack {
                Text(variant.rawValue)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 110, alignment: .leading)
                ServiceVariantPill(variant: variant, routeColor: .blue)
            }
        }
        Divider().padding(.vertical, 4)
        Text("Compact mode")
            .font(.caption)
        ForEach([ServiceVariant.express, .limited, .sbs], id: \.self) { variant in
            ServiceVariantPill(variant: variant, routeColor: .blue, isCompact: true)
        }
        Divider().padding(.vertical, 4)
        Text("Custom label")
            .font(.caption)
        ServiceVariantPill(
            variant: .superExpress,
            customLabel: "Super Exp via Madison",
            routeColor: .red
        )
    }
    .padding()
}
