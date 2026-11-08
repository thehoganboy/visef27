# HORUSEYES 2.0 — PHASE 01B-B0 MULTI-STAGE ERROR ATTRIBUTION ARCHITECTURE
**Work Package:** WP-01B-B0  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Scope:** 6-Stage Perception Pipeline Attribution Taxonomy  

---

## 1. Why Multi-Stage Attribution is Mandatory

In an end-to-end assistive vision pipeline, observing that an audio alert did not fire ("System Miss") does not reveal the root cause. The failure could stem from an obscured lens, neural depth erasure, aggressive morphological erosion, a lost Kalman track, an incorrect TTC threshold, or auditory budget suppression.

Treating the pipeline as a black box leads to misdirected "fixes" (e.g. tuning auditory volume when the actual defect is depth model boundary blur).

`eval/harness.py` implements a **Stage-Isolated Evaluation Harness** that decomposes errors into six sequential domains:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       6-STAGE EVALUATION HARNESS                            │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
 ┌─────────────────────────────────┼─────────────────────────────────┐
 ▼                                 ▼                                 ▼
[STAGE 1: ACQUISITION]   ──►  [STAGE 2: DEPTH]      ──►  [STAGE 3: SEGMENTATION]
  - Motion blur               - Boundary blur              - Morphological erosion
  - Underexposure / glare     - Disparity float            - Depth quantile shift
  - Shutter rolling artifact  - Scale inversion            - False clustering
                                   │
 ┌─────────────────────────────────┴─────────────────────────────────┐
 ▼                                 ▼                                 ▼
[STAGE 4: KINEMATICS]    ──►  [STAGE 5: RISK]       ──►  [STAGE 6: AUDITORY]
  - Track ID churn            - TTC misclassification      - Budget suppression
  - Kalman v_z divergence     - Static/dynamic conflict    - Hysteresis lock-out
  - False evasion flag        - Sector localization error  - Psychoacoustic masking
```

---

## 2. Six-Stage Failure Taxonomy

### Stage 1: Frame Acquisition & Visual Observability
- **Error Types**:
  - `E1.1_EXPOSURE_BLINDING`: Mean luminance $L > 240$ (sun glare).
  - `E1.2_UNDEREXPOSURE`: $L < 15$ without flash.
  - `E1.3_MOTION_BLUR`: Normalized Laplacian $\sigma_{lap}^2 < 12$.
  - `E1.4_ROLLING_SHUTTER`: Skewed vertical geometry during fast pan.
- **Diagnostic Signal**: `AssessVisualObservability()` returns `DEGRADED` or `UNOBSERVABLE`.

### Stage 2: Depth Map Estimation
- **Error Types**:
  - `E2.1_BOUNDARY_EROSION`: Thin obstacle ($<5$ cm) erased during bilinear upsampling.
  - `E2.2_SPECULAR_TRANSPARENCY`: Glass or shiny surfaces assigned infinite background depth.
  - `E2.3_DISPARITY_SCALE_DRIFT`: Global scale floating due to changing lighting context.
- **Diagnostic Signal**: $\text{MAE}_{depth} > 50$ cm while Stage 1 is `OBSERVABLE`.

### Stage 3: Spatial Segmentation & Obstacle Extraction
- **Error Types**:
  - `E3.1_MORPHOLOGICAL_ERASURE`: Erosion kernel completely removes thin structures.
  - `E3.2_GROUND_PLANE_BLEED`: Floor texture incorrectly clustered as vertical obstacle.
  - `E3.3_SECTOR_MISASSIGNMENT`: Centroid pan assigned to adjacent sector.
- **Diagnostic Signal**: Depth map contains valid high disparity, but `SingleObstacle` list is empty.

### Stage 4: Multi-Object Tracking & Kinematics Fit
- **Error Types**:
  - `E4.1_TRACK_ID_SWITCH`: Hungarian association swaps IDs between adjacent objects.
  - `E4.2_VELOCITY_NOISE`: Spurious $v_z$ spike from frame-to-frame contour fluctuation.
  - `E4.3_FALSE_EVASION`: Phone yaw interpreted as user dodging obstacle.
- **Diagnostic Signal**: Obstacle detected in Stage 3, but $v_z$ diverges by $>50$ cm/s from ground truth.

### Stage 5: Threat & Risk Classification
- **Error Types**:
  - `E5.1_TTC_UNDERESTIMATION`: False emergency alarm for distant slow-moving object.
  - `E5.2_STATIC_PROXIMITY_BLINDNESS`: Zero $v_z$ suppresses warning on close hazard ($<40$ cm).
  - `E5.3_PERIPHERAL_NEGLECT`: Shoulder-width obstacle erroneously classified as safe outside.
- **Diagnostic Signal**: Kinematics correct, but `threat_level` output is `SAFE` when $Z \le 80$ cm.

### Stage 6: Auditory Budget & Acoustic Synthesis
- **Error Types**:
  - `E6.1_SUPPRESSION_LOCKOUT`: Active warning muted by hysteresis budget when it should preempt.
  - `E6.2_CUE_THRASHING`: Tone rapidly alternates between ping and geiger clicks ($\mathcal{TI} > 0.30$).
  - `E6.3_SPATIAL_MASKING`: Audio pan inverted or mono-collapsed.
- **Diagnostic Signal**: `threat_level` is `CRITICAL`, but `is_active == False` or `cue_mode == 'MUTED'`.

---

## 3. Automated Error Logging in Harness

When executing `eval/harness.py`, each test frame generates an attribution trace:
```json
{
  "frame_idx": 42,
  "ground_truth_threat": "CRITICAL",
  "system_threat": "SAFE",
  "stage_attribution": {
    "stage_1_acquisition": "PASS",
    "stage_2_depth_inference": "PASS",
    "stage_3_obstacle_segmentation": "FAIL (E3.1_MORPHOLOGICAL_ERASURE: Pole width 3px eroded)",
    "stage_4_kinematics": "NOT_REACHED",
    "stage_5_risk": "NOT_REACHED",
    "stage_6_auditory": "NOT_REACHED"
  },
  "root_cause_stage": 3,
  "actionable_recommendation": "Preserve 1-pixel connected components in depth morphological kernel."
}
```
This guarantees pinpoint engineering diagnosis for every failure case.
