//
//  NetworkErrorBanner.swift
//  Track
//
//  A compact, dismissable error banner shown when the backend is unreachable.
//  Replaces inline error text with a more polished UX.
//

import SwiftUI

struct NetworkErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            if let onDismiss = onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                }
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.alertRed.opacity(0.9))
        .cornerRadius(AppTheme.Layout.cornerRadius)
        .padding(.horizontal, AppTheme.Layout.margin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network error: \(message)")
    }
}

#Preview {
    VStack(spacing: 16) {
        NetworkErrorBanner(
            message: "Unable to connect to server",
            onDismiss: {}
        )
        NetworkErrorBanner(
            message: "No network connection available"
        )
    }
    .padding()
    .background(AppTheme.Colors.background)
}
