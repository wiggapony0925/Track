import SwiftUI

/// A sleek, creative Amtrak annotation with a signature "Amtrak Wave" blue aesthetic.
struct AmtrakAnnotationView: View {
    let routeId: String
    var isHighlighted: Bool = false
    
    var body: some View {
        ZStack {
            // Motion Trail / Glow
            Capsule()
                .fill(Color(hex: "#005596").opacity(0.3))
                .frame(width: isHighlighted ? 50 : 40, height: isHighlighted ? 24 : 18)
                .blur(radius: 4)
                .offset(y: 2)

            // Main Railcar Pill
            HStack(spacing: 6) {
                // Amtrak-style wave/icon abstracted
                Image(systemName: "tram.fill")
                    .font(.system(size: isHighlighted ? 12 : 10, weight: .bold))
                    .foregroundColor(Color(hex: "#EE3124")) // Red accent
                
                Text("Amtrak")
                    .font(.system(size: isHighlighted ? 11 : 9, weight: .black))
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#005596"), Color(hex: "#002C5A")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
            }
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.2), radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.2 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
    }
}
