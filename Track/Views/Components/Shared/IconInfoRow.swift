// Reusable icon-info row — circle icon + title/subtitle + optional trailing.
// Consolidates the recurring pattern of 42pt colored circle + text stack
// used across fare estimates, environmental impact, action cards, etc.

import SwiftUI

struct IconInfoRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = AppTheme.Colors.accent
    var circleSize: CGFloat = 42
    var circleOpacity: Double = 0.1
    let title: String
    var titleSize: CGFloat = 14
    var subtitle: String? = nil
    var subtitleView: AnyView? = nil
    var subtitleColor: Color = AppTheme.Colors.textTertiary
    @ViewBuilder var trailing: () -> Trailing

    init(
        icon: String,
        iconColor: Color = AppTheme.Colors.accent,
        circleSize: CGFloat = 42,
        circleOpacity: Double = 0.1,
        title: String,
        titleSize: CGFloat = 14,
        subtitle: String? = nil,
        subtitleView: AnyView? = nil,
        subtitleColor: Color = AppTheme.Colors.textTertiary,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.circleSize = circleSize
        self.circleOpacity = circleOpacity
        self.title = title
        self.titleSize = titleSize
        self.subtitle = subtitle
        self.subtitleView = subtitleView
        self.subtitleColor = subtitleColor
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(circleOpacity))
                    .frame(width: circleSize, height: circleSize)
                Image(systemName: icon)
                    .font(.system(size: circleSize * 0.4, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Colors.textPrimary)

                if let subtitleView {
                    subtitleView
                } else if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(subtitleColor)
                }
            }

            Spacer()

            trailing()
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        IconInfoRow(
            icon: "creditcard.fill",
            title: "Estimated Fare",
            subtitle: "$2.90 with OMNY"
        )
        .padding(14)
        .trackGlassCard(cornerRadius: 14, hasHighlight: false)

        IconInfoRow(
            icon: "leaf.fill",
            iconColor: .green,
            title: "Environmental Impact",
            subtitle: "1.2 kg CO₂ saved"
        )
        .padding(14)
        .trackGlassCard(cornerRadius: 14, hasHighlight: false)
    }
    .padding()
    .preferredColorScheme(.dark)
}
