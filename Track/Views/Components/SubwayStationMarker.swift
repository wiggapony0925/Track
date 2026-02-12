//
//  SubwayStationMarker.swift
//  Track
//
//  A small white dot with an MTA Blue stroke used for subway station
//  map annotations. Displayed when the map is zoomed in.
//

import SwiftUI

struct SubwayStationMarker: View {
    let station: HomeViewModel.CachedSubwayStation

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .overlay(
                Circle()
                    .stroke(AppTheme.Colors.mtaBlue, lineWidth: 3)
            )
            .accessibilityLabel("Station: \(station.name)")
    }
}
