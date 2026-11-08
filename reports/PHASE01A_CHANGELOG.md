# HorusEyes 2.0 — Phase 01A Detailed Engineering Changelog
**Project:** HorusEyes 2.0 (Assistive Navigation for Visually Impaired)  
**Directive:** Engineering Directive 01A (Approved for Controlled Implementation)  
**Date:** 2026-11-08  
**Scope:** P0 Safety, Correctness, Numerical Integrity & Cross-Platform Parity

---

## 1. Executive Summary

Phase 01A establishes an auditable, scientifically sound, and safe foundation across the HorusEyes 2.0 system. All synthetic benchmarks, fabricated latency calculations, and dangerous prescriptive steering commands have been eliminated. Depth estimation, motion tracking, auditory display, and cross-platform mobile implementations have been aligned with physical reality and safety-critical principles.

---

## 2. Comprehensive File-by-File Modifications

### 2.1. `depth_engine.py` (Desktop Depth Processing Engine)

- **Original Problem & Safety Hazard:**
  1. *NaN/Inf silent propagation:* The custom pure-NumPy and SciPy fallback PCHIP interpolators produced erroneous values or crashed when processing NaN/Inf disparity inputs.
  2. *Corridor False-Negative:* Raw disparity 250 was falsely assumed to represent $\ge 250$ cm (PCHIP knot $K_3$ actually maps raw 250 to 237.2 cm), and unverified uniform depth was marked as `"SAFE"`.
  3. *Dangerous Saturation Semantics:* Raw 800 was conflated with an arbitrary 13 cm saturation clamp instead of its true PCHIP knot value of 30.0 cm ($K_9$).
  4. *Missing Input Validation:* Frames with dead camera feeds, corrupt buffers, or invalid shapes were processed blindly, often returning a false 350.0 cm "SAFE corridor".

- **Root Cause:**
  - Lack of edge-case assertion in PCHIP mathematical fallback.
  - Conflation of model saturation with metric distance.
  - Lack of a front-end sensor validation gate in `detect_obstacle`.

- **Exact Modifications:**
  - **PCHIP NaN Preservation:** Modified `PchipInterpolator.__call__` to explicitly isolate NaNs via `np.isnan(x)` and assign `res[is_nan] = np.nan`.
  - **Metric Distance Validation:** In `compute_metric_distance_cm()`, added an immediate guard: if `math.isnan(disp)` or `math.isinf(disp)`, return `float('nan')`.
  - **Sensor Fault Gate (Step 0):** Added `_create_sensor_fault_result()` in `detect_obstacle()`. Triggers if input is `None`, empty, non-2D, or has $>15\%$ NaN/Inf elements, returning `SENSOR_FAULT_INVALID_INPUT` with `is_scale_uncalibrated = True` and zero clearance.
  - **Saturation vs. Distance Separation (Step 1):** Raw 800 is mapped strictly to 30.0 cm ($K_9$) and raw 1200 to 13.0 cm ($K_{11}$). Emergency lens saturation warning is triggered without fabricating distance.
  - **Clear Path Labeling (Step 3):** When no obstacle is detected, `mode_text` is explicitly set to `"NO_OBSTACLE_DETECTED (Unverified Path)"` with `is_scale_uncalibrated = True` to signify that monocular scale remains unverified without LiDAR.

- **Why It Is Safer:**
  - Corrupt or blinded camera frames immediately trigger a sensor fault rather than deceiving a visually impaired user into walking into an undetected hazard.
  - Physical distance estimates correspond 1:1 with calibrated spline knots.

- **Possible Regressions / Mitigations:**
  - Downstream modules expecting a string containing `"SAFE"` will need to handle `"NO_OBSTACLE_DETECTED"`. All tests and HUD components have been updated accordingly.

---

### 2.2. `motion_ttc.py` (Kinematics & Hazard Direction Engine)

- **Original Problem & Safety Hazard:**
  1. *Unconditional Ego-Motion Floor:* `effective_vz = max(ovz, 120.0)` was unconditionally applied to frontal obstacles, forcing an artificial 120 cm/s closing speed onto completely stationary obstacles in front of a stationary user. This generated continuous false CRITICAL alarms.
  2. *Prescriptive Autonomous Steering:* The engine outputted `safe_direction = "LEFT"` or `"RIGHT"`, commanding the user to turn into adjacent sectors whose traversability had never been verified (e.g., could be a cliff or wall).
  3. *Inverted Evasion Logic:* Evasion detection used arbitrary thresholds that failed during stationary head turns.

- **Root Cause:**
  - Premature autonomy: attempting to solve navigation rather than situational awareness.
  - Hardcoded heuristic velocity assumption without camera ego-motion estimation.

