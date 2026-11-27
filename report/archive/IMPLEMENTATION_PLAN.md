# HORUSEYES 2.0 — PHASE 01+ IMPLEMENTATION PLAN
**Role:** Senior Computer Vision Engineer & Safety-Critical Software Engineer  
**Date:** 2026-11-08  
**Scope:** Dependency-Aware Repair Roadmap for Python, Android, iOS, and Benchmarking  
**Status:** PROPOSED (Awaiting PM Approval to Begin Phase 01)

---

## 1. Roadmap Architecture & Dependency Graph

```
[Phase 00: Read-Only Audit & Baseline]  ◄── COMPLETED
                  │
                  ▼
[Phase 01: Core Algorithmic & Safety Repair] (Python Reference)
  ├─ Task 1.1: Eliminate Synthetic Benchmarks & Instrument Real Timers
  ├─ Task 1.2: Remove Prescriptive Steering ("ESCAPE_LEFT/RIGHT") & Refactor Guidance Policy
  ├─ Task 1.3: Eliminate Ego-Motion False Approach on Stationary Users
  ├─ Task 1.4: Ingest Local Test Assets into `data/close_range/`
  └─ Task 1.5: Correct NYU Zone Filtering & Metric Polarity
                  │
                  ▼
[Phase 02: Cross-Platform Parity & Mobile Hardening] (Kotlin & Swift)
  ├─ Task 2.1: Sync Android Sector Percentiles (0.50/0.65 -> 0.80) in DepthEngine.kt
  ├─ Task 2.2: Implement Multi-Object Centroid & IoU Tracker in iOS KinematicsEngine.swift
  ├─ Task 2.3: Reduce Peak Audio SPL (-1.0 dBFS -> -12 dBFS + Dynamic Holding Decay)
  └─ Task 2.4: Integrate iPhone 14 Pro ARKit LiDAR sceneDepth with CoreML Fallback
                  │
                  ▼
[Phase 03: Full Empirical Re-Benchmarking & Scientific Validation]
  ├─ Task 3.1: Execute Full Multi-Frame TUM Dynamic Sequences (100% Real Timers)
  ├─ Task 3.2: Execute Full NYU Depth V2 Benchmark with Ground Truth
  └─ Task 3.3: Publish Validated Reports & Machine-Readable Manifest
```

---

## 2. Detailed Task Breakdown

### TASK 1.1: Eliminate Synthetic Latency Generators & Instrument Real Profiling Timers
- **Target Files:** `benchmark_master_suite.py` (lines 450–456, lines 674–683).
- **Action:**
  - Remove all occurrences of `lat_depth = float(np.clip(38.4 + ...))` and Gaussian random jitter.
  - Implement per-stage wall-clock instrumentation using `time.perf_counter_ns()`.
  - Capture $T_{pre}$, $T_{inference}$, $T_{post}$, $T_{tracking}$, $T_{budget}$, and $T_{audio}$ individually.
- **Proposed Test Case:** Run benchmark over 50 test iterations; assert standard deviation of measurements corresponds to genuine OS thread scheduling variance, with zero mathematical sine/cosine dependencies.
- **Acceptance Criteria:** Every reported latency and throughput value in the terminal and generated markdown is 100% derived from recorded `perf_counter` deltas.

---

### TASK 1.2: Eliminate Prescriptive Steering Commands ("ESCAPE_LEFT/RIGHT")
- **Target Files:**
  - `motion_ttc.py`: lines 678–726
  - `auditory_budget.py`: lines 270–278
  - `android/app/src/main/java/com/horuseyes/app/kinematics/KinematicsEngine.kt`: lines 50–70
  - `ios/HorusEyes/Kinematics/KinematicsEngine.swift`: lines 173–188
- **Action:**
  - Deprecate prescriptive steering commands (`safe_direction = "LEFT"`, `guidance_state = "ESCAPE_LEFT"`) that direct a blind user to move without positive traversability verification.
  - Refactor to **Objective Spatial Hazard Awareness**:
    - The binaural audio pans directly to the **location of the detected hazard** (so the user knows where the obstacle is located).
    - If sector clearance is conveyed, designate it as `SECTOR_CLEARANCE_OPEN` and require positive ground floor plane continuity before indicating an open path.
    - If any drop-off or downward stair is suspected in a sector, immediately force that sector's score to 0.0.
