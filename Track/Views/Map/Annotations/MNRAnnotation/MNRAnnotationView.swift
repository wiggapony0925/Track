import SwiftUI

/// A Metro-North Railroad annotation with a dark navy/teal palette
/// to visually distinguish it from LIRR's blue/yellow design.
struct MNRAnnotationView: View {
    let routeId: String
    var isHighlighted: Bool = false

    /// Metro-North dark navy
    private let mnrNavy = Color(red: 0/255, green: 57/255, blue: 100/255)
    /// Metro-North accent (silver/light gray for the "M" bullet)
    private let mnrAccent = Color(red: 200/255, green: 210/255, blue: 220/255)

    var body: some View {
        ZStack {
            // Glow
            Capsule()
                .fill(mnrNavy.opacity(0.3))
                .frame(width: isHighlighted ? 50 : 40, height: isHighlighted ? 24 : 18)
                .blur(radius: 4)
                .offset(y: 2)

            // The "MNR Railcar"
            HStack(spacing: 4) {
                // Bullet design
                ZStack {
                    Circle()
                        .fill(mnrAccent)
                        .frame(width: 14, height: 14)

                    Text("M")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(mnrNavy)
                }

                Text("MNR")
                    .font(.system(size: isHighlighted ? 11 : 9, weight: .black))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(mnrNavy)
            }
            .overlay {
                Capsule()
                    .stroke(mnrAccent.opacity(0.5), lineWidth: 1.5)
            }
            .foregroundColor(.white)
            .shadow(radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.2 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        VStack(spacing: 20) {
            MNRAnnotationView(routeId: "MNR_1", isHighlighted: false)
            MNRAnnotationView(routeId: "MNR_2", isHighlighted: true)
        }
    }
}
