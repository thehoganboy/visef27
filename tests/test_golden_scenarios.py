"""Cross-platform golden directional scenario test suite for Python (Directive Section 6)."""
import json
import math
import os
import sys
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from directional_advisory import estimate_directional_advisory, DirectionState
from depth_engine import SpatialBin, SingleObstacle, ObstacleDetectionResult


def load_scenarios():
    path = os.path.join(os.path.dirname(__file__), "golden_directional_scenarios.json")
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return data["scenarios"]


@pytest.mark.parametrize("scenario", load_scenarios(), ids=lambda s: f"Scenario_{s['id']:02d}_{s['name'].replace(' ', '_')}")
def test_golden_directional_scenario(scenario):
    bins = []
    for b in scenario.get("spatial_bins", []):
        dist = b["dist_cm"]
        dist_val = float("nan") if dist is None else float(dist)
        bins.append(SpatialBin(
            bin_id=b["bin_id"],
            angle_min=b["angle_min"],
            angle_max=b["angle_max"],
            angle_center=b["angle_center"],
            valid_ratio=b["valid_ratio"],
            depth_raw_p80=250.0 if b["is_valid"] else float("nan"),
            dist_cm=dist_val,
            is_valid=b["is_valid"],
            has_obstacle=b.get("has_obstacle", False)
        ))

    obstacles = []
    for o in scenario.get("all_obstacles", []):
        bbox = tuple(o["bbox"])
        obstacles.append(SingleObstacle(
            id=o["id"],
            x=o["x"],
            y=o["y"],
            bbox=bbox,
            pan=o["pan"],
            proximity=o["proximity"],
            dist_cm=o["dist_cm"],
            mode_text=o["mode_text"],
            uncertainty_score=o["uncertainty_score"],
            is_wall=o["is_wall"]
        ))

    obs = ObstacleDetectionResult(
        x=scenario["cam_width"] // 2,
        y=scenario["cam_height"] // 2,
        bbox=(scenario["cam_width"] // 4, scenario["cam_height"] // 4, scenario["cam_width"] // 2, scenario["cam_height"] // 2),
        pan=0.0,
        proximity=0.5,
        dist_cm=scenario["sector_dists"].get("CENTER") or 200.0,
        mode_text="TEST",
        uncertainty_score=0.1,
        is_wall=False,
        sector_dists=scenario["sector_dists"],
        all_obstacles=obstacles,
        is_valid=scenario["is_valid"],
        spatial_bins=bins
    )
    setattr(obs, "timestamp", scenario["obs_timestamp"])
    setattr(obs, "cam_width", scenario["cam_width"])
    setattr(obs, "cam_height", scenario["cam_height"])

    adv = estimate_directional_advisory(
        observation=obs,
        threat=scenario["threat"],
        now=scenario["now"],
        hfov_deg=scenario["hfov_deg"],
        prev_angle=scenario.get("prev_angle")
    )

    expected = scenario["expected"]
    assert adv.state.value == expected["state"], f"State mismatch for scenario {scenario['id']}: expected {expected['state']}, got {adv.state.value}"

    if expected["state"] == "AVAILABLE":
        assert adv.angle_deg is not None, f"Expected angle for AVAILABLE state in scenario {scenario['id']}"
        sign = expected["direction_sign"]
        if sign == "FORWARD":
            assert abs(adv.angle_deg) <= 2.0, f"Scenario {scenario['id']} expected FORWARD, got {adv.angle_deg}"
        elif sign == "LEFT":
            assert adv.angle_deg < 0.0, f"Scenario {scenario['id']} expected LEFT, got {adv.angle_deg}"
        elif sign == "RIGHT":
            assert adv.angle_deg > 0.0, f"Scenario {scenario['id']} expected RIGHT, got {adv.angle_deg}"

        if expected.get("angle_range") is not None:
            min_a, max_a = expected["angle_range"]
            assert min_a <= adv.angle_deg <= max_a, f"Scenario {scenario['id']} angle {adv.angle_deg} outside range [{min_a}, {max_a}]"
    else:
        assert adv.angle_deg is None, f"Scenario {scenario['id']} non-AVAILABLE state must have None angle, got {adv.angle_deg}"
