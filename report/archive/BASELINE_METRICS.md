# HORUSEYES 2.0 — BASELINE METRICS & EMPIRICAL BENCHMARK AUDIT
**Role:** Senior Computer Vision Engineer & Safety-Critical Software Engineer  
**Date:** 2026-11-08  
**Target Architecture:** HorusEyes 2.0 (Python Desktop, Android Kotlin, iOS Swift/CoreML)  
**Status:** COMPLETE (Baseline Established)

---

## 1. Overview of Published Benchmarks vs. Reproducible Reality

Prior documentation (`reports/benchmark_summary.md` and `reports/full_benchmark_tum_nyu_report.md`) published several quantitative claims regarding depth accuracy, motion tracking, auditory budget compliance, and edge latency.

A rigorous audit of the benchmark scripts (`benchmark_master_suite.py`, `benchmark_nyu_pipeline.py`) reveals a substantial gap between published claims and what can be scientifically reproduced from physical hardware execution:

| Metric Category | Published Claim in Reports | Actual Reproducible Reality | Provenance / Audit Evidence |
| :--- | :---: | :---: | :--- |
| **Pipeline Latency (CPU)** | **`45.2 ms`** (Mean), **`45.4 ms`** (P95) | **`119.55 ms`** (Mean), **`193.86 ms`** (P95) | Published latency was generated using `np.sin() + np.random.normal()` in `benchmark_master_suite.py:678-681`. Physical measurement via `diagnose_system.py:575-585`. |
| **System Throughput (CPU)** | **`22.1 FPS`** | **`8.4 FPS`** (with HUD) / **`10.1 FPS`** (headless) | Fabricated from the inverted synthetic latency formula `1000.0 / lat_total`. |
| **TUM Dynamic Evaluation** | "Comprehensive Multi-Dataset Benchmark across 6 TUM sequences" | **Only 2 frames evaluated per sequence** (12 frames total) | `reports/full_benchmark_tum_nyu_report.md` Table 2 explicitly records `Frames = 2` for all 6 sequences. |
| **Depth Error (NYU Depth V2)** | MAE: `74.86 cm`, AbsRel: `45.77%` | **AbsRel = 45.77% verified**, but zone slicing had defective boundaries | In `benchmark_master_suite.py:475`, `<80cm` points were placed into `<30cm` bucket. |
| **Critical Zone Error (<30cm)** | MAE: `26.15 cm`, AbsRel: `171.59%` | **AbsRel is 171.59%** (severe error), but claimed "ĐẠT XUẤT SẮC" | `reports/benchmark_summary.md:66` labeled 26.15 cm error against a $\le 10$ cm target as "Excellent". |
| **False-Alarm Rate (FAR)** | Reported as **`100.00%`** | **100% False-Alarm Rate** (all clear frames alarmed) | `reports/full_benchmark_tum_nyu_report.md` Table 4 literally prints `100.00%` and mislabels it as "excellent resistance". |
| **Auditory Budget Compliance** | `100.0%` (Max 1 Stream) | **VERIFIED 100.0%** | Hard architectural mutex in `auditory_budget.py` guarantees $\le 1$ active stream. |
| **PCHIP Monotonicity** | `100.0%` monotonic ($d(dist)/d(raw) < 0$) | **VERIFIED 100.0%** | Tested across 10,000 points in `test_pipeline.py`; zero Runge oscillations. |
| **Memory Leak Stability** | Tracks bounded $\le 10$ | **VERIFIED** (1 track at frame 50, 1 track at frame 500) | Validated in 500-cycle stress test in `diagnose_system.py:588-594`. |

---

## 2. Reproducible Empirical Measurements (Execution Log: 2026-11-08)

The following metrics were physically measured on the local host workstation by executing `diagnose_system.py` and `test_pipeline.py`:

### A. End-to-End Latency Decomposition (500-Cycle Continuous Profiling)
- **Host CPU:** x86_64, Windows 11, Python 3.12, ONNX Runtime 1.20 (Execution Provider: CPUExecutionProvider, Intra-Op Threads: 4).
- **Test Resolution:** 640 x 480 BGR input, MiDaS ONNX Mobile input 160 x 160.

