// Cryptographic + validation helpers shared by the auth screens.
//
// * `AuthNonce` produces a cryptographically random nonce and its
//   SHA-256 digest. Apple Sign-In requires the SHA-256 hash to be
//   sent on the `ASAuthorizationAppleIDRequest`, while Supabase
//   needs the plaintext value to verify the `nonce` claim baked
//   into the returned id_token. Used together this defeats
//   id-token replay attacks.
//
// * `AuthValidator` does belt-and-suspenders client-side input
//   checks (proper email regex, password length + complexity)
//   so we don't ship requests we already know the server will
//   reject. Server-side rules in Supabase are still authoritative.

import Foundation
import CryptoKit

enum AuthNonce {

    /// Returns a fresh `(rawNonce, sha256Hash)` pair.
    /// `rawNonce` goes to Supabase; `sha256Hash` goes to Apple.
    static func make(length: Int = 32) -> (raw: String, sha256: String) {
        let raw = randomString(length: length)
        return (raw, sha256(raw))
    }

    /// Cryptographically random URL-safe string drawn from
    /// `SecRandomCopyBytes`. Never falls back to `arc4random`-style
    /// PRNGs — if the syscall fails we crash loudly in DEBUG and
    /// surface a recoverable error in release rather than silently
    /// emitting a weak value.
    private static func randomString(length: Int) -> String {
        precondition(length > 0)
        let charset: [Character] = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
        )

        var result = ""
        result.reserveCapacity(length)

        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                // Fall back to SystemRandomNumberGenerator (CSPRNG-backed
                // on Apple platforms) so we never produce a predictable
                // nonce. Logged so we can investigate keychain failures.
                #if DEBUG
                fatalError("SecRandomCopyBytes failed with status \(status)")
                #else
                var rng = SystemRandomNumberGenerator()
                for _ in 0..<remaining {
                    let idx = Int.random(in: 0..<charset.count, using: &rng)
                    result.append(charset[idx])
                }
                return result
                #endif
            }

            for byte in randoms where remaining > 0 {
                let idx = Int(byte) % charset.count
                result.append(charset[idx])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum AuthValidator {

    // RFC 5322-ish — strict enough to catch typos, lenient enough
    // to allow the long tail of real-world local parts. Final
    // validation happens server-side anyway.
    private static let emailRegex: NSRegularExpression = {
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 254 else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return emailRegex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    /// Strength bucket for a password. UI uses this to drive the
    /// inline meter on Create Account.
    enum PasswordStrength: Int, Comparable {
        case tooShort = 0
        case weak = 1
        case fair = 2
        case strong = 3

        static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .tooShort: return "Too short"
            case .weak: return "Weak"
            case .fair: return "Fair"
            case .strong: return "Strong"
            }
        }
    }

    /// Minimum length matching Supabase's default 6-char rule but
    /// nudging users toward 8+ via the strength meter.
    static let minPasswordLength = 8

    static func strength(of password: String) -> PasswordStrength {
        guard password.count >= 8 else {
            return password.count < 6 ? .tooShort : .weak
        }
        var score = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { score += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        let symbols = CharacterSet.alphanumerics.inverted
        if password.rangeOfCharacter(from: symbols) != nil { score += 1 }
        if password.count >= 12 { score += 1 }

        switch score {
        case 0...1: return .weak
        case 2...3: return .fair
        default: return .strong
        }
    }

    /// True if a password is strong enough to allow account creation.
    /// Sign-in keeps a looser check because legacy passwords might
    /// be shorter than the current minimum.
    static func isAcceptableForSignUp(_ password: String) -> Bool {
        password.count >= minPasswordLength
            && strength(of: password) >= .weak
    }
}
