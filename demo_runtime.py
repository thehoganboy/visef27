"""Bounded inference worker. UI owns health checks/audio; tokens reject late output."""
from dataclasses import dataclass
import logging
import threading
import time
import numpy as np
from depth_engine import DepthEstimator
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager, BudgetDecision
from directional_advisory import estimate_directional_advisory, DirectionState

@dataclass(frozen=True)
class PipelineResult:
    generation: int
    timestamp: float
    observation: object
    kinematics: object
    decision: BudgetDecision
    frame: object
    latency_ms: float
    advisory: object = None
    frame_id: int = 0
    inference_completed: float = 0.0
    depth_viz: object = None  # Genuine normalized depth tensor from the SAME inference call

    @property
    def capture_timestamp(self) -> float:
        return self.timestamp

    def age(self, now: float) -> float:
        return max(0.0, now - self.timestamp)

    def is_overlay_fresh(self, now: float, window: float = 0.250) -> bool:
        return self.age(now) <= window

    def is_advisory_fresh(self, now: float, window: float = 0.500) -> bool:
        return self.age(now) <= window

class DemoRuntime:
    def __init__(self, estimator_factory=DepthEstimator, clock=time.monotonic):
        self.clock, self.factory = clock, estimator_factory
        self.lock = threading.Lock()
        self.event = threading.Event()
        self.generation = 0
        self.active = self.closed = False
        self.pending = self.result = self.error = None
        self.dropped_frames = 0
        self.started = clock()
        self.thread = threading.Thread(target=self._work, name="HorusInference", daemon=True)
        self.thread.start()

    def set_active(self, active):
        with self.lock:
            self.generation += 1
            self.active = active
            self.pending = self.result = self.error = None
            self.started = self.clock()

    def submit(self, frame, frame_id, timestamp, lighting):
        with self.lock:
            if self.active and not self.closed:
                if self.pending is not None:
                    self.dropped_frames += 1
                self.pending = (self.generation, frame, frame_id, timestamp, lighting)
                self.event.set()

    def snapshot(self, camera_healthy):
        with self.lock:
            now = self.clock()
            if not self.active:
                return "PAUSED", None, BudgetDecision()
            r = self.result
            if self.error or not camera_healthy or now - (r.timestamp if r else self.started) > 1:
                return "SENSOR_FAULT", None, BudgetDecision(is_active=True,
                    cue_mode="SYSTEM_FAULT_TONE", proximity=.4, volume_factor=.35,
                    threat_level="SENSOR_FAULT", dist_cm=float("nan"))
            if r is None:
                return "INITIALIZING", None, BudgetDecision()
            return r.kinematics.threat_level, r, r.decision

    def close(self):
        self.set_active(False)
        with self.lock:
            self.closed = True
        self.event.set()
        self.thread.join(timeout=.25)

    def _work(self):
        estimator, generation, last_id = None, -1, None
        prev_angle = None
        while True:
            self.event.wait()
            with self.lock:
                if self.closed:
                    return
                item, self.pending = self.pending, None
                self.event.clear()
            if item is None:
                continue
            token, frame, frame_id, timestamp, lighting = item
            if generation != token:
                kin, budget = KinematicsEngine(), AuditoryBudgetManager()
                generation, last_id = token, None
                prev_angle = None
            if frame_id == last_id:
                continue
            last_id = frame_id
            try:
                start = self.clock()
                if estimator is None:
                    estimator = self.factory()
                norm, raw = estimator.infer_depth(frame)
                obs = estimator.detect_obstacle(norm, raw, frame_bgr=frame,
                    lighting_status=lighting, is_zero_lux=lighting.get("is_zero_lux_blind", False))
                k = kin.compute(obs, timestamp, frame_id=frame_id,
                                ae_settle_counter=lighting.get("ae_settle_counter", 0))
                adv = estimate_directional_advisory(obs, threat=k.threat_level, now=timestamp, prev_angle=prev_angle)
                if adv.state == DirectionState.AVAILABLE:
                    prev_angle = adv.angle_deg
                else:
                    prev_angle = None
                now_completed = self.clock()
                depth_viz = norm.copy() if hasattr(norm, "copy") else norm
                if isinstance(raw, np.ndarray):
                    invalid_mask = np.isnan(raw) | np.isinf(raw) | (raw <= 0)
                    if np.any(invalid_mask):
                        depth_viz = depth_viz.copy()
                        depth_viz[invalid_mask] = 0
                result = PipelineResult(token, timestamp, obs, k, budget.coordinate(obs, k, advisory=adv),
                                        frame, (now_completed - start) * 1000, adv,
                                        frame_id=frame_id, inference_completed=now_completed,
                                        depth_viz=depth_viz)
                with self.lock:
                    if token == self.generation and self.active:
                        self.result, self.error = result, None
            except Exception as exc:
                logging.exception("Perception unavailable")
                with self.lock:
                    if token == self.generation:
                        self.result, self.error = None, str(exc)
                time.sleep(.5)  # Bound model retries; UI health checks continue.
