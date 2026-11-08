# HORUSEYES 2.0 — PHASE 01B-A+ SAFETY & VERIFICATION CLOSURE REPORT
**Work Package:** WP-01B-A+  
**Classification:** P0 Safety Architecture Closure  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Target Review Branch:** `fix/01b-a-plus-safety`  

---

## 1. Safety Problem Statements & Root-Cause Analysis

Monocular RGB perception in wearable assistive technology presents unique safety vulnerabilities. Prior to Phase 01B-A+, the codebase suffered from four critical safety defects that could directly endanger visually impaired pedestrians:

### Defect S-01: Premature Hazard Audio Muting from Phone Rotation ("False Evasion")
- **Mechanism**: The original kinematics engine inferred that if an obstacle's normalized horizontal position changed ($|\Delta pan| > 0.15$), the user had successfully performed an evasive sidestep, attenuating the warning volume by $50\%$ or muting the cue entirely.
- **Root Cause**: A handheld or neck-mounted smartphone rotates constantly due to natural torso yaw and arm swing ($15^\circ - 45^\circ / s$). An obstacle shifting from center to right in the camera's image plane merely proves camera angular displacement; it provides zero evidence that the user's torso or legs have navigated around the hazard.
- **Safety Impact**: A user walking straight toward a concrete pillar would have their audio warning muted the moment they turned their phone slightly, leading directly to a collision.

### Defect S-02: Variable Frame-Rate Hazard Dropping ("Frame-Count Coasting Failure")
- **Mechanism**: Hazard coasting was implemented as a simple 5-frame counter (`self.coasting_frames = 5`).
- **Root Cause**: On mobile devices undergoing thermal throttling or background GC pauses, frame rate fluctuates between $33$ FPS and $2$ FPS. At $33$ FPS, 5 frames expire in $150$ ms (insufficient time for human reaction, typically $250 - 450$ ms). At $2$ FPS, 5 frames persist for $2.5$ seconds after an obstacle has been cleared, generating false alarms and blocking new alerts. Furthermore, previous coasting logic erroneously downgraded threat level from `CRITICAL` to `WARNING`.
- **Safety Impact**: Transient tracking dropouts caused critical warnings to vanish before the user could react, or downgraded imminent collision warnings.

### Defect S-03: Shoulder-Envelope Peripheral Hazard Blindness
- **Mechanism**: Obstacles located outside the narrow central corridor ($|pan| > 0.30$) were marked as `OUTSIDE_PATH` and suppressed.
- **Root Cause**: A human torso has a 95th-percentile adult shoulder breadth of $46$ cm ($X = \pm 23$ cm). At a distance of $Z = 50$ cm, an obstacle at $pan = 0.70$ (horizontal angle $\theta \approx 25^\circ$) has a physical lateral offset $X = 50 \cdot \tan(25^\circ) \approx 23.3$ cm. This obstacle is directly in the path of the user's right shoulder.
- **Safety Impact**: Side-swiping injuries from bollards, low walls, doorframes, and scaffolding poles.

### Defect S-04: Conflation of Tensor Validity and Environmental Observability
- **Mechanism**: System validity checked only for numerical NaN, Inf, and tensor shape anomalies.
- **Root Cause**: A camera can produce mathematically flawless float arrays while being physically covered (black image), blinded by direct sunlight (whiteout), or completely motion-blurred. Conversely, a featureless white wall with low Laplacian variance was at risk of false blindness alarms.
- **Safety Impact**: Failure to alert the user that the system is visually blind, or falsely shutting down in plain indoor corridors.

---

## 2. Engineering Solutions & Theoretical Rigor

### 2.1. Evasion Verification Closure & Decoupling
To eliminate false evasion, the perception pipeline decouples image-plane motion into five explicit hypotheses:
1. `CAMERA_ROTATION`: Observed $\Delta pan$ without proportional distance recession.
2. `POSSIBLE_RISK_REDUCTION`: $\Delta pan$ accompanied by increasing radial distance ($v_z < -20$ cm/s).
3. `OBSERVED_RELATIVE_RECESSION`: Confirmed radial separation from obstacle.
4. `COLLISION_RISK_UNRESOLVED`: Candidate obstacle remains within physical corridor boundary.
5. `EVASION_CONFIRMED`: Verified lateral translation with clearance envelope proven.

**Safety Mandate**: In monocular RGB mode without calibrated 6-DoF visual-inertial odometry, `is_evading` is fixed to `False`. Warning volume attenuation is prohibited. The system localizes the obstacle in its current sector (e.g. `RIGHT`) at full volume ($1.0$), informing the user of the hazard's exact relative angle without guessing user intent.

### 2.2. Monotonic Wall-Clock Hazard Coasting
Coasting is governed by monotonic system clock timestamps ($t_{mono}$):
$$\Delta t_{seen} = t_{now} - t_{last\_seen}$$