```
==========================================================================================
  BẢNG TỔNG KẾT HIỆU NĂNG 500 CHU KỲ (STRESS TEST & LATENCY PROFILING)
==========================================================================================
  TẦNG XỬ LÝ (PIPELINE STAGE)              | MEAN (ms)  | P50 (ms)   | P95 (ms)   | P99 (ms)  
------------------------------------------------------------------------------------------
  1. T_depth: Spatial Obstacle & Spline    |    98.07 ms |    89.55 ms |   166.83 ms |   209.83 ms
  2. T_motion: Centroid Tracker & v_z Fit  |     1.25 ms |     1.00 ms |     2.73 ms |     4.99 ms
  3. T_budget: Hysteresis Lock-in          |     0.10 ms |     0.08 ms |     0.18 ms |     0.57 ms
  4. T_audio: Thread-safe Audio State Swap |     0.02 ms |     0.02 ms |     0.03 ms |     0.11 ms
  5. T_hud: Side-by-Side Canvas Render     |    20.11 ms |    17.66 ms |    37.42 ms |    52.12 ms
==========================================================================================
  TỔNG ĐỘ TRỄ ĐƯỜNG ỐNG BIÊN (Edge Latency) : Mean=119.55ms | P50=110.06ms | P95=193.86ms | P99=271.07ms
  TỐC ĐỘ XỬ LÝ ĐƯỜNG ỐNG (Throughput)      :    8.4 FPS (CPU Single-Core Execution)
==========================================================================================
```

### B. Headless Algorithmic Latency (Excluding HUD Canvas Rendering)
When HUD graphics rendering (`cv2.imshow`, contour rendering, text rendering, colormap heatmap generation) is omitted:
- **Net Algorithmic Processing Time:** $98.07 + 1.25 + 0.10 + 0.02 = \mathbf{99.44\text{ ms}}$
- **Net Algorithmic Throughput:** **`10.06 FPS`** on CPU single-threaded execution.
- **Hardware Bottleneck:** $T_{depth}$ contributes **98.6%** of total algorithmic runtime. The ONNX inference and spatial Sobel/connected-component extraction represent the sole critical compute constraint.

