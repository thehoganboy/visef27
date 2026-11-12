"""Behavior regressions for the actual desktop runtime and shared safety contract."""
import math
from pathlib import Path
import threading
import time
from dataclasses import replace
import numpy as np
import pytest
from depth_engine import DepthEstimator, ObstacleDetectionResult, SingleObstacle, _verify_onnx_sha256
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager
from demo_runtime import DemoRuntime
from directional_advisory import DirectionalAdvisory, DirectionState, advisory_for_risk, aspect_fit, image_x_to_angle
from demo_ui import DemoViewport

def observation(distance=30, valid=True, objects=True):
    obj = SingleObstacle(1,320,240,(280,180,80,120),0,1,distance,"OBSTACLE",.1,False)
    return ObstacleDetectionResult(320,240,obj.bbox,0,1,distance,"OBSTACLE",.1,False,
        {"LEFT":250.,"CENTER":distance,"RIGHT":250.},[obj] if objects else [],is_valid=valid)

def test_fault_on_first_frame_and_unknown_never_safe():
    k = KinematicsEngine().compute(observation(float('nan'),False),10,frame_id=1)
    assert k.threat_level == 'SENSOR_FAULT'
    d = AuditoryBudgetManager().coordinate(observation(float('nan'),False),k)
    assert d.is_active and d.cue_mode == 'SYSTEM_FAULT_TONE' and math.isinf(d.ttc)

def test_critical_cannot_be_suppressed_by_safe_label_or_far_primary():
    o = observation()
    k = KinematicsEngine().compute(o,10,frame_id=1)
    o.mode_text = 'SAFE'; o.dist_cm = 350
    decision = AuditoryBudgetManager().coordinate(o,k)
    assert decision.is_active and decision.threat_level == 'CRITICAL'
    assert math.isinf(decision.ttc)

def test_sensor_fault_preempts_unresolved_standby():
    o = observation(float('nan'),False)
    k = KinematicsEngine().compute(o,10,frame_id=1)
    k.threat_level='UNRESOLVED_HAZARD'; k.hazard_state='LOST_UNRESOLVED'
    k.lost_unresolved_timestamp=1; k.timestamp=10
    d=AuditoryBudgetManager().coordinate(o,k)
    assert d.is_active and d.cue_mode=='SYSTEM_FAULT_TONE'

def test_close_static_has_infinite_ttc():
    kin=KinematicsEngine()
    for i in range(12):
        k=kin.compute(observation(),10+i*.1,frame_id=i+1)
        assert k.threat_level=='CRITICAL' and math.isinf(k.primary_ttc)

def test_missing_model_is_not_optional_integrity(tmp_path):
    p=tmp_path/'unregistered.onnx';p.write_bytes(b'not a model')
    assert not _verify_onnx_sha256(str(p))

def test_direction_freshness_fov_and_sign():
    a=DirectionalAdvisory(DirectionState.AVAILABLE,20,.8,(-30,30),10)
    assert a.drawable_angle(10.5)==20
    assert a.drawable_angle(12) is None
    assert replace(a,angle_deg=60).drawable_angle(10.5) is None
    assert replace(a,observed_angular_range=None).drawable_angle(10.5) is None
    assert replace(a,confidence=float('nan')).drawable_angle(10.5) is None
    assert image_x_to_angle(10,20,50)<0<image_x_to_angle(30,20,50)
    for risk in ['SAFE','WARNING','UNKNOWN','SENSOR_FAULT','UNRESOLVED_HAZARD']:
        assert advisory_for_risk(risk,10).drawable_angle(10) is None

def test_aspect_fit_and_button_geometry():
    scale,x,y=aspect_fit(640,480,480,680)
    assert (scale,x,y)==(.75,0,160)
    view=DemoViewport()
    assert view.render(np.zeros((480,640,3),np.uint8)).shape==(800,480,3)
    assert view.button_hit(200,740) and not view.button_hit(200,100)

def test_watchdog_remains_active_during_inference_and_stop_rejects_result():
    entered,release=threading.Event(),threading.Event()
    clock=[10.]
    class Stalled:
        def infer_depth(self,frame):
            entered.set(); release.wait(5)
            return frame,frame
        def detect_obstacle(self,*a,**kw): return observation()
    runtime=DemoRuntime(Stalled,lambda:clock[0])
    try:
        runtime.set_active(True)
        runtime.submit(np.zeros((4,4,3),np.uint8),1,10,{})
        assert entered.wait(2)
        clock[0]=12
        threat,result,decision=runtime.snapshot(True)
        assert threat=='SENSOR_FAULT' and result is None and decision.is_active
        runtime.set_active(False); release.set()
        time.sleep(.05)
        assert runtime.snapshot(True)[0]=='PAUSED'
        runtime.set_active(True)
        assert runtime.snapshot(True)[1] is None
        assert runtime.snapshot(False)[0]=='SENSOR_FAULT'
    finally:
        release.set(); runtime.close()

def test_inference_exception_and_recovery():
    class Flaky:
        failed=False
        def infer_depth(self,frame):
            if not self.failed:
                self.failed=True; raise RuntimeError('injected failure')
            return frame,frame
        def detect_obstacle(self,*a,**kw): return observation()
    runtime=DemoRuntime(Flaky)
    try:
        runtime.set_active(True)
        frame=np.zeros((4,4,3),np.uint8)
        runtime.submit(frame,1,time.monotonic(),{})
        deadline=time.monotonic()+2
        while runtime.error is None and time.monotonic()<deadline: time.sleep(.01)
        assert runtime.snapshot(True)[0]=='SENSOR_FAULT'
        runtime.submit(frame,2,time.monotonic(),{})
        deadline=time.monotonic()+2
        while runtime.result is None and time.monotonic()<deadline: time.sleep(.01)
        assert runtime.snapshot(True)[0]=='CRITICAL'
    finally: runtime.close()

def test_actual_model_real_frame():
    import cv2
    model=DepthEstimator()
    frame=cv2.imread(str(Path(__file__).parent/'fixtures/demo/frame_0.png'))
    normalized,raw=model.infer_depth(frame)
    assert raw.shape==frame.shape[:2] and np.isfinite(raw).all()
    assert np.ptp(raw)>1
    result=model.detect_obstacle(normalized,raw,frame_bgr=frame)
    assert result is not None
