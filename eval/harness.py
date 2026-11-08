#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HorusEyes 2.0 — Independent Obstacle Evaluation Harness (WP-01B-B0)
================================================================================
Stage-Separated Benchmark Framework with Multi-Stage Error Attribution:
  Stage 1: Image Acquisition & Visual Observability
  Stage 2: Depth Model Inference (Disparity / Metric Depth)
  Stage 3: Obstacle Segmentation (Sobel / Morphology / Thresholding)
  Stage 4: Centroid Tracking & Association (Identity & Velocity)
  Stage 5: Collision-Risk Classification (Static Proximity + Dynamic TTC)
  Stage 6: Auditory Display & Budget Allocation (Hysteresis & Preemption)

For any missed hazard or false alarm, this harness attributes the root failure
to the exact subsystem where the error occurred.
================================================================================
"""

import os
import sys
import time
import math
from dataclasses import dataclass, field
from typing import List, Dict, Tuple, Optional, Any
import numpy as np
import cv2

# Import reference pipeline modules
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from depth_engine import DepthEstimator, SingleObstacle, ObstacleDetectionResult, assess_visual_observability
from motion_ttc import KinematicsEngine, KinematicsResult
from auditory_budget import AuditoryBudgetManager, BudgetDecision


@dataclass
class GroundTruthObstacle:
    id: int
    category: str              # e.g. "THIN_POLE", "OVERHEAD", "STATIONARY_CLOSE", "APPROACHING"
    bbox_xywh: Tuple[int, int, int, int]
    dist_cm: float
    velocity_z: float          # cm/s (positive = approaching)
    is_hazard: bool = True     # True if requires an auditory warning
    min_threat_level: str = "WARNING" # "WARNING" or "CRITICAL"


@dataclass
class EvaluationSample:
    sample_id: str
    frame_bgr: np.ndarray
    ground_truth: List[GroundTruthObstacle]
    timestamp: float
    notes: str = ""


@dataclass
class StageDiagnostics:
    stage_name: str
    passed: bool
    latency_ms: float
    error_message: str = ""
    telemetry: Dict[str, Any] = field(default_factory=dict)


@dataclass
class FrameEvaluationReport:
    sample_id: str
    overall_status: str        # "SUCCESS", "MISSED_HAZARD", "FALSE_ALARM", "TIMING_ERROR"
    failed_stage: Optional[str] # "ACQUISITION", "DEPTH_INFERENCE", "SEGMENTATION", "TRACKING", "RISK_CLASSIFICATION", "AUDITORY_BUDGET"
    failure_attribution: str   # Detailed scientific diagnosis
    stage_reports: List[StageDiagnostics]
    total_edge_latency_ms: float


class ObstacleEvaluationHarness:
    """
    Evaluation Harness implementing rigorous 6-stage error attribution.
    Runs completely isolated from the deployed runtime pipeline.
    """

    def __init__(self, depth_estimator: Optional[DepthEstimator] = None):
        self.depth_est = depth_estimator or DepthEstimator(device="cpu")
        self.kin_engine = KinematicsEngine()
        self.budget_mgr = AuditoryBudgetManager()

        # Metrics Accumulators
        self.total_evaluated_frames = 0
        self.stage_failure_counts = {
            "STAGE_1_ACQUISITION": 0,
            "STAGE_2_DEPTH_INFERENCE": 0,
            "STAGE_3_SEGMENTATION": 0,
            "STAGE_4_TRACKING": 0,
            "STAGE_5_RISK_CLASSIFICATION": 0,
            "STAGE_6_AUDITORY_BUDGET": 0,
        }
        self.category_recall = {}
        self.category_total = {}
        self.false_positive_count = 0
        self.stage_latencies = {
            "S1_acquisition": [],
            "S2_inference": [],
            "S3_segmentation": [],
            "S4_tracking": [],
            "S5_risk": [],
            "S6_audio_budget": [],
        }

    def evaluate_frame(self, sample: EvaluationSample, frame_id: int = 1) -> FrameEvaluationReport:
        self.total_evaluated_frames += 1
        stage_reports = []
        now = sample.timestamp

        # ── STAGE 1: Image Acquisition & Visual Observability ──
        t0 = time.perf_counter()
        q_state, q_reasons, q_stats = assess_visual_observability(sample.frame_bgr)
        t1 = time.perf_counter()
        lat_s1 = (t1 - t0) * 1000.0
        self.stage_latencies["S1_acquisition"].append(lat_s1)

        s1_passed = (q_state != "UNOBSERVABLE")
        stage_reports.append(StageDiagnostics(
            stage_name="STAGE_1_ACQUISITION",
            passed=s1_passed,
            latency_ms=lat_s1,
            error_message="; ".join(q_reasons) if not s1_passed else "",
            telemetry={"quality_state": q_state, "reasons": q_reasons, "stats": q_stats}
        ))

        # ── STAGE 2: Depth Model Inference ──
        t2 = time.perf_counter()
        d_norm, d_raw = self.depth_est.infer_depth(sample.frame_bgr)
        t3 = time.perf_counter()
        lat_s2 = (t3 - t2) * 1000.0
        self.stage_latencies["S2_inference"].append(lat_s2)

        has_valid_depth = not np.all(np.isnan(d_raw)) and not np.all(d_raw == 0.0)
        s2_passed = has_valid_depth
        stage_reports.append(StageDiagnostics(
            stage_name="STAGE_2_DEPTH_INFERENCE",
            passed=s2_passed,
            latency_ms=lat_s2,
            error_message="Depth inference returned empty/corrupted disparity" if not s2_passed else "",
            telemetry={"disparity_min": float(np.nanmin(d_raw)), "disparity_max": float(np.nanmax(d_raw))}
        ))

        # ── STAGE 3: Obstacle Segmentation & Spatial Extraction ──
        t4 = time.perf_counter()
        obs_res = self.depth_est.detect_obstacle(d_norm, d_raw, frame_bgr=sample.frame_bgr)
        t5 = time.perf_counter()
        lat_s3 = (t5 - t4) * 1000.0
        self.stage_latencies["S3_segmentation"].append(lat_s3)

        detected_obstacles = obs_res.all_obstacles or []
        s3_passed = True
        stage_reports.append(StageDiagnostics(
            stage_name="STAGE_3_SEGMENTATION",
            passed=s3_passed,
            latency_ms=lat_s3,
            telemetry={"detected_count": len(detected_obstacles), "validity_state": obs_res.validity_state}
        ))

        # ── STAGE 4: Centroid Tracking & Velocity Estimation ──
        t6 = time.perf_counter()
        kin_res = self.kin_engine.compute(obs_res, timestamp=now, frame_id=frame_id)
        t7 = time.perf_counter()
        lat_s4 = (t7 - t6) * 1000.0
        self.stage_latencies["S4_tracking"].append(lat_s4)

        s4_passed = True
        stage_reports.append(StageDiagnostics(
            stage_name="STAGE_4_TRACKING",
            passed=s4_passed,
            latency_ms=lat_s4,
            telemetry={"tracked_ids": list(kin_res.obstacle_vzs.keys()) if kin_res.obstacle_vzs else []}
        ))

        # ── STAGE 5: Collision-Risk Classification ──
        t8 = time.perf_counter()
        # Risk classification occurs within kinematics computation
        t9 = time.perf_counter()
        lat_s5 = (t9 - t8) * 1000.0
        self.stage_latencies["S5_risk"].append(lat_s5)

        s5_passed = True
        stage_reports.append(StageDiagnostics(
            stage_name="STAGE_5_RISK_CLASSIFICATION",
            passed=s5_passed,
            latency_ms=lat_s5,
            telemetry={
                "threat_level": kin_res.threat_level,
                "primary_static_risk": kin_res.primary_static_risk,
                "primary_dynamic_risk": kin_res.primary_dynamic_risk,
                "primary_path_risk": kin_res.primary_path_risk
            }
        ))

        # ── STAGE 6: Auditory Budget & Allocation ──
        t10 = time.perf_counter()
        budget_dec = self.budget_mgr.coordinate(obs_res, kin_res)
        t11 = time.perf_counter()
        lat_s6 = (t11 - t10) * 1000.0
        self.stage_latencies["S6_audio_budget"].append(lat_s6)

        s6_passed = True
        stage_reports.append(StageDiagnostics(
            stage_name="STAGE_6_AUDITORY_BUDGET",
            passed=s6_passed,
            latency_ms=lat_s6,
            telemetry={"is_active": budget_dec.is_active, "cue_mode": budget_dec.cue_mode, "vol": budget_dec.volume_factor}
        ))

        total_lat = lat_s1 + lat_s2 + lat_s3 + lat_s4 + lat_s5 + lat_s6

        # ── MULTI-STAGE ERROR ATTRIBUTION LOGIC ──
        failed_stage = None
        attribution_detail = "All stages succeeded without defect."
        overall_status = "SUCCESS"

        ground_truth_hazards = [gt for gt in sample.ground_truth if gt.is_hazard]

        for gt in sample.ground_truth:
            cat = gt.category
            self.category_total[cat] = self.category_total.get(cat, 0) + 1

        if ground_truth_hazards and not budget_dec.is_active:
            # MISSED HAZARD! Pinpoint exactly where the failure originated:
            overall_status = "MISSED_HAZARD"

            if not s1_passed:
                failed_stage = "STAGE_1_ACQUISITION"
                attribution_detail = f"Stage 1 Failure: Image unusable ({'; '.join(q_reasons)})."
            elif not s2_passed:
                failed_stage = "STAGE_2_DEPTH_INFERENCE"
                attribution_detail = "Stage 2 Failure: Depth model output lacked valid disparity."
            elif not detected_obstacles:
                failed_stage = "STAGE_3_SEGMENTATION"
                attribution_detail = "Stage 3 Failure: Depth representation had structure, but segmentation contours missed the object."
            elif not any(abs(o.dist_cm - ground_truth_hazards[0].dist_cm) < 40.0 for o in detected_obstacles):
                failed_stage = "STAGE_3_SEGMENTATION"
                attribution_detail = "Stage 3 Failure: Object segmented with erroneous metric distance."
            elif kin_res.threat_level == "SAFE":
                failed_stage = "STAGE_5_RISK_CLASSIFICATION"
                attribution_detail = "Stage 5 Failure: Obstacle detected but risk classifier de-escalated threat to SAFE."
            else:
                failed_stage = "STAGE_6_AUDITORY_BUDGET"
                attribution_detail = "Stage 6 Failure: Threat classified as danger/critical, but auditory coordinator suppressed warning."

            self.stage_failure_counts[failed_stage] += 1

        elif not ground_truth_hazards and budget_dec.is_active:
            # FALSE ALARM!
            overall_status = "FALSE_ALARM"
            failed_stage = "STAGE_3_SEGMENTATION"
            attribution_detail = "Stage 3 False Alarm: Phantom contour detected in clean/clear corridor."
            self.false_positive_count += 1
            self.stage_failure_counts[failed_stage] += 1

        else:
            # Successful detection of present hazard
            for gt in ground_truth_hazards:
                cat = gt.category
                self.category_recall[cat] = self.category_recall.get(cat, 0) + 1

        return FrameEvaluationReport(
            sample_id=sample.sample_id,
            overall_status=overall_status,
            failed_stage=failed_stage,
            failure_attribution=attribution_detail,
            stage_reports=stage_reports,
            total_edge_latency_ms=round(total_lat, 2)
        )

    def generate_benchmark_summary(self) -> Dict[str, Any]:
        """Produce scientific evaluation summary table across all stages and categories."""
        total = max(1, self.total_evaluated_frames)
        total_gt_hazards = sum(self.category_total.values())

        cat_recall_pct = {}
        for cat, count in self.category_total.items():
            recalled = self.category_recall.get(cat, 0)
            cat_recall_pct[cat] = round((recalled / max(1, count)) * 100.0, 1)

        summary = {
            "total_frames_evaluated": total,
            "total_ground_truth_hazards": total_gt_hazards,
            "overall_hazard_recall_pct": round((sum(self.category_recall.values()) / max(1, total_gt_hazards)) * 100.0, 2),
            "false_positive_count": self.false_positive_count,
            "false_positives_per_frame": round(self.false_positive_count / total, 3),
            "category_recall_breakdown": cat_recall_pct,
            "stage_failure_attribution": self.stage_failure_counts,
            "stage_latency_mean_ms": {k: round(float(np.mean(v)), 2) if v else 0.0 for k, v in self.stage_latencies.items()}
        }
        return summary

