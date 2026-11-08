"""
Controlled Benchmark & Profiling Suite for Directive 01B-A++ Task P1-F03
================================================================================
Compares per-stage latencies, core perception (T1-T5) vs full pipeline (T1-T6),
and validates the visual observability optimization under identical conditions.
Exports raw measurements to JSON and CSV.
================================================================================
"""

import sys
import os
import time
import json
import csv
import numpy as np
import cv2

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from depth_engine import DepthEstimator, assess_visual_observability
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager
from audio_synth import SpatialAudioEngine
from telemetry_gui import TelemetryHUD


def run_controlled_benchmark(num_frames: int = 500, warmup_frames: int = 50):
    print("=" * 80)
    print("  HORUSEYES 2.0 — CONTROLLED PIPELINE PROFILING BENCHMARK (TASK P1-F03)")
    print("=" * 80)
    print(f"[*] Configuration: {warmup_frames} warm-up frames, {num_frames} measured frames.")

    depth_est = DepthEstimator(device="cpu")
    kin_engine = KinematicsEngine()
    budget_mgr = AuditoryBudgetManager()
    audio_engine = SpatialAudioEngine()
    hud = TelemetryHUD()

    h, w = config.CAM_HEIGHT, config.CAM_WIDTH
    dummy_frame = np.full((h, w, 3), 120, dtype=np.uint8)
    cv2.circle(dummy_frame, (int(w * 0.6), int(h * 0.5)), 60, (255, 255, 255), -1)

    print("[*] Performing warm-up cycles...")
    for _ in range(warmup_frames):
        d_norm, d_raw = depth_est.infer_depth(dummy_frame)
        o_res = depth_est.detect_obstacle(d_norm, d_raw)
        k_res = kin_engine.compute(o_res, time.perf_counter())
        dec = budget_mgr.coordinate(o_res, k_res)
        audio_engine.update_state(dec)
        hud.render(dummy_frame, d_norm, o_res, k_res, dec, 30.0, 30.0)

    print(f"[*] Executing {num_frames} measured cycles with isolated per-stage timers...")

    raw_records = []
    t1_list, t2_list, t3_list, t4_list, t5_list, t6_list = [], [], [], [], [], []
    core_list, full_list = [], []

    for frame_idx in range(1, num_frames + 1):
        t_start_total = time.perf_counter()

        # T1: Preprocessing + Depth Inference
        t0 = time.perf_counter()
        d_norm, d_raw = depth_est.infer_depth(dummy_frame)
        t1 = time.perf_counter()

        # T2: PCHIP & Obstacle extraction
        # To isolate T2 from T3, we measure detect_obstacle components
        o_res = depth_est.detect_obstacle(d_norm, d_raw)
        t2 = time.perf_counter()

        # T3: Observability analysis alone
        t_obs0 = time.perf_counter()
        obs_res = assess_visual_observability(dummy_frame)
        t_obs1 = time.perf_counter()

        # T4: Kinematics & TTC
        t3 = time.perf_counter()
        k_res = kin_engine.compute(o_res, t3, frame_id=frame_idx)
        t4 = time.perf_counter()

        # T5: Auditory Budget & Audio State Swap
        t5_0 = time.perf_counter()
        dec = budget_mgr.coordinate(o_res, k_res)
        audio_engine.update_state(dec)
        t5 = time.perf_counter()

        # Core perception total (T1 to T5)
        core_latency = (t5 - t0) * 1000.0

        # T6: Telemetry HUD Rendering
        t6_0 = time.perf_counter()
        hud_canvas = hud.render(dummy_frame, d_norm, o_res, k_res, dec, 30.0, 30.0)
        t6 = time.perf_counter()

        full_latency = (t6 - t_start_total) * 1000.0

        m_t1 = (t1 - t0) * 1000.0
        m_t2 = (t2 - t1) * 1000.0
        m_t3 = (t_obs1 - t_obs0) * 1000.0
        m_t4 = (t4 - t3) * 1000.0
        m_t5 = (t5 - t5_0) * 1000.0
        m_t6 = (t6 - t6_0) * 1000.0

        t1_list.append(m_t1)
        t2_list.append(m_t2)
        t3_list.append(m_t3)
        t4_list.append(m_t4)
        t5_list.append(m_t5)
        t6_list.append(m_t6)
        core_list.append(core_latency)
        full_list.append(full_latency)

        raw_records.append({
            "frame_idx": frame_idx,
            "t1_inference_ms": round(m_t1, 3),
            "t2_obstacle_ms": round(m_t2, 3),
            "t3_observability_ms": round(m_t3, 3),
            "t4_kinematics_ms": round(m_t4, 3),
            "t5_budget_ms": round(m_t5, 3),
            "t6_hud_ms": round(m_t6, 3),
            "core_perception_ms": round(core_latency, 3),
            "full_pipeline_ms": round(full_latency, 3),
        })

    def calc_stats(arr):
        return {
            "mean": round(float(np.mean(arr)), 2),
            "median": round(float(np.median(arr)), 2),
            "p95": round(float(np.percentile(arr, 95)), 2),
            "p99": round(float(np.percentile(arr, 99)), 2),
        }

    summary = {
        "sample_count": num_frames,
        "stages": {
            "T1_depth_inference": calc_stats(t1_list),
            "T2_pchip_obstacle": calc_stats(t2_list),
            "T3_observability": calc_stats(t3_list),
            "T4_kinematics_ttc": calc_stats(t4_list),
            "T5_budget_audio": calc_stats(t5_list),
            "T6_hud_rendering": calc_stats(t6_list),
        },
        "core_perception_T1_T5": calc_stats(core_list),
        "full_pipeline_T1_T6": calc_stats(full_list),
        "core_throughput_fps": round(1000.0 / float(np.mean(core_list)), 1),
        "full_throughput_fps": round(1000.0 / float(np.mean(full_list)), 1),
    }

    # Export raw data to reports/
    reports_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "reports")
    os.makedirs(reports_dir, exist_ok=True)

    json_path = os.path.join(reports_dir, "benchmark_raw_measurements.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({"summary": summary, "per_frame": raw_records}, f, indent=2)

    csv_path = os.path.join(reports_dir, "benchmark_raw_measurements.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(raw_records[0].keys()))
        writer.writeheader()
        writer.writerows(raw_records)

    print("\n" + "=" * 80)
    print("  CONTROLLED BENCHMARK SUMMARY (500 FRAMES)")
    print("=" * 80)
    print(f"  Stage T1 (Depth Inference)    : Mean = {summary['stages']['T1_depth_inference']['mean']:6.2f} ms | P95 = {summary['stages']['T1_depth_inference']['p95']:6.2f} ms")
    print(f"  Stage T2 (PCHIP Obstacle)     : Mean = {summary['stages']['T2_pchip_obstacle']['mean']:6.2f} ms | P95 = {summary['stages']['T2_pchip_obstacle']['p95']:6.2f} ms")
    print(f"  Stage T3 (Observability)      : Mean = {summary['stages']['T3_observability']['mean']:6.2f} ms | P95 = {summary['stages']['T3_observability']['p95']:6.2f} ms")
    print(f"  Stage T4 (Kinematics & TTC)   : Mean = {summary['stages']['T4_kinematics_ttc']['mean']:6.2f} ms | P95 = {summary['stages']['T4_kinematics_ttc']['p95']:6.2f} ms")
    print(f"  Stage T5 (Budget & Audio Swap): Mean = {summary['stages']['T5_budget_audio']['mean']:6.2f} ms | P95 = {summary['stages']['T5_budget_audio']['p95']:6.2f} ms")
    print("-" * 80)
    print(f"  CORE PERCEPTION (T1-T5)       : Mean = {summary['core_perception_T1_T5']['mean']:6.2f} ms | P95 = {summary['core_perception_T1_T5']['p95']:6.2f} ms ({summary['core_throughput_fps']} FPS)")
    print(f"  Stage T6 (Telemetry HUD)      : Mean = {summary['stages']['T6_hud_rendering']['mean']:6.2f} ms | P95 = {summary['stages']['T6_hud_rendering']['p95']:6.2f} ms")
    print("-" * 80)
    print(f"  FULL PIPELINE (T1-T6 with HUD): Mean = {summary['full_pipeline_T1_T6']['mean']:6.2f} ms | P95 = {summary['full_pipeline_T1_T6']['p95']:6.2f} ms ({summary['full_throughput_fps']} FPS)")
    print("=" * 80)
    print(f"  Raw measurements saved to: {json_path} and {csv_path}")

    # ── Observability Comparative Test: 640x480 CV_64F vs 160x120 CV_16S ──
    print("\n[*] Comparing Observability implementations under identical conditions...")
    gray_full = cv2.cvtColor(dummy_frame, cv2.COLOR_BGR2GRAY)
    t_full_list = []
    for _ in range(100):
        t_a = time.perf_counter()
        lap_full = cv2.Laplacian(gray_full, cv2.CV_64F)
        var_full = float(lap_full.var())
        t_b = time.perf_counter()
        t_full_list.append((t_b - t_a) * 1000.0)

    t_opt_list = []
    for _ in range(100):
        t_a = time.perf_counter()
        small_gray = cv2.resize(gray_full, (160, 120), interpolation=cv2.INTER_AREA)
        lap_opt = cv2.Laplacian(small_gray, cv2.CV_16S)
        var_opt = float(lap_opt.var())
        t_b = time.perf_counter()
        t_opt_list.append((t_b - t_a) * 1000.0)

    print(f"  Full-Resolution (640x480 CV_64F): Mean = {np.mean(t_full_list):.2f} ms")
    print(f"  Optimized Thumbnail (160x120 CV_16S): Mean = {np.mean(t_opt_list):.2f} ms")
    print(f"  Observed Speedup: {np.mean(t_full_list) / np.mean(t_opt_list):.1f}x")

    return summary


if __name__ == "__main__":
    run_controlled_benchmark()

