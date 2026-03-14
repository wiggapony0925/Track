//
//  StationComplexLookup.swift
//  Track
//
//  Hybrid station classifier: JSON-driven complex registry +
//  geographic structure inference.
//
//  DATA LIFECYCLE
//  ┌───────────────────┬───────────────┬───────────────────────┐
//  │ Component         │ Storage       │ Update Frequency      │
//  ├───────────────────┼───────────────┼───────────────────────┤
//  │ Complex Registry  │ Bundled JSON  │ Yearly (MTA renovate) │
//  │ Structure Type    │ Inferred      │ Never (geography)     │
//  │ Reroute Override  │ Live alerts   │ Every 30 s            │
//  │ Colors            │ xcassets      │ Never                 │
//  │ Station Names     │ Remote+Cache  │ Per-session           │
//  │ Polylines         │ Remote+Cache  │ Per-session           │
//  └───────────────────┴───────────────┴───────────────────────┘
//
//  The JSON file `station_complexes.json` holds ONLY the ~20
//  multi-level transfer complexes (~60 stop IDs).  Everything
//  else — elevated, open-cut, at-grade — is derived at runtime
//  from route IDs + lat/lon using well-known NYC topology rules.
//
//  To add a new complex (e.g., future IBX station), edit the JSON —
//  no recompilation needed for TestFlight / App Store builds.
//

import Foundation

// MARK: - Station Structure Type

/// Physical structure of a subway station / platform.
///
/// Determines visual treatment:
///   - `.subway`   → capsule (pill) marker, dark stroke
///   - `.elevated` → circle marker, lighter stroke + drop shadow
///   - `.openCut`  → capsule marker, dashed stroke
///   - `.atGrade`  → small circle, no shadow (SIR)
///   - `.viaduct`  → same as elevated (concrete overpass)
enum StationStructure: String, CaseIterable, Codable {
    case subway
    case elevated
    case openCut
    case atGrade
    case viaduct
}

// MARK: - Complex Lookup Entry

/// Associates a GTFS parent station ID with its complex group and structure.
struct StationComplexEntry {
    let complexID: Int
    let structure: StationStructure
}

// MARK: - JSON Models (private)

/// Codable models for `station_complexes.json`.
private struct ComplexRegistryJSON: Codable {
    let version: String
    let complexes: [ComplexJSON]
}

private struct ComplexJSON: Codable {
    let id: Int
    let name: String
    let stations: [ComplexStationJSON]
}

private struct ComplexStationJSON: Codable {
    let stop_id: String
    let structure: String
}

// MARK: - Lookup

/// Hybrid station classifier: JSON-driven complex IDs + runtime
/// geographic structure inference.
///
/// **Complex IDs** (from bundled JSON):
/// Stations that share a physical complex (connected by passageways)
/// have the same `complexID`.  Within a complex, stations are sub-
/// grouped by `structure`.  An underground platform and an elevated
/// platform become separate markers connected by a transfer indicator.
///
/// **Structure** (inferred at runtime):
/// For stations NOT in the complex registry, physical structure is
/// derived from route service + geographic position.  The rules
/// encode well-known NYC subway topology: the 7 is elevated in
/// Queens, the J/Z is elevated east of Marcy Av, etc.
///
/// Example: 74 St–Roosevelt Ave
///   - Station `710` (7 train) → complexID 601, `.elevated` (from JSON)
///   - Station `G14` (E/F/M/R) → complexID 601, `.subway`  (from JSON)
///   → Two separate markers, visually linked as one transfer complex.
enum StationComplexLookup {

    // MARK: - Public API

    /// Returns the complex entry for a station.
    ///
    /// 1. Check the JSON-loaded complex registry first.
    /// 2. Fall back to geographic inference + hash-derived complex ID.
    static func entry(
        for stationID: String,
        routes: [String] = [],
        lat: Double = 0,
        lon: Double = 0
    ) -> StationComplexEntry {
        if let e = complexTable[stationID] { return e }
        let structure = inferStructure(routes: routes, lat: lat, lon: lon)
        return StationComplexEntry(
            complexID: defaultComplexID(for: stationID),
            structure: structure
        )
    }

    // MARK: - Geographic Structure Inference

