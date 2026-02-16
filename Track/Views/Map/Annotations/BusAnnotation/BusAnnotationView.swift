import SwiftUI

/// A sleek, creative Bus annotation using a glassmorphic pill and high-visibility branding.
struct BusVehicleAnnotation: View {
    let routeName: String
    let bearing: Double?
    var isHighlighted: Bool = false

    var body: some View {
        ZStack {
            // Shadow Glow
            Capsule()
                .fill(isHighlighted ? Color.red.opacity(0.3) : Color.blue.opacity(0.2))
                .frame(width: isHighlighted ? 55 : 45, height: isHighlighted ? 26 : 20)
                .blur(radius: 4)
                .offset(y: 2)

            // Main Glass Pill
            HStack(spacing: 4) {
                // Bus Icon in Branding Color
                ZStack {
                    Circle()
                        .fill(isHighlighted ? Color(hex: "#EE3124") : Color(hex: "#0039A6"))
                        .frame(width: isHighlighted ? 18 : 14)
                    
                    Image(systemName: "bus.fill")
                        .font(.system(size: isHighlighted ? 9 : 7))
                        .foregroundColor(.white)
                }
                
                Text(routeName)
                    .font(.system(size: isHighlighted ? 12 : 10, weight: .black))
                    .foregroundColor(.white)
            }
            .padding(4)
            .padding(.trailing, 4)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.3 : 1.0)
        .rotationEffect(.degrees(bearing ?? 0))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
    }
}
