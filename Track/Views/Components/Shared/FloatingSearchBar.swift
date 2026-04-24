// Floating search bar that sits ABOVE the bottom sheet top edge.
// Its bottom is pinned exactly to the sheet top — no overlap, no gap.
//
// PILL LAYOUT:
//   [icon] [location name + status subtitle] [spacer] [mic] [|] [shortcut]
//   The location text is capped so the right-side buttons always render.
//
// SHORTCUT BUTTON (right of |):
//   Not near Home → house.fill   → one-tap trip to Home
//   Near Home     → briefcase.fill → one-tap trip to Work
//   Nothing saved → house.badge.plus (disabled placeholder)

import SwiftUI
import CoreLocation
import SwiftData

private let searchRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// Distance (metres) within which the user is considered "at" a saved place.
private let nearPlaceThresholdMeters: Double = 400

struct FloatingSearchBar: View {
    @Binding var searchText: String
    var locationName: String?
    var isDragSearchActive: Bool = false

    // Passed in from HomeView — keeps this component dependency-free.
    var homePlace: SavedLocation? = nil
    var workPlace: SavedLocation? = nil
    var userCoordinate: CLLocationCoordinate2D? = nil

    /// Optional override for the pill tap. When supplied, the default
    /// behavior of focusing the inline TextField is replaced — callers
    /// typically use this to open a richer search sheet (e.g. the
    /// ``DestinationSearchView`` popup on the Home tab).
    var onTap: (() -> Void)? = nil

    @State private var speechManager = SpeechRecognitionManager()
    @FocusState private var isTextFieldFocused: Bool

    // MARK: - Shortcut Logic

    private var isNearHome: Bool {
        guard let home = homePlace, let user = userCoordinate else { return false }
        let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
        let userLoc  = CLLocation(latitude: user.latitude,  longitude: user.longitude)
        return userLoc.distance(from: homeLoc) < nearPlaceThresholdMeters
    }

    private var shortcutPlace: (place: SavedLocation, icon: String, label: String)? {
        if isNearHome {
            guard let work = workPlace else {
                // At home but no work saved — still offer Home shortcut
                guard let home = homePlace else { return nil }
                return (home, "house.fill", "Home")
            }
            return (work, "briefcase.fill", "Work")
        } else {
            guard let home = homePlace else { return nil }
            return (home, "house.fill", "Home")
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // ── Left icon ──
            Image(systemName: searchText.isEmpty
                  ? (isDragSearchActive ? "mappin.and.ellipse" : "location.fill")
                  : "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 36)
                .contentTransition(.symbolEffect(.replace))

            // ── Center: always-present TextField + location overlay ──
            VStack(alignment: .leading, spacing: 1) {
                ZStack(alignment: .leading) {
                    // Location name shown when idle — acts as a styled placeholder.
                    // Hidden as soon as the user starts typing or focuses.
                    if searchText.isEmpty && !isTextFieldFocused {
                        Text(isDragSearchActive
                             ? (locationName ?? "Searching near pin…")
                             : "Where to?")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .allowsHitTesting(false) // let taps fall through to TextField
                    }

                    // TextField is ALWAYS in the hierarchy so it can receive focus.
                    // When idle, it's visually hidden behind the overlay text above.
                    TextField("Search a destination…", text: $searchText)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .tint(.white)
                        .focused($isTextFieldFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // Hide the system placeholder and cursor text while idle
                        .opacity(searchText.isEmpty && !isTextFieldFocused ? 0 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Mic ──
            micButton
                .frame(width: 38)

            // ── Divider ──
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 20)

            // ── Smart shortcut ──
            shortcutButton
                .frame(width: 38)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 11)
        .background {
            Capsule()
                // Slightly darker when drag-search is active — signals that
                // the search origin is no longer the user's GPS position.
                .fill(isDragSearchActive
                      ? AppTheme.Colors.accent.opacity(0.78)
                      : AppTheme.Colors.accent)
                .shadow(color: AppTheme.Colors.accent.opacity(isDragSearchActive ? 0.35 : 0.5),
                        radius: isDragSearchActive ? 8 : 14, y: 4)
        }
        .padding(.horizontal, AppTheme.Layout.margin)
        .animation(.easeInOut(duration: 0.25), value: isDragSearchActive)
        .onAppear {
            speechManager.onTranscription = { text in searchText = text }
        }
        // Whole pill is tappable — either fire the caller's hook
        // (e.g. open the search sheet) or fall back to focusing the
        // inline TextField for legacy in-place typing.
        .onTapGesture {
            if let onTap {
                HapticManager.impact(.light)
                onTap()
            } else {
                isTextFieldFocused = true
            }
        }
    }


    // MARK: - Mic button

    private var micButton: some View {
        let isRecording = speechManager.isRecording
        return Button {
            speechManager.toggle()
        } label: {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isRecording ? AppTheme.Colors.alertRed : .white.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Smart shortcut button

    // Always renders an icon — either the user's home/work shortcut or a
    // "save home" nudge. Uses .symbolEffect(.replace) to swap icons cleanly
    // without any opacity=0 mid-transition frames that would hide the icon.
    private var shortcutButton: some View {
        let iconName: String = {
            if let shortcut = shortcutPlace { return shortcut.icon }
            return "house.badge.plus"   // nudge: no saved places yet
        }()

        return Button {
            if let shortcut = shortcutPlace {
                fireQuickTrip(to: shortcut.place)
            } else {
                HapticManager.impact(.light)
            }
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                // symbolEffect replaces the glyph in-place with no opacity dip.
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    private func fireQuickTrip(to place: SavedLocation) {
        NotificationCenter.default.post(name: .quickDestination, object: PlanLocation.saved(place))
        NotificationCenter.default.post(name: .switchToTab, object: AppTab.trips)
        HapticManager.impact(.medium)
    }
}

#Preview {
    FloatingSearchBar(
        searchText: .constant(""),
        locationName: "95 Manhattan West Plaza"
    )
    .padding()
    .background(Color.black)
}
