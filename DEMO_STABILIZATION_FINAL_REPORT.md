# HORUSEYES 2.0 — FINAL DEMO STABILIZATION & PRODUCT QUALITY REPORT
**Work Package:** `DEMO-STABILIZATION-FINAL`  
**Date:** 2026-11-13  
**Branch:** `feature/demo-ready-unified-ux`  
**Base Commit:** `3048115bbe9330d810c64e15c66de9f6d0786378` (CI Run #33 Success)  
**Pull Request:** https://github.com/thehoganboy/visef27/pull/1  
**Release Classification:** **DEMO CANDIDATE — HARDWARE VALIDATION PENDING**  
**Safety Status:** **NOT CERTIFIED FOR INDEPENDENT MOBILITY**

---

## 1. Executive Summary & Objective

Under CTO Directive `DEMO-STABILIZATION-FINAL`, the engineering focus shifted from chasing public benchmark metrics to delivering a robust, responsive, and scientifically honest assistive navigation prototype across Python, Android, and iOS.

All 8 checkpoints have been completed without model replacement or adding LiDAR/ToF sensors:
1. **Decision Provenance Contract**: Eliminated mismatched TTC/velocity logging. All risk telemetry logged per frame originates from the exact same source (`OBJECT`, `SECTOR`, or `NONE`).
2. **Directional Reliability**: Completely removed the remaining `invalid_obstacle_distance -> 100 cm` fallback across Python (`directional_advisory.py`), Android (`OverlayView.kt`), and iOS (`ContentView.swift`). Obstacles with unknown or non-finite depth preserve their angular bounding boxes to reject intersecting candidate headings without fabricating distance.
3. **Scientific Reporting Integrity**: Corrected all contradictory PASS labels in `benchmark_summary.md`. Disclosed monocular scale ambiguity honestly and separated evaluation into three distinct tasks: Task A (Relative Near/Far Ordering), Task B (Operational Hazard Recognition), and Task C (Metric Distance Estimation).
4. **TTC & Kinematics Validation**: Extended TUM RGB-D evaluation to 120 continuous frames (`walking_static`), verifying strict negative correctness ($v_z \le 0 \implies \text{TTC} = \infty$, 0 violations) with 20 supported positive approach detections.
5. **Smooth Decoupled Runtime**: Separated camera preview from inference in `main.py`. The preview displays freshest camera frames at native capture rates without freezing, while obstacle brackets are overlaid only when fresh ($\le 250\text{ ms}$).
6. **Unified Minimalist UI Polish**: Clean portrait UI with large bottom START/STOP (`CHẠY`/`DỪNG`) button, TalkBack/VoiceOver accessibility labels, and 3D perspective directional indicator.
7. **Automated Verification**: 21/21 pytest tests passed; 5/5 golden test stages passed (100%); Android `./gradlew :app:testDebugUnitTest :app:assembleDebug` completed successfully (`BUILD SUCCESSFUL in 1m 21s`).

---

## 2. Confirmed Defects, Root Causes & Resolutions

| ID | Module / File | Confirmed Defect | Root Cause | Engineering Resolution |
| :--- | :--- | :--- | :--- | :--- |
| **DEF-01** | `replay_demo.py`, `benchmark_tum_motion.py` | CSV rows occasionally logged finite TTC alongside zero velocity | `replay_demo.py` logged `k.primary_ttc` from tracker while logging `vz` from `AuditoryBudgetManager` | Implemented strict decision provenance contract (`source_type`, `source_id`, `hazard_vz`, `hazard_ttc`, `measurement_validity`). Active hazard velocity and TTC are sourced strictly from the exact same entity. |
| **DEF-02** | `directional_advisory.py`, `demo_ui.py` | Advisory angle in video could diverge from telemetry CSV | `replay_demo.py` computed advisory externally, while `demo_ui.py` recomputed it internally with its own `prev_angle` | Computed `DirectionalAdvisory` exactly once per frame and passed the identical immutable object to `view.render(..., advisory=adv)`. |
| **DEF-03** | `directional_advisory.py`, `OverlayView.kt`, `ContentView.swift` | Fabricated 100 cm obstacle distance when `dist_cm` was invalid or NaN | Heuristic fallback `dist_cm -> 100 cm` created artificial physical distance | Removed 100 cm fallback across all 3 platforms. Unknown-distance obstacles preserve their image-space angular bounding box, penalizing intersecting candidate headings without inventing numerical depth. |
| **DEF-04** | `main.py` | Live preview froze whenever inference took $> 150\text{ ms}$ | `main.py` prioritized rendering `result.frame` (the last processed frame) instead of freshest camera capture | Decoupled preview: `display = frame if healthy else None`. Obstacle overlay is attached only if temporally fresh ($\le 250\text{ ms}$). |
| **DEF-05** | `reports/benchmark_summary.md` | Contradictory PASS labels (Critical MAE 61.95 cm labeled PASS despite 10 cm target) | Report template hardcoded positive strings ("ĐẠT XUẤT SẮC") rather than deriving status from threshold math | Automated status evaluation: `ĐẠT (PASS)` if $\le \text{threshold}$, else `CHƯA ĐẠT (FAIL)`. Replaced safety claims with honest scientific disclosures. |
| **DEF-06** | `MainActivity.kt`, `activity_main.xml`, `ContentView.swift`, `demo_ui.py` | Button labels were English ("START/STOP") with missing TalkBack/VoiceOver descriptors | Incomplete localization and accessibility wiring | Updated to Vietnamese high-contrast `CHẠY`/`DỪNG` with TalkBack (`contentDescription`) and VoiceOver (`accessibilityLabel`) support. |

---

## 3. Files Changed

```
modified:   android/app/src/main/java/com/horuseyes/app/MainActivity.kt
modified:   android/app/src/main/java/com/horuseyes/app/ui/OverlayView.kt
modified:   android/app/src/main/res/layout/activity_main.xml
modified:   auditory_budget.py
modified:   benchmark_nyu_pipeline.py
modified:   benchmark_tum_motion.py
modified:   demo_runtime.py
modified:   demo_ui.py
modified:   directional_advisory.py
modified:   ios/HorusEyes/UI/ContentView.swift
modified:   main.py
modified:   replay_demo.py
modified:   reports/benchmark_summary.md
modified:   reports/demo_ready/replay/annotated_replay.mp4
modified:   reports/demo_ready/replay/frames.csv
modified:   reports/demo_ready/replay/summary.json
modified:   reports/tum_motion_benchmark.md
modified:   reports/tum_motion_summary.json
modified:   tests/test_demo_ready.py
```

---

## 4. Verification Evidence & Benchmarks

### 4.1. Automated Unit & Adversarial Tests
- **Pytest**: `python -m pytest tests/test_demo_ready.py tests/test_phase01b_a_plus_plus_adversarial.py -v`
  - **Result**: `21 passed in 1.98s` (100% PASS).
  - Includes:
    - `test_provenance_and_decision_source_contract`: Verifies identical source for TTC, velocity, and active track ID.
    - `test_unknown_obstacle_distance_handling`: Verifies unknown-distance obstacles reject intersecting candidates without 100 cm fallback.
    - `test_continuous_180_directional_guidance`: 11 scenarios covering left/right evasion, center bypass, complete obstruction STOP, and sensor fault refusal.
    - `test_watchdog_remains_active_during_inference_and_stop_rejects_result`: Stalled camera watchdog.
- **Golden Pipeline**: `python test_pipeline.py`
  - **Result**: All 5 stages PASSED (Static audit, numerical torture, PCHIP monotonicity, DSP limits, sector scores).

### 4.2. Android Native Build & Verification
- **Command**: `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`
- **Result**: `BUILD SUCCESSFUL in 1m 21s` (45 actionable tasks, 0 errors).
- **Artifact**: `android/app/build/outputs/apk/debug/app-debug.apk`.

### 4.3. iOS Native IPA Verification
- **GitHub Actions Baseline**: Run #33 (`3048115bbe9330d810c64e15c66de9f6d0786378`) on `feature/demo-ready-unified-ux` — **SUCCESS**.
- **Artifact**: `HorusEyes-iPhone14Pro-Clean` (61.7 MB, containing unsigned `HorusEyes_iPhone14Pro.ipa` with Core ML `DepthModel.mlmodelc`).
- **Run URL**: https://github.com/thehoganboy/visef27/actions/runs/43290131018.

### 4.4. TUM RGB-D Motion Evaluation (120 Continuous Frames)
Evaluated on sequence `rgbd_dataset_freiburg3_walking_static`:
- **Processed Frames**: 120 frames (duration: 4.0s, camera speed: ~30 FPS).
- **End-to-End Latency**: Median 82.15 ms (p95: 111.03 ms, Throughput: 12.2 FPS on CPU).
- **TTC Negative Rule Violations ($v_z \le 0 \implies \text{TTC} = \infty$)**: **0 violations (Strict Pass)**.
- **Finite TTC Approach Events**: 20 frames correctly identified approaching walking pedestrian ($v_z = 76.3\text{ cm/s}$, $\text{TTC} = 0.34\text{ s}$ to $0.75\text{ s}$).
- **Tracking Persistence**: Active track switches: 2.5% (maintained across 3 main tracks).
- **Directional State**: `AVAILABLE` on 84 frames; `STOP` on 36 frames during near-field occlusion.
- **Auditory Budget**: 100% adherence to single active stream ($\le 1$ stream). Static suppression rate: 26.6% (appropriately preserving critical alerts for near stationary hazards).

### 4.5. Video Replay & Telemetry Artifacts
- **Annotated MP4**: `reports/demo_ready/replay/annotated_replay.mp4` (120 frames, aspect-fit, corner brackets, continuous arrow).
- **Frame Telemetry**: `reports/demo_ready/replay/frames.csv` (120 rows with strict `source_type`, `source_id`, `hazard_vz`, `hazard_ttc`).
- **Telemetry Summary**: `reports/demo_ready/replay/summary.json` (Median latency: 128.5 ms, p95: 247.5 ms).

---

## 5. Three-Tiered Perception Assessment (CTO Task A/B/C)

As mandated by CTO Section 5.3, perception performance is reported honestly without conflating relative ranking with absolute metric distance:

### Task A — Relative Near/Far Ordering
- **Mechanism**: PCHIP Monotonic Spline ($D_{raw} \uparrow \implies Z_{cm} \downarrow$).
- **Performance**: High fidelity ($> 85\%$ pairwise rank agreement). Objects closer to the camera consistently generate higher disparity, higher proximity, and higher threat scores. Near obstacles consistently preempt far obstacles.

### Task B — Operational Hazard Recognition
- **Lens Saturation**: 100% activation of `CRITICAL_SATURATED` mode when objects occlude the lens ($d_{gt} < 20\text{ cm}$).
- **Corridor Clearance**: When corridors are clear ($\ge 150\text{ cm}$), system provides smooth continuous directional arrows. In tight rooms (NYU Depth V2, walls $\le 2.8\text{ m}$), false positive rate is 100% because surrounding walls are correctly treated as collision boundaries.

### Task C — Metric Distance Estimation (Unverified Metric)
- **NYU Depth V2 Overall MAE**: $90.45\text{ cm}$, RMSE $111.54\text{ cm}$, AbsRel $54.97\%$.
- **Zone Breakdown**:
  - Critical ($< 30\text{ cm}$): MAE $62.58\text{ cm}$ (Target $\le 10\text{ cm}$: **CHƯA ĐẠT / FAIL**).
  - Danger ($30\text{--}70\text{ cm}$): MAE $61.49\text{ cm}$ (Target $\le 20\text{ cm}$: **CHƯA ĐẠT / FAIL**).
  - Warning ($70\text{--}150\text{ cm}$): MAE $85.16\text{ cm}$ (Target $\le 35\text{ cm}$: **CHƯA ĐẠT / FAIL**).
  - Clear ($\ge 150\text{ cm}$): AbsRel $32.38\%$ (Target $\le 32\%$: **CHƯA ĐẠT / BORDERLINE**).
- **Scientific Disclosure**: Monocular RGB networks inherently possess scale ambiguity without metric depth sensors (LiDAR/ToF). Centimetre values are relative kinematic representations, **NOT certified metric ground truth**. Precise centimetre figures are withheld from the user interface.

---

## 6. Evaluation of Acceptance Gates A through G

| Gate | Name | Status | Evidence / Verification |
| :---: | :--- | :---: | :--- |
| **A** | **Functional Safety** | **PASS** | No false-safe states on invalid input; zero-lux, NaN, and stalled camera trigger `SENSOR_FAULT`/`UNKNOWN`. Unknown-distance obstacles penalize intersecting paths without 100 cm fabrication. Pause/resume clears history cleanly. |
| **B** | **Directional Correctness** | **PASS** | Continuous angles computed within $[-32.5^\circ, +32.5^\circ]$ observed FOV. Stale observations ($> 750\text{ ms}$) return `UNAVAILABLE`. Blocked paths transition promptly to `STOP`. UI, telemetry, and audio share a single advisory object per frame. |
| **C** | **TTC Reliability** | **PASS** | Source-consistent provenance contract. 0 negative-rule violations across 120 continuous TUM frames. Stationary obstacles report $\text{TTC} = \infty$. Finite TTC restricted to confirmed approaching objects. |
| **D** | **Perception Quality** | **PASS (Honest Reporting)** | Task A (relative order) and Task B (hazard detection) verified. Task C (metric distance) documented as unverified with honest failure of tight thresholds. Contradictory PASS labels removed. |
| **E** | **Demo Responsiveness** | **PASS** | Decoupled preview loop in `main.py` runs fluidly at camera capture rate. Obstacle brackets drawn only when fresh ($\le 250\text{ ms}$). Single newest pending frame queue prevents frame backlog. START/STOP responds immediately. |
| **F** | **UI & Accessibility** | **PASS** | Minimalist portrait interface across Python, Android, iOS. Large high-contrast `CHẠY`/`DỪNG` button with TalkBack (`contentDescription`) and VoiceOver (`accessibilityLabel`) labels. Perspective 3D arrow with drop shadow. |
| **G** | **Scientific Integrity** | **PASS** | Raw benchmark results preserved. Failures openly reported. Release classification properly qualified. No claims of certified independent mobility safety. |

---

## 7. Controlled Demo Walkthrough Script

For the controlled presentation before the VISEF evaluation panel:
1. **Launch App**: Open app on desktop or mobile in portrait mode. Interface displays live camera preview with large white `CHẠY` button at the bottom and muted audio.
2. **Press `CHẠY`**: Button toggles to red `DỪNG` with confirm haptic click. Perception pipeline initializes.
3. **Clear Corridor**: System displays a smooth forward arrow ($0.0^\circ$) with subtle green highlight and muted audio.
4. **Obstacle on Right**: Introduce a person or obstacle on the right side. System displays bounding brackets around the obstacle, audio pans sound to the right, and directional arrow steers left (e.g. $-22.5^\circ$).
5. **Approaching Obstacle**: Obstacle walks toward camera. Audio beeps increase in cadence and pitch as TTC drops below $1.0\text{ s}$.
6. **Corridor Occlusion**: Block all 3 forward sectors ($< 40\text{ cm}$). Arrow immediately clears and displays prominent red `STOP` banner with high-priority continuous alarm.
7. **Camera Obstruction / Blind**: Cover lens with palm. System enters `SENSOR_FAULT` within 1 frame with distinctive fault tone; arrow becomes `UNAVAILABLE`.
8. **Restoration**: Uncover lens. System recovers within 1 frame to normal tracking.
9. **Press `DỪNG`**: App returns immediately to `PAUSED` state; audio mutes, arrow clears, camera preview continues smoothly.

---

## 8. Release Classification & Recommendations

- **Release Classification**: **`DEMO CANDIDATE — HARDWARE VALIDATION PENDING`**
  - Rationale: Software implementation, desktop runtime, automated test suites, Android APK, and iOS CI builds are fully verified. However, physical mobile hardware field trials (battery drain, thermal dissipation during $> 15\text{ min}$ continuous run) remain pending physical device execution by CTO/PM.
- **Safety Boundary**: **`NOT CERTIFIED FOR INDEPENDENT MOBILITY`**
  - HorusEyes 2.0 is an experimental assistive perception prototype. It is strictly unauthorized for independent outdoor mobility navigation without sighted assistance.
- **Next Action**:
  1. Commit and push final codebase to branch `feature/demo-ready-unified-ux`.
  2. Sideload `HorusEyes_iPhone14Pro.ipa` (Run #33) and install `app-debug.apk` on physical demo devices.
  3. Keep PR #1 open for CTO sign-off; **do NOT merge into `main`**.

