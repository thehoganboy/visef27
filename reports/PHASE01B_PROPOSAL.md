# HorusEyes 2.0 — Phase 01B Engineering Proposal
**Project:** HorusEyes 2.0  
**Directive:** Engineering Directive 01A Section 8  
**Date:** 2026-11-08  
**Status:** PROPOSED FOR PM REVIEW & CONDITIONAL AUTHORIZATION

---

## 1. Context & Motivation

Phase 01A successfully established scientific integrity, eliminated fabricated latencies and benchmarks, eradicated dangerous prescriptive steering commands, and secured numerical robustness.

With the foundational pipeline validated, **Phase 01B** proposes to address the remaining architectural gaps, with particular focus on hardware sensor fusion (LiDAR), physical 3D world coordinates, negative obstacle detection, and mobile platform parity.

---

## 2. Prioritized Work Packages for Phase 01B

### WP1: iPhone 14 Pro Hardware LiDAR Fusion (Priority: P0 — Highest)
- **Problem:** Monocular neural depth suffers from global scale ambiguity in uncalibrated environments.
- **Proposed Solution:**
  - Integrate Apple ARKit `ARFrame.sceneDepth` (dToF LiDAR) on iPhone 14 Pro.
  - Implement a confidence-weighted fusion layer: use LiDAR metric ground truth ($0.3m - 5.0m$) to calibrate and anchor neural depth scale dynamically.
  - Implement real-time confidence masking (`ARConfidenceLevel.high` / `.medium`).
- **Acceptance Criteria:** Zero scale ambiguity within the LiDAR operational envelope ($<5$ m); metric accuracy verified within $\pm 5\%$.

### WP2: 3D Camera Coordinate Transformation & Ground Plane Segmentation (Priority: P0)
- **Problem:** Current 2D bounding boxes and pixel percentiles do not isolate true 3D spatial geometry or account for phone tilt/pitch.
- **Proposed Solution:**
  - Leverage IMU gravity vector ($g$) to align the camera coordinate frame with the real-world horizon.
  - Formulate ground-plane extraction via RANSAC on 3D point cloud back-projected via camera intrinsics:
    $$X = (u - c_x) \frac{Z}{f_x}, \quad Y = (v - c_y) \frac{Z}{f_y}$$
  - Classify objects as true obstacles only if their 3D height exceeds ground clearance threshold ($>8$ cm) and falls within head-clearance bounds ($<200$ cm).
- **Acceptance Criteria:** Rejection of floor textures, road markings, and shadows as false obstacles; accurate detection of overhead hazards.

### WP3: Robust Negative Obstacle (Drop-Off / Stairs) Detection (Priority: P0)
- **Problem:** Descending stairs, curbs, and construction trenches produce void or divergent disparity that can be misread as distant free space.
- **Proposed Solution:**
  - Implement ground plane continuity monitoring: detect sudden downward depth discontinuities along the forward traversal path.
  - Require consecutive multi-frame confirmation to prevent false triggers from walking gait bounce.
- **Acceptance Criteria:** 100% detection of descending steps $>12$ cm at lookahead distances of $1.5m - 2.5m$.

### WP4: Mobile Tracking Parity & Kalman State Unification (Priority: P1)
- **Problem:** Android and iOS mobile trackers currently maintain lightweight heuristic tracking rather than the full 3D Kalman state implemented in the Python reference.
- **Proposed Solution:**
  - Port unified 3D Kalman Filter state ($[X, Y, Z, v_x, v_y, v_z]^T$) to Kotlin and Swift.
  - Synchronize Hungarian association with IoU + 3D spatial gating across all platforms.
- **Acceptance Criteria:** Parity across desktop, Android, and iOS within $\pm 2\%$ tracking velocity error on standardized motion sequences.

### WP5: Auditory Acoustic Safety & SPL Dosimetry (Priority: P1)
- **Problem:** Prolonged acoustic navigation can cause ear fatigue, masking of ambient environmental sounds, or temporary threshold shift.
- **Proposed Solution:**
  - Implement OSHA/NIOSH acoustic dose tracking in `AuditoryBudgetManager`.
  - Introduce ambient sound ducking and dynamic frequency adaptation to prevent masking traffic or speech.
- **Acceptance Criteria:** Ambient speech intelligibility preserved; cumulative SPL exposure below 75 dBA time-weighted average.

---

## 3. Resource Requirements & Timeline

- **Estimated Duration:** 3 sprints (approx. 2 weeks per sprint).
- **Hardware Prerequisites:** iPhone 14 Pro test unit running iOS 17+, Android ARCore-supported test unit, calibrated optical test rig with ground-truth laser measure.
- **Gate Requirement:** Authorization from Technical PM before merging any WP into production branches.
