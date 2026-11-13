"""Behavior regressions for the actual desktop runtime and shared safety contract."""
import os
import sys
import math
from pathlib import Path
import threading
import time
from dataclasses import replace
import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from depth_engine import DepthEstimator, ObstacleDetectionResult, SingleObstacle, _verify_onnx_sha256
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager
from demo_runtime import DemoRuntime
from directional_advisory import (
    DirectionalAdvisory, DirectionState, advisory_for_risk,
    aspect_fit, image_x_to_angle, estimate_directional_advisory
)
from demo_ui import DemoViewport

def observation(distance=30, valid=True, objects=True):
    obj = SingleObstacle(1, 320, 240, (280, 180, 80, 120), 0, 1, distance, "OBSTACLE", .1, False)
    return ObstacleDetectionResult(320, 240, obj.bbox, 0, 1, distance, "OBSTACLE", .1, False,
        {"LEFT": 250., "CENTER": distance, "RIGHT": 250.}, [obj] if objects else [], is_valid=valid)

def test_fault_on_first_frame_and_unknown_never_safe():
    k = KinematicsEngine().compute(observation(float('nan'), False), 10, frame_id=1)
    assert k.threat_level == 'SENSOR_FAULT'
    d = AuditoryBudgetManager().coordinate(observation(float('nan'), False), k)
    assert d.is_active and d.cue_mode == 'SYSTEM_FAULT_TONE' and math.isinf(d.ttc)

def test_critical_cannot_be_suppressed_by_safe_label_or_far_primary():
    o = observation()
    k = KinematicsEngine().compute(o, 10, frame_id=1)
    o.mode_text = 'SAFE'; o.dist_cm = 350
    decision = AuditoryBudgetManager().coordinate(o, k)
    assert decision.is_active and decision.threat_level == 'CRITICAL'
    assert math.isinf(decision.ttc)

def test_sensor_fault_preempts_unresolved_standby():
    o = observation(float('nan'), False)
    k = KinematicsEngine().compute(o, 10, frame_id=1)
    k.threat_level = 'UNRESOLVED_HAZARD'; k.hazard_state = 'LOST_UNRESOLVED'
    k.lost_unresolved_timestamp = 1; k.timestamp = 10
    d = AuditoryBudgetManager().coordinate(o, k)
    assert d.is_active and d.cue_mode == 'SYSTEM_FAULT_TONE'

def test_close_static_has_infinite_ttc():
    kin = KinematicsEngine()
    for i in range(12):
        k = kin.compute(observation(), 10 + i * .1, frame_id=i + 1)
        assert k.threat_level == 'CRITICAL' and math.isinf(k.primary_ttc)

def test_missing_model_is_not_optional_integrity(tmp_path):
    p = tmp_path / 'unregistered.onnx'; p.write_bytes(b'not a model')
    assert not _verify_onnx_sha256(str(p))

def test_direction_freshness_fov_and_sign():
    a = DirectionalAdvisory(DirectionState.AVAILABLE, 20, .8, (-30, 30), 10)
    assert a.drawable_angle(10.5) == 20
    assert a.drawable_angle(12) is None
    assert replace(a, angle_deg=60).drawable_angle(10.5) is None
    assert replace(a, observed_angular_range=None).drawable_angle(10.5) is None
    assert replace(a, confidence=float('nan')).drawable_angle(10.5) is None
    assert image_x_to_angle(10, 20, 50) < 0 < image_x_to_angle(30, 20, 50)
    for risk in ['SAFE', 'WARNING', 'UNKNOWN', 'SENSOR_FAULT', 'UNRESOLVED_HAZARD']:
        assert advisory_for_risk(risk, 10).drawable_angle(10) is None

def test_aspect_fit_and_button_geometry():
    scale, x, y = aspect_fit(640, 480, 480, 680)
    assert (scale, x, y) == (.75, 0, 160)
    view = DemoViewport()
    assert view.render(np.zeros((480, 640, 3), np.uint8)).shape == (800, 480, 3)
    assert view.button_hit(200, 740) and not view.button_hit(200, 100)

