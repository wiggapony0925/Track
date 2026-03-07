import SwiftUI

/// A signature Long Island Rail Road (LIRR) annotation with the classic blue/yellow palette.
struct LIRRAnnotationView: View, Equatable {
    let routeId: String
    var isHighlighted: Bool = false

    static func == (lhs: LIRRAnnotationView, rhs: LIRRAnnotationView) -> Bool {
        lhs.routeId == rhs.routeId && lhs.isHighlighted == rhs.isHighlighted
    }
    
    var body: some View {
        ZStack {
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
            .shadow(color: Color(hex: "#0039A6").opacity(0.35), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.15), radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.2 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
        .drawingGroup()
    }
}
