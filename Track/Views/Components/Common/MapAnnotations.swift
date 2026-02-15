//
//  MapAnnotations.swift
//  Track
//
//  Reusable map annotation views used in HomeView's Map.
//  Extracted to keep HomeView focused on layout and state management.
//

import SwiftUI

// MARK: - Search Pin Annotation

/// A draggable search pin for exploring transit at other locations.
struct SearchPinAnnotation: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Colors.alertRed)
                .frame(width: 36, height: 36)
                .shadow(color: AppTheme.Colors.alertRed.opacity(0.4), radius: AppTheme.Layout.shadowRadius)
            Image(systemName: "mappin")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(AppTheme.Colors.textOnColor)
        }
        .accessibilityLabel("Search pin — drag to explore")
    }
}

// MARK: - Bus Vehicle Annotation

/// A map pin showing a live bus position with its route name and bearing.
struct BusVehicleAnnotation: View {
    let routeName: String
    let bearing: Double?
    var isHighlighted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Shadow for 3D lift
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.4))
                    .frame(width: isHighlighted ? 39 : 26, height: isHighlighted ? 75 : 50)
                    .offset(x: 2, y: 4)
                    .blur(radius: 3)

                // Bus Body (3D effect with gradient)
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [
//                                AppTheme.Colors.mtaBlue.opacity(0.9), // Original
//                                AppTheme.Colors.mtaBlue
                                isHighlighted ? AppTheme.Colors.alertRed : AppTheme.Colors.mtaBlue.opacity(0.9),
                                isHighlighted ? AppTheme.Colors.alertRed.opacity(0.9) : AppTheme.Colors.mtaBlue
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: isHighlighted ? 39 : 26, height: isHighlighted ? 72 : 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(isHighlighted ? 0.8 : 0.3), lineWidth: isHighlighted ? 2 : 1)
                    )
                    .overlay(
                        VStack(spacing: 0) {
                            // Windshield (shiny glass effect)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    LinearGradient(
                                        colors: [.black.opacity(0.8), .black.opacity(0.6)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(height: isHighlighted ? 12 : 8)
                                .padding(.top, isHighlighted ? 4 : 3)
                                .padding(.horizontal, isHighlighted ? 3 : 2)
                                .overlay(
                                    // Glare on windshield
                                    Capsule()
                                        .fill(Color.white.opacity(0.3))
                                        .frame(width: isHighlighted ? 18 : 12, height: isHighlighted ? 3 : 2)
                                        .offset(x: -4, y: -2)
                                )

                            // Roof details / AC units
                            HStack(spacing: 4) {
                                Circle().fill(Color.white.opacity(0.2)).frame(width: 4, height: 4)
                                Circle().fill(Color.white.opacity(0.2)).frame(width: 4, height: 4)
                            }
                            .padding(.top, 8)

                            Spacer()

                            // Rear window
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.black.opacity(0.5))
                                .frame(height: 5)
                                .padding(.bottom, 3)
                                .padding(.horizontal, 3)
                        }
                    )
                
                // Route Label on Roof
                Text(routeName)
                    .font(.system(size: isHighlighted ? 13 : 9, weight: .heavy))
                    .foregroundColor(.white)
                    .shadow(radius: 1)
                    .rotationEffect(.degrees(-90))
            }
            .scaleEffect(isHighlighted ? 1.2 : 1.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isHighlighted)
            .rotationEffect(.degrees(bearing ?? 0))
            // Subtle bobbing animation could be added here if desired
        }
    }
}

// MARK: - Train Annotation

/// A map pin showing a live train position.
struct TrainAnnotation: View {
    let routeId: String
    let direction: String // "N" or "S"
    var isHighlighted: Bool = false
    
    var body: some View {
        ZStack {
            // Shadow
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.5))
                .frame(width: isHighlighted ? 24 : 16, height: isHighlighted ? 60 : 40)
                .offset(y: 2)
                .blur(radius: 2)
            
            // Train Car Body
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: "#808183")) // Stainless steel color
                .frame(width: isHighlighted ? 24 : 16, height: isHighlighted ? 60 : 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isHighlighted ? AppTheme.SubwayColors.color(for: routeId) : Color.white.opacity(0.4), lineWidth: isHighlighted ? 3 : 1)
                )
            
            // Route Bullet (Circle)
            Circle()
                .fill(AppTheme.SubwayColors.color(for: routeId))
                .frame(width: isHighlighted ? 18 : 12, height: isHighlighted ? 18 : 12)
                .overlay(
                    Text(routeId)
                        .font(.system(size: isHighlighted ? 12 : 8, weight: .bold))
                        .foregroundColor(.white)
                )
                .offset(y: isHighlighted ? -15 : -10) // Near front
        }
        .scaleEffect(isHighlighted ? 1.2 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isHighlighted)
    }
}
