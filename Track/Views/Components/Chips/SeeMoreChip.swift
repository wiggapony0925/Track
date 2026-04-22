// Trailing chip in the horizontal countdown scroller that switches
// the user to the Departures tab so they can browse the full
// schedule board.  Sized to match a standard non-first
// `ArrivalChipView` (92 × 138, r18) so the strip looks uniform.

import SwiftUI

struct SeeMoreChip: View {
    let routeColor: Color
    let remainingCount: Int
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(routeColor)
                Text("More")
                    .font(.custom("Helvetica-Bold", fixedSize: 12))
                    .foregroundColor(routeColor)
                Text("departures")
                    .font(.custom("Helvetica-Bold", fixedSize: 12))
                    .foregroundColor(routeColor)
                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.custom("Helvetica", fixedSize: 11))
                        .foregroundColor(routeColor.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .frame(width: 92, height: 138)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(routeColor.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(routeColor.opacity(0.12), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("See more departures"))
    }
}
