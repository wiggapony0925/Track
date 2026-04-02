// A compact loading banner shown at the top of the bottom sheet
// when drag-to-search is fetching transit data for a new area.
// Styled to match the app's glassmorphism design language.

import SwiftUI

/// Animated banner displayed in the dashboard while drag-to-search is loading.
struct DragSearchLoadingBanner: View {
    
    @State private var dotPhase = 0.0
    
    var body: some View {
        HStack(spacing: 10) {
            // Animated spinner
            ProgressView()
                .scaleEffect(0.75)
                .tint(AppTheme.Colors.mtaBlue)
            
            Text("Checking area…")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(AppTheme.Colors.textPrimary)
            
            Spacer()
            
            // Animated dots to show activity
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(AppTheme.Colors.mtaBlue)
                        .frame(width: 4, height: 4)
                        .opacity(dotOpacity(for: i))
                }
            }
        }
        .padding(.horizontal, AppTheme.Layout.cardPadding)
        .padding(.vertical, 10)
        .trackFloatingChrome(cornerRadius: 14)
        .padding(.horizontal, AppTheme.Layout.margin)
        .padding(.top, 4)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                dotPhase = 1.0
            }
        }
    }
    
    private func dotOpacity(for index: Int) -> Double {
        let progress = (dotPhase + Double(index) * 0.33).truncatingRemainder(dividingBy: 1.0)
        return 0.3 + 0.7 * max(0, 1.0 - abs(progress - 0.5) * 4)
    }
}

#Preview {
    VStack {
        DragSearchLoadingBanner()
        Spacer()
    }
    .background(AppTheme.Colors.background)
}