- **Proposed Test Case:** Construct a scene with a left-sector drop-off (`drop_off_hazard = True`). Verify that the system never instructs the user to step left.
- **Acceptance Criteria:** Zero prescriptive steering commands issued without positive planar ground proof; compliance with Directive Rule 10.

---

### TASK 1.3: Eliminate Ego-Motion False Approach on Stationary Users
- **Target Files:**
  - `motion_ttc.py`: lines 535–542
  - `ios/HorusEyes/Kinematics/KinematicsEngine.swift`: lines 110–113
  - `android/app/src/main/java/com/horuseyes/app/kinematics/KinematicsEngine.kt`: lines 414–426
- **Action:**
  - Remove unconditional forced approach velocity `effective_vz = max(ovz, user_walk_est)`.
  - Gate user walking speed by actual motion verification:
    - On mobile (iOS & Android): check CoreMotion / Android Pedometer / Accelerometer variance. If the phone is stationary, $v_{user} = 0$.
    - On Python reference: require physical net displacement $\Delta d \ge \text{MIN\_NET\_DISPLACEMENT\_CM}$ across the sliding window before applying any closing motion velocity.
- **Proposed Test Case:** Feed a static obstacle at 90 cm across 30 frames with zero frame translation.
- **Acceptance Criteria:** $v_z$ settles to 0.0 cm/s; $TTC = \infty$; alert mode is static proximity (`WARNING`), never dynamic looming collision (`CRITICAL`).

---

### TASK 1.4: Refactor Ingestion of Close-Range Suite into Repository
- **Target Files:**
  - `benchmark_master_suite.py`: lines 229–232
  - `data/close_range/`: New directory to house the 8 close-range test images.
- **Action:**
  - Copy all 8 test images from the temporary user-upload path into `data/close_range/`.
  - Update `candidates_dirs` in `benchmark_master_suite.py` to point strictly to `os.path.join(os.path.dirname(__file__), "data", "close_range")`.
- **Proposed Test Case:** Run benchmark on an isolated environment without access to `C:\Users\DELL\.gemini\...`.
- **Acceptance Criteria:** 100% reproducible test suite discovery from repository-internal files.

---

### TASK 1.5: Correct NYU Zone Filtering & False-Alarm Rate Calculation
- **Target Files:**
  - `benchmark_master_suite.py`: lines 475–485, lines 510–515
  - `reports/benchmark_summary.md` & `reports/full_benchmark_tum_nyu_report.md`
- **Action:**
  - Fix stratified zone masks:
    - `m_crit` strictly filters $gt < 30.0$ cm (and notes that Kinect v1 valid points start at 50 cm, so this bucket is evaluated via the close-range suite).
    - `m_dang` filters $30.0 \le gt < 70.0$ cm.
    - `m_warn` filters $70.0 \le gt < 140.0$ cm.
    - `m_clear` filters $gt \ge 140.0$ cm.
  - Fix False-Alarm Rate formula: calculate $FAR = N_{false\_alarms} / N_{clear\_frames}$. Ensure correct polarity and report actual percentage.
- **Proposed Test Case:** Evaluate on 35 NYU test images; verify all bucket ranges match their names.
- **Acceptance Criteria:** Zero boundary mismatch between code variables and table headers; realistic, unmanipulated FAR reported.

---

### TASK 2.1: Establish 100% Sector Percentile Parity in Android `DepthEngine.kt`
- **Target Files:** `android/app/src/main/java/com/horuseyes/app/vision/DepthEngine.kt` (lines 243–245).
- **Action:** Change `percentile(secLSamples, 0.50f)` and `percentile(secCSamples, 0.65f)` to `percentile(..., 0.80f)` across Left, Center, and Right sectors.
- **Proposed Test Case:** Inject a test tensor with a narrow obstacle occupying 20% of sector pixels.
- **Acceptance Criteria:** Android detects narrow obstacle at identical physical distance as Python and iOS ($\pm 1.0$ cm).

---

### TASK 2.2: Implement Multi-Object Centroid & IoU Tracker in iOS `KinematicsEngine.swift`
- **Target Files:** `ios/HorusEyes/Kinematics/KinematicsEngine.swift` (lines 26–105).
- **Action:**
  - Create `TrackedObstacle` class in Swift with independent history deques for time and distance (`historyT: [Double]`, `historyD: [Float]`).
  - Implement bipartite IoU and centroid distance matching with adaptive radius $R = \max(80, 0.45 \cdot \text{diag})$.
  - Track up to 5 concurrent obstacles independently.
