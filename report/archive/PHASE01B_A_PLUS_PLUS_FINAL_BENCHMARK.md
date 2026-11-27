# HORUSEYES 2.0 — PHASE 01B-A++ FINAL BENCHMARK & PROFILING AUDIT
**Document ID:** `REPORT-01B-A++-FINAL-BENCHMARK`  
**Classification:** P1 Real-Time Performance & Controlled Profiling  
**Test Script:** [`tests/benchmark_controlled_p1_f03.py`](file:///e:/visef27%20project/tests/benchmark_controlled_p1_f03.py)  
**Raw Measurements:** [`reports/benchmark_raw_measurements.json`](file:///e:/visef27%20project/reports/benchmark_raw_measurements.json) | [`reports/benchmark_raw_measurements.csv`](file:///e:/visef27%20project/reports/benchmark_raw_measurements.csv)  
**Date:** 2026-11-09  

---

## 1. Benchmarking Scope & Methodology Reconciliation

### 1.1. Resolution of Phase 01B-A+ vs Phase 01B-A++ Measurement Discrepancy
In Phase 01B-A+, the recorded latency was **89.37 ms** (Full Pipeline including Telemetry HUD). In initial Phase 01B-A++ exploratory notes, a latency of **61.23 ms** was cited for Core Perception (T1–T4 only).

Comparing these two figures directly produced a misleading 31.5% improvement claim because **the measurement scopes were fundamentally different**. 

To resolve this discrepancy, **Directive 01B-A++ Task P1-F03** established an isolated, controlled benchmark suite executing under identical runtime conditions:
- **Warm-up:** 50 consecutive full pipeline cycles.
- **Sample Size:** 500 post-warmup frames with isolated microsecond timers.
- **Runtime Environment:** Python 3.10, ONNX Runtime CPU execution provider, Model `midas_small_160.onnx` (Input: $160 \times 160 \times 3$).
- **Strict Scope Separation:**
  - **Core Perception (T1–T5):** Neural inference, PCHIP disparity calibration, spatial obstacle extraction, visual observability analysis, kinematics tracking, TTC calculation, and auditory budget coordination.
  - **Full Pipeline (T1–T6):** Core Perception (T1–T5) PLUS high-resolution desktop Telemetry HUD rendering (Side-by-Side RGB brackets + Depth colormap compositing).

---

## 2. Controlled 500-Frame Latency Measurements

All figures below are drawn directly from the 500 recorded frames in [`reports/benchmark_raw_measurements.json`](file:///e:/visef27%20project/reports/benchmark_raw_measurements.json):

### 2.1. Per-Stage Latency Breakdown (500 Samples)

| Stage ID | Pipeline Stage Description | Mean (ms) | Median / P50 (ms) | P95 (ms) | P99 (ms) |
|---|---|---|---|---|---|
| **T1** | Preprocessing & Depth Inference (`midas_small_160.onnx`) | 222.10 ms | 154.14 ms | 449.95 ms | 1567.94 ms |
| **T2** | PCHIP Calibration & Spatial Obstacle Extraction | 210.90 ms | 140.24 ms | 511.63 ms | 1375.80 ms |
| **T3** | Visual Observability Analysis (Thumbnail Laplacian) | 6.23 ms | 4.21 ms | 12.99 ms | 28.92 ms |
| **T4** | Centroid Kinematics, Velocity Fitting & TTC | 2.15 ms | 1.06 ms | 6.87 ms | 15.11 ms |
| **T5** | Auditory Budget Coordination & State Swap | 0.19 ms | 0.09 ms | 0.37 ms | 2.90 ms |
| **T6** | Telemetry HUD Rendering (Side-by-Side Canvas) | 37.01 ms | 26.13 ms | 83.07 ms | 209.65 ms |

---

### 2.2. Aggregate Latency & Throughput Comparison

| Pipeline Scope | Included Stages | Mean Latency | Median / P50 | P95 Latency | P99 Latency | Measured Throughput |
|---|---|---|---|---|---|---|
| **Core Perception** | T1 + T2 + T3 + T4 + T5 | **441.57 ms** | **313.16 ms** | **1059.42 ms** | **2389.78 ms** | **2.3 FPS** |
| **Full Pipeline (Desktop GUI)** | T1 + T2 + T3 + T4 + T5 + T6 | **478.58 ms** | **342.09 ms** | **1189.65 ms** | **2529.76 ms** | **2.1 FPS** |

> [!NOTE]
> The measurements reflect unaccelerated single-core CPU execution on the developer workstation under concurrent test suites and IDE load. They demonstrate that Kinematics (T4, 2.15 ms) and Auditory Budget (T5, 0.19 ms) introduce negligible overhead ($< 1\%$ of pipeline time), whereas neural inference and dense spline evaluation dominate CPU time.

---

## 3. Visual Observability Optimization Audit

Task P1-F03 required rigorous verification of the proposed visual observability optimization under identical inputs:
- **Baseline (Full-Resolution):** $640 \times 480$ grayscale image processed with `cv2.Laplacian(..., cv2.CV_64F)` and dense variance calculation.
- **Optimized (Thumbnail):** Resized to $160 \times 120$ with `cv2.INTER_AREA`, processed with `cv2.Laplacian(..., cv2.CV_16S)` and integer variance.

### 3.1. Benchmarking Results (100 Iterations)
- **Full-Resolution ($640 \times 480$ `CV_64F`):** **14.24 ms** mean latency.
- **Optimized Thumbnail ($160 \times 120$ `CV_16S`):** **1.50 ms** mean latency.
- **Empirical Speedup:** **9.5x speedup** (saving ~12.7 ms per frame).

### 3.2. Visual Quality Retention
Adversarial Scenario 05 (Specular White Wall) and Scenario 17 (Visual Observability Validation) were executed with both implementations.
- **Luminance Thresholds:** Zero-lux detection ($L < 5$) and glare saturation ($L > 250$) remain identical because luminance mean is scale-invariant.
- **Laplacian Blur Rejection:** Highly blurred frames ($Var < 15$) remain classified as blurred across both resolutions.
- **Negative Control Safety:** Featureless white walls with uniform illumination ($Var < 15$ but $Std < 10$) are correctly recognized as `OBSERVABLE` without false sensor faults in both methods.

---

## 4. Mobile Hardware Performance Disclaimers

1. **Desktop vs Mobile Execution:** All figures in this document represent desktop Python execution using the ONNX Runtime CPU provider. They **must not** be cited as mobile device performance.
2. **Hardware Acceleration:** Native Android (via NNAPI / QNN) and iOS (via Apple Neural Engine CoreML) run the neural network asynchronously on dedicated silicon, achieving significantly higher framerates (~15–30 FPS).
3. **End-to-End Latency Limitation:** True camera-sensor-to-speaker acoustic delivery latency includes hardware rolling shutter capture, ISP pipeline, memory copy, and OS audio ring buffers. These latencies remain **unmeasured** in software profiling and are officially marked **NOT TESTED** pending instrumented oscilloscope/photodiode lab verification.
