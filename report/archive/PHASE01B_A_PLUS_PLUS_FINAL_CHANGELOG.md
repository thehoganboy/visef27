# HORUSEYES 2.0 — PHASE 01B-A++ FINAL CHANGELOG
**Document ID:** `REPORT-01B-A++-FINAL-CHANGELOG`  
**Classification:** P0 Safety Correctness & P1 Runtime Reliability  
**Base Commit:** `14f54ad`  
**Working Branch:** `fix/phase-01b-a-plus-plus`  
**Date:** 2026-11-09  

---

## 1. Executive Summary

In compliance with **FINAL ENGINEERING DIRECTIVE 01B-A++**, this work package finalizes the safety-critical state semantics, eliminates frame-rate-dependent warning durations, verifies camera freeze watchdogs, reconciles benchmark methodology, and synchronizes behaviors across Python, Android Kotlin, and iOS Swift.

No models were replaced, no new sensor dependencies (LiDAR/ToF) were introduced, no autonomous steering logic was restored, and no uncalibrated physical safety claims were made.

---

## 2. Inventory of Modified Source Files

| Component | File Path | Scope of Modification |
|---|---|---|
| **Python Kinematics** | [`motion_ttc.py`](file:///e:/visef27%20project/motion_ttc.py) | 6-state taxonomy, startup `INITIALIZING`/`UNKNOWN`, `NO_HAZARD_DETECTED_IN_OBSERVED_REGION`, camera-rotation pan guard, frame watchdog `check_watchdog()` |
| **Python Auditory Budget** | [`auditory_budget.py`](file:///e:/visef27%20project/auditory_budget.py) | Monotonic time-based 1.5s reminder duration (`UNRESOLVED_REMINDER_DURATION_SEC`), camera stall handling |
| **Python Diagnostics** | [`diagnose_system.py`](file:///e:/visef27%20project/diagnose_system.py) | Synchronized Scenario 18 with `OBSERVED_LOW_RISK` and `NO_HAZARD_DETECTED_IN_OBSERVED_REGION` |
| **Android Kotlin Kinematics** | [`KinematicsEngine.kt`](file:///e:/visef27%20project/android/app/src/main/java/com/horuseyes/app/kinematics/KinematicsEngine.kt) | Parity for `INITIALIZING`, rotation guard, `NO_HAZARD_DETECTED_IN_OBSERVED_REGION`, `checkWatchdog()` |
| **Android Kotlin Budget** | [`AuditoryBudgetManager.kt`](file:///e:/visef27%20project/android/app/src/main/java/com/horuseyes/app/budget/AuditoryBudgetManager.kt) | Monotonic time-based 1.5s reminder duration (`UNRESOLVED_REMINDER_DURATION_SEC`) |
| **iOS Swift Kinematics** | [`KinematicsEngine.swift`](file:///e:/visef27%20project/ios/HorusEyes/Kinematics/KinematicsEngine.swift) | Parity for `INITIALIZING`, rotation guard, `NO_HAZARD_DETECTED_IN_OBSERVED_REGION`, `checkWatchdog()` |
| **iOS Swift Budget** | [`AuditoryBudgetManager.swift`](file:///e:/visef27%20project/ios/HorusEyes/Budget/AuditoryBudgetManager.swift) | Monotonic time-based 1.5s reminder duration (`UNRESOLVED_REMINDER_DURATION_SEC`) |
| **Controlled Benchmark** | [`tests/benchmark_controlled_p1_f03.py`](file:///e:/visef27%20project/tests/benchmark_controlled_p1_f03.py) | 500-frame controlled profiling suite separating T1–T5 Core Perception from T1–T6 HUD |
| **Adversarial Suite** | [`tests/test_phase01b_a_plus_plus_adversarial.py`](file:///e:/visef27%20project/tests/test_phase01b_a_plus_plus_adversarial.py) | 8 unit tests covering startup safety, rotation immunity, preemption, 1.5s timer, and watchdog |
| **Golden Test Cases** | [`tests/golden_test_cases.json`](file:///e:/visef27%20project/tests/golden_test_cases.json) | Added GOLDEN-11, GOLDEN-12, and GOLDEN-13 cross-platform test cases |
| **Test Manifest** | [`reports/test_manifest.json`](file:///e:/visef27%20project/reports/test_manifest.json) | Upgraded to v2.4.0 with Suite 09 (Adversarial) and Suite 10 (Profiling Benchmark) |

---

## 3. Detailed Root Causes & Code Modifications

### 3.1. Task P0-F01: Safe-State Semantics & Startup Initialization

#### Root Cause
1. On boot (frame 0/1), before any depth frames or tracking statistics were accumulated, the system previously reported `SAFE` or `PATH_CLEAR_CONFIRMED`.
2. When an obstacle was lost because the user turned the phone away, the newly framed clear region satisfied the 3-frame clear corridor counter, asserting that the old hazard was resolved and the corridor was physically safe.
3. Monocular relative depth was being semantically labeled as `PATH_CLEAR_CONFIRMED`, conflating model-predicted uncalibrated distances with verified physical obstacle-free space.

#### Code Modifications
- In [`motion_ttc.py`](file:///e:/visef27%20project/motion_ttc.py):
  - Initialized `hazard_state = "INITIALIZING"`, `threat_level = "UNKNOWN"`, and `guidance_state = "PATH_UNVERIFIED"` during initial frames.
  - Replaced `PATH_CLEAR_CONFIRMED` with `NO_HAZARD_DETECTED_IN_OBSERVED_REGION` and `OBSERVED_LOW_RISK`.
  - Added pan-rotation tracking before the coasting check to detect camera turns:
    ```python
    is_rotating_away = is_camera_rotating or (abs(d_pan) > 0.15)
    if is_rotating_away:
        self.consecutive_clear_frames = 0
    ```
  - Ported identical state logic to Android [`KinematicsEngine.kt`](file:///e:/visef27%20project/android/app/src/main/java/com/horuseyes/app/kinematics/KinematicsEngine.kt) and iOS [`KinematicsEngine.swift`](file:///e:/visef27%20project/ios/HorusEyes/Kinematics/KinematicsEngine.swift).

---

### 3.2. Task P1-F02: FPS-Independent Reminder Duration & Watchdog

#### Root Cause
1. In `auditory_budget.py`, `unresolved_reminder_count <= 20` was indexed by video frames. At 5 FPS, 20 frames took 4.0 seconds; at 30 FPS, it took only 0.67 seconds.
2. If the camera froze or inference stalled, the frame loop stopped executing, indefinitely displaying the last computed hazard state and never detecting the fault.

#### Code Modifications
- In [`auditory_budget.py`](file:///e:/visef27%20project/auditory_budget.py):
  - Added `self.UNRESOLVED_REMINDER_DURATION_SEC = 1.5` seconds.
  - Replaced the frame counter with real-time interval calculation:
    ```python
    elapsed_unresolved = current_timestamp - kinematics_res.lost_timestamp
    if elapsed_unresolved <= self.UNRESOLVED_REMINDER_DURATION_SEC:
        cue_mode = "CAUTION_REMINDER"
        volume_factor = 0.35
    else:
        cue_mode = "STANDBY_UNRESOLVED"
        volume_factor = 0.0
    ```
- In [`motion_ttc.py`](file:///e:/visef27%20project/motion_ttc.py):
  - Added `check_watchdog(current_timestamp, timeout_sec=1.0)`:
    If `current_timestamp - self.last_frame_timestamp > timeout_sec`, the engine sets `hazard_state = "SENSOR_FAULT"` and `threat_level = "CAMERA_STALLED"`, clearing active tracks to prevent stale hazard retention.
  - Ported identical time calculations to Android [`AuditoryBudgetManager.kt`](file:///e:/visef27%20project/android/app/src/main/java/com/horuseyes/app/budget/AuditoryBudgetManager.kt) and iOS [`AuditoryBudgetManager.swift`](file:///e:/visef27%20project/ios/HorusEyes/Budget/AuditoryBudgetManager.swift).

---

### 3.3. Task P1-F03: Controlled Benchmarking Suite

#### Root Cause
In Phase 01B-A+, the recorded 89.37 ms latency included the Telemetry HUD canvas compositing (~20–35 ms), whereas in preliminary Phase 01B-A++ notes, 61.23 ms measured only Core Perception (T1–T4). Comparing these two figures created an inconsistent benchmark claim.

#### Code Modifications
- Created [`tests/benchmark_controlled_p1_f03.py`](file:///e:/visef27%20project/tests/benchmark_controlled_p1_f03.py):
  - Enforces 50 warm-up frames followed by 500 measured frames under identical CPU conditions.
  - Profiles individual stages: T1 (Inference), T2 (PCHIP/Obstacle), T3 (Observability), T4 (Kinematics/TTC), T5 (Budget/Audio), and T6 (Telemetry HUD).
  - Explicitly separates **Core Perception (T1–T5)** from **Full Processing Pipeline (T1–T6 with HUD)**.
  - Directly compares full-resolution $640 \times 480$ `CV_64F` vs optimized $160 \times 120$ `CV_16S` Laplacian on 100 iterations.
  - Saves all 500 records to `reports/benchmark_raw_measurements.json` and `reports/benchmark_raw_measurements.csv`.

---

## 4. Regression Risks & Mitigations

| Risk | Likelihood | Impact | Applied Mitigation |
|---|---|---|---|
| **Auditory fatigue during persistent lost state** | Low | Low | Reminder strictly silences after 1.5s real time to `STANDBY_UNRESOLVED` (vol 0.0) while preserving visual/system uncertainty. |
| **New hazard delayed by stale track** | Low | Critical | New critical obstacle ($Z < 80\text{ cm}$) immediately preempts stale coasting or unresolved tracks without waiting for reminder expiration. |
| **Camera freeze unnoticed by UI** | Low | High | `check_watchdog()` fires at $> 1.0\text{s}$ timeout, marking `SENSOR_FAULT` and preventing display of stale safe conditions. |
| **Clock skew or non-monotonic timestamps** | Medium | Medium | Kinematics engine checks `dt <= 0` and caches last valid velocity, preventing division-by-zero or negative time intervals. |
