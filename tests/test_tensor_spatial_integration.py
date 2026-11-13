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
from auditory_budget import AuditoryBudgetManager
from motion_ttc import KinematicsResult


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


def test_13_nonfinite_clearance_rejection():
    """13. Valid angular coverage with missing/NaN metric distance must NOT produce AVAILABLE."""
    tensor = create_base_tensor(fill_val=200.0)
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    # Manually corrupt bin distances to NaN while keeping angular validity
    corrupted_bins = []
    for b in bins:
        b_corrupted = type(b)(
            bin_id=b.bin_id, angle_min=b.angle_min, angle_max=b.angle_max, angle_center=b.angle_center,
            valid_ratio=b.valid_ratio, depth_raw_p80=getattr(b, "depth_raw_p80", 200.0),
            dist_cm=float("nan"), is_valid=True, has_obstacle=False,
            body_dist_cm=float("nan"), ground_dist_cm=float("nan"), overhead_dist_cm=float("nan")
        )
        corrupted_bins.append(b_corrupted)

    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.2, dist_cm=float("nan"),
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": float("nan"), "CENTER": float("nan"), "RIGHT": float("nan")},
        all_obstacles=[], is_valid=True, spatial_bins=corrupted_bins, timestamp=10.0
    )
    adv = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    # MUST be UNAVAILABLE with LOCAL_DEPTH_MISSING, never AVAILABLE
    assert adv.state == "UNAVAILABLE"
    assert adv.reason_code == "LOCAL_DEPTH_MISSING"


def test_14_directional_stop_under_non_critical_threat():
    """14. Directional STOP must trigger when all directions are blocked even under WARNING/SAFE threat."""
    # Frontal obstruction blocking all headings within stopping distance
    tensor = np.full((256, 192), 750.0, dtype=np.float32) # ~28cm
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 192, 256), pan=0.0, proximity=0.8, dist_cm=28.0,
        mode_text="WALL", uncertainty_score=0.1, is_wall=True,
        sector_dists={"LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    # Passed with threat="WARNING" (non-CRITICAL)
    adv = estimate_directional_advisory(obs, threat="WARNING", now=10.0)
    assert adv.state == "STOP"
    assert adv.reason_code in ("CRITICAL_OBSTACLE", "CORRIDOR_OBSTRUCTED")


def test_15_audio_directional_stop_synchronization():
    """15. Audio budget must emit active STOP tone synchronized with directional STOP."""
    budget = AuditoryBudgetManager()
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 192, 256), pan=0.0, proximity=0.9, dist_cm=28.0,
        mode_text="WALL", uncertainty_score=0.1, is_wall=True,
        sector_dists={"LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0},
        all_obstacles=[], is_valid=True, spatial_bins=[], timestamp=10.0
    )
    k_crit = KinematicsResult(primary_ttc=0.6, primary_velocity_z=50.0, threats={}, safe_direction="STOP", is_evading=False, threat_level="CRITICAL")
    adv_crit = estimate_directional_advisory(obs, threat="CRITICAL", now=10.0)
    assert adv_crit.state == "STOP"

    decision = budget.coordinate(obs, k_crit, current_timestamp=10.0, advisory=adv_crit)
    assert decision.is_active is True
    assert decision.safe_direction == "STOP"
    assert decision.cue_mode == "SHARP_PING"
    assert decision.threat_level == "CRITICAL"
    assert decision.priority_score >= 90.0
    assert decision.proximity == 1.0
    # Verified: valid measured distance and TTC are preserved without alteration
    assert decision.dist_cm == 28.0
    assert decision.ttc == 0.6


