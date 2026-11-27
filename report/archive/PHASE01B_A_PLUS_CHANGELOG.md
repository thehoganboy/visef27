# HORUSEYES 2.0 — PHASE 01B-A+ DETAILED ENGINEERING CHANGELOG
**Work Package:** WP-01B-A+ (Safety, Reliability & Verification Closure)  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Baseline Git Commit:** `e5e884f8f1e682df62eef203e5f3d9e00f972b07` (`origin/main`)  
**Target Review Branch:** `fix/01b-a-plus-safety`  
**Classification:** P0 Safety Closure  

---

## 1. Executive Summary of Changes

Under Engineering Directive 01B-A+ & 01B-B0, WP-01B-A+ executes mandatory safety hardening across Python reference implementation, native Android (Kotlin), native iOS (Swift), and CI/CD automation pipelines. No new sensors or neural models were added. All modifications strictly enforce camera-only passive perception safety principles.

Key fixes include:
1. **Visual Observability vs Numerical Validity Separation (`depth_engine.py`)**: Split validation into numerical tensor validity (`VALID`, `DEGRADED`, `INVALID`) and environmental visual observability (`OBSERVABLE`, `DEGRADED`, `UNOBSERVABLE`) with negative-control guarding for textureless walls.
2. **Evasion Verification Closure (`motion_ttc.py`)**: Completely eliminated dangerous attenuation of audio hazard cues caused by phone rotation; replaced with `COLLISION_RISK_UNRESOLVED` and enforced `is_evading = False` in camera-only operation.
3. **Monotonic Timestamp Hazard Coasting (`motion_ttc.py`)**: Replaced frame-count coasting with monotonic wall-clock retention (`COASTING_DURATION_SEC = 0.60`), maintaining threat level `CRITICAL` without downgrade, with first-frame cache initialization and camera-freeze timeout protection.
4. **Peripheral Corridor Candidate Protection (`motion_ttc.py`)**: Replaced binary `OUTSIDE` classification with `CORRIDOR_CANDIDATE`, `PERIPHERAL_UNVERIFIED`, `TRAJECTORY_INTERSECTION_POSSIBLE`, and `COLLISION_GEOMETRY_UNKNOWN`. Maintained warnings for close off-axis objects ($Z \le 80$ cm, $|pan| \le 0.75$) threatening user shoulder clearance.
5. **Auditory Budget Degradation Awareness (`auditory_budget.py`)**: Ensured warnings are never suppressed or muted when observability or validity is degraded, or when coasting is active.
6. **Cross-Platform Kinematics Alignment (`KinematicsEngine.kt`, `KinematicsEngine.swift`)**: Removed forced $120$ cm/s walking speed assumption on stationary obstacles in iOS; eliminated pan-based evasion attenuation in Android and iOS.
7. **CI/CD Reliability Fix (`.github/workflows/build_ios_ipa.yml`)**: Removed external action `maxim-lobanov/setup-xcode@v1` that suffered HTTP 504 timeouts; replaced with native runner Xcode invocation.

---

## 2. File-by-File Line Diffs and Detailed Technical Rationale

### 2.1. `depth_engine.py`

#### Changes:
1. Enhanced `SingleObstacle` and `ObstacleDetectionResult` dataclasses with `quality_state: str = "OBSERVABLE"` and `quality_reasons: List[str] = field(default_factory=list)`.
2. Implemented `assess_visual_observability(frame_bgr, roi_mask)`:
   - Evaluates scene luminance ($L_{mean} = 0.299R + 0.587G + 0.114B$), dynamic range ($L_{std}$), Shannon entropy ($H$), and Laplacian blur variance ($\sigma_{lap}^2$).
   - Distinguishes underexposure ($L_{mean} < 20.0$), blinding overexposure ($L_{mean} > 240.0$), covered/blocked lens ($L_{std} < 5.0$, $H < 1.0$), and severe motion blur ($\sigma_{lap}^2 < 12.0$).
   - **Negative Control Guard**: A textureless, uniform white wall exhibits low texture variance ($\sigma_{lap}^2 < 20.0$) but normal mid-range luminance ($30 \le L_{mean} \le 225$). The algorithm checks that low variance is NOT classified as `UNOBSERVABLE` when luminance is well within visible bounds, preserving obstacle detection in plain indoor corridors.

#### Diff Excerpt:
```python
@dataclass
class SingleObstacle:
    ...
    quality_state: str = "OBSERVABLE"  # "OBSERVABLE", "DEGRADED", "UNOBSERVABLE"
    quality_reasons: List[str] = field(default_factory=list)

def assess_visual_observability(frame_bgr: np.ndarray, roi_mask: Optional[np.ndarray] = None) -> Tuple[str, List[str]]:
    # Negative control: Plain walls have normal luminance, moderate std
    is_plain_wall = (30.0 <= mean_l <= 225.0) and (5.0 <= std_l <= 45.0)
    if is_plain_wall:
        # Textureless wall is physically observable even if variance is low
        return "OBSERVABLE", []
    ...
```

---

