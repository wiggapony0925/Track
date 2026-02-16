import SwiftUI

/// A signature Long Island Rail Road (LIRR) annotation with the classic blue/yellow palette.
struct LIRRAnnotationView: View {
    let routeId: String
    var isHighlighted: Bool = false
    
    var body: some View {
        ZStack {
            // Glow
            Capsule()
                .fill(Color(hex: "#0039A6").opacity(0.3))
                .frame(width: isHighlighted ? 50 : 40, height: isHighlighted ? 24 : 18)
                .blur(radius: 4)
                .offset(y: 2)

            // The "LIRR Railcar"
            HStack(spacing: 4) {
                // Classic Bullet design inside a pill
                ZStack {
                    Circle()
                        .fill(Color(hex: "#FCCC0A"))
                        .frame(width: 14, height: 14)
                    
                    Text("L")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.black)
                }
                
                Text("LIRR")
                    .font(.system(size: isHighlighted ? 11 : 9, weight: .black))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color(hex: "#0039A6"))
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
            }
            .foregroundColor(.white)
            .shadow(radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.2 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
    }
}