def test_watchdog_remains_active_during_inference_and_stop_rejects_result():
    entered, release = threading.Event(), threading.Event()
    clock = [10.]
    class Stalled:
        def infer_depth(self, frame):
            entered.set(); release.wait(5)
            return frame, frame
        def detect_obstacle(self, *a, **kw): return observation()
    runtime = DemoRuntime(Stalled, lambda: clock[0])
    try:
        runtime.set_active(True)
        runtime.submit(np.zeros((4, 4, 3), np.uint8), 1, 10, {})
        assert entered.wait(2)
        clock[0] = 12
        threat, result, decision = runtime.snapshot(True)
        assert threat == 'SENSOR_FAULT' and result is None and decision.is_active
        runtime.set_active(False); release.set()
        time.sleep(.05)
        assert runtime.snapshot(True)[0] == 'PAUSED'
        runtime.set_active(True)
        assert runtime.snapshot(True)[1] is None
        assert runtime.snapshot(False)[0] == 'SENSOR_FAULT'
    finally:
        release.set(); runtime.close()

def test_inference_exception_and_recovery():
    class Flaky:
        failed = False
        def infer_depth(self, frame):
            if not self.failed:
                self.failed = True; raise RuntimeError('injected failure')
            return frame, frame
        def detect_obstacle(self, *a, **kw): return observation()
    runtime = DemoRuntime(Flaky)
    try:
        runtime.set_active(True)
        frame = np.zeros((4, 4, 3), np.uint8)
        runtime.submit(frame, 1, time.monotonic(), {})
        deadline = time.monotonic() + 2
        while runtime.error is None and time.monotonic() < deadline: time.sleep(.01)
        assert runtime.snapshot(True)[0] == 'SENSOR_FAULT'
        runtime.submit(frame, 2, time.monotonic(), {})
        deadline = time.monotonic() + 2
        while runtime.result is None and time.monotonic() < deadline: time.sleep(.01)
        assert runtime.snapshot(True)[0] == 'CRITICAL'
    finally: runtime.close()

def test_actual_model_real_frame():
    import cv2
    model = DepthEstimator()
    frame = cv2.imread(str(Path(__file__).parent / 'fixtures/demo/frame_0.png'))
    normalized, raw = model.infer_depth(frame)
    assert raw.shape == frame.shape[:2] and np.isfinite(raw).all()
    assert np.ptp(raw) > 1
    result = model.detect_obstacle(normalized, raw, frame_bgr=frame)
    assert result is not None

