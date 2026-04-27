"""Tests for OpenAPI-visible static/offline data metadata."""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_data_status_includes_offline_static_metadata():
    response = client.get("/data/status")
    assert response.status_code == 200
    data = response.json()

    assert "offline_static_data" in data
    offline = data["offline_static_data"]
    assert offline["source_of_truth"] == "MTA static GTFS and NYS/MTA Open Data"
    assert "generated_at" in offline
    assert offline["groups"]

    subway_core = next(
        group for group in offline["groups"]
        if group["description"] == "Subway shapes, trips, stops, shape_stops.json"
    )
    assert subway_core["available"] is True
    assert subway_core["last_materialized_at"] is not None
    assert {file["path"] for file in subway_core["files"]} >= {
        "shapes.txt",
        "trips.txt",
        "shape_stops.json",
    }


def test_openapi_documents_data_status_metadata():
    schema = app.openapi()
    description = schema["paths"]["/data/status"]["get"]["description"]
    assert "offline-data metadata" in description
    assert "MTA Last-Modified" in description