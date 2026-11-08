# HorusEyes 2.0 — Phase 01B-A Safety & Correctness Audit Report

**Project:** HorusEyes 2.0 (Assistive Navigation for Visually Impaired)  
**Directive:** Engineering Directive 01B (Phase 01B-A Implementation)  
**Supervising:** Technical Project Manager (PM) & Chief Technology Officer (CTO)  
**Date:** 2026-11-08  
**Status:** IMPLEMENTED & AUDITED  
**Priority:** P0 — Safety, Correctness & Scientific Integrity  

---

## 1. Audit Scope & Traceability

This report establishes the verified state of the HorusEyes 2.0 reference pipeline following the execution of **Phase 01A** and the targeted safety enhancements of **Phase 01B-A**.

### 1.1. Reference Commit & Repository State
- **Baseline Commit (Phase 01A):** `b6bd3f1` (*Phase 01A: Implement P0 safety directives, direct hazard localization, zero unverified steering, and benchmark scientific integrity*)
- **Cross-Platform Compilation Fixes:** `6d23224`, `c834f77` (*CI Build #25: green checkmark on iOS unsigned IPA compilation*)
- **Target Implementation (Phase 01B-A):** Monocular RGB perception enhancement, multi-level spatial validity analysis, decoupled static/dynamic risk assessment, and camera-rotation hazard persistence.

### 1.2. Changed Files Audited
| File Path | Component | Scope of Modification |
| :--- | :--- | :--- |
| `depth_engine.py` | Python Depth Processing | Multi-level spatial validity analysis, per-sector valid pixel masking, `validity_state` taxonomy. |
| `motion_ttc.py` | Python Kinematics & TTC | Static/dynamic risk decoupling, 5-frame coasting buffer, phone rotation vs body evasion separation. |
| `auditory_budget.py` | Python Auditory Display | Full warning volume preservation ($1.0$ factor), coasting warning non-suppression. |
| `diagnose_system.py` | Python Adversarial Suite | Addition of Scenarios 14, 15, and 16; verification of all 19 test cases. |
| `test_pipeline.py` | Python Red-Team Suite | PCHIP monotonicity, spatial flip, supply-chain offline guard, cross-platform parity. |
| `tests/golden_test_cases.json` | Cross-Platform Ground Truth | 7 standardized golden test scenarios defining multi-platform input/output contracts. |
| `android/.../AuditoryBudgetManager.kt` | Android Native Budget | Warning volume preservation ($1.0\text{f}$), evasion attenuation elimination. |
| `ios/.../Budget/AuditoryBudgetManager.swift` | iOS Native Budget | Warning volume preservation ($1.0\text{f}$), evasion attenuation elimination. |
| `ios/.../Kinematics/KinematicsEngine.swift` | iOS Kinematics Engine | Compilation fix (`obstacleResult.allObstacles.count`), hazard direction contract. |
| `ios/.../Views/ContentView.swift` | iOS SwiftUI User Interface | Compilation fix (`hazardDirectionLabel` extracted helper, float literal casting). |

---

## 2. Elimination of Unverified Claims and Fabricated Benchmarks

In compliance with Engineering Directive 01B (Principle A & Section 3):

1. **Synthetic Latency Claims Removed:**
   - Pre-computed static claims ("12 ms real-time") have been completely replaced with live wall-clock micro-benchmarking using `time.perf_counter()`.
   - On the reference CPU testbed (Intel Core i7-10610U @ 1.80GHz), single-core pipeline latency is empirically measured at **Mean: 57.72 ms, P50: 54.89 ms, P95: 81.31 ms, P99: 98.34 ms** (~17.3 FPS). No speculative GPU acceleration or theoretical NPU numbers are claimed.

2. **Prescriptive Steering Elimination:**
   - The hazardous `safe_direction = "LEFT" | "RIGHT"` steering commands have been permanently expunged.
   - The engine now outputs strictly `hazard_direction = "LEFT" | "CENTER" | "RIGHT"` with `safe_direction = "NONE"`. The system localizes obstacles and informs the user where threats exist, leaving locomotion decisions to the user.

3. **Arbitrary Saturation Separated from Physical Distance:**
   - Raw disparity saturation ($>800$) is no longer treated as an arbitrary $13\text{ cm}$ metric distance.
   - PCHIP knot $K_9$ ($800 \to 30.0\text{ cm}$) and $K_{11}$ ($1200 \to 13.0\text{ cm}$) are strictly mapped. An explicit `mode_text = "LENS_SATURATION (<15cm)"` triggers emergency alerts without fabricating numerical sensor accuracy.

4. **Corridor Traversability Re-classified:**
   - A uniform disparity field ($raw \approx 250$) is no longer labeled `"SAFE CORRIDOR"`.
   - The system now explicitly designates this state as `"NO_OBSTACLE_DETECTED (Unverified Path)"` with `measurement_basis = "METRIC_ESTIMATED_UNVERIFIED"`, honoring monocular scale ambiguity.

---

## 3. Detailed Audit of Phase 01B-A Safety Enhancements

### 3.1. Task A3: Multi-Level Spatial Validity Analysis
- **Problem Identified in 01A:** The global invalidity guard checked whether global NaN/Inf ratio exceeded $15\%$. However, a user's walking corridor represents only $\approx 16\%$ of the camera frame ($pan \in [-0.20, +0.20]$). A localized lens smudge, intense specular glare, or partial camera obstruction could completely blind the corridor (corridor invalidity $100\%$) while remaining under the global threshold (global invalidity $\approx 16\%$), causing the system to falsely report a clear path.
- **Audited Solution:**
  - Implemented `spatial_validity` computing `global_invalid_ratio`, `left_invalid_ratio`, `center_invalid_ratio`, `right_invalid_ratio`, and `corridor_invalid_ratio`.
  - Added concentrated invalidity guard: if `center_invalid_ratio > 0.20` or `corridor_invalid_ratio > 0.20`, system transitions to `validity_state = "DEGRADED"` and sets center distance to `NaN`, preventing false traversability declarations.
  - Per-sector percentile calculation is restricted strictly to valid pixels (`disp[valid_mask]`) if invalidity is $\le 20\%$.

### 3.2. Task A2: Phone Rotation vs. Body Evasion Separation & Coasting Persistence
- **Problem Identified in 01A:** Panning the camera away from an obstacle produced $\Delta pan < -0.03$. The legacy code flagged this as `is_evading = True`, which attenuated warning volume by $-6\text{ dB}$ ($50\%$ volume) or completely silenced the warning when the obstacle exited the frame. In reality, a visually impaired user often holds the phone with minor tremor or head/torso sway while walking directly toward an obstacle. Muting the hazard under these conditions created a severe collision risk.
- **Audited Solution:**
  - Phone rotation is decoupled from body evasion: `is_evading = True` is only permitted if there is verified physical distance increase ($\Delta Z \ge 15\text{ cm}$), negative closing velocity ($v_z \le -20\text{ cm/s}$), and peripheral pan position ($|pan| > 0.65$).
  - Warning volume is maintained at $100\%$ ($1.0$ factor) for all obstacles within the traversal corridor.
  - Added a 5-frame coasting buffer (`hazard_persistence_active = True`). If an obstacle within $Z \le 80\text{ cm}$ suddenly leaves the camera view due to user movement or camera jerk, the alert persists for up to 5 consecutive frames.

### 3.3. Task A4: Decoupled Static Proximity Risk vs. Dynamic Closing Risk
- **Problem Identified in 01A:** Kinematic risk was evaluated primarily through Time-to-Collision ($TTC = Z / v_z$). When a user stood stationary in front of a wall at $30\text{ cm}$, relative velocity $v_z = 0\text{ cm/s}$, yielding $TTC = \infty$. This caused the system to classify dynamic threat as `SAFE` or `NONE`.
- **Audited Solution:**
  - Evaluated `static_risk` ($Z \le 40\text{ cm} \implies \text{CRITICAL}$, $Z \le 80\text{ cm} \implies \text{WARNING}$) independently of `dynamic_risk` ($TTC \le 1.0\text{ s} \implies \text{CRITICAL}$, $TTC \le 2.0\text{ s} \implies \text{WARNING}$).
  - Final threat level is computed as `max(static_risk, dynamic_risk)`. A stationary obstacle at $30\text{ cm}$ immediately triggers `CRITICAL` alert regardless of $TTC = \infty$.
  - Peripheral crossing objects ($|pan| > 0.60$) are classified as `OUTSIDE` traversal path and de-escalated to prevent alert fatigue.

---

## 4. Execution Trace & Test Verification

All automated test suites were executed on the reference codebase:

```powershell
# Suite 1: Static Code, Supply-Chain & Parity
python test_pipeline.py
# Output: TẤT CẢ CÁC BÀI KIỂM ĐỊNH VÀ TRA TẤN TOÁN HỌC ĐỀU PASS 100%!

# Suite 2: Adversarial Diagnostic Suite (19 Scenarios)
python diagnose_system.py
# Output: 100% (19/19) KỊCH BẢN ĐỀU VƯỢT QUA CHUẨN NGHIỆM THU VISEF!
# Output: Mean Edge Latency = 57.72 ms | P50 = 54.89 ms | P95 = 81.31 ms | Active Tracks 50 vs 500 = 1 (Zero Leak)
```

| Test Group | Test Case ID | Assertion Verified | Result |
| :--- | :--- | :--- | :--- |
| **Pipeline Audit** | Spatial Orientation | Right-side obstacle pan $>+0.30$, `hazard_direction = 'RIGHT'`, `safe_dir = 'NONE'` | **PASS** |
| | Supply Chain | Zero `torch.hub.load` runtime calls, offline enforcement | **PASS** |
| | Monotonicity | 10,000 synthetic points strictly monotonic, bounded $[13, 350]\text{ cm}$ | **PASS** |
| | Kinematics | $v_z$ regression with large Unix timestamps matches $100.00\text{ cm/s} \pm 2\text{ cm/s}$ | **PASS** |
| | Cross-Platform Parity | 11 PCHIP knots match identically across Python, Kotlin, and Swift | **PASS** |
| **Adversarial** | Scenario 01 | Raw 250 maps to $237.2\text{ cm}$, audio muted, unverified path | **PASS** |
| | Scenario 02 | Raw 800 maps to $30.0\text{ cm}$, Raw 1200 maps to $13.0\text{ cm}$ | **PASS** |
| | Scenario 03 | Thin obstacle ($2\%$ area) detected at $70.0\text{ cm}$, mode `DANGER (<80cm)` | **PASS** |
| | Scenario 04 | Overhead hazard ($59\text{ cm}$) and drop-off detected | **PASS** |
| | Scenario 05 | Specular white wall uncertainty ($0.50$), mode `ACOUSTIC_BLUR` | **PASS** |
| | Scenario 06A | Stationary camera + stationary obstacle ($v_z=0$, $TTC=\infty$) | **PASS** |
| | Scenario 06B | Stationary camera + approaching object ($v_z=100$, $TTC=0.85\text{s}$) | **PASS** |
| | Scenario 06C | Moving camera + stationary obstacle ($v_{rel}=80$, $TTC=1.15\text{s}$) | **PASS** |
| | Scenario 06D | Rotating camera + stationary obstacle ($v_z=0$, $TTC=\infty$) | **PASS** |
| | Scenario 07 | Critical preemption bypasses hysteresis lock | **PASS** |
| | Scenario 08 | 12-frame anti-thrashing hysteresis lock | **PASS** |
| | Scenario 09 | Center corridor hazard localization, `safe_direction = 'NONE'` | **PASS** |
| | Scenario 10 | False evasion immunity, `volume_factor = 1.0` | **PASS** |
| | Scenario 11 | Zero-lux flash trigger, AE settle freeze, strobe prevention | **PASS** |
| | Scenario 12 | Camera freeze watchdog triggers `SYSTEM_FAULT` | **PASS** |
| | Scenario 13 | Global invalid depth ($>15\%$) triggers `SENSOR_FAULT` | **PASS** |
| | Scenario 14 | Concentrated corridor invalidity ($>20\%$) triggers `DEGRADED` | **PASS** |
| | Scenario 15 | Phone rotation vs coasting persistence holds warning for 5 frames | **PASS** |
| | Scenario 16 | Stationary close obstacle at $30\text{ cm}$ triggers `CRITICAL` alert | **PASS** |

---

## 5. Residual Risks and Physical Constraints

While Phase 01B-A resolves critical algorithmic and safety vulnerabilities, the following physical constraints remain inherent to monocular vision:

1. **Monocular Scale Ambiguity:**
   - Without active depth sensing (LiDAR / ToF / Stereo), absolute metric scale is inferred via visual priors learned by MiDaS v2.1 Small and calibrated by PCHIP spline. Unseen environments with non-standard ceiling heights or optical geometry may exhibit scale distortion ($\pm 15\% - 25\%$).
   - *Mitigation:* The system labels unverified paths as `METRIC_ESTIMATED_UNVERIFIED` and maintains conservative audio warning thresholds.

2. **Specular and Low-Texture Surfaces:**
   - Mirror surfaces, featureless glossy white walls, or clear glass doors lack monocular depth cues.
   - *Mitigation:* Step 0 uncertainty estimation computes spatial standard deviation and local entropy, triggering `ACOUSTIC_BLUR` when visual confidence is degraded.

3. **Thin Wires and Hanging Cords:**
   - Low-resolution ($160 \times 160$) downsampling suppresses high-frequency spatial features thinner than $2\%$ frame area.
   - *Phase 01B-B Mitigation:* The proposed design integrates edge-preserving Laplacian pyramid filtering and directional Sobel edge enhancement.