def test_continuous_180_directional_guidance():
    """Verify continuous angles theta in [-90, +90], obstacle avoidance, and refusal."""
    def make_custom_obs(obstacles, sectors=None, valid=True, is_zero_lux=False):
        s_dists = sectors if sectors is not None else {'LEFT': 250.0, 'CENTER': 250.0, 'RIGHT': 250.0}
        return ObstacleDetectionResult(
            x=320, y=240, bbox=(280, 180, 80, 120), pan=0.0, proximity=0.5, dist_cm=200.0,
            mode_text='TEST', uncertainty_score=0.1, is_wall=False,
            sector_dists=s_dists, all_obstacles=obstacles,
            is_zero_lux_blind=is_zero_lux, is_valid=valid
        )

    # 1. Clear forward path -> points straight ahead (0 degrees)
    clear_adv = estimate_directional_advisory(make_custom_obs([]), threat='SAFE', now=10.0)
    assert clear_adv.state == DirectionState.AVAILABLE
    assert clear_adv.angle_deg == 0.0
    # Heuristic support score, not a fabricated certainty
    assert 0.4 <= clear_adv.confidence <= 0.65
    assert clear_adv.drawable_angle(10.2) == 0.0

    # 2. Right-side obstacle (x=480) -> steers left (angle < 0)
    r_obs = SingleObstacle(1, 480, 240, (440, 180, 80, 120), 0.5, 0.8, 70.0, 'OBS', 0.1, False)
    r_adv = estimate_directional_advisory(
        make_custom_obs([r_obs], {'LEFT': 250.0, 'CENTER': 180.0, 'RIGHT': 70.0}),
        threat='WARNING', now=10.0
    )
    assert r_adv.state == DirectionState.AVAILABLE
    assert r_adv.angle_deg < 0.0
    assert -32.5 <= r_adv.angle_deg <= 32.5

    # 3. Left-side obstacle (x=160) -> steers right (angle > 0)
    l_obs = SingleObstacle(2, 160, 240, (120, 180, 80, 120), -0.5, 0.8, 70.0, 'OBS', 0.1, False)
    l_adv = estimate_directional_advisory(
        make_custom_obs([l_obs], {'LEFT': 70.0, 'CENTER': 180.0, 'RIGHT': 250.0}),
        threat='WARNING', now=10.0
    )
    assert l_adv.state == DirectionState.AVAILABLE
    assert l_adv.angle_deg > 0.0
    assert -32.5 <= l_adv.angle_deg <= 32.5

    # 4. Center obstacle with clear right side -> steers right
    cent_obs = SingleObstacle(3, 320, 240, (280, 180, 80, 120), 0.0, 0.9, 55.0, 'OBS', 0.1, False)
    cr_adv = estimate_directional_advisory(
        make_custom_obs([cent_obs], {'LEFT': 70.0, 'CENTER': 55.0, 'RIGHT': 250.0}),
        threat='CRITICAL', now=10.0
    )
    assert cr_adv.state == DirectionState.AVAILABLE
    assert cr_adv.angle_deg > 10.0

    # 5. Center obstacle with clear left side -> steers left
    cl_adv = estimate_directional_advisory(
        make_custom_obs([cent_obs], {'LEFT': 250.0, 'CENTER': 55.0, 'RIGHT': 70.0}),
        threat='CRITICAL', now=10.0
    )
    assert cl_adv.state == DirectionState.AVAILABLE
    assert cl_adv.angle_deg < -10.0

    # 6. Two obstacles with central gap -> passes straight through gap
    gap_left = SingleObstacle(4, 180, 240, (140, 180, 80, 120), -0.4, 0.8, 65.0, 'OBS', 0.1, False)
    gap_right = SingleObstacle(5, 460, 240, (420, 180, 80, 120), 0.4, 0.8, 65.0, 'OBS', 0.1, False)
    gap_adv = estimate_directional_advisory(
        make_custom_obs([gap_left, gap_right], {'LEFT': 65.0, 'CENTER': 250.0, 'RIGHT': 65.0}),
        threat='WARNING', now=10.0
    )
    assert gap_adv.state == DirectionState.AVAILABLE
    assert abs(gap_adv.angle_deg) <= 2.5

    # 7. Completely obstructed corridor (all sectors < 50cm) -> STOP
    blocked_adv = estimate_directional_advisory(
        make_custom_obs([cent_obs], {'LEFT': 40.0, 'CENTER': 35.0, 'RIGHT': 45.0}),
        threat='CRITICAL', now=10.0
    )
    assert blocked_adv.state == DirectionState.STOP
    assert blocked_adv.angle_deg is None

    # 8. Unreliable perception refusal (Sensor fault, invalid observation, zero-lux, paused)
    assert estimate_directional_advisory(make_custom_obs([], valid=False), threat='SENSOR_FAULT', now=10.0).state == DirectionState.UNKNOWN
    assert estimate_directional_advisory(make_custom_obs([], is_zero_lux=True), threat='WARNING', now=10.0).state == DirectionState.UNKNOWN
    assert estimate_directional_advisory(make_custom_obs([]), threat='PAUSED', now=10.0).state == DirectionState.UNKNOWN

    # 9. Continuous varying angles across lateral positions
    angles = []
    for x_pos in [160, 240, 400, 480]:
        o = SingleObstacle(6, x_pos, 240, (x_pos - 40, 180, 80, 120), 0.0, 0.8, 60.0, 'OBS', 0.1, False)
        s_d = {'LEFT': 60.0 if x_pos < 280 else 250.0, 'CENTER': 200.0, 'RIGHT': 60.0 if x_pos > 360 else 250.0}
        adv = estimate_directional_advisory(make_custom_obs([o], s_d), threat='WARNING', now=10.0)
        angles.append(adv.angle_deg)
    # Check that angles vary continuously and smoothly across positions
    assert len(set(angles)) > 1

    # 10. Temporal smoothing test with prev_angle
    smooth_adv = estimate_directional_advisory(
        make_custom_obs([r_obs], {'LEFT': 250.0, 'CENTER': 180.0, 'RIGHT': 70.0}),
        threat='WARNING', now=10.0, prev_angle=0.0
    )
    assert smooth_adv.state == DirectionState.AVAILABLE
    assert -32.5 <= smooth_adv.angle_deg <= 32.5

    # 11. P0-01 Mandatory Tests: Sector Validity & Fabricated Defaults Rejection
    # (a) Three missing sectors -> no AVAILABLE direction (UNAVAILABLE)
    no_sec_obs = make_custom_obs([], sectors={})
    no_sec_adv = estimate_directional_advisory(no_sec_obs, threat='SAFE', now=10.0)
    assert no_sec_adv.state == DirectionState.UNAVAILABLE
    assert no_sec_adv.angle_deg is None

    # (b) Left sector missing -> candidates on left rejected; cannot steer left from missing data
    missing_left_obs = make_custom_obs([cent_obs], sectors={'CENTER': 55.0, 'RIGHT': 250.0})
    ml_adv = estimate_directional_advisory(missing_left_obs, threat='CRITICAL', now=10.0)
    # Left candidates ineligible -> must choose valid Right candidates or STOP
    assert ml_adv.state == DirectionState.AVAILABLE
    assert ml_adv.angle_deg > 0.0  # Steers right, NOT into missing left!

    # (c) Center sector is NaN -> cannot recommend forward solely from other sectors
    nan_center_obs = make_custom_obs([], sectors={'LEFT': 250.0, 'CENTER': float('nan'), 'RIGHT': 250.0})
    nan_c_adv = estimate_directional_advisory(nan_center_obs, threat='SAFE', now=10.0)
    # Forward is not eligible, so it can only recommend a supported side or UNAVAILABLE
    if nan_c_adv.state == DirectionState.AVAILABLE:
        assert abs(nan_c_adv.angle_deg) > 10.0  # Cannot be straight ahead

    # (d) Missing obstacle list with invalid depth -> UNKNOWN
    inv_obs = make_custom_obs([], sectors={'LEFT': float('nan'), 'CENTER': float('nan'), 'RIGHT': float('nan')}, valid=False)
    assert estimate_directional_advisory(inv_obs, threat='SENSOR_FAULT', now=10.0).state == DirectionState.UNKNOWN

    # (e) Critical obstacle appearing during smoothing -> immediate STOP (no smoothing into STOP)
    sudden_block = estimate_directional_advisory(
        make_custom_obs([cent_obs], {'LEFT': 30.0, 'CENTER': 25.0, 'RIGHT': 30.0}),
        threat='CRITICAL', now=10.0, prev_angle=15.0
    )
    assert sudden_block.state == DirectionState.STOP
    assert sudden_block.angle_deg is None

    # (f) Hysteresis prevents rapid left/right oscillation for small score differences
    obs_symmetric = make_custom_obs([], {'LEFT': 200.0, 'CENTER': 200.0, 'RIGHT': 200.0})
    adv_favors_prev_left = estimate_directional_advisory(obs_symmetric, threat='SAFE', now=10.0, prev_angle=-5.0)
    assert adv_favors_prev_left.state == DirectionState.AVAILABLE
    assert adv_favors_prev_left.angle_deg < 0.0


