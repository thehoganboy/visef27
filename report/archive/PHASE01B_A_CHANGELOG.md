# HorusEyes 2.0 — Phase 01B-A Detailed Engineering Changelog

**Project:** HorusEyes 2.0 (Assistive Navigation for Visually Impaired)  
**Directive:** Engineering Directive 01B (Phase 01B-A Implementation)  
**Supervising:** Technical Project Manager (PM) & Chief Technology Officer (CTO)  
**Date:** 2026-11-08  
**Scope:** Perception Robustness, Spatial Validity, Hazard Persistence, Risk Decoupling & Parity  

---

## 1. Overview of Modifications

Phase 01B-A delivers the core algorithmic and safety enhancements mandated by Directive 01B (Section 4). All changes strictly adhere to the monocular RGB camera-only constraint, rejecting any dependency on LiDAR or active depth sensors.

The primary improvements implemented across the Python reference pipeline, Android Kotlin codebase, and iOS Swift codebase include:
1. **Task A3 — Multi-Level Spatial Validity Analysis (`depth_engine.py`)**
2. **Task A2 — Phone Rotation vs. Body Evasion Separation & Hazard Coasting (`motion_ttc.py`, `auditory_budget.py`, Android & iOS)**
3. **Task A4 — Decoupled Static Proximity vs. Dynamic Looming Risk (`motion_ttc.py`)**
4. **Warning Volume Preservation (0 dB attenuation for hazards in path)**
5. **Standardized Cross-Platform Golden Test Suite (`tests/golden_test_cases.json`)**

---

## 2. File-by-File Detailed Engineering Changes

### 2.1. `depth_engine.py` (Desktop Depth Processing Engine)

- **Problem:**
  - In Phase 01A, `_create_sensor_fault_result()` checked only the global ratio of NaN/Inf values ($>15\%$). If camera smudge or glare corrupted only the central walking corridor ($pan \in [-0.20, +0.20]$), the global invalid ratio remained under $15\%$, allowing the engine to calculate a false distance and declare a clear path.
  - Sector percentile calculation blindly operated over arrays containing invalid or clamped values, introducing skew into obstacle bounds.
- **Modifications:**
  - Added `validity` and `measurement_basis` fields to `SingleObstacle`.
  - Added `validity_state`, `spatial_validity`, and `measurement_basis` to `ObstacleDetectionResult`.
  - Implemented **Step 0 Multi-Level Spatial Validity Analysis**:
    ```python
    # Measures global and regional invalidity
    global_invalid_ratio = float(np.mean(invalid_mask))
    left_invalid_ratio = float(np.mean(invalid_mask[:, :w_third]))
    center_invalid_ratio = float(np.mean(invalid_mask[:, w_third:2*w_third]))
    right_invalid_ratio = float(np.mean(invalid_mask[:, 2*w_third:]))
    corridor_invalid_ratio = float(np.mean(invalid_mask[:, int(w*0.35):int(w*0.65)]))
    ```
  - Introduced concentrated invalidity guard:
    - If `center_invalid_ratio > 0.20` or `corridor_invalid_ratio > 0.20`, sets `validity_state = "DEGRADED"`, `is_valid = False`, `mode_text = "VISUAL_EVIDENCE_DEGRADED"`, and sets `dist_center = float('nan')`.
  - Updated sector percentile calculations to evaluate only valid non-NaN pixels if sector invalidity is $\le 20\%$.

### 2.2. `motion_ttc.py` (Kinematics & Risk Engine)

- **Problem:**
  - **Phone Rotation False Evasion:** A small tilt or rotation of the phone caused $\Delta pan < -0.03$, triggering `is_evading = True` and cutting auditory volume in half or muting alerts when an obstacle left the frame, while the user was still walking directly toward the physical object.
  - **Stationary Close Obstacles Silenced:** Stationary obstacles at $30\text{ cm}$ produced $v_z \approx 0$, yielding $TTC = \infty$, which under dynamic-only classification caused the system to report low danger.
  - **Peripheral False Alarms:** Objects moving laterally across the periphery were assigned high collision risk even though their trajectory did not intersect the user's traversal corridor.
