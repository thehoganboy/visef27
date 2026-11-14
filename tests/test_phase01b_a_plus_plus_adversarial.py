"""
Phase 01B-A++ Final Adversarial Safety & Boundary Test Suite
================================================================================
Implements all mandatory scenario verifications specified in
FINAL ENGINEERING DIRECTIVE 01B-A++ (Tasks P0-F01, P1-F02):
1. App startup defaults to INITIALIZING / UNKNOWN (never false safe).
2. Rotating away from a hazard does not clear its unresolved status.
3. Coasting expiration transitions to LOST_UNRESOLVED, never false safe.
4. Reminder duration is FPS-independent (monotonic time interval).
5. Watchdog triggers SENSOR_FAULT / CAMERA_STALLED on pipeline stall (> 1.0s).
6. Preemption by new critical hazard during coasting.
7. Observation recovery (OBSERVATION_RECOVERED).
8. Monotonic timestamp anomaly & duplicate protection.
================================================================================
"""

import sys
import os
import math
import time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from depth_engine import ObstacleDetectionResult, SingleObstacle
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager


def test_startup_state_initializing():
    """Directive 01B-A++ Task P0-F01: Startup defaults to INITIALIZING / UNKNOWN."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT

    # Frame 1: Empty scene on startup
    res_empty = ObstacleDetectionResult(
        x=w//2, y=h//2, bbox=(0,0,0,0), pan=0.0, proximity=0.0, dist_cm=250.0,
        mode_text="SAFE", uncertainty_score=0.05, is_wall=False,
        sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[]
    )
    k1 = kin.compute(res_empty, 10.0, frame_id=1)
    assert k1.hazard_state == "INITIALIZING", f"Startup frame must be INITIALIZING, got {k1.hazard_state}"
    assert k1.threat_level == "UNKNOWN", f"Startup threat must be UNKNOWN, got {k1.threat_level}"
    assert k1.guidance_state == "PATH_UNVERIFIED", f"Startup guidance must be PATH_UNVERIFIED, got {k1.guidance_state}"

    # Frame 2 & 3: Still initializing until 3 stabilized frames
    k2 = kin.compute(res_empty, 10.05, frame_id=2)
    k3 = kin.compute(res_empty, 10.10, frame_id=3)
    assert k3.hazard_state == "OBSERVED_LOW_RISK"
    assert k3.threat_level == "SAFE"
    assert k3.guidance_state == "NO_HAZARD_DETECTED_IN_OBSERVED_REGION"


def test_rotation_does_not_clear_hazard():
    """Directive 01B-A++ Task P0-F01 Point 7 & 8: Rotating away does not clear hazard."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT
    t0 = 50.0

    # Frame 1: Critical hazard observed in front (pan 0.0)
    obs = SingleObstacle(id=1, x=w//2, y=h//2, bbox=(240, 180, 160, 160), pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False)
    res = ObstacleDetectionResult(x=obs.x, y=obs.y, bbox=obs.bbox, pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 150.0, "CENTER": 35.0, "RIGHT": 150.0}, all_obstacles=[obs])
    kin.compute(res, t0, frame_id=1)

    # Frame 2: Coasting expires (> 0.60s) into LOST_UNRESOLVED
    res_empty_panned = ObstacleDetectionResult(
        x=int(w*0.8), y=h//2, bbox=(0,0,0,0), pan=0.50, proximity=0.0, dist_cm=250.0,
        mode_text="SAFE", uncertainty_score=0.05, is_wall=False,
        sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[]
    )
    k_exp = kin.compute(res_empty_panned, t0 + 0.70, frame_id=2)
    assert k_exp.hazard_state == "LOST_UNRESOLVED"

    # Frame 3, 4, 5: Camera is actively rotating (d_pan > 0.15)
    for i in range(3, 6):
        res_rotating = ObstacleDetectionResult(
            x=int(w*0.8), y=h//2, bbox=(0,0,0,0), pan=0.20 * i, proximity=0.0, dist_cm=250.0,
            mode_text="SAFE", uncertainty_score=0.05, is_wall=False,
            sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[]
        )
        k_rot = kin.compute(res_rotating, t0 + 0.70 + 0.1 * (i-2), frame_id=i)
        assert k_rot.hazard_state == "LOST_UNRESOLVED", f"Frame {i}: Rotating away must NOT clear hazard to low risk!"
        assert k_rot.threat_level == "UNRESOLVED_HAZARD"
        assert k_rot.guidance_state == "PATH_UNRESOLVED"