def test_provenance_and_decision_source_contract():
    """Checkpoint 1 Acceptance: Decision-source contract & source-consistent TTC/velocity."""
    kin = KinematicsEngine()
    budget = AuditoryBudgetManager()

    # Case 1: Approaching object -> positive velocity and finite TTC
    obs1 = SingleObstacle(1, 320, 240, (280, 180, 80, 120), 0.0, 0.8, 150.0, "OBSTACLE", 0.1, False)
    res1 = ObstacleDetectionResult(320, 240, obs1.bbox, 0.0, 0.8, 150.0, "OBSTACLE", 0.1, False,
                                  {"LEFT": 250.0, "CENTER": 150.0, "RIGHT": 250.0}, [obs1], is_valid=True)
    k1 = kin.compute(res1, 1.0, frame_id=1)

    # Frame 2 with obstacle closer (approach motion)
    obs2 = SingleObstacle(1, 320, 240, (280, 180, 80, 120), 0.0, 0.9, 100.0, "OBSTACLE", 0.1, False)
    res2 = ObstacleDetectionResult(320, 240, obs2.bbox, 0.0, 0.9, 100.0, "OBSTACLE", 0.1, False,
                                  {"LEFT": 250.0, "CENTER": 100.0, "RIGHT": 250.0}, [obs2], is_valid=True)
    k2 = kin.compute(res2, 1.5, frame_id=2)
    d2 = budget.coordinate(res2, k2)

    assert d2.source_type == "OBJECT"
    assert d2.source_id == "1"
    assert d2.velocity_z > 0.0
    assert math.isfinite(d2.ttc)
    assert d2.measurement_validity == "VALID"

    # Case 2: Stationary hazard -> infinite TTC and vz <= 0 from same source
    kin_static = KinematicsEngine()
    budget_static = AuditoryBudgetManager()
    obs_s1 = SingleObstacle(2, 320, 240, (280, 180, 80, 120), 0.0, 0.9, 35.0, "OBSTACLE", 0.1, False)
    res_s1 = ObstacleDetectionResult(320, 240, obs_s1.bbox, 0.0, 0.9, 35.0, "OBSTACLE", 0.1, False,
                                    {"LEFT": 250.0, "CENTER": 35.0, "RIGHT": 250.0}, [obs_s1], is_valid=True)
    _ = kin_static.compute(res_s1, 1.0, frame_id=1)
    k_s2 = kin_static.compute(res_s1, 1.1, frame_id=2)
    d_s2 = budget_static.coordinate(res_s1, k_s2)

    assert d_s2.threat_level == "CRITICAL"
    assert d_s2.velocity_z <= 0.0
    assert math.isinf(d_s2.ttc)
    assert d_s2.source_type == "OBJECT"
    assert d_s2.source_id == str(res_s1.all_obstacles[0].id)
    assert d_s2.active_obstacle_id == res_s1.all_obstacles[0].id

    # Case 3: Multiple simultaneous hazards - selected object TTC belongs strictly to selected object
    obs_close_static = SingleObstacle(10, 320, 240, (280, 180, 80, 120), 0.0, 0.95, 25.0, "CRIT_STATIC", 0.1, False)
    obs_far_dynamic = SingleObstacle(20, 480, 240, (440, 180, 80, 120), 0.5, 0.7, 120.0, "DYN_APPROACH", 0.1, False)
    res_multi = ObstacleDetectionResult(320, 240, obs_close_static.bbox, 0.0, 0.95, 25.0, "OBSTACLE", 0.1, False,
                                        {"LEFT": 250.0, "CENTER": 25.0, "RIGHT": 120.0},
                                        [obs_close_static, obs_far_dynamic], is_valid=True)
    k_multi = kin.compute(res_multi, 2.0, frame_id=3)
    d_multi = budget.coordinate(res_multi, k_multi)

    # Active winner is the critical obstacle 10 (tracked as res_multi.all_obstacles[0].id)
    assert d_multi.active_obstacle_id == res_multi.all_obstacles[0].id
    assert d_multi.source_type == "OBJECT"
    assert d_multi.source_id == str(res_multi.all_obstacles[0].id)
    # Provenance invariant: velocity_z and ttc belong strictly to the active obstacle
    expected_vz = k_multi.obstacle_vzs.get(d_multi.active_obstacle_id, k_multi.primary_velocity_z)
    assert d_multi.velocity_z == expected_vz
    if d_multi.velocity_z <= 0.0:
        assert math.isinf(d_multi.ttc)
    else:
        assert d_multi.ttc == k_multi.obstacle_ttcs.get(d_multi.active_obstacle_id, float("inf"))


