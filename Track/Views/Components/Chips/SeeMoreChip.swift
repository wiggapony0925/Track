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
            VStack(spacing: 7) {
                Spacer(minLength: 0)
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundColor(routeColor)
                Text("More")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(routeColor)
                Text("departures")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(routeColor)
                if remainingCount > 0 {
                    Text("+\(remainingCount)")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(routeColor.opacity(0.92)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: 92, height: 138)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(routeColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(routeColor.opacity(0.16), lineWidth: 0.75)
                    )
            )
            .shadow(color: routeColor.opacity(0.08), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("See more departures"))
    }
}
