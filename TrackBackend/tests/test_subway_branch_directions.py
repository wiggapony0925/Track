from __future__ import annotations

from app.services.mapping.subway import shapes


def _stop(stop_id: str, name: str, sequence: int) -> shapes.RouteStopEntry:
    return shapes.RouteStopEntry(
        stop_id=stop_id,
        name=name,
        lat=40.0 + sequence / 1000,
        lon=-73.0 - sequence / 1000,
        sequence=sequence,
    )


def test_subway_shape_directions_split_branches_by_headsign(monkeypatch):
    monkeypatch.setattr(
        shapes,
        "_load_route_shapes",
        lambda: {"A": {0: ["inwood"], 1: ["far_rock", "lefferts"]}},
    )
    monkeypatch.setattr(
        shapes,
        "_load_shapes",
        lambda: {
            "inwood": b"inwood",
            "far_rock": b"far_rock",
            "lefferts": b"lefferts",
        },
    )
    monkeypatch.setattr(
        shapes,
        "_unpack_coords",
        lambda buf: {
            b"inwood": [(40.0, -73.0), (40.1, -73.1)],
            b"far_rock": [(40.2, -73.2), (40.3, -73.3)],
            b"lefferts": [(40.4, -73.4), (40.5, -73.5)],
        }[buf],
    )
    monkeypatch.setattr(
        shapes,
        "_load_direction_headsigns",
        lambda: {"A": {0: "Inwood-207 St", 1: "Far Rockaway-Mott Av"}},
    )
    monkeypatch.setattr(
        shapes,
        "_load_shape_headsigns",
        lambda: {
            "A": {
                0: {"inwood": "Inwood-207 St"},
                1: {
                    "far_rock": "Far Rockaway-Mott Av",
                    "lefferts": "Ozone Park-Lefferts Blvd",
                },
            }
        },
    )
    monkeypatch.setattr(
        shapes,
        "_get_stops_for_shape",
        lambda shape_id: tuple(
            {
                "inwood": [_stop("A02N", "Inwood-207 St", 1)],
                "far_rock": [_stop("H11S", "Far Rockaway-Mott Av", 2)],
                "lefferts": [_stop("A65S", "Ozone Park-Lefferts Blvd", 3)],
            }[shape_id]
        ),
    )

    result = shapes.get_subway_route_shape("A")

    assert result is not None
    polylines, stops, directions = result
    assert len(polylines) == 3
    assert {stop.name for stop in stops} == {
        "Inwood-207 St",
        "Far Rockaway-Mott Av",
        "Ozone Park-Lefferts Blvd",
    }
    assert [(d.direction_id, d.headsign) for d in directions] == [
        (0, "Inwood-207 St"),
        (1, "Far Rockaway-Mott Av"),
        (1, "Ozone Park-Lefferts Blvd"),
    ]
    assert all(len(d.polylines) == 1 for d in directions)
    assert all(len(d.stops) == 1 for d in directions)


def test_subway_shape_direction_falls_back_to_direction_headsign(monkeypatch):
    monkeypatch.setattr(shapes, "_load_route_shapes", lambda: {"Q": {0: ["north"]}})
    monkeypatch.setattr(shapes, "_load_shapes", lambda: {"north": b"north"})
    monkeypatch.setattr(
        shapes,
        "_unpack_coords",
        lambda buf: [(40.0, -73.0), (40.1, -73.1)],
    )
    monkeypatch.setattr(
        shapes,
        "_load_direction_headsigns",
        lambda: {"Q": {0: "96 St"}},
    )
    monkeypatch.setattr(shapes, "_load_shape_headsigns", lambda: {"Q": {0: {}}})
    monkeypatch.setattr(
        shapes,
        "_get_stops_for_shape",
        lambda shape_id: (_stop("Q05N", "96 St", 1),),
    )

    result = shapes.get_subway_route_shape("Q")

    assert result is not None
    _, _, directions = result
    assert len(directions) == 1
    assert directions[0].headsign == "96 St"
    assert directions[0].direction_id == 0