def test_unknown_obstacle_distance_handling():
    """Checkpoint 2 Acceptance: Unknown distance obstacles preserve bbox and steer away without fabricating 100cm."""
    # Obstacle with NaN distance on left side (x=160)
    unk_left_obs = SingleObstacle(7, 160, 240, (120, 180, 80, 120), -0.5, 0.8, float("nan"), "UNKNOWN_DIST_OBS", 0.1, False)
    obs_res = ObstacleDetectionResult(
        x=320, y=240, bbox=(120, 180, 80, 120), pan=-0.5, proximity=0.5, dist_cm=180.0,
        mode_text="TEST", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 70.0, "CENTER": 200.0, "RIGHT": 250.0},
        all_obstacles=[unk_left_obs], is_valid=True
    )
    adv = estimate_directional_advisory(obs_res, threat="WARNING", now=10.0)
    # The unknown distance obstacle occupies left: candidate steering into it must be rejected!
    assert adv.state == DirectionState.AVAILABLE
    assert adv.angle_deg > 0.0  # Steers right, avoiding unknown obstacle on left!

    # Center unknown obstacle blocking center, with clear left sector
    unk_center_obs = SingleObstacle(8, 320, 240, (280, 180, 80, 120), 0.0, 0.8, float("nan"), "UNKNOWN_CENTER", 0.1, False)
    obs_center = ObstacleDetectionResult(
        x=320, y=240, bbox=(280, 180, 80, 120), pan=0.0, proximity=0.5, dist_cm=200.0,
        mode_text="TEST", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 250.0, "CENTER": 200.0, "RIGHT": 70.0},
        all_obstacles=[unk_center_obs], is_valid=True
    )
    adv_c = estimate_directional_advisory(obs_center, threat="WARNING", now=10.0)
    assert adv_c.state == DirectionState.AVAILABLE
    assert adv_c.angle_deg < -5.0  # Steers left away from center unknown obstacle and right hazard!