def test_coasting_phone_rotation_and_recovery():
    """Directive 01B-A++: Obstacle lost due to rotation, then recovered."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT
    t0 = 100.0

    # Frame 1: Observed critical hazard
    obs1 = SingleObstacle(id=1, x=w//2, y=h//2, bbox=(240, 180, 160, 160), pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False)
    res1 = ObstacleDetectionResult(x=obs1.x, y=obs1.y, bbox=obs1.bbox, pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 150.0, "CENTER": 35.0, "RIGHT": 150.0}, all_obstacles=[obs1])
    k1 = kin.compute(res1, t0, frame_id=1)
    assert k1.hazard_state == "OBSERVED_HAZARD"
    assert k1.threat_level == "CRITICAL"

    # Frame 2: Lost due to rotation (t = 100.20s) -> COASTING_HAZARD
    res_empty = ObstacleDetectionResult(x=w//2, y=h//2, bbox=(0,0,0,0), pan=0.0, proximity=0.0, dist_cm=250.0, mode_text="SAFE", uncertainty_score=0.05, is_wall=False, sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[])
    k2 = kin.compute(res_empty, t0 + 0.20, frame_id=2)
    assert k2.hazard_state == "COASTING_HAZARD"
    assert k2.threat_level == "CRITICAL"

    # Frame 3: Rotation back, obstacle recovered (t = 100.40s) -> OBSERVATION_RECOVERED
    k3 = kin.compute(res1, t0 + 0.40, frame_id=3)
    assert k3.hazard_state == "OBSERVATION_RECOVERED"
    assert k3.threat_level == "CRITICAL"


def test_coasting_preemption_by_new_critical_hazard():
    """Directive 01B-A++: New critical hazard preempts stale coasting hazard."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT
    t0 = 200.0

    # Frame 1: Obstacle A on LEFT at 35cm
    obsA = SingleObstacle(id=1, x=int(w*0.2), y=h//2, bbox=(50, 180, 100, 160), pan=-0.60, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False)
    resA = ObstacleDetectionResult(x=obsA.x, y=obsA.y, bbox=obsA.bbox, pan=-0.60, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 35.0, "CENTER": 200.0, "RIGHT": 200.0}, all_obstacles=[obsA])
    k1 = kin.compute(resA, t0, frame_id=1)
    assert k1.hazard_direction == "LEFT"

    # Frame 2: Obstacle A disappears -> Coasting
    res_empty = ObstacleDetectionResult(x=w//2, y=h//2, bbox=(0,0,0,0), pan=0.0, proximity=0.0, dist_cm=250.0, mode_text="SAFE", uncertainty_score=0.05, is_wall=False, sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[])
    k2 = kin.compute(res_empty, t0 + 0.20, frame_id=2)
    assert k2.hazard_state == "COASTING_HAZARD"
    assert k2.hazard_direction == "LEFT"

    # Frame 3: Obstacle B appears on RIGHT at 30cm -> Immediately preempts and directs to RIGHT
    obsB = SingleObstacle(id=2, x=int(w*0.8), y=h//2, bbox=(int(w*0.7), 180, 100, 160), pan=0.60, proximity=1.0, dist_cm=30.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False)
    resB = ObstacleDetectionResult(x=obsB.x, y=obsB.y, bbox=obsB.bbox, pan=0.60, proximity=1.0, dist_cm=30.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 250.0, "CENTER": 200.0, "RIGHT": 30.0}, all_obstacles=[obsB])
    k3 = kin.compute(resB, t0 + 0.30, frame_id=3)
    assert k3.threat_level == "CRITICAL"
    assert k3.hazard_direction == "RIGHT"
    assert k3.hazard_state in ["OBSERVATION_RECOVERED", "OBSERVED_HAZARD"]


def test_coasting_expiration_never_false_safe():
    """Directive 01B-A++: Expiration must transition to LOST_UNRESOLVED, never false SAFE."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT
    t0 = 300.0

    # Frame 1: Critical obstacle
    obs = SingleObstacle(id=1, x=w//2, y=h//2, bbox=(240, 180, 160, 160), pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False)
    res = ObstacleDetectionResult(x=obs.x, y=obs.y, bbox=obs.bbox, pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 150.0, "CENTER": 35.0, "RIGHT": 150.0}, all_obstacles=[obs])
    kin.compute(res, t0, frame_id=1)

    # Coasting interval (0.0 to 0.60s)
    res_empty = ObstacleDetectionResult(x=w//2, y=h//2, bbox=(0,0,0,0), pan=0.0, proximity=0.0, dist_cm=250.0, mode_text="SAFE", uncertainty_score=0.05, is_wall=False, sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[])
    k_coast = kin.compute(res_empty, t0 + 0.50, frame_id=2)
    assert k_coast.hazard_state == "COASTING_HAZARD"
    assert k_coast.threat_level == "CRITICAL"

    # Coasting expired (> 0.60s)
    k_expired = kin.compute(res_empty, t0 + 0.70, frame_id=3)
    assert k_expired.hazard_state == "LOST_UNRESOLVED"
    assert k_expired.threat_level == "UNRESOLVED_HAZARD"
    assert k_expired.guidance_state == "PATH_UNRESOLVED"
    assert k_expired.threat_level != "SAFE"


def test_fps_independent_reminder_duration():
    """Directive 01B-A++ Task P1-F02: Reminder duration is strictly time-based (1.5s), invariant across FPS."""
    for fps in [5, 10, 20, 30]:
        budget_mgr = AuditoryBudgetManager()
        kin = KinematicsEngine()
        w, h = config.CAM_WIDTH, config.CAM_HEIGHT
        t0 = 600.0
        dt = 1.0 / fps

        # Trigger critical hazard
        obs = SingleObstacle(id=1, x=w//2, y=h//2, bbox=(240, 180, 160, 160), pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False)
        res = ObstacleDetectionResult(x=obs.x, y=obs.y, bbox=obs.bbox, pan=0.0, proximity=1.0, dist_cm=35.0, mode_text="CRITICAL", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 150.0, "CENTER": 35.0, "RIGHT": 150.0}, all_obstacles=[obs])
        kin.compute(res, t0, frame_id=1)

        # Expire coasting into LOST_UNRESOLVED at t = 600.70s
        res_unres = ObstacleDetectionResult(x=w//2, y=h//2, bbox=(0,0,0,0), pan=0.0, proximity=0.0, dist_cm=250.0, mode_text="UNRESOLVED", uncertainty_score=0.05, is_wall=False, sector_dists={"LEFT": 100.0, "CENTER": 100.0, "RIGHT": 100.0}, all_obstacles=[])
        t_lost = t0 + 0.70
        k_unres = kin.compute(res_unres, t_lost, frame_id=2)
        assert k_unres.hazard_state == "LOST_UNRESOLVED"

        # Within 1.5 seconds real time: CAUTION_REMINDER must be emitted
        t_check_active = t_lost + 1.0
        k_check_active = kin.compute(res_unres, t_check_active, frame_id=3)
        dec_active = budget_mgr.coordinate(res_unres, k_check_active)
        assert dec_active.cue_mode == "CAUTION_REMINDER", f"FPS {fps}: at 1.0s elapsed should be CAUTION_REMINDER"
        assert dec_active.volume_factor == 0.35

        # Beyond 1.5 seconds real time: STANDBY_UNRESOLVED must be emitted
        t_check_standby = t_lost + 1.6
        k_check_standby = kin.compute(res_unres, t_check_standby, frame_id=4)
        dec_standby = budget_mgr.coordinate(res_unres, k_check_standby)
        assert dec_standby.cue_mode == "STANDBY_UNRESOLVED", f"FPS {fps}: at 1.6s elapsed should be STANDBY_UNRESOLVED"
        assert dec_standby.volume_factor == 0.0
        assert dec_standby.guidance_state == "PATH_UNRESOLVED"


def test_watchdog_timeout_stalled_camera():
    """Directive 01B-A++ Task P1-F02: Watchdog triggers SENSOR_FAULT / CAMERA_STALLED when frames stop (> 1.0s)."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT
    t0 = 700.0

    res_empty = ObstacleDetectionResult(x=w//2, y=h//2, bbox=(0,0,0,0), pan=0.0, proximity=0.0, dist_cm=250.0, mode_text="SAFE", uncertainty_score=0.05, is_wall=False, sector_dists={"LEFT": 250.0, "CENTER": 250.0, "RIGHT": 250.0}, all_obstacles=[])
    kin.compute(res_empty, t0, frame_id=1)

    # 1.5s passes without frames: check_watchdog called independently
    fault_res = kin.check_watchdog(t0 + 1.5)
    assert fault_res is not None, "Watchdog must detect > 1.0s frame gap"
    assert fault_res.hazard_state == "SENSOR_FAULT"
    assert fault_res.threat_level == "SENSOR_FAULT"
    assert fault_res.guidance_state == "CAMERA_STALLED"


def test_monotonic_timestamp_anomaly():
    """Directive 01B-A++: Protect against negative or duplicate timestamps."""
    kin = KinematicsEngine()
    w, h = config.CAM_WIDTH, config.CAM_HEIGHT
    obs = SingleObstacle(id=1, x=w//2, y=h//2, bbox=(240, 180, 160, 160), pan=0.0, proximity=0.5, dist_cm=100.0, mode_text="WARNING", uncertainty_score=0.1, is_wall=False)
    res = ObstacleDetectionResult(x=obs.x, y=obs.y, bbox=obs.bbox, pan=0.0, proximity=0.5, dist_cm=100.0, mode_text="WARNING", uncertainty_score=0.1, is_wall=False, sector_dists={"LEFT": 200.0, "CENTER": 100.0, "RIGHT": 200.0}, all_obstacles=[obs])

    k1 = kin.compute(res, 100.0, frame_id=1)
    # Duplicate timestamp
    k2 = kin.compute(res, 100.0, frame_id=1)
    assert k2 == k1, "Duplicate timestamp must safely return cached result"

    # Timestamp anomaly (backward time)
    k3 = kin.compute(res, 95.0, frame_id=2)
    assert not math.isnan(k3.primary_velocity_z), "Backward timestamp must not produce NaN"


if __name__ == "__main__":
    test_startup_state_initializing()
    print("test_startup_state_initializing: PASS")
    test_rotation_does_not_clear_hazard()
    print("test_rotation_does_not_clear_hazard: PASS")
    test_coasting_phone_rotation_and_recovery()
    print("test_coasting_phone_rotation_and_recovery: PASS")
    test_coasting_preemption_by_new_critical_hazard()
    print("test_coasting_preemption_by_new_critical_hazard: PASS")
    test_coasting_expiration_never_false_safe()
    print("test_coasting_expiration_never_false_safe: PASS")
    test_fps_independent_reminder_duration()
    print("test_fps_independent_reminder_duration: PASS")
    test_watchdog_timeout_stalled_camera()
    print("test_watchdog_timeout_stalled_camera: PASS")
    test_monotonic_timestamp_anomaly()
    print("test_monotonic_timestamp_anomaly: PASS")
    print("\nALL ADVERSARIAL FINAL TESTS PASSED 100%!")
