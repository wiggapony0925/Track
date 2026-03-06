//
//  TrunkRouteLabelView.swift
//  Track
//
//  Apple Maps–style route bullet labels that appear at intervals along
//  trunk polylines. Shows small colored circles with white route letters
//  to indicate which trains run on a given section.
//

import SwiftUI

/// Compact row of route bullets placed along a trunk polyline.
///
/// At system-map zoom the bullets are tiny (12×12 pt) and arranged in
/// a tight horizontal stack.  Keeping the view minimal is critical —
/// hundreds of labels may be visible simultaneously.
struct TrunkRouteLabelView: View {
    let routeIds: [String]
    let color: Color

    var body: some View {
        HStack(spacing: 1) {
            ForEach(routeIds.prefix(4), id: \.self) { routeId in
                Text(routeId)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundColor(textColor(for: routeId))
                    .frame(width: 12, height: 12)
                    .background(
                        Circle().fill(color)
                    )
                    .clipShape(Circle())
            }
        }
        .padding(1.5)
        .background(
            Capsule()
                .fill(.white)
        )
        .allowsHitTesting(false)
    }

    /// Yellow lines use black text; all others use white.
    private func textColor(for routeId: String) -> Color {
        switch routeId.uppercased() {
        case "N", "Q", "R", "W": return .black
        default: return .white
        }
    }
}
