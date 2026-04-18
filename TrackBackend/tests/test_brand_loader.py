from __future__ import annotations

import importlib
import json
from pathlib import Path


def _reload_brand_with_config_dir(config_dir: Path):
    import app.utils.brand as brand

    brand.os.environ["TRACK_CONFIG_DIR"] = str(config_dir)
    return importlib.reload(brand)


def test_brand_loader_uses_fallback_without_missing_entries_warning(
    tmp_path: Path,
) -> None:
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    source = Path(__file__).resolve().parents[2] / "config" / "brand_colors.json"
    (config_dir / "brand_colors.json").write_text(source.read_text())

    brand = _reload_brand_with_config_dir(config_dir)

    try:
        assert brand.subway_color("A") == "#0062CF"
        assert brand.subway_color("7") == "#9A38A1"
        assert brand._colors_path == config_dir / "brand_colors.json"
        assert brand._missing_subway_color_keys == []
    finally:
        brand.os.environ.pop("TRACK_CONFIG_DIR", None)
        importlib.reload(brand)


def test_brand_loader_warns_when_file_exists_but_is_incomplete(
    tmp_path: Path,
) -> None:
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    (config_dir / "brand_colors.json").write_text(
        json.dumps({"subway": {"A": "#123456"}})
    )

    brand = _reload_brand_with_config_dir(config_dir)

    try:
        assert brand.subway_color("A") == "#123456"
        assert brand._colors_path == config_dir / "brand_colors.json"
        assert len(brand._missing_subway_color_keys) == 33
    finally:
        brand.os.environ.pop("TRACK_CONFIG_DIR", None)
        importlib.reload(brand)