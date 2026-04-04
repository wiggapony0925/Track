// Auto-computed fingerprint for the polyline flattening pipeline.
// Encodes every algorithm constant that affects rendered geometry
// into a stable SHA-256 hash.  When any constant changes the hash
// changes automatically — no manual version bumps required.

import CryptoKit
import Foundation

/// Produces a deterministic short hash from every constant that
/// affects flattened polyline geometry.  Used as the cache filename
/// suffix so stale geometry is never restored after a code change.
///
/// To add a new constant: append it to `allParameters` and the
/// cache file will self-invalidate on the next build.
enum PipelineFingerprint {

    // MARK: - Public API

    /// 8-character hex digest that changes whenever any pipeline
    /// constant is modified.  Example: `"a3f1c8b2"`.
    static let shortHash: String = {
        computeShortHash()
    }()

    // MARK: - Pipeline Constants Registry
    //
    // Every value here MUST mirror the actual constant used at
    // the call-site.  If you change a pipeline constant anywhere
    // in the codebase, update the matching entry here.
    //
    // The key strings are arbitrary but should be descriptive;
    // they exist so the hash input is human-readable for debugging.

    /// All algorithm parameters that affect flattened polyline output,
    /// grouped by pipeline stage.
    static let allParameters: [(key: String, value: Double)] = {
        var params: [(key: String, value: Double)] = []

        // ── Catmull-Rom smoothing ──────────────────────────
        params.append(("catmull.segmentsPerCurve", 4))
        params.append(("catmull.alpha", 0.5))
        params.append(("catmull.minLenForFull", 0.00045))
        params.append(("catmull.minLenForAny", 0.00004))

        // ── Simplification (Ramer-Douglas-Peucker) ─────────
        params.append(("rdp.offsetFanOut", 0.00001))
        params.append(("rdp.offsetNormal", 0.000015))
        params.append(("rdp.zeroOffset", 0.00004))
        params.append(("rdp.commuterRail", 0.00006))

        // ── Spike removal ──────────────────────────────────
        params.append(("spike.angleThreshold", 160.0))

        // ── Near-duplicate removal ─────────────────────────
        params.append(("dedup.minSpacing", 0.00004))

        // ── Backtrack removal ──────────────────────────────
        params.append(("backtrack.cellSize", 0.001))
        params.append(("backtrack.maxPasses", 5))
        params.append(("backtrack.netArcRatio", 0.20))

        // ── Junction-aware fillet (call-site values) ───────
        params.append(("fillet.angleThreshold", 10.0))
        params.append(("fillet.baseRadiusDeg", 0.00045))
        params.append(("fillet.scaleFactor", 0.00030))
        params.append(("fillet.arcPoints", 16))
        params.append(("fillet.soloClampRatio", 0.40))
        params.append(("fillet.edgeBudgetRatio", 0.90))

        // ── Lane offset rendering ──────────────────────────
        params.append(("lane.interpolationBase", 1.6))
        params.append(("lane.touchRatio", 0.98))
        params.append(("lane.minMultiplier", 0.8))

        // ── Polyline merge/unification ─────────────────────
        params.append(("merge.gapThreshold", 0.002))
        params.append(("merge.postGapThreshold", 0.003))
        params.append(("merge.overlapGrid", 0.001))

        return params
    }()

    // MARK: - Internals

    /// Builds a canonical string from all parameters and returns
    /// the first 8 hex characters of its SHA-256 digest.
    private static func computeShortHash() -> String {
        // Canonical format: sorted key=value pairs, one per line.
        // Sorting by key makes the hash independent of append order.
        let canonical = allParameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")

        let digest = SHA256.hash(data: Data(canonical.utf8))
        // First 4 bytes = 8 hex chars — 4 billion possible values,
        // more than sufficient for cache-busting.
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
