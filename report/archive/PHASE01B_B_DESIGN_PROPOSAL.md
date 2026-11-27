# HorusEyes 2.0 — Phase 01B-B Technical Design Proposal
## Advanced Monocular Depth Architecture, Obstacle Geometry & Spatial Corridor Modeling

**Project:** HorusEyes 2.0 (Assistive Navigation for Visually Impaired)  
**Directive:** Engineering Directive 01B (Phase 01B-B Proposal)  
**Supervising:** Technical Project Manager (PM) & Chief Technology Officer (CTO)  
**Date:** 2026-11-08  
**Status:** PROPOSED FOR CTO REVIEW (Zero Code Changes Permitted until Authorized)  

---

## 1. Executive Summary & Scope

In accordance with the CTO's Strategic Decision (Directive 01B, Section 1), **Phase 01B-B** focuses entirely on advancing monocular RGB camera perception. Active sensors (LiDAR, ToF, ARKit `sceneDepth`, ARCore Depth) are strictly excluded.

This design proposal addresses four key challenges in monocular assistive perception:
1. **Model Evaluation Framework:** Evaluating next-generation Monocular Depth Estimation architectures (Depth Anything V2 Small vs. current MiDaS v2.1 Small).
2. **Thin & Overhead Obstacle Detection:** Enhanced mathematical operators for detecting poles, wires, tree branches, and low awnings that typically escape low-resolution downsampling.
3. **Pinhole Camera Intrinsics & Traversal Corridor:** 3D coordinate projection ($X, Y, Z$) using calibrated camera intrinsics to define a dynamic physical collision corridor.
4. **Cross-Platform Accuracy-Latency Optimization:** Multi-tier deployment matrix for edge execution on Android (TFLite/NNAPI) and iOS (CoreML/Apple Neural Engine).

---

## 2. Monocular Depth Model Evaluation Framework

### 2.1. Candidate Architectures Comparison

| Attribute | Baseline: MiDaS v2.1 Small | Candidate: Depth Anything V2 Small |
| :--- | :--- | :--- |
| **Backbone Architecture** | EfficientNet-Lite3 / MobileNetV2 | Vision Transformer (ViT-Small / DPT) |
| **Parameter Count** | ~21.4 Million | ~24.8 Million |
| **Training Dataset** | Multi-dataset mix (12 datasets, 2020) | Large-scale synthetic (Hypersim, Virtual KITTI) + 62M pseudo-labeled real images (2024) |
| **Boundary Crispness** | Moderately smoothed, edge dilation | Extremely sharp object boundaries; preserves thin structures |
| **Metric Depth Fine-Tuning** | Relative disparity only (requires PCHIP) | Available in both Relative and Metric (NYUv2 indoor pre-trained metric weights) |
| **CoreML FP16 Model Size** | ~42.8 MB | ~49.6 MB |
| **Expected CoreML ANE Latency (iPhone 14)** | ~18 ms ($160 \times 160$), ~28 ms ($256 \times 256$) | ~22 ms ($160 \times 160$), ~35 ms ($256 \times 256$) |
| **Expected TFLite GPU/NNAPI (Snapdragon 778G)** | ~32 ms ($160 \times 160$) | ~42 ms ($160 \times 160$) |

### 2.2. Scientific Evaluation Protocol
To evaluate Depth Anything V2 Small against the frozen MiDaS baseline without introducing unverified assumptions:
1. **Held-Out Test Datasets:**
   - **TUM RGB-D Indoor SLAM:** 5 sequences (`freiburg1_desk`, `freiburg1_room`, `freiburg2_desk`, `freiburg3_long_office_household`).
   - **NYUv2 654-image official test split:** Real indoor ground-truth metric depth captured with Microsoft Kinect.
2. **Standard Evaluation Metrics:**
   - Absolute Relative Error: $\text{AbsRel} = \frac{1}{|D|} \sum \frac{|d - d^*|}{d^*}$
   - Root Mean Square Error: $\text{RMSE} = \sqrt{\frac{1}{|D|} \sum (d - d^*)^2}$
   - Threshold Accuracy: $\delta < 1.25$ ($\%$ of pixels where $\max(\frac{d}{d^*}, \frac{d^*}{d}) < 1.25$)
   - Edge Boundary F1-Score: Boundary localization accuracy along depth discontinuities (Canny / Sobel edge agreement).
3. **Acceptance Criteria for Replacement:**
   - Depth Anything V2 Small must achieve $\ge 15\%$ improvement in Edge Boundary F1-score for thin objects ($<2\%$ frame area).
   - End-to-end edge inference on device must remain $\le 45\text{ ms}$ on target hardware.

---

## 3. Thin & Overhead Obstacle Detection Geometry

Monocular depth models commonly blur or erase high-frequency structural elements such as signposts, hanging cables, table edges, and low-hanging tree branches. Phase 01B-B introduces a dual-stream spatial detection geometry:

```
RGB Input Frame (e.g. 640x480)
   ├── Stream A (Macro Depth): Downsampled to 160x160 -> Depth Neural Network -> Dense Disparity Map
   └── Stream B (High-Frequency Geometry):
         ├── Directional Sobel Edge Kernels (Horizontal + Vertical)
         ├── Upper-Third Vertical ROI (Overhead Hazard Detector)
         └── Lower-Third Floor Plane Discontinuity (Drop-Off / Curb Detector)
```