    /// Derives physical structure from route service + geographic
    /// position using bounding-box rules.
    ///
    /// The NYC subway has a predictable physical topology: lines run
    /// underground in Manhattan and transition to elevated structures
    /// in outer boroughs at well-known geographic boundaries.  These
    /// boundaries reflect physical infrastructure that hasn't changed
    /// in decades.
    ///
    /// Rules are evaluated top-to-bottom; first match wins.
    static func inferStructure(
        routes: [String],
        lat: Double,
        lon: Double
    ) -> StationStructure {
        let routeSet = Set(routes)

        // ── Staten Island Railway ──
        // Entirely at-grade commuter-style rail.
        if routeSet.contains("SI") || routeSet.contains("SIR")
            || (lon < -74.05 && lat < 40.65) {
            return .atGrade
        }

        // ── Rockaway branch (A train) ──
        // Elevated trestle across Jamaica Bay and on the peninsula.
        if routeSet.contains("A") && lat < 40.62 && lon > -73.86 {
            return .elevated
        }

        // ── 7 train: elevated in Queens ──
        // Underground: 34 St-Hudson Yards → Grand Central (lon < -73.96)
        // Elevated: Vernon Blvd → Flushing-Main St (lon > -73.96)
        if routeSet.contains("7") && lon > -73.96 {
            return .elevated
        }

        // ── J/Z line: elevated east of Williamsburg ──
        // Underground: Broad St → Marcy Av (lon < -73.95)
        // Elevated: Hewes St → Jamaica (lon > -73.95)
        if (routeSet.contains("J") || routeSet.contains("Z")) && lon > -73.95 {
            return .elevated
        }

        // ── N/W: elevated in Astoria ──
        // Elevated: 39 Av → Ditmars Blvd (lat > 40.76, lon > -73.935)
        if (routeSet.contains("N") || routeSet.contains("W"))
            && lat > 40.76 && lon > -73.935 {
            return .elevated
        }

        // ── IRT 2/5: elevated on White Plains Rd (Bronx) ──
        if (routeSet.contains("2") || routeSet.contains("5")) && lat > 40.815 {
            return .elevated
        }

        // ── IRT 4: elevated on Jerome Av (Bronx) ──
        if routeSet.contains("4") && lat > 40.825 {
            return .elevated
        }

        // ── IRT 6: elevated on Pelham line (Bronx) ──
        if routeSet.contains("6") && lat > 40.815 && lon > -73.89 {
            return .elevated
        }

        // ── IRT 1: elevated north of Dyckman St ──
        if routeSet.contains("1") && lat > 40.87 {
            return .elevated
        }

        // ── Brighton line open cut (south Brooklyn) ──
        if (routeSet.contains("B") || routeSet.contains("Q")) && lat < 40.59 {
            return .openCut
        }

        return .subway
    }

    // MARK: - Real-Time Structure Override

    /// Route IDs whose service is currently rerouted or suspended,
    /// meaning their normal physical infrastructure classification
    /// should be temporarily ignored.
    ///
    /// The MTA Mercury extension `alert_type` distinguishes operational
    /// impact levels.  We only flag alerts that alter WHERE a train
    /// physically runs — not simple delays or station skips:
    ///
    ///   Flagged:
    ///     "Planned - Reroute"         — running on different tracks
    ///     "Planned - Suspended"       — service suspended entirely
    ///     "Planned - Part Suspended"  — partial suspension
    ///
    ///   NOT flagged (normal ops):
    ///     "Delays"                    — slower but same tracks
    ///     "Planned - Stations Skipped"— same tracks, fewer stops
    ///     "Planned - Express to Local"— same structure, diff stops
    ///
    /// The set auto-clears when the backend's `active_period` filter
    /// drops the expired alert from `/alerts`.
    static func reroutedRouteIDs(from alerts: [TransitAlert]) -> Set<String> {
        var rerouted = Set<String>()
        for alert in alerts {
            guard alert.mode == "subway" else { continue }
            let type = (alert.alertType ?? "").lowercased()

            // Only reroutes and suspensions change physical infrastructure.
            guard type.contains("reroute") || type.contains("suspended") else {
                continue
            }

            for route in alert.affectedRoutes {
                rerouted.insert(route.uppercased())
            }
        }
        return rerouted
    }

    // MARK: - Complex Registry (JSON-loaded)

    /// Loaded once from `station_complexes.json`.  Maps GTFS stop ID →
    /// `StationComplexEntry`.  Only contains multi-level / multi-
    /// structure transfer complexes (~60 entries, ~20 complexes).
    static let complexTable: [String: StationComplexEntry] = loadComplexRegistry()

    // MARK: - Private Helpers

    /// Loads the complex registry from the bundled JSON file.
    /// Falls back to an empty dictionary if the file is missing or
    /// malformed — the app still works, just without complex grouping.
    private static func loadComplexRegistry() -> [String: StationComplexEntry] {
        guard let url = Bundle.main.url(
            forResource: "station_complexes", withExtension: "json"
        ) else {
            assertionFailure("station_complexes.json not found in bundle")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let registry = try JSONDecoder().decode(ComplexRegistryJSON.self, from: data)
            var table = [String: StationComplexEntry]()
            table.reserveCapacity(80)

            for complex in registry.complexes {
                for station in complex.stations {
                    let structure = StationStructure(rawValue: station.structure) ?? .subway
                    table[station.stop_id] = StationComplexEntry(
                        complexID: complex.id,
                        structure: structure
                    )
                }
            }
            return table
        } catch {
            assertionFailure("Failed to decode station_complexes.json: \(error)")
            return [:]
        }
    }

    /// Generates a stable unique complex ID for stations not in the
    /// curated complex registry.
    ///
    /// Uses FNV-1a 64-bit hash for deterministic, collision-resistant
    /// IDs.  Swift's `String.hashValue` is randomized per process,
    /// which caused different stations to collide on every launch —
    /// merging e.g. Bedford Av + 238 St and placing the centroid in
    /// the East River.  FNV-1a with a 2-billion-bucket range makes
    /// collisions statistically impossible for ~500 stations.
    private static func defaultComplexID(for stationID: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037          // FNV offset basis
        for byte in stationID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211                          // FNV prime
        }
        return 10_000 + Int(hash & 0x7FFF_FFFF)                // ~2.1 billion buckets
    }
}