### 2.2. `motion_ttc.py`

#### Changes:
1. **Task A+1: Evasion Verification Closure**:
   - Replaced naive pan-change evasion heuristic with explicit telemetry states: `CAMERA_ROTATION`, `POSSIBLE_RISK_REDUCTION`, `OBSERVED_RELATIVE_RECESSION`, `COLLISION_RISK_UNRESOLVED`, and `EVASION_CONFIRMED`.
   - In monocular RGB mode without full 6-DoF body-mount odometry, `is_evading` is permanently fixed to `False`. The system assigns `COLLISION_RISK_UNRESOLVED` to prevent premature warning muting or volume reduction.
2. **Task A+2: Monotonic Timestamp Hazard Coasting**:
   - Eliminated variable-frame-rate vulnerability (where 5 frames could expire in $150$ ms at 33 FPS or persist for $5.0$ s at 1 FPS).
   - Implemented wall-clock retention: `COASTING_DURATION_SEC = 0.60`.
   - Monitored elapsed monotonic time $\Delta t = t_{now} - t_{last\_seen}$.
   - Maintained original threat level: if an obstacle was `CRITICAL` ($TTC < 1.0$ s or $dist \le 40$ cm), it **remains `CRITICAL`** during coasting; it is **never downgraded to `WARNING`**.
   - Handled identical timestamps ($\Delta t \le 0$) and camera freeze timeouts ($\Delta t > 1.0$ s).
   - Fixed first-frame initialization: cached `self.last_seen_timestamp`, `self.last_threat_level`, and `self.last_hazard_dist` during frame 1 so that dropping an obstacle immediately in frame 2 correctly enters coasting.
3. **Task A+4: Peripheral Risk Calibration**:
   - Expanded boundary assessment into: `CORRIDOR_CANDIDATE`, `PERIPHERAL_UNVERIFIED`, `TRAJECTORY_INTERSECTION_POSSIBLE`, and `COLLISION_GEOMETRY_UNKNOWN`.
   - For close-range off-axis obstacles ($Z \le 80$ cm, $|pan| \le 0.75$), lateral distance is $X = Z \cdot \tan(\theta) \le 80 \cdot \tan(30^\circ) \approx 46$ cm, which encroaches on the user's shoulder envelope ($X \approx 23$ cm). These are classified as `CORRIDOR_CANDIDATE` and assigned threat level `WARNING` with volume factor $1.0$.

#### Diff Excerpt:
```python
# Task A+1: Evasion verification closure
if pan_shift_detected and not dist_increasing:
    evasion_hypothesis = "CAMERA_ROTATION"
    evasion_verification = "COLLISION_RISK_UNRESOLVED"
    is_evading = False  # Mandatory safety fix: never mute audio on rotation alone

# Task A+2: Monotonic timestamp coasting
if last_seen_dt < self.COASTING_DURATION_SEC:
    coasting_active = True
    # Crucial safety rule: Threat level is NEVER downgraded during coasting
    threat_level = self.last_threat_level  # CRITICAL stays CRITICAL

# Task A+4: Peripheral corridor candidate
if dist_cm <= 80.0 and abs(pan) <= 0.75:
    path_risk_assessment = "CORRIDOR_CANDIDATE"
    if threat_level == "SAFE":
        threat_level = "WARNING"
```

---

### 2.3. `auditory_budget.py`

#### Changes:
1. Hardened suppression filters against unsafe muting:
   - If `validity_state` is `DEGRADED` or `INVALID`, or `quality_state` is `UNOBSERVABLE`, audio warnings are NOT suppressed.
   - If `is_coasting` is active, volume attenuation is prohibited (`volume_factor` forced to $1.0$).
   - Prevented false silence during sensor transitions or temporary hazard occlusion.

---

### 2.4. Native Mobile Alignment

#### `android/app/src/main/java/com/horuseyes/app/kinematics/KinematicsEngine.kt`:
- Removed pan-change-based evasion triggering:
  ```kotlin
  // WP-01B-A+ Safety Closure: Evasion cannot be verified from monocular camera rotation alone
  val isEvading = false
  ```
- Ensures Android audio cue volume is not attenuated when the phone swivels.

#### `ios/HorusEyes/Kinematics/KinematicsEngine.swift`:
- Removed artificial forced forward approach speed:
  ```swift
  // Phase 01B-A+ Fix: Decouple static obstacle from forced 120 cm/s approach
  let effectiveVz = smoothedVz // previously max(smoothedVz, userWalkSpeedCmS)
  let isEvading = false
  ```
- Resolves false TTC alarms on distant stationary obstacles while preserving immediate static proximity warnings when $Z \le 40$ cm.

---

### 2.5. CI/CD Workflow (`.github/workflows/build_ios_ipa.yml`)

#### Changes:
- Removed `maxim-lobanov/setup-xcode@v1` dependency, which caused build failures due to external GitHub API HTTP 504 timeouts.
- Used direct `xcodebuild -version` check on GitHub `macos-latest` runners, ensuring deterministic local toolchain execution.