- **Modifications:**
  - **Decoupled Static and Dynamic Risk:**
    ```python
    # Static proximity risk
    if dist <= 40.0: static_risk = "CRITICAL"
    elif dist <= 80.0: static_risk = "WARNING"
    elif dist <= 150.0: static_risk = "INFO"
    else: static_risk = "SAFE"

    # Dynamic closing risk
    if ttc is not None and ttc <= 1.0 and path_risk == "CORRIDOR": dynamic_risk = "CRITICAL"
    elif ttc is not None and ttc <= 2.0 and path_risk == "CORRIDOR": dynamic_risk = "WARNING"
    else: dynamic_risk = "NONE"

    # Unified risk escalation
    threat_level = max_risk(static_risk, dynamic_risk)
    ```
  - **Phone Rotation vs. True Evasion Separation:**
    - `is_evading = True` requires physical clearance: distance increase $\Delta Z \ge 15.0\text{ cm}$, receding speed $v_z \le -20.0\text{ cm/s}$, and peripheral pan $|pan| > 0.65$. Rotation alone no longer triggers evasion.
  - **5-Frame Hazard Coasting Buffer:**
    - If an active hazard ($Z \le 80\text{ cm}$) suddenly disappears from the camera FOV, the engine retains the threat for up to 5 frames (`hazard_persistence_active = True`, `threat_level = "WARNING"`), preventing blind-spot collisions.
  - **Peripheral Path Risk Classification:**
    - Obstacles with $|pan| > 0.60$ are tagged as `path_risk = "OUTSIDE"` and dynamic threat is de-escalated to avoid unnecessary auditory overload.

### 2.3. `auditory_budget.py` (Desktop Auditory Display Manager)

- **Problem:**
  - `volume_factor = 0.5` ($-6\text{ dB}$) was applied during perceived evasion, attenuating alarms even when an obstacle was within striking distance.
  - Suppression logic muted audio whenever `len(all_obstacles) == 0`, immediately silencing coasting hazards.
- **Modifications:**
  - Preserved **$100\%$ full warning volume** (`volume_factor = 1.0`) for any obstacle located in the traversal corridor.
  - Updated suppression filter: audio is **not muted** if `is_coasting` is active or if sensor validity is degraded (`not obs_res.is_valid`).

### 2.4. Cross-Platform Mobile Synchronizations

- **Android Native (`AuditoryBudgetManager.kt`):**
  - Updated `volumeFactor = 1.0f` to prevent phone rotation from cutting alarm volume.
  - Preserved warning state integrity during evasion maneuvers.
- **iOS Native (`AuditoryBudgetManager.swift`):**
  - Updated `volumeFactor: Float = 1.0` ensuring full audibility.
  - Preserved alarm volume during sudden camera movement.
- **iOS Compilation & UI (`ContentView.swift` & `KinematicsEngine.swift`):**
  - Resolved SwiftUI `@ViewBuilder` syntax violation by extracting `hazardDirectionLabel(pan: Float) -> String`.
  - Corrected obstacle count property reference to `obstacleResult.allObstacles.count`.
  - Verified green build on GitHub Actions CI (Run #25, unsigned IPA generated).

### 2.5. Diagnostic & Test Infrastructure

- **`diagnose_system.py`:**
  - Added **Scenario 14:** Concentrated Corridor Invalidity (verifies that $60\%$ invalidity in the center sector triggers `DEGRADED` state and `NaN` distance, while global invalidity remains $<10\%$).
  - Added **Scenario 15:** Phone Rotation vs. Body Evasion & Coasting Persistence (verifies that camera panning maintains full volume $1.0$ and persists warning for 5 coasting frames).
  - Added **Scenario 16:** Stationary Close Obstacle at $30\text{ cm}$ (verifies `static_risk = "CRITICAL"`, `dynamic_risk = "NONE"`, and immediate warning emission despite $TTC = \infty$).
- **`tests/golden_test_cases.json`:**
  - Created JSON test specification defining 7 golden test cases for cross-platform validation.

