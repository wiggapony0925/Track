// Shimmer skeleton for the route info footer.

import SwiftUI

struct RouteInfoFooterSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBar(width: 90, height: 30, opacity: 0.08)
            SkeletonBar(width: 110, height: 30, opacity: 0.08)
            Spacer()
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .shimmer()
    }
}
