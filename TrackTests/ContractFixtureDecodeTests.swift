//
//  ContractFixtureDecodeTests.swift
//  TrackTests
//
//  Heavy iOS↔backend contract test: loads real backend response
//  fixtures captured by `TrackBackend/scripts/capture_contract_fixtures.py`
//  and decodes each one through the real iOS Codable models.
//
//  Why: the Pydantic↔Swift drift detector
//  (`tests/test_field_drift_swift_pydantic.py`) catches *schema* drift
//  statically. This test catches the runtime cases that static
//  inspection cannot: field-level type mismatches, real-world null
//  values, optional-vs-required, date format drift, etc. Every endpoint
//  the iOS app decodes through `TrackAPI` is exercised here against an
//  actual response captured from the running backend.
//
//  To refresh fixtures:
//      cd TrackBackend
//      .venv/bin/python scripts/capture_contract_fixtures.py
//
//  The test is silently skipped (with a console warning) if no
//  fixtures have been captured yet, so CI doesn't go red on a fresh
//  clone.
//

import Foundation
import Testing
@testable import Track

// MARK: - Manifest model

private struct FixtureManifest: Decodable {
    struct Entry: Decodable {
        let slug: String
        let path: String
        let url: String?
        let status: Int
        let swiftType: String
        let fixtureFile: String?
        let skipped: Bool
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case slug
            case path
            case url
            case status
            case swiftType = "swift_type"
            case fixtureFile = "fixture_file"
            case skipped
            case reason
        }
    }
    let entries: [Entry]

    enum CodingKeys: String, CodingKey { case entries }
}

// MARK: - Fixture location

/// Absolute path to the fixtures directory, resolved at compile time
/// from this source file's location. Works regardless of bundle layout
/// because XCTest binaries always keep `#filePath` pointing at the
/// source-tree path on local/CI runs.
private let fixtureDirectory: URL = {
    let here = URL(fileURLWithPath: #filePath)
    return here
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("Contract", isDirectory: true)
}()

private let manifestURL = fixtureDirectory.appendingPathComponent("manifest.json")

// MARK: - Decoder (matches `TrackAPI.decoder` semantics)

/// A decoder configured identically to `TrackAPI.decoder` so this test
/// catches every drift the production decoder would hit. Keep in sync
/// with `Track/Network/TrackAPI.swift`.
private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    let isoFull = ISO8601DateFormatter()
    isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoBase = ISO8601DateFormatter()
    isoBase.formatOptions = [.withInternetDateTime]
    d.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if let date = isoFull.date(from: str) { return date }
        if let date = isoBase.date(from: str) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Cannot decode date: \(str)"
        )
    }
    return d
}

// MARK: - Type-erased decoder dispatch

/// Maps a `swift_type` manifest string (e.g. "[TransitArrivalResponse]")
/// to a closure that decodes the JSON through the *real* iOS type.
///
/// When you add a new endpoint to
/// `capture_contract_fixtures.py::ENDPOINTS`, also add a case here.
/// A missing case fails the test loudly so the contract harness can't
/// silently skip new payloads.
private func decode(swiftType: String, data: Data, decoder: JSONDecoder) throws {
    switch swiftType {
    // Subway
    case "[TransitArrivalResponse]":
        _ = try decoder.decode([TransitArrivalResponse].self, from: data)
    case "AllSubwayLinesResponse":
        _ = try decoder.decode(AllSubwayLinesResponse.self, from: data)
    case "AllSubwayStationsResponse":
        _ = try decoder.decode(AllSubwayStationsResponse.self, from: data)
    case "ProcessedStationsResponse":
        _ = try decoder.decode(ProcessedStationsResponse.self, from: data)
    case "RouteShapeResponse":
        _ = try decoder.decode(RouteShapeResponse.self, from: data)
    case "[TrainVehicle]":
        _ = try decoder.decode([TrainVehicle].self, from: data)
    case "[LiveVehicleDetailResponse]":
        _ = try decoder.decode([LiveVehicleDetailResponse].self, from: data)
    // Bus
    case "[BusRoute]":
        _ = try decoder.decode([BusRoute].self, from: data)
    case "[BusStop]":
        _ = try decoder.decode([BusStop].self, from: data)
    case "[BusArrival]":
        _ = try decoder.decode([BusArrival].self, from: data)
    case "[BusVehicleResponse]":
        _ = try decoder.decode([BusVehicleResponse].self, from: data)
    case "BusScheduleResponse":
        _ = try decoder.decode(BusScheduleResponse.self, from: data)
    case "BusTileDataResponse":
        _ = try decoder.decode(BusTileDataResponse.self, from: data)
    // Commuter rail
    case "AllCommuterRailLinesResponse":
        _ = try decoder.decode(AllCommuterRailLinesResponse.self, from: data)
    // Nearby
    case "[NearbyTransitResponse]":
        _ = try decoder.decode([NearbyTransitResponse].self, from: data)
    case "[GroupedNearbyTransitResponse]":
        _ = try decoder.decode([GroupedNearbyTransitResponse].self, from: data)
    case "[InactiveRouteResponse]":
        _ = try decoder.decode([InactiveRouteResponse].self, from: data)
    // System
    case "__rawJSON__":
        // iOS consumes this payload as a raw `[String: Any]` dictionary;
        // we only need to confirm it parses.
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    case "[TransitAlert]":
        _ = try decoder.decode([TransitAlert].self, from: data)
    case "[ElevatorStatus]":
        _ = try decoder.decode([ElevatorStatus].self, from: data)
    case "DelayPrediction":
        _ = try decoder.decode(DelayPrediction.self, from: data)
    default:
        Issue.record(
            "Unknown swift_type '\(swiftType)' in manifest — add a case to `decode(swiftType:)`."
        )
    }
}