- **Proposed Test Case:** Pass two obstacles alternating priority every frame for 30 frames.
- **Acceptance Criteria:** Zero velocity spikes or cross-track contamination; stable velocity estimation per object.

---

### TASK 2.3: Audio Volume Safety Attenuation & Environmental Sound Preservation
- **Target Files:**
  - `config.py`: line 161 (`PEAK_LIMITER_THRESHOLD_DBFS`)
  - `audio_synth.py`: lines 468–477
  - `ios/HorusEyes/Audio/SpatialAudioEngine.swift` & Android `SpatialAudioEngine.kt`
- **Action:**
  - Lower default maximum audio limiter threshold from $-1.0$ dBFS to $-12.0$ dBFS.
  - Implement temporal volume decay: if an obstacle remains in `CRITICAL` or `DANGER` range for $> 3.0$ seconds without closing, decay volume by 6 dB and increase beep interval by $1.5\times$ to prevent continuous sensory blocking.
- **Proposed Test Case:** Feed continuous critical obstacle for 5 seconds; measure synthetic output amplitude before and after 3 seconds.
- **Acceptance Criteria:** Audible warning remains distinct without saturating headphone transducers; ambient acoustic pass-through preserved.

---

### TASK 2.4: Integrate iPhone 14 Pro ARKit LiDAR Depth as Primary Metric Source
- **Target Files:**
  - `ios/HorusEyes/Vision/DepthEngine.swift`
  - `ios/HorusEyes/Vision/CameraTorchManager.swift`
  - `ios/HorusEyes/UI/ContentView.swift`
- **Action:**
  - On devices with LiDAR (iPhone 14 Pro), initialize `ARSession` with `ARWorldTrackingConfiguration.sceneReconstruction = .mesh` and `frameSemantics = .sceneDepth`.
  - In `DepthEngine.swift`, sample `arFrame.sceneDepth?.depthMap` (direct metric float32 meters) as the primary depth source.
  - Use CoreML MiDaS only as a peripheral contextual fill beyond the 5 m LiDAR cutoff.
- **Proposed Test Case:** Run on iPhone 14 Pro; verify depth accuracy within $\pm 2$ cm against laser ground truth.
- **Acceptance Criteria:** Complete elimination of scale/shift ambiguity on iPhone 14 Pro hardware.

---

## 3. Risk Assessment & Mitigations

| Proposed Change | Introduced Risk | Risk Severity | Mitigation Strategy |
| :--- | :--- | :---: | :--- |
| **Switch from steering ("ESCAPE_LEFT") to hazard warning** | Users may initially expect the app to steer them like a car GPS. | Medium | Clear audio documentation explaining that the device is a spatial radar indicating obstacle positions, not an autonomous steering driver. |
| **Lower audio limiter to -12 dBFS** | Alerts might be missed in extremely loud environments (e.g. busy highway). | Medium | Add microphone-based ambient noise auto-gain: monitor ambient SPL and maintain alert level at $\text{ambient} + 6$ dB up to safe max. |
| **ARKit LiDAR on iOS** | Increases battery consumption and thermal load compared to pure AVCapture. | Low | Run LiDAR depth at 15–20 Hz; toggle off mesh reconstruction when simple obstacle ranging is active. |
| **Swift Multi-Object Tracker** | Additional array allocation and matching loop on mobile CPU. | Negligible | $N \le 5$ obstacles; matching matrix $5 \times 5$ takes $< 0.05$ ms. |

---

## 4. Phase 01 Acceptance Criteria & Verification Sign-Off

Phase 01 will be deemed complete and ready for PM sign-off when:
1. `benchmark_master_suite.py` produces 100% reproducible results with zero synthetic numbers.
2. `diagnose_system.py` passes 12/12 tests with all physical timer outputs documented.
3. Prescriptive directional commands are eliminated; spatial hazard localization is verified.
4. Python, Android, and iOS maintain strict mathematical parity across all sector percentiles, knots, and tracker interfaces.
5. All tests in `reports/test_manifest.json` pass without regressions.