- **Exact Modifications:**
  - **Removed Artificial Velocity Floor:** Replaced `effective_vz = max(ovz, 120.0)` with measured relative velocity $v_{rel} = ovz$.
  - **Motion State Classification:** Added explicit states: `APPROACHING` ($ovz \ge 20$ cm/s), `RECEDING` ($ovz \le -20$ cm/s), `STATIONARY` ($-20 < ovz < 20$ cm/s), and `UNKNOWN`.
  - **TTC Calculation:** Finite TTC ($Z / v_{rel}$) is calculated *only* when the state is `APPROACHING` and closing speed is positive. Stationary objects receive $TTC = \infty$, eliminating false looming alarms.
  - **Eliminated Prescriptive Steering:** Removed `ESCAPE_LEFT` and `ESCAPE_RIGHT`. Added `hazard_direction` (`"LEFT"`, `"CENTER"`, `"RIGHT"`, `"NONE"`).
  - **Guidance State Protocol:** `guidance_state` is set to `"HAZARD_BLOCKED (STOP)"` (if all 3 sectors blocked), `"DROP_OFF_WARNING"` (negative obstacle), `"HAZARD_DETECTED"` (obstacle present), or `"PATH_UNVERIFIED"`. `safe_direction` is restricted to `"STOP"` or `"NONE"`.
  - **Closed-Loop Evasion Verification:** `is_evading` now verifies that the user is turning away from the detected `hazard_direction`.

- **Why It Is Safer:**
  - Prevents directing visually impaired users into unverified spaces.
  - Drastically reduces cognitive fatigue by eliminating false looming alarms on stationary objects.

- **Possible Regressions / Mitigations:**
  - If user is walking forward without IMU integration, relative closing speed is derived purely from depth differential $\Delta Z / \Delta t$. Addressed via Kalman smoothing.

---

### 2.3. `auditory_budget.py` (Acoustic Display & Budget Manager)

- **Original Problem & Safety Hazard:**
  - *Inverted Panning Hazard:* The audio engine panned sound to the *opposite* sector of the hazard (`pan = -0.75 if safe_dir == "LEFT"`), tricking blind users into hearing acoustic alerts where no obstacle was present and moving toward the actual hazard.

- **Root Cause:**
  - Misguided assumption that audio panning should indicate where the user should walk, rather than where the obstacle is located.

- **Exact Modifications:**
  - **Direct Spatial Hazard Localization:** Audio panning now directly reflects the spatial azimuth of the hazard: `outputPan = float(np.clip(winnerObs.pan, -1.0, 1.0))`.
  - **Blocked Corridor Panning:** If `safe_direction == "STOP"`, `pan = 0.0` (centered binaural warning).

- **Why It Is Safer:**
  - Adheres to universal human psychoacoustics: a sound from the right warns of an obstacle on the right.

---

### 2.4. `telemetry_gui.py` (Desktop Visual Telemetry)

- **Original Problem:**
  - Displayed prescriptive green arrows (`SAFE ESCAPE: -> RIGHT`), visually reinforcing unverified steering directions.
  - Missing `math` import resulting in runtime crash on certain frames.

- **Exact Modifications:**
  - Added `import math`.
  - Replaced prescriptive steering banners with objective hazard notifications: `HAZARD DETECTED: [SECTOR] ([Z]cm)` or `[STOP - ALL PATHS BLOCKED]`.

---

### 2.5. `benchmark_master_suite.py` (Scientific Benchmark Suite)

- **Original Problem:**
  - Latencies were synthesized using formulaic Gaussian noise (`38.2 + np.random.normal(0, 0.4)`).
  - NYU dataset benchmarks fabricated 200 data points per zone with synthetic jitter.
  - Contained absolute user paths (`C:\Users\DELL\...`).
  - Distorted NYU zone definitions.

- **Exact Modifications:**
  - Replaced all synthetic latency generators with real wall-clock instrumentation using `time.perf_counter_ns()`.
  - Removed synthetic loops, jittering, and fabricated augmentations.
  - Standardized dataset paths to repository-relative `data/close_range/`.
  - Corrected NYU zone boundaries to physical standards: Critical $<40$ cm, Danger $40-80$ cm, Warning $80-140$ cm, Clear $\ge 140$ cm.
  - Added explicit disclaimers regarding monocular depth scale limitations.

---

### 2.6. Cross-Platform Parity: Android & iOS

- **Files Modified:**
  - Android: `AuditoryBudgetManager.kt`, `KinematicsEngine.kt`, `DepthEngine.kt`, `OverlayView.kt`
  - iOS: `AuditoryBudgetManager.swift`, `KinematicsEngine.swift`, `ContentView.swift`
- **Modifications:**
  - Synchronized removal of `ESCAPE_LEFT` and `ESCAPE_RIGHT`.
  - Synchronized direct hazard audio panning (`winnerObs.pan`).
  - Aligned Android depth sector percentiles to 0.80 across Left, Center, and Right.
  - Replaced mobile HUD banners with objective hazard localization alerts.

