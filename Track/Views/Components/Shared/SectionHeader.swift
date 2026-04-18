// Reusable uppercase section header — "LIVE ALERTS", "FROM", etc.
// Replaces 25+ hand-rolled instances across the app.

import SwiftUI

struct SectionHeader: View {
    let title: String
    var size: CGFloat = 12
    var weight: Font.Weight = .heavy
    var tracking: CGFloat = 0.8
    var color: Color = AppTheme.Colors.textTertiary

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(color)
            .textCase(.uppercase)
            .tracking(tracking)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        SectionHeader(title: "Live Alerts")
        SectionHeader(title: "Next Arrivals", size: 11, tracking: 1.0)
        SectionHeader(title: "nearby", color: AppTheme.Colors.textSecondary)
    }
    .padding()
    .preferredColorScheme(.dark)
}