```
                [Obstacle Detected in Frame k]
                            │
                            ▼
               Record: t_last_seen = t_k
                       threat = CRITICAL
                       dist = Z_k
                            │
               [Obstacle Lost in Frame k+1]
                            │
           ┌────────────────┴────────────────┐
           ▼                                 ▼
   Δt_seen < 0.60 s                  Δt_seen >= 0.60 s
           │                                 │
           ▼                                 ▼
    COASTING ACTIVE                  COASTING EXPIRED
    Threat = CRITICAL (Locked)       Threat = SAFE
    Audio Vol = 1.0 (Full)           Cue Mode = MUTED
```

- **Retention Duration**: $T_{coast} = 0.60$ seconds, guaranteeing that human auditory-motor reaction latency ($300 - 500$ ms) is fully spanned regardless of whether the camera runs at $5$ FPS or $60$ FPS.
- **Threat Level Invariance**: When coasting is triggered, `threat_level` is locked to the last verified level (`CRITICAL` remains `CRITICAL`). Downgrading to `WARNING` is forbidden.
- **Timestamp Integrity**: If $\Delta t_{seen} > 1.0$ s (camera pipeline freeze) or duplicate timestamps occur ($\Delta t_{seen} \le 0$), the pipeline flags a timing anomaly and gracefully resets.
- **Cold-Start Protection**: First-frame cache stores `last_seen_timestamp`, ensuring coasting functions even if an obstacle is visible for only a single frame.

### 2.3. Peripheral Risk Calibration & Shoulder Envelope
The user's physical clearance requires an lateral envelope $W_{shoulder} = 0.50$ m ($\pm 0.25$ m from center). For an obstacle at estimated distance $Z$ and normalized horizontal pan $p \in [-1, 1]$ across a horizontal FOV $\Phi \approx 65^\circ$:
$$X = Z \cdot \tan\left(p \cdot \frac{\Phi}{2}\right)$$

For $Z \le 80$ cm and $|p| \le 0.75$:
$$X_{max} = 80 \cdot \tan(0.75 \cdot 32.5^\circ) = 80 \cdot \tan(24.4^\circ) = 80 \cdot 0.453 = 36.2 \text{ cm}$$

This is classified as `CORRIDOR_CANDIDATE`. Threat level is upgraded to `WARNING` with volume factor $1.0$, preventing corner-swiping collisions.

### 2.4. Environmental Observability vs Numerical Validity
Validation is formally partitioned into two independent tiers:
1. **Numerical Validity** (`validity_state`):
   - Tensor shape: exactly $(H, W, 1)$ or $(H, W)$.
   - Float anomalies: zero `NaN`, zero `+Inf`, zero `-Inf`.
   - Dynamic range: $\min(D) \ge 0$, $\max(D) \le 5000$.
2. **Visual Observability** (`quality_state`):
   - **Covered Lens**: Mean luminance $L_{mean} < 10.0$ and standard deviation $L_{std} < 5.0$.
   - **Blinding Glare**: $L_{mean} > 240.0$ and $L_{std} < 15.0$.
   - **Severe Motion Blur**: Normalized Laplacian variance $\sigma_{lap}^2 < 12.0$.
   - **Negative Control (Featureless Wall)**: If $30.0 \le L_{mean} \le 225.0$ and $5.0 \le L_{std} \le 45.0$, the scene is classified as `OBSERVABLE`, ensuring white walls with low gradient variance are not falsely rejected.

---

## 3. Verification & Compliance Matrix

| Safety Requirement | Verification Test | Result | Compliance |
|:---|:---|:---:|:---:|
| No warning attenuation during camera pan | Scenario 10 (`diagnose_system.py`) | PASS | 100% Compliant |
| Coasting holds threat `CRITICAL` for 0.60 s | Scenario 18 (`diagnose_system.py`) | PASS | 100% Compliant |
| Coasting terminates after 0.60 s | Scenario 18 (`diagnose_system.py`) | PASS | 100% Compliant |
| Off-axis obstacle ($Z=50$ cm, $pan=0.70$) yields `WARNING` | Scenario 19 (`diagnose_system.py`) | PASS | 100% Compliant |
| Plain white wall classified `OBSERVABLE` | Scenario 17 (`diagnose_system.py`) | PASS | 100% Compliant |
| Covered lens yields `UNOBSERVABLE` & `SYSTEM_FAULT` | Scenario 17 (`diagnose_system.py`) | PASS | 100% Compliant |
| Zero unverified steering directions | Scenario 09 & Pipeline Audit 1.1 | PASS | 100% Compliant |
| Mobile kinematics parity (Android & iOS) | Audit 1.3, 1.4 & Code Review | PASS | 100% Compliant |