def test_unknown_obstacle_hard_exclusion_and_eligibility():
    """Verify candidate headings intersecting unknown-distance obstacles are hard-rejected before scoring."""
    # Obstacle covering center (-10 deg to +10 deg) with unknown (NaN) distance
    unk_obs = SingleObstacle(9, 320, 240, (280, 180, 80, 120), 0.0, 0.8, float("nan"), "UNKNOWN", 0.1, False)
    # Left and right sectors blocked by close hazards (< 40cm)
    obs_res = ObstacleDetectionResult(
        x=320, y=240, bbox=(280, 180, 80, 120), pan=0.0, proximity=0.5, dist_cm=float("nan"),
        mode_text="TEST", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 30.0, "CENTER": float("nan"), "RIGHT": 30.0},
        all_obstacles=[unk_obs], is_valid=True
    )
    # Because center is blocked by unknown obstacle and sides are < 40cm, all candidates must be rejected -> STOP
    adv = estimate_directional_advisory(obs_res, threat="CRITICAL", now=10.0)
    assert adv.state == DirectionState.STOP
    assert adv.angle_deg is None


def test_narrow_gap_candidate_rejection():
    """Verify tight gap between two obstacles does not produce an AVAILABLE heading intersecting either obstacle."""
    # Two obstacles close to center: one at -5 deg (x=300), one at +5 deg (x=340), each width 80
    obs_l = SingleObstacle(11, 300, 240, (260, 180, 80, 120), -0.1, 0.9, 45.0, "OBS_L", 0.1, False)
    obs_r = SingleObstacle(12, 340, 240, (300, 180, 80, 120), 0.1, 0.9, 45.0, "OBS_R", 0.1, False)
    # Both sides also restricted
    obs_res = ObstacleDetectionResult(
        x=320, y=240, bbox=(260, 180, 120, 120), pan=0.0, proximity=0.9, dist_cm=45.0,
        mode_text="TEST", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 45.0, "CENTER": 45.0, "RIGHT": 45.0},
        all_obstacles=[obs_l, obs_r], is_valid=True
    )
    adv = estimate_directional_advisory(obs_res, threat="CRITICAL", now=10.0)
    assert adv.state == DirectionState.STOP
    assert adv.angle_deg is None


def test_stale_result_withdraws_directional_arrow():
    """Verify drawable_angle withdraws when result age exceeds 0.50s (500ms)."""
    adv = DirectionalAdvisory(DirectionState.AVAILABLE, 12.0, 0.85, (-30, 30), 10.0)
    # Fresh within 500ms
    assert adv.drawable_angle(10.20) == 12.0
    assert adv.drawable_angle(10.50) == 12.0
    # Stale after 500ms
    assert adv.drawable_angle(10.51) is None
    assert adv.drawable_angle(11.00) is None

    # Verify PipelineResult helpers
    from demo_runtime import PipelineResult
    pr = PipelineResult(
        generation=1, timestamp=10.0, observation=None, kinematics=None,
        decision=None, frame=None, latency_ms=50.0, advisory=adv,
        frame_id=1, inference_completed=10.05
    )
    assert pr.is_overlay_fresh(10.24) is True
    assert pr.is_overlay_fresh(10.26) is False  # 250ms overlay threshold
    assert pr.is_advisory_fresh(10.49) is True
    assert pr.is_advisory_fresh(10.52) is False  # 500ms advisory threshold


def test_pause_resume_clears_heading_history():
    """Verify pause immediately clears advisory state and heading history."""
    obs_res = ObstacleDetectionResult(
        x=320, y=240, bbox=(280, 180, 80, 120), pan=0.0, proximity=0.5, dist_cm=200.0,
        mode_text="TEST", uncertainty_score=0.1, is_wall=False,
        sector_dists={"LEFT": 250.0, "CENTER": 200.0, "RIGHT": 250.0},
        all_obstacles=[], is_valid=True
    )
    # First active frame with previous angle
    adv1 = estimate_directional_advisory(obs_res, threat="SAFE", now=10.0, prev_angle=15.0)
    assert adv1.state == DirectionState.AVAILABLE

    # Enter PAUSED state: advisory must become UNKNOWN and angle None
    adv_paused = estimate_directional_advisory(obs_res, threat="PAUSED", now=10.1, prev_angle=adv1.angle_deg)
    assert adv_paused.state == DirectionState.UNKNOWN
    assert adv_paused.angle_deg is None
    assert adv_paused.drawable_angle(10.1) is None

