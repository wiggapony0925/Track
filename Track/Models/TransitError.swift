// Error types for transit data fetching operations.
// Provides user-friendly error descriptions for display.

import Foundation

/// Error types for transit data fetching.
enum TransitError: Error, LocalizedError, CustomStringConvertible {
    case networkUnavailable
    case feedParsingFailed
    case signalLost
    case unknown(Error)
    
    var description: String {
        switch self {
        case .networkUnavailable:
            return "No network connection available"
        case .feedParsingFailed:
            return "Unable to read transit data"
        case .signalLost:
            return "Signal Lost in Tunnel"
        case .unknown(let error):
            return error.localizedDescription
        }
    }

    var errorDescription: String? { description }
}
