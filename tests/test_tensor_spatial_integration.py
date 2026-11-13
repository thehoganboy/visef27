# tests/test_tensor_spatial_integration.py
# HorusEyes 2.0 — End-to-End Spatial Decision Integration Tests (P0-04)
# Verifies: Known Disparity Tensor -> SpatialBin Extraction -> Candidate Eligibility -> Directional State

import os
import sys
import math
import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from depth_engine import compute_spatial_bins, ObstacleDetectionResult, SingleObstacle
from directional_advisory import estimate_directional_advisory, advisory_for_risk


def create_base_tensor(h=256, w=192, fill_val=200.0):
    """Creates a base disparity tensor representing clear space (~200cm distance)."""
    return np.full((h, w), fill_val, dtype=np.float32)


def test_01_open_central_corridor():
    """1. Open central region: unobstructed forward path."""
    tensor = create_base_tensor(fill_val=180.0)
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    assert len(bins) == 24
    assert all(b.is_valid for b in bins)
    
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.0, dist_cm=220.0,
        mode_text="SAFE", uncertainty_score=0.05, is_wall=False,
        sector_dists={"LEFT": 220.0, "CENTER": 220.0, "RIGHT": 220.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    assert adv.state == "AVAILABLE"
    assert abs(adv.angle_deg) <= 2.0


def test_02_near_sidewalls():
    """2. Near sidewalls: high disparity on left and right, clear center passage."""
    tensor = create_base_tensor(fill_val=180.0)
    # Left wall (cols 0..50) ~25cm (raw disparity 750)
    tensor[:, :50] = 750.0
    # Right wall (cols 142..192) ~25cm
    tensor[:, 142:] = 750.0
    
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.2, dist_cm=200.0,
        mode_text="DOORWAY", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 28.0, "CENTER": 200.0, "RIGHT": 28.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    assert adv.state == "AVAILABLE"
    assert abs(adv.angle_deg) <= 2.5


def test_03_narrow_opening_below_clearance():
    """3. Narrow opening: gap narrower than human shoulder envelope (e.g. 10 pixels wide)."""
    tensor = np.full((256, 192), 750.0, dtype=np.float32) # completely blocked
    # Narrow slot of only 8 pixels at center
    tensor[:, 92:100] = 180.0
    
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.9, dist_cm=28.0,
        mode_text="WALL", uncertainty_score=0.1, is_wall=True,
        sector_dists={"LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="CRITICAL", now=10.0)
    assert adv.state == "STOP"


def test_04_central_near_obstruction():
    """4. Central near obstruction: obstacle at center (55cm), sides clear."""
    tensor = create_base_tensor(fill_val=180.0)
    # Center block cols 72..120 high disparity ~55cm (raw 600)
    tensor[51:166, 72:120] = 600.0
    
    obs_item = SingleObstacle(
        id=1, x=96, y=108, bbox=(72, 51, 48, 115), pan=0.0, proximity=0.7,
        dist_cm=55.0, mode_text="OBSTACLE", uncertainty_score=0.1, is_wall=False
    )
    bins = compute_spatial_bins(tensor, w=192, h=256, detected_list=[obs_item], num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=108, bbox=obs_item.bbox, pan=0.0, proximity=0.7, dist_cm=55.0,
        mode_text="OBSTACLE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 200.0, "CENTER": 55.0, "RIGHT": 200.0},
        all_obstacles=[obs_item], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    setattr(obs, "cam_width", 192)
    adv = estimate_directional_advisory(obs, threat="WARNING", now=10.0)
    assert adv.state == "AVAILABLE"
    # Must steer away from center
    assert abs(adv.angle_deg) >= 5.0


def test_05_invalid_outer_bins():
    """5. Invalid outer bins: edge distortion/NaNs, center clear."""
    tensor = create_base_tensor(fill_val=180.0)
    # NaNs on edges
    tensor[:, :24] = np.nan
    tensor[:, 168:] = np.nan
    
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    # Outer bins invalid
    assert not bins[0].is_valid
    assert not bins[23].is_valid
    # Center bins valid
    assert bins[11].is_valid and bins[12].is_valid
    
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.0, dist_cm=200.0,
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": None, "CENTER": 200.0, "RIGHT": None},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    assert adv.state == "AVAILABLE"
    assert abs(adv.angle_deg) <= 2.0


def test_06_invalid_central_bins():
    """6. Invalid central bins: central region NaN/unknown -> UNAVAILABLE."""
    tensor = create_base_tensor(fill_val=180.0)
    # Center columns NaN
    tensor[:, 72:120] = np.nan
    
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    assert not bins[11].is_valid
    assert not bins[12].is_valid
    
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.0, dist_cm=None,
        mode_text="UNKNOWN", uncertainty_score=0.9, is_wall=False,
        sector_dists={"LEFT": 200.0, "CENTER": None, "RIGHT": 200.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    assert adv.state == "UNAVAILABLE"


def test_07_upper_hazard_multi_band():
    """7. Upper obstacle: high disparity in overhead band [0.0, 0.20h], body clear."""
    tensor = create_base_tensor(fill_val=180.0)
    # Top 40 rows high disparity ~40cm (raw 650)
    tensor[:40, :] = 650.0
    
    obs_item = SingleObstacle(
        id=1, x=96, y=20, bbox=(30, 0, 132, 40), pan=0.0, proximity=0.8,
        dist_cm=40.0, mode_text="OVERHEAD", uncertainty_score=0.1, is_wall=False
    )
    bins = compute_spatial_bins(tensor, w=192, h=256, detected_list=[obs_item], num_bins=24)
    # Verify overhead band populated with near distance
    assert any(b.overhead_dist_cm < 60.0 for b in bins if not math.isnan(b.overhead_dist_cm))
    
    obs = ObstacleDetectionResult(
        x=96, y=20, bbox=obs_item.bbox, pan=0.0, proximity=0.8, dist_cm=40.0,
        mode_text="OVERHEAD", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 40.0, "CENTER": 40.0, "RIGHT": 40.0},
        all_obstacles=[obs_item], is_valid=True, overhead_hazard=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="CRITICAL", now=10.0)
    assert adv.state == "STOP"


def test_08_low_obstruction_multi_band():
    """8. Low ground obstacle: high disparity in ground band [0.65h, 0.85h]."""
    tensor = create_base_tensor(fill_val=180.0)
    # Ground band (rows 166..217) high disparity ~30cm
    tensor[166:217, 72:120] = 700.0
    
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    # Verify ground band caught the low hazard
    assert any(b.ground_dist_cm < 50.0 for b in bins if not math.isnan(b.ground_dist_cm))


def test_09_partly_visible_lateral_object():
    """9. Partly visible lateral obstacle at frame edge."""
    tensor = create_base_tensor(fill_val=180.0)
    tensor[51:166, 160:] = 600.0 # right edge obstacle ~55cm
    
    obs_item = SingleObstacle(
        id=1, x=176, y=108, bbox=(160, 51, 32, 115), pan=0.8, proximity=0.6,
        dist_cm=55.0, mode_text="OBSTACLE", uncertainty_score=0.15, is_wall=False
    )
    bins = compute_spatial_bins(tensor, w=192, h=256, detected_list=[obs_item], num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.3, dist_cm=180.0,
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 200.0, "CENTER": 180.0, "RIGHT": 55.0},
        all_obstacles=[obs_item], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="WARNING", now=10.0)
    assert adv.state == "AVAILABLE"
    # Steering should stay within safe corridor bounds
    assert abs(adv.angle_deg) <= 15.0


def test_10_entirely_invalid_tensor():
    """10. Entirely invalid tensor: all zeros / NaNs -> UNAVAILABLE."""
    tensor = np.full((256, 192), np.nan, dtype=np.float32)
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    assert all(not b.is_valid for b in bins)
    
    obs = ObstacleDetectionResult(
        x=0, y=0, bbox=(0, 0, 0, 0), pan=0.0, proximity=0.0, dist_cm=None,
        mode_text="FAULT", uncertainty_score=1.0, is_wall=False,
        sector_dists={}, all_obstacles=[], is_valid=False, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SENSOR_FAULT", now=10.0)
    assert adv.state == "UNKNOWN"


def test_11_low_light_corridor_below_150cm():
    """11. Low-light corridor (e.g. 110cm clearance) must be AVAILABLE, not UNAVAILABLE."""
    tensor = create_base_tensor(fill_val=220.0) # ~110cm distance
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.2, dist_cm=110.0,
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 110.0, "CENTER": 110.0, "RIGHT": 110.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    assert adv.state == "AVAILABLE"
    assert adv.reason_code == "AVAILABLE_FORWARD"
    assert abs(adv.angle_deg) <= 2.5


def test_12_reason_codes_and_stale_rejection():
    """12. Test diagnostic reason codes and stale frame rejection (>750ms)."""
    # Stale observation
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.2, dist_cm=110.0,
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 110.0, "CENTER": 110.0, "RIGHT": 110.0},
        all_obstacles=[], is_valid=True, spatial_bins=[], timestamp=10.0
    )
    adv_stale = estimate_directional_advisory(obs, threat="SAFE", now=11.0)
    assert adv_stale.state == "UNAVAILABLE"
    assert adv_stale.reason_code == "SOURCE_FRAME_STALE"

    # Emergency stop advisory
    adv_stop = advisory_for_risk("CRITICAL", 10.0)
    assert adv_stop.state == "STOP"
    assert adv_stop.reason_code == "CRITICAL_OBSTACLE"
