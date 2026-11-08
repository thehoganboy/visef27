# HORUSEYES 2.0 — PHASE 01B-B0 BENCHMARK DATASET PLAN
**Work Package:** WP-01B-B0 (Perception Evaluation Foundation)  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Scope:** Dataset Acquisition, Curation, Provenance & Split Specifications  
**Compliance:** Zero Data Leakage; Strict Scientific Traceability for VISEF 2026–2027  

---

## 1. Objective and Provenance Philosophy

To evaluate monocular camera-only assistive navigation without fabricating sensor capabilities or relying on unverified synthetic artifacts, WP-01B-B0 establishes an evaluation dataset protocol grounded in physical ground truth.

### Strict Anti-Leakage Rules:
1. **Separation of Calibration and Test Splits**: The 11 PCHIP calibration knots in `config.py` were historically derived from NYU Depth V2 training sequences and TUM RGB-D `freiburg1_desk`. Under no circumstances may any evaluation metric be reported on these training frames.
2. **Held-Out Test Splits**: All formal VISEF metrics must use the official NYU Depth V2 654-image held-out test split, held-out TUM sequences (`freiburg2_desk_with_person`, `freiburg3_long_office_household`), and newly curated controlled real-world captures.
3. **Physical Ground-Truth Instrumentation**: Real-world captures use calibrated laser rangefinder measurements (Leica DISTO D2, accuracy $\pm 1.5$ mm) and plumb-line elevation references.

---

## 2. Obstacle Taxonomy (14 Categories)

As codified in `eval/dataset_manifest.json`, the benchmark encompasses 14 rigorous obstacle categories:

```
┌───────────────────────────────────────┬───────────────────────────────────────┐
│ GEOMETRIC & ELEVATION CATEGORIES      │ ADVERSARIAL & DYNAMIC CATEGORIES      │
├───────────────────────────────────────┼───────────────────────────────────────┤
│ CAT-01: Thin Vertical Poles (<5 cm)   │ CAT-08: Drop-Offs & Descending Stairs │
│ CAT-02: Hanging Cables & Wires        │ CAT-09: Ascending Staircases          │
│ CAT-03: Horizontal Branches           │ CAT-10: Dynamic Approaching Pedestrians│
│ CAT-04: Head-Height Obstacles         │ CAT-11: Crossing Obstacles & Vehicles │
│ CAT-05: Upper-Body (Table Corners)    │ CAT-12: Rapid Camera Torso Rotation   │
│ CAT-06: Low Ground-Level Obstacles    │ CAT-13: Severe Low-Light / Night (0 Lux)│
│ CAT-07: Transparent / Reflective Glass│ CAT-14: Direct Blinding Sun Glare     │
└───────────────────────────────────────┴───────────────────────────────────────┘
```

### Detailed Category Specifications:
1. **CAT-01 Thin Vertical Poles**: Metal signposts, bollards, scaffolding poles ($D \le 5.0$ cm). Evaluates whether morphological operations preserve high-frequency structures at $160 \times 160$ resolution.
2. **CAT-02 Hanging Cables & Wires**: Catenary utility wires, loose cables ($4 - 12$ mm diameter) suspended at chest-to-head height.
3. **CAT-03 Horizontal Branches & Overhangs**: Low tree branches protruding horizontally at $120 - 190$ cm from ground.
4. **CAT-04 Head-Height Hazards**: Wall-mounted air conditioner outdoor units, open cabinet doors, awning frames ($150 - 190$ cm elevation).
5. **CAT-05 Upper-Body Obstacles**: Table edges, protruding counter corners, turnstiles ($80 - 120$ cm elevation).
6. **CAT-06 Ground-Level Obstacles**: Curbs, steps, scattered floor boxes ($5 - 30$ cm height).
7. **CAT-07 Transparent / Reflective Glass**: Clean glass entrance doors, floor-to-ceiling windows.
8. **CAT-08 Drop-Offs & Negative Obstacles**: Descending staircase steps, subway entrances, drainage trenches.
9. **CAT-09 Ascending Stairs**: Steps rising in front of user, evaluated for gradient slope vs wall confusion.
10. **CAT-10 Dynamic Approaching Pedestrians**: Pedestrians walking directly toward camera at $80 - 140$ cm/s.
11. **CAT-11 Orthogonal Crossing Obstacles**: Bicycles, carts, or pedestrians moving perpendicular to travel path ($v_x \ne 0, v_z \approx 0$).
12. **CAT-12 Torso Swivel / Rapid Rotation**: Camera experiencing angular velocity $\omega_y \in [20^\circ/s, 90^\circ/s]$.
13. **CAT-13 Low-Light & Zero-Lux**: Indoor corridors with lights extinguished ($< 1.0$ lux) and outdoor twilight.
14. **CAT-14 Blinding Glare**: Direct transition from indoor shade to harsh sun facing camera lens.

---

## 3. Hardware Acquisition Fixture & Recording Specifications

### Primary Capture Devices:
- **Device A (iOS)**: iPhone 14 Pro, $12$ MP main camera ($f/1.78$, $24$ mm equivalent, $65^\circ$ H-FOV), locked 1080p@30fps, 48 kHz stereo audio.
- **Device B (Android)**: Samsung Galaxy S23 / Pixel 7, Camera2 API, locked exposure and white balance during benchmark clips.
- **Chest-Harness Mount**: Standard body harness securing device at chest level ($135$ cm from floor), simulating actual visually impaired user posture.
- **Handheld Gimbal**: Controlled pitch/yaw sweeps for camera-motion decoupling experiments.

---

## 4. Annotation Standards & Ground-Truth Attribution

Every benchmark clip is accompanied by an immutable JSON annotation sidecar:
```json
{
  "clip_id": "CAT01_POLE_004",
  "category": "CAT-01-POLE",
  "lighting_lux": 280,
  "camera_motion": "WALKING_FORWARD",
  "ground_truth": {
    "obstacle_type": "POLE_DIAMETER_4CM",
    "measured_distances_cm": [
      {"timestamp_s": 0.00, "z_laser_cm": 250.0, "lateral_offset_cm": 0.0},
      {"timestamp_s": 1.00, "z_laser_cm": 150.0, "lateral_offset_cm": 0.0},
      {"timestamp_s": 1.80, "z_laser_cm": 70.0,  "lateral_offset_cm": 0.0}
    ],
    "collision_envelope_cm": {"width": 5.0, "height": 180.0, "z_min": 0.0}
  }
}
```
Zero synthetic extrapolation. Laser ground truth is interpolated solely between physical measurements recorded at fixed spatial markers.
