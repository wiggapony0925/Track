//
//  DragSearchOverlay.swift
//  Track
//
//  Live drag-to-search overlay. When the user pans the map away from
//  their real location, a subtle dim covers the map, a blue dot appears
//  at the screen center, and the bottom sheet shows a loading state.
//  The API fires automatically after panning stops.
//

import SwiftUI

/// A fixed-position blue dot at screen center + a status pill at the top,
/// with a subtle map dim while the user is actively panning.
struct DragSearchOverlay: View {
    
    let isActive: Bool
    let isSearching: Bool
    let isPanning: Bool
    let onDismiss: () -> Void
    
    /// The bottom safe-area padding applied to the map (e.g. 350pt for the bottom sheet).
    /// The map camera center is shifted up by half this value, so we offset the dot to match.
    var mapBottomPadding: CGFloat = 350
    
    var body: some View {
        if isActive {
            ZStack {
                // ── Subtle dim while actively panning ──
                if isPanning {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                
                // ── Blue dot pinned to map's effective center ──
                // The map has safeAreaPadding(.bottom, 350), which shifts
                // its camera center upward by half that amount.
                // We offset the dot by the same amount so it sits exactly
                // where the map reports its center coordinate.
                appleLocationDot
                    .offset(y: -(mapBottomPadding / 2))
                    .allowsHitTesting(false)
                
                // ── Status pill at top ──
                VStack {
                    statusPill
                        .padding(.top, 14)
                    Spacer()
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: isPanning)
        }
    }
    
    // MARK: - Apple-style Location Dot
    
    private var appleLocationDot: some View {
        ZStack {
            // Soft accuracy halo
            Circle()
                .fill(Color(red: 0.0, green: 0.48, blue: 1.0).opacity(isPanning ? 0.15 : 0.10))
                .frame(width: 44, height: 44)
            
            // White border
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
            
            // Blue fill — pulses while searching
            Circle()
                .fill(Color(red: 0.0, green: 0.48, blue: 1.0))
                .frame(width: 16, height: 16)
                .scaleEffect(isSearching ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isSearching)
        }
    }
    
    // MARK: - Status Pill
    
    private var statusPill: some View {
        HStack(spacing: 8) {
            if isSearching {
                ProgressView()
                    .scaleEffect(0.65)
                    .tint(Color(red: 0.0, green: 0.48, blue: 1.0))
            } else if isPanning {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.0, green: 0.48, blue: 1.0))
            } else {
                Circle()
                    .fill(Color(red: 0.0, green: 0.48, blue: 1.0))
                    .frame(width: 7, height: 7)
            }
            
            Text(statusText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .animation(.easeInOut(duration: 0.2), value: statusText)
    }
    
    private var statusText: String {
        if isSearching { return "Checking area…" }
        if isPanning { return "Release to search" }
        return "Exploring area"
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.15).ignoresSafeArea()
        DragSearchOverlay(isActive: true, isSearching: false, isPanning: true, onDismiss: {})
    }
}