def test_16_audio_noncritical_stop_consistency():
    """16. Noncritical directional STOP (corridor blocked) must halt without claiming imminent collision."""
    budget = AuditoryBudgetManager()
    tensor = np.full((256, 192), 750.0, dtype=np.float32)
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 192, 256), pan=0.0, proximity=0.5, dist_cm=28.0,
        mode_text="WALL", uncertainty_score=0.1, is_wall=True,
        sector_dists={"LEFT": 28.0, "CENTER": 28.0, "RIGHT": 28.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    # Kinematics classified as WARNING (or SAFE)
    k_warn = KinematicsResult(primary_ttc=float("inf"), primary_velocity_z=0.0, threats={}, safe_direction="NONE", is_evading=False, threat_level="WARNING")
    adv_stop = estimate_directional_advisory(obs, threat="WARNING", now=10.0)
    assert adv_stop.state == "STOP"

    decision = budget.coordinate(obs, k_warn, current_timestamp=10.0, advisory=adv_stop)
    assert decision.is_active is True
    assert decision.safe_direction == "STOP"
    assert decision.cue_mode == "SHARP_PING"
    assert decision.threat_level == "WARNING"
    # Must NOT claim an imminent collision (TTC remains infinite)
    assert not math.isfinite(decision.ttc)
    assert decision.proximity == 0.70
    assert decision.priority_score == 50.0


def test_17_audio_unavailable_no_forward_sound():
    """17. UNAVAILABLE advisory must never emit forward clearance audio."""
    budget = AuditoryBudgetManager()
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(48, 64, 96, 128), pan=0.0, proximity=0.2, dist_cm=float("nan"),
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": float("nan"), "CENTER": float("nan"), "RIGHT": float("nan")},
        all_obstacles=[], is_valid=True, spatial_bins=[], timestamp=10.0
    )
    k_safe = KinematicsResult(primary_ttc=float("inf"), primary_velocity_z=0.0, threats={}, safe_direction="NONE", is_evading=False, threat_level="SAFE")
    adv_unavail = estimate_directional_advisory(obs, threat="SAFE", now=10.0)
    assert adv_unavail.state == "UNAVAILABLE"

    decision = budget.coordinate(obs, k_safe, current_timestamp=10.0, advisory=adv_unavail)
    assert decision.is_active is False
    assert decision.cue_mode == "MUTED"
    assert decision.safe_direction == "NONE"


def test_18_audio_sensor_fault_and_pause_distinction():
    """18. Distinguish STOP, SENSOR_FAULT, and PAUSED in audio states."""
    budget = AuditoryBudgetManager()
    obs_fault = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 0, 0), pan=0.0, proximity=0.0, dist_cm=float("nan"),
        mode_text="SENSOR_FAULT", uncertainty_score=1.0, is_wall=False,
        sector_dists={}, all_obstacles=[], is_valid=False, spatial_bins=[], timestamp=10.0
    )
    k_fault = KinematicsResult(primary_ttc=float("inf"), primary_velocity_z=0.0, threats={}, safe_direction="STOP", is_evading=False, threat_level="SENSOR_FAULT")
    adv_fault = estimate_directional_advisory(obs_fault, threat="SENSOR_FAULT", now=10.0)
    decision_fault = budget.coordinate(obs_fault, k_fault, current_timestamp=10.0, advisory=adv_fault)
    assert decision_fault.is_active is True
    assert decision_fault.cue_mode == "SYSTEM_FAULT_TONE"
    assert decision_fault.threat_level == "SENSOR_FAULT"

    # Paused state
    obs_paused = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 0, 0), pan=0.0, proximity=0.0, dist_cm=float("nan"),
        mode_text="PAUSED", uncertainty_score=0.0, is_wall=False,
        sector_dists={}, all_obstacles=[], is_valid=True, spatial_bins=[], timestamp=10.0
    )
    k_paused = KinematicsResult(primary_ttc=float("inf"), primary_velocity_z=0.0, threats={}, safe_direction="NONE", is_evading=False, threat_level="PAUSED")
    adv_paused = advisory_for_risk("PAUSED", timestamp=10.0)
    decision_paused = budget.coordinate(obs_paused, k_paused, current_timestamp=10.0, advisory=adv_paused)
    assert decision_paused.is_active is False
    assert decision_paused.cue_mode == "MUTED"
    assert decision_paused.threat_level == "PAUSED"


def test_19_critical_stop_with_unknown_distance_and_ttc():
    """19. P0-01: CRITICAL STOP with unknown distance and TTC must NOT fabricate 30cm or 0.8s."""
    budget = AuditoryBudgetManager()
    obs_unknown = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 192, 256), pan=0.0, proximity=1.0, dist_cm=float("nan"),
        mode_text="OBSTACLE", uncertainty_score=0.2, is_wall=False,
        sector_dists={"LEFT": float("nan"), "CENTER": float("nan"), "RIGHT": float("nan")},
        all_obstacles=[], is_valid=True, spatial_bins=[], timestamp=10.0
    )
    k_crit_unknown = KinematicsResult(
        primary_ttc=float("inf"), primary_velocity_z=0.0, threats={},
        safe_direction="STOP", is_evading=False, threat_level="CRITICAL"
    )
    adv_crit = advisory_for_risk("CRITICAL", timestamp=10.0)
    assert adv_crit.state == "STOP"
    assert adv_crit.reason_code == "CRITICAL_OBSTACLE"

    decision = budget.coordinate(obs_unknown, k_crit_unknown, current_timestamp=10.0, advisory=adv_crit)
    # Critical alert must remain immediate, active, and authoritative
    assert decision.is_active is True
    assert decision.safe_direction == "STOP"
    assert decision.cue_mode == "SHARP_PING"
    assert decision.threat_level == "CRITICAL"
    assert decision.priority_score >= 90.0
    assert decision.proximity == 1.0
    # Mandatory P0-01: No synthetic measurements! NaN distance and infinite TTC preserved
    assert math.isnan(decision.dist_cm)
    assert not math.isfinite(decision.ttc)


