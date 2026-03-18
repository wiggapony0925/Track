//
//  ErrorStateCard.swift
//  Track
//
//  A single, reusable error / empty-state card driven by `ErrorStateKind`.
//  Consolidates NetworkOfflineCard, BackendErrorCard, OutsideServiceAreaCard,
//  NoNearbyArrivalsCard, NoServiceEmptyState, and NetworkErrorBanner into one
//  place so the visual language stays consistent and nothing is duplicated.
//

import SwiftUI

// MARK: - Error State Kind

/// Every distinct empty / error condition the app can display.
/// Add new cases here instead of creating one-off card views.
enum ErrorStateKind: Equatable {
    /// Device has no internet connection.
    case networkOffline
    /// Backend returned 5xx or is unreachable.  Carries the raw error string.
    case backendError(message: String)
    /// User's GPS is outside the NYC metro service area.
    case outsideServiceArea
    /// In service area but no live arrivals found nearby.
    case noNearbyArrivals
    /// Mode-specific "no service" (subway, bus, LIRR, MNR).
    case noService(icon: String, title: String, message: String, brandColor: Color)

    /// True for any `.backendError` regardless of message content.
    var isBackendError: Bool {
        if case .backendError = self { return true }
        return false
    }
}

// MARK: - Visual Configuration (private)

/// Internal struct that maps an `ErrorStateKind` to its visual tokens.
private struct ErrorStateConfig {
    let icon: String
    let iconColor: Color
    let iconBackgroundColor: Color
    let title: String
    let body: String
    let hint: ErrorStateHint?
    let borderColor: Color?

    struct ErrorStateHint {
        let icon: String
        let text: String
    }
}

private extension ErrorStateKind {
    var config: ErrorStateConfig {
        switch self {
        case .networkOffline:
            return .init(
                icon: "wifi.slash",
                iconColor: AppTheme.Colors.alertRed,
                iconBackgroundColor: AppTheme.Colors.alertRed.opacity(0.1),
                title: "No Internet Connection",
                body: "Track needs an internet connection to fetch live transit data. Check your Wi-Fi or cellular settings and try again.",
                hint: .init(icon: "arrow.clockwise", text: "Data will reload automatically when you reconnect"),
                borderColor: AppTheme.Colors.alertRed.opacity(0.2)
            )

        case .backendError(let message):
            return .init(
                icon: "exclamationmark.icloud.fill",
                iconColor: AppTheme.Colors.warningYellow,
                iconBackgroundColor: AppTheme.Colors.warningYellow.opacity(0.12),
                title: "Server Temporarily Unavailable",
                body: "Our servers are waking up or experiencing a brief hiccup. This usually resolves in a few seconds.",
                hint: .init(icon: "info.circle", text: message),
                borderColor: AppTheme.Colors.warningYellow.opacity(0.2)
            )

        case .outsideServiceArea:
            return .init(
                icon: "map.fill",
                iconColor: AppTheme.Colors.accent,
                iconBackgroundColor: AppTheme.Colors.accent.opacity(0.1),
                title: "You're Outside Our Coverage",
                body: "Track currently covers the New York City metro area — subways, buses, LIRR, and Metro-North. We haven't partnered with transit agencies in this region yet.",
                hint: .init(icon: "building.2.fill", text: "Serving the 5 boroughs, Long Island & the Hudson Valley"),
                borderColor: nil
            )

        case .noNearbyArrivals:
            return .init(
                icon: "tram.fill",
                iconColor: AppTheme.Colors.accent,
                iconBackgroundColor: AppTheme.Colors.accent.opacity(0.08),
                title: "No Arrivals Nearby",
                body: "There aren't any live departures in your immediate area. Try moving closer to a station or bus stop, or use the search pin to explore.",
                hint: nil,
                borderColor: nil
            )

        case .noService(let icon, let title, let message, let brandColor):
            return .init(
                icon: icon,
                iconColor: brandColor,
                iconBackgroundColor: brandColor.opacity(0.12),
                title: title,
                body: message,
                hint: .init(icon: "magnifyingglass", text: "Try searching for a station"),
                borderColor: nil
            )
        }
    }
}

// MARK: - Error State Card (full-width card)

/// A reusable full-width error / empty-state card.
///
/// Usage:
/// ```swift
/// ErrorStateCard(.networkOffline, onRetry: { … })
/// ErrorStateCard(.backendError(message: "502"), onRetry: { … })
/// ErrorStateCard(.outsideServiceArea, action: .explore($camera, $is3D))
/// ErrorStateCard(.noNearbyArrivals, action: .explore($camera, $is3D))
/// ErrorStateCard(.noService(icon: "bus.fill", title: "No Buses", message: "…", brandColor: .blue))
/// ```
struct ErrorStateCard: View {

    // MARK: - Action type

    /// The primary action a card can present.
    enum Action {
        /// A "Retry / Try Again" button that fires a closure.
        case retry(() -> Void)
        /// An "Explore" button that moves the camera to the NYC overview.
        case explore(cameraPosition: Binding<TrackCameraPosition>, is3DMode: Binding<Bool>)
    }

    // MARK: - Properties

    let kind: ErrorStateKind
    var action: Action?

    /// Compact mode strips the card chrome and reduces spacing — used by
    /// mode-specific dashboards (Bus, Subway, LIRR, MNR) that already have
    /// their own container.
    var compact: Bool = false

    // MARK: - Init (convenience)

    init(_ kind: ErrorStateKind, action: Action? = nil, compact: Bool = false) {
        self.kind = kind
        self.action = action
        self.compact = compact
    }

    /// Legacy convenience: create with an optional retry closure.
    init(_ kind: ErrorStateKind, onRetry: (() -> Void)?) {
        self.kind = kind
        self.action = onRetry.map { .retry($0) }
        self.compact = false
    }

    // MARK: - Body

    var body: some View {
        let cfg = kind.config

        VStack(spacing: compact ? 12 : 16) {
            // Hero icon
            ZStack {
                Circle()
                    .fill(cfg.iconBackgroundColor)
                    .frame(width: compact ? 64 : 72, height: compact ? 64 : 72)
                Image(systemName: cfg.icon)
                    .font(.system(size: compact ? 28 : 30, weight: .medium))
                    .foregroundColor(cfg.iconColor)
            }

            // Title + body
            VStack(spacing: 6) {
                Text(cfg.title)
                    .font(AppTheme.Typography.headerMedium)
                    .foregroundColor(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(cfg.body)
                    .font(AppTheme.Typography.cardSubtitle)
                    .foregroundColor(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Optional hint row
            if let hint = cfg.hint {
                HStack(spacing: 6) {
                    Image(systemName: hint.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(hint.text)
                        .font(AppTheme.Typography.caption)
                }
                .foregroundColor(compact ? cfg.iconColor : AppTheme.Colors.textTertiary)
            }

            // Action button
            actionButton
        }
        .frame(maxWidth: .infinity)
        .if(compact) { view in
            view.padding(.vertical, 32)
        }
        .if(!compact) { view in
            view
                .padding(AppTheme.Layout.cardPadding + 4)
                .trackCardBackground(cornerRadius: AppTheme.Layout.cornerRadius)
                .overlay(borderOverlay)
                .padding(.horizontal, AppTheme.Layout.margin)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var actionButton: some View {
        switch action {
        case .retry(let closure):
            Button {
                closure()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text(kind.isBackendError ? "Retry" : "Try Again")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(AppTheme.Colors.textOnColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .trackAccentBackground(cornerRadius: 10)
            }
            .padding(.top, 4)

        case .explore(let cameraPosition, let is3DMode):
            Button {
                withAnimation(.easeInOut(duration: 1.0)) {
                    cameraPosition.wrappedValue = MapCameraPresets.explorer(is3D: is3DMode.wrappedValue)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind == .outsideServiceArea ? "subway.fill" : "location.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                    Text(kind == .outsideServiceArea ? "Explore New York City" : "Explore Nearby")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(AppTheme.Colors.textOnColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .trackAccentBackground(cornerRadius: 10)
            }
            .padding(.top, 4)

        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if let borderColor = kind.config.borderColor {
            RoundedRectangle(cornerRadius: AppTheme.Layout.cornerRadius)
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }
}

// MARK: - Conditional modifier helper

private extension View {
    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Compact Error Banner

/// A slim, dismissable banner for inline error display (replaces NetworkErrorBanner).
struct ErrorBanner: View {
    let kind: ErrorStateKind
    var onDismiss: (() -> Void)?

    private var icon: String {
        switch kind {
        case .backendError: return "exclamationmark.icloud.fill"
        case .networkOffline: return "wifi.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var tintColor: Color {
        switch kind {
        case .backendError: return AppTheme.Colors.warningYellow
        case .networkOffline: return AppTheme.Colors.alertRed
        default: return AppTheme.Colors.alertRed
        }
    }

    private var displayMessage: String {
        switch kind {
        case .backendError: return "Server temporarily unavailable — retrying…"
        case .networkOffline: return "No internet connection"
        default: return kind.config.title
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)

            Text(displayMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.8))
                }
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tintColor.opacity(0.92))
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(displayMessage)")
    }
}

// MARK: - Backward-compatible aliases

/// Drop-in replacement so existing `NetworkErrorBanner` call sites keep working.
struct NetworkErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    /// Map the raw message string to an ErrorStateKind.
    private var resolvedKind: ErrorStateKind {
        let msg = message.lowercased()
        let isServer = msg.contains("server error") || msg.contains("502")
            || msg.contains("503") || msg.contains("504") || msg.contains("500")
        return isServer ? .backendError(message: message) : .networkOffline
    }

    var body: some View {
        ErrorBanner(kind: resolvedKind, onDismiss: onDismiss)
    }
}

// MARK: - Previews

#Preview("All Error States") {
    ScrollView {
        VStack(spacing: 24) {
            ErrorStateCard(.networkOffline, onRetry: {})
            ErrorStateCard(.backendError(message: "Server error (502)"), onRetry: {})
            ErrorStateCard(.outsideServiceArea)
            ErrorStateCard(.noNearbyArrivals)
            ErrorStateCard(.noService(
                icon: "bus.fill",
                title: "No Buses Nearby",
                message: "We couldn't find any bus arrivals within your search radius.",
                brandColor: AppTheme.Colors.mtaBlue
            ), compact: true)
        }
        .padding(.vertical, 24)
    }
    .background(AppTheme.Colors.background)
}