### 3.1. Upper-Third Overhead Hazard Extraction
1. **Region of Interest (ROI):** Define row index $y \in [0, \frac{H}{3}]$.
2. **Disparity Differential:** Compute the vertical gradient $\frac{\partial D}{\partial y}$. In normal walking conditions, depth increases monotonically toward the upper frame (ceiling or far horizon).
3. **Overhead Anomaly Condition:** If an isolated cluster in the upper third exhibits depth $Z \le 120\text{ cm}$ (closer than the floor plane directly beneath it), an `OVERHEAD_HAZARD` flag is triggered immediately.

### 3.2. Directional Edge Fusion for Thin Structures
- Convolve the input luminance with directional Sobel kernels $G_x$ and $G_y$.
- Where strong spatial edges coincide with high disparity variance in Stream A, apply an adaptive morphological dilation filter to prevent thin obstacles from dissolving during sector percentile pooling.

---

## 4. Pinhole Camera Intrinsics & Traversal Corridor

### 4.1. Coordinate Transformation
Using monocular depth $Z$ (calibrated in cm) and normalized camera intrinsics matrix $K$:

$$
K = \begin{bmatrix} f_x & 0 & c_x \\ 0 & f_y & c_y \\ 0 & 0 & 1 \end{bmatrix}
$$

The 3D point in the camera reference frame is given by:

$$
X = \frac{(u - c_x) \cdot Z}{f_x}, \quad Y = \frac{(v - c_y) \cdot Z}{f_y}, \quad Z = Z_{metric}
$$

- For standard smartphone wide-angle lenses in landscape orientation:
  - Horizontal Field of View ($\text{H-FOV}$) $\approx 68^\circ \implies f_x \approx \frac{W}{2 \tan(34^\circ)} \approx 0.741 \cdot W$
  - Vertical Field of View ($\text{V-FOV}$) $\approx 54^\circ \implies f_y \approx \frac{H}{2 \tan(27^\circ)} \approx 0.981 \cdot H$

### 4.2. Physical Collision Corridor
Instead of arbitrary image column slicing (e.g., $33\%$ left, $34\%$ center, $33\%$ right), the traversal corridor is mathematically defined in real-world metric units:

$$
\text{Corridor Bounds: } |X| \le \frac{W_{\text{body}}}{2} + \sigma_{\text{sway}}
$$

- $W_{\text{body}} = 60.0\text{ cm}$ (average adult shoulder width)
- $\sigma_{\text{sway}} = 15.0\text{ cm}$ (lateral gait sway buffer)
- **Total Corridor Half-Width:** $X_{\text{limit}} = \pm 45.0\text{ cm}$
- **Dynamic Path Intersection:** An obstacle located at metric $(X_k, Y_k, Z_k)$ is classified as a direct collision hazard if and only if:
  1. $|X_k| \le 45.0\text{ cm}$ (within physical walking corridor)
  2. $-100.0\text{ cm} \le Y_k \le +60.0\text{ cm}$ (between user head height and shin level)
  3. $Z_k \le 200.0\text{ cm}$ (within alert stopping distance)

This mathematical corridor formulation eliminates false alarms caused by wide peripheral obstacles while ensuring complete protection for obstacles directly in the user's travel path.

---

## 5. Accuracy-Latency Trade-Off Matrix Across Target Tiers

| Device Tier | Example Hardware | Target Depth Model | Resolution | Target Latency | Target FPS | Feasibility |
| :--- | :--- | :--- | :---: | :---: | :---: | :--- |
| **Tier 1 (High-End iOS)** | iPhone 13, 14, 15 (ANE) | Depth Anything V2 Small | $256 \times 256$ | ~28 ms | ~30 FPS | Feasible via CoreML FP16 |
| **Tier 2 (Mainstream iOS)** | iPhone 11, 12, SE 3 (ANE) | MiDaS v2.1 Small / DAV2 | $160 \times 160$ | ~20 ms | ~30 FPS | Proven in CI Run #25 |
| **Tier 3 (Upper-Mid Android)** | Snapdragon 778G / 8 Gen 1 | Depth Anything V2 Small | $160 \times 160$ | ~38 ms | ~25 FPS | Feasible via NNAPI / GPU |
| **Tier 4 (Entry Android)** | Helio G99 / Snapdragon 680 | MiDaS v2.1 Small | $160 \times 160$ | ~55 ms | ~18 FPS | Feasible via TFLite XNNPACK |

---

## 6. Verification & Acceptance Plan for Phase 01B-B

Upon CTO authorization to proceed with Phase 01B-B implementation:
1. **Convert Depth Anything V2 Small to ONNX, CoreML, and TFLite formats.**
2. **Execute benchmark on TUM RGB-D and NYUv2 test sets; compare against Phase 01B-A baseline metrics.**
3. **Implement Pinhole Corridor Projection in Python reference pipeline.**
4. **Validate on all 19 adversarial scenarios in `diagnose_system.py`.**
5. **No mobile native modifications will be made until desktop Python verification achieves 100% test pass.**