### C. Numerical Stability & Adversarial Scenario Verification
Executed via `diagnose_system.py` (12 adversarial edge cases):
- **Clear Corridor Muting ($>250$ cm):** PASS (`is_active = False`, `cue_mode = MUTED`, `dist_cm = 250.0 cm`).
- **Lens Saturation Detection ($<15$ cm):** PASS (`modeText = CRITICAL_SATURATED`, `dist_cm = 13.0 cm`, `proximity = 1.0`, `beep_interval = 0.080 s`).
- **Thin Obstacle Survival (2% Area, 70 cm post):** PASS (`modeText = DANGER (<80cm)`, `dist_cm = 70.0 cm`, `is_active = True`).
- **Overhead Hazard (Top 15% ROI):** PASS (`is_overhead = True`, detected at 59 cm).
- **Drop-off Hazard (Bottom 15% ROI):** PASS (`is_drop_off = True`, gradient ratio drop detected).
- **Specular White Wall ($V_{std} < 4$, $Lap < 15$):** PASS (`uncertaintyScore = 0.50`, `cue_mode = ACOUSTIC_BLUR`).
- **CRITICAL Preemption:** PASS (Switches active target from #1 to #2 in 0 frames when $Z \le 40$ cm or $TTC \le 1.0$ s).
- **Anti-Thrashing Stability ($\pm 4\%$ priority oscillation):** PASS (Active ID remained stable on #2 across 12 frames).
- **False Evasion Immunity:** PASS (Camera turn while $Z$ decreasing maintained `is_evading = False`, `volume_factor = 1.0`).
- **0-Lux Blind Defense:** PASS (Under 0-Lux sensor blindness, triggers `SYSTEM_FAULT` tone at 440/330 Hz, non-muted).

---

## 3. Discrepancy & Provenance Analysis

### Discrepancy 1: Fabricated Latency in `benchmark_master_suite.py`
- **Location:** `benchmark_master_suite.py` lines 451–454 and 678–681.
- **Code:**
  ```python
  lat_depth = float(np.clip(38.4 + seq_offset + frame_var, 36.5, 41.5))
  lat_kin = float(np.clip(5.8 + 0.3 * np.cos(idx * 0.5) + float(np.random.normal(0, 0.1)), 5.1, 6.8))
  lat_budget = float(np.clip(0.42 + float(np.random.normal(0, 0.03)), 0.32, 0.55))
  lat_total = lat_depth + lat_kin + lat_budget
  ```
- **Provenance:** These formulas were written as an assumed proxy for Snapdragon 8 Gen 2 hardware rather than measured on any actual device. However, they were presented in `reports/full_benchmark_tum_nyu_report.md` as empirical results of the test suite.
- **Scientific Impact:** Completely invalidates the published latency and FPS claims in that report.

### Discrepancy 2: 2-Frame TUM Dynamic Sequences
- **Location:** `reports/full_benchmark_tum_nyu_report.md` Table 2.
- **Evidence:** Table 2 explicitly shows `Frames = 2` for every sequence. An evaluation of only 2 frames per sequence cannot evaluate tracking stability, ID switches, velocity convergence (which requires at least 4–8 frames for the sliding regression window), or acoustic hysteresis.
- **Root Cause:** The benchmark script was run with `--tum-frames 2` (likely for quick smoke testing) and the output report was committed without re-running the full sequence.

### Discrepancy 3: Mismatched Depth Evaluation Zones in NYU Benchmark
- **Location:** `benchmark_master_suite.py` lines 475–478:
  ```python
  m_crit = (gt_cm < config.DIST_DANGER_CM) & corridor_valid   # DIST_DANGER_CM is 80.0 cm!
  m_dang = (gt_cm >= config.DIST_DANGER_CM) & (gt_cm < config.DIST_WARNING_CM) & corridor_valid # 80 to 140 cm
  m_warn = (gt_cm >= config.DIST_WARNING_CM) & (gt_cm < config.DIST_ALERT_CM) & corridor_valid   # 140 to 200 cm
  m_clear = (gt_cm >= config.DIST_ALERT_CM) & corridor_valid  # >= 200 cm
  ```
- **Provenance:** The variable names in `config.py` were updated (`DIST_CRITICAL_CM = 40.0`, `DIST_DANGER_CM = 80.0`, `DIST_WARNING_CM = 140.0`, `DIST_ALERT_CM = 200.0`), but the benchmark script assigned `m_crit` to `"Critical (<30cm)"`. Furthermore, Kinect v1 cannot record depth below 50 cm; thus, zero real Kinect test points existed below 50 cm. All points in the published "Critical (<30cm)" bucket were actually between 50 cm and 80 cm.

### Discrepancy 4: Mislabeled False-Alarm Rate
- **Location:** `reports/full_benchmark_tum_nyu_report.md` Table 4:
  `False-Alarm Rate - FAR (%): 100.00% | Standard: < 8.0% | Scientific Evaluation: Kháng báo động giả xuất sắc`
- **Root Cause:** A formula error or polarity inversion in `benchmark_master_suite.py:511` caused `clear_frames_false_alarm / clear_frames_total` to evaluate to 1.0 (100%), which was then blindly pasted into the report alongside boilerplate praise text.

---

## 4. Hardware and Software Environment Specifications

To ensure absolute reproducibility of all future Phase 01 benchmarks, the exact operating environment is documented:

### Workstation Environment (Reference Testbed)
- **Operating System:** Microsoft Windows 11 Pro 64-bit (10.0.26100)
- **Host CPU:** 11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz (4 Cores, 8 Threads)
- **RAM:** 16.0 GB DDR4
- **Python Runtime:** Python 3.12.3 (64-bit)
- **Key Python Packages:**
  - `onnxruntime`: 1.20.1
  - `numpy`: 1.26.4
  - `opencv-python`: 4.10.0.84
  - `torch`: 2.4.1+cpu
  - `scipy`: 1.14.1
  - `sounddevice`: 0.5.1
  - `matplotlib`: 3.9.2

### Mobile Target Environments
1. **iOS Target (Native):**
   - **Device:** iPhone 14 Pro
   - **SoC:** Apple A16 Bionic (6 CPU cores, 5 GPU cores, 16-core Apple Neural Engine)
   - **OS:** iOS 17.x / 18.x
   - **Sensors:** 48MP Main Camera (Widescreen 16:9 `.hd1280x720`), LiDAR Scanner (dToF sensor, 5m range), IMU (6-axis gyro/accelerometer).
   - **Frameworks:** Core ML, Vision, Accelerate (vDSP), AVFoundation, CoreMotion.
2. **Android Target (Native):**
   - **Reference Device:** Google Pixel 7 / Samsung Galaxy S23 (Snapdragon 8 Gen 2)
   - **Runtime:** Android 13+ (API 33+), Kotlin 1.9, CameraX, ONNX Runtime Mobile 1.17+, AudioTrack / AAudio.

---

## 5. Missing Data & Unresolved Evaluations

The following datasets and evaluation assets are currently missing or require formal ingestion into the repo:
1. **Curated Close-Proximity Suite ($<50$ cm):**
   - Currently, `benchmark_master_suite.py` points to a temporary user upload folder (`C:\Users\DELL\.gemini\antigravity\brain\11c59d74-2c40-4aa6-8f82-017c0b623774\.user_uploaded`).
   - These 8 ground-truth close-range images must be copied into `data/close_range/` inside the repo and version-controlled.
2. **LiDAR Calibration Pairings for iPhone 14 Pro:**
   - No paired dataset exists in the repo comparing the iPhone 14 Pro LiDAR `sceneDepth` against CoreML MiDaS disparity to determine the optimal fusion knot points.
3. **Full Multi-Frame TUM Dynamic Trajectory Logs:**
   - The TUM sequences in `data/` contain 700–1200 frames each, but full trajectory evaluations (ground truth $v_z$ vs estimated $v_z$) have never been executed across the full sequences.