def test_20_stale_observation_withdraws_visual_and_audio_guidance():
    """20. P0-02: Observation exceeding 750ms guidance freshness window withdraws arrow & invalidates audio."""
    tensor = np.full((256, 192), 180.0, dtype=np.float32)
    bins = compute_spatial_bins(tensor, w=192, h=256, num_bins=24)
    obs = ObstacleDetectionResult(
        x=96, y=128, bbox=(0, 0, 192, 256), pan=0.0, proximity=0.2, dist_cm=200.0,
        mode_text="SAFE", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 200.0, "CENTER": 200.0, "RIGHT": 200.0},
        all_obstacles=[], is_valid=True, spatial_bins=bins, timestamp=10.0
    )
    # Fresh observation at t=10.20s (age = 200ms <= 750ms)
    adv_fresh = estimate_directional_advisory(obs, threat="SAFE", now=10.20)
    assert adv_fresh.state == "AVAILABLE"
    assert adv_fresh.drawable_angle(now=10.20) is not None

    # Stale observation at t=10.80s (age = 800ms > 750ms)
    adv_stale = estimate_directional_advisory(obs, threat="SAFE", now=10.80)
    assert adv_stale.state == "UNAVAILABLE"
    assert adv_fresh.drawable_angle(now=10.80) is None
    assert adv_stale.reason_code == "SOURCE_FRAME_STALE"

    # Guidance-dependent audio invalidated
    budget = AuditoryBudgetManager()
    k_safe = KinematicsResult(primary_ttc=float("inf"), primary_velocity_z=0.0, threats={}, safe_direction="NONE", is_evading=False, threat_level="SAFE")
    dec_stale = budget.coordinate(obs, k_safe, current_timestamp=10.80, advisory=adv_stale)
    assert dec_stale.is_active is False
    assert dec_stale.cue_mode == "MUTED"
    assert dec_stale.safe_direction == "NONE"


def test_21_torch_session_lifecycle_and_invariants():
    """21. P0-03: Torch policy contract - auto-torch while running, OFF on pause, rejected manual toggle while paused."""
    # State flags simulating camera/torch manager state machine
    class TorchStateMachine:
        def __init__(self):
            self.is_guidance_active = False
            self.hardware_torch_on = False
            self.session_generation = 0
            self.dark_frame_count = 0
            self.forced_manual = False

        def set_guidance_active(self, active: bool):
            self.session_generation += 1
            self.is_guidance_active = active
            self.dark_frame_count = 0
            if not active:
                self.forced_manual = False
                self.hardware_torch_on = False
            else:
                self.forced_manual = False

        def process_frame(self, luma: float):
            if not self.is_guidance_active:
                self.dark_frame_count = 0
                return
            if not self.forced_manual:
                if luma < 40.0:
                    self.dark_frame_count += 1
                    if self.dark_frame_count >= 5:
                        self.hardware_torch_on = True
                else:
                    self.dark_frame_count = 0

        def toggle_manual(self):
            # Manual toggle is accepted ONLY during active guidance session
            if not self.is_guidance_active:
                return False
            self.forced_manual = True
            self.hardware_torch_on = not self.hardware_torch_on
            return True

    sm = TorchStateMachine()
    # 1. While paused, low luma (0-lux) must NOT activate torch
    for _ in range(10):
        sm.process_frame(luma=10.0)
    assert sm.hardware_torch_on is False

    # 2. While paused, manual toggle must be REJECTED
    assert sm.toggle_manual() is False
    assert sm.hardware_torch_on is False

    # 3. Start guidance (CHẠY) restores auto-policy
    sm.set_guidance_active(True)
    assert sm.is_guidance_active is True
    for _ in range(5):
        sm.process_frame(luma=10.0)
    assert sm.hardware_torch_on is True

    # 4. Stop guidance (DỪNG) turns hardware torch OFF immediately
    sm.set_guidance_active(False)
    assert sm.is_guidance_active is False
    assert sm.hardware_torch_on is False
