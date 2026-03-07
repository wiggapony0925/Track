import SwiftUI

/// A Metro-North Railroad annotation with a dark navy/teal palette
/// to visually distinguish it from LIRR's blue/yellow design.
struct MNRAnnotationView: View, Equatable {
    let routeId: String
    var isHighlighted: Bool = false

    static func == (lhs: MNRAnnotationView, rhs: MNRAnnotationView) -> Bool {
        lhs.routeId == rhs.routeId && lhs.isHighlighted == rhs.isHighlighted
    }

    /// Metro-North dark navy
    private let mnrNavy = Color(red: 0/255, green: 57/255, blue: 100/255)
    /// Metro-North accent (silver/light gray for the "M" bullet)
    private let mnrAccent = Color(red: 200/255, green: 210/255, blue: 220/255)

    var body: some View {
        ZStack {
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
            .shadow(color: mnrNavy.opacity(0.35), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.15), radius: 2)
        }
        .scaleEffect(isHighlighted ? 1.2 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
        .drawingGroup()
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