// MARK: - Tests

@Suite("Contract: backend fixture decode")
struct ContractFixtureDecodeTests {

    /// Decode every captured fixture through the real iOS Codable type.
    /// One sub-test per fixture so failures pinpoint the exact endpoint.
    @Test
    func decodeAllCapturedFixtures() throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            // No fixtures captured yet — leave a clear note so devs know
            // how to populate them, but don't fail the suite (CI without
            // a backend running shouldn't go red).
            print("""
            ⚠️  ContractFixtureDecodeTests skipped: no manifest.json at
                \(manifestURL.path)
                Capture fixtures with:
                    cd TrackBackend && .venv/bin/python scripts/capture_contract_fixtures.py
            """)
            return
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: manifestData)
        let decoder = makeDecoder()

        var attempted = 0
        var skipped: [String] = []
        var failures: [(slug: String, error: Error)] = []

        for entry in manifest.entries {
            if entry.skipped || entry.fixtureFile == nil {
                skipped.append("\(entry.slug) (\(entry.reason ?? "skipped"))")
                continue
            }
            let url = fixtureDirectory.appendingPathComponent(entry.fixtureFile!)
            guard let data = try? Data(contentsOf: url) else {
                failures.append((entry.slug, NSError(
                    domain: "ContractFixtureDecodeTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "fixture file missing on disk: \(url.path)"]
                )))
                continue
            }
            attempted += 1
            do {
                try decode(swiftType: entry.swiftType, data: data, decoder: decoder)
            } catch {
                failures.append((entry.slug, error))
            }
        }

        if !failures.isEmpty {
            let lines = failures.map { failure -> String in
                "  • \(failure.slug): \(prettyDecodeError(failure.error))"
            }
            Issue.record(
                """
                Contract decode failed for \(failures.count) of \(attempted) fixtures:
                \(lines.joined(separator: "\n"))
                """
            )
        }

        if attempted == 0 {
            print("⚠️  ContractFixtureDecodeTests: 0 fixtures decoded; \(skipped.count) skipped.")
        } else {
            print("✅ ContractFixtureDecodeTests: \(attempted) fixtures decoded; \(skipped.count) skipped.")
        }
    }
}

// MARK: - Pretty errors

private func prettyDecodeError(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else {
        return "\(error)"
    }
    switch decodingError {
    case .keyNotFound(let key, let ctx):
        return "keyNotFound '\(key.stringValue)' at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
    case .typeMismatch(let type, let ctx):
        return "typeMismatch \(type) at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
    case .valueNotFound(let type, let ctx):
        return "valueNotFound \(type) at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
    case .dataCorrupted(let ctx):
        return "dataCorrupted at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
    @unknown default:
        return "\(decodingError)"
    }
}

private func pathString(_ path: [CodingKey]) -> String {
    if path.isEmpty { return "<root>" }
    return path.map { key in
        if let i = key.intValue { return "[\(i)]" }
        return key.stringValue
    }.joined(separator: ".")
}
