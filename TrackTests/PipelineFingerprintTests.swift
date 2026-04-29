import CryptoKit
import XCTest
@testable import Track

/// Tests for `PipelineFingerprint` — the auto-hash mechanism that
/// invalidates flattened polyline caches whenever algorithm constants change.
final class PipelineFingerprintTests: XCTestCase {

    // MARK: - Hash Stability

    /// The hash must be deterministic across multiple calls.
    func testHashIsDeterministic() {
        let h1 = PipelineFingerprint.shortHash
        let h2 = PipelineFingerprint.shortHash
        XCTAssertEqual(h1, h2, "Same binary should always produce the same hash")
    }

    /// The hash must be exactly 8 hex characters (4 bytes of SHA-256).
    func testHashLengthIsEightHexChars() {
        let hash = PipelineFingerprint.shortHash
        XCTAssertEqual(hash.count, 8, "Expected 8 hex chars, got \(hash.count)")
    }

    /// The hash string must contain only lowercase hex digits.
    func testHashContainsOnlyHexDigits() {
        let hash = PipelineFingerprint.shortHash
        let hexSet = CharacterSet(charactersIn: "0123456789abcdef")
        for scalar in hash.unicodeScalars {
            XCTAssertTrue(
                hexSet.contains(scalar),
                "Non-hex character '\(scalar)' found in hash: \(hash)"
            )
        }
    }

    // MARK: - Parameter Registry Integrity

    /// Every parameter must have a non-empty key.
    func testAllParameterKeysAreNonEmpty() {
        for param in PipelineFingerprint.allParameters {
            XCTAssertFalse(
                param.key.isEmpty,
                "Found a parameter with an empty key"
            )
        }
    }

    /// All parameter keys must be unique — a duplicate would silently
    /// shadow one value and break the fingerprint.
    func testAllParameterKeysAreUnique() {
        let keys = PipelineFingerprint.allParameters.map(\.key)
        let unique = Set(keys)
        XCTAssertEqual(
            keys.count, unique.count,
            "Duplicate keys found: \(keys.filter { k in keys.filter { $0 == k }.count > 1 })"
        )
    }

    /// Sanity: there should be a reasonable number of parameters.
    /// The pipeline currently has ~27 constants.  If this drops below 20
    /// someone probably removed entries by accident.
    func testParameterCountIsReasonable() {
        let count = PipelineFingerprint.allParameters.count
        XCTAssertGreaterThanOrEqual(
            count, 20,
            "Expected at least 20 pipeline parameters, got \(count)"
        )
    }

    /// All values must be finite (no NaN/Inf sneaking in).
    func testAllValuesAreFinite() {
        for param in PipelineFingerprint.allParameters {
            XCTAssertTrue(
                param.value.isFinite,
                "Parameter '\(param.key)' has non-finite value: \(param.value)"
            )
        }
    }

    // MARK: - Hash Sensitivity

    /// Changing any single parameter must change the hash.
    /// We verify this by perturbing each value and checking
    /// the resulting canonical string differs.
    func testHashChangesWhenAnyParameterChanges() {
        let baseHash = PipelineFingerprint.shortHash

        // Build the same canonical string the real code uses,
        // but perturb one parameter at a time.
        let params = PipelineFingerprint.allParameters

        for idx in params.indices {
            var mutated = params
            mutated[idx] = (key: params[idx].key, value: params[idx].value + 0.001)

            let canonical = mutated
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")

            // Compute hash the same way PipelineFingerprint does
            let digest = CryptoKit.SHA256.hash(data: Data(canonical.utf8))
            let perturbedHash = digest.prefix(4).map {
                String(format: "%02x", $0)
            }.joined()

            XCTAssertNotEqual(
                perturbedHash, baseHash,
                "Perturbing '\(params[idx].key)' did not change the hash"
            )
        }
    }

    /// Reordering allParameters must NOT change the hash because
    /// the implementation sorts by key before hashing.
    func testHashIsOrderIndependent() {
        // The hash is computed from sorted keys, so any order of
        // `allParameters` should yield the same result.  We can't
        // easily mutate the static, but we can verify the sort
        // contract by checking the canonical string ourselves.
        let params = PipelineFingerprint.allParameters

        let canonical1 = params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")

        let canonical2 = params.reversed()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")

        XCTAssertEqual(
            canonical1, canonical2,
            "Sorted canonical strings should be identical regardless of input order"
        )
    }

    // MARK: - Known Pipeline Stages Coverage

    /// Verify all expected pipeline stages have at least one parameter.
    func testAllPipelineStagesRepresented() {
        let keys = Set(
            PipelineFingerprint.allParameters.map {
                $0.key.components(separatedBy: ".").first ?? ""
            }
        )
        let expectedStages = [
            "catmull", "rdp", "spike", "dedup", "backtrack",
            "fillet", "lane", "merge",
        ]
        for stage in expectedStages {
            XCTAssertTrue(
                keys.contains(stage),
                "Pipeline stage '\(stage)' not represented in fingerprint"
            )
        }
    }

    /// Spot-check a few critical values to catch accidental edits
    /// to the registry that don't match the real call sites.
    func testCriticalParameterValues() {
        let lookup = Dictionary(
            PipelineFingerprint.allParameters.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        // Catmull-Rom
        XCTAssertEqual(lookup["catmull.segmentsPerCurve"], 4)
        XCTAssertEqual(lookup["catmull.alpha"], 0.5)

        // Fillet call-site overrides
        XCTAssertEqual(lookup["fillet.angleThreshold"], 10.0)
        XCTAssertEqual(lookup["fillet.baseRadiusDeg"], 0.00045)
        XCTAssertEqual(lookup["fillet.arcPoints"], 16)

        // Lane offset
        XCTAssertEqual(lookup["lane.interpolationBase"], 1.6)
        XCTAssertEqual(lookup["lane.touchRatio"], 0.58)
        XCTAssertEqual(lookup["lane.minMultiplier"], 0.0)
        XCTAssertEqual(lookup["lane.serverLocalOffsets"], 0.0)
        XCTAssertEqual(lookup["station.serverLocalOffsets"], 0.0)
        XCTAssertEqual(lookup["subway.casingCrossingGaps"], 0.0)
    }
}
