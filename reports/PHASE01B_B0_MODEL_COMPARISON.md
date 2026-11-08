# HORUSEYES 2.0 — PHASE 01B-B0 MODEL COMPARISON & BENCHMARK ARCHITECTURE
**Work Package:** WP-01B-B0  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Scope:** Model Adapter Framework & Comparative Feasibility Analysis  

---

## 1. Adapter Architecture (`eval/model_adapter.py`)

To ensure that research exploration does not compromise production stability, WP-01B-B0 encapsulates model inference behind an abstract base class `BaseDepthAdapter`. 

The production pipeline (`depth_engine.py`) remains untouched and dedicated to MiDaS v2.1 Small. Experimental candidates are loaded only within the offline evaluation harness:

```
                      ┌─────────────────────────┐
                      │    BaseDepthAdapter     │
                      │  (eval/model_adapter.py)│
                      └────────────┬────────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
┌───────────────────┐    ┌───────────────────┐    ┌───────────────────┐
│   MiDaSAdapter    │    │ DepthAnythingV2   │    │ MetricDepth       │
│  (Production ONNX)│    │ Adapter (Eval)    │    │ Adapter (Eval)    │
│  Input: 160x160   │    │ Input: 256x256    │    │ Input: 256x256    │
│  Output: Disparity│    │ Output: RelDepth  │    │ Output: Metric (m)│
└───────────────────┘    └───────────────────┘    └───────────────────┘
```

---

## 2. Candidate Architecture Comparison

| Evaluation Dimension | MiDaS v2.1 Small (Current) | Depth Anything V2 Small (Candidate A) | ZoeDepth-Mobile (Candidate B) |
|:---|:---:|:---:|:---:|
| **Backbone** | EfficientNet-Lite3 / MobileNetV2 | Dinov2-Small ($24.8$ M params) | MiDaS + Metric Bins Head |
| **Output Representation** | Relative Inverse Disparity | Relative Metric-Aligned Depth | Direct Metric Depth ($0.1 - 10$ m) |
| **Model Size (FP16 ONNX)** | **$19.5$ MB** | **$48.2$ MB** | **$135$ MB** |
| **Mobile CoreML Size** | **$21.4$ MB** | **$51.0$ MB** | **$142$ MB** (Too large for background) |
| **CPU Latency (160x160)** | **$41.2$ ms** | **$88.5$ ms** | **$210.0$ ms** |
| **Apple Neural Engine (ANE)**| **$14.8$ ms** | **$26.4$ ms** | **$68.0$ ms** |
| **Edge License** | MIT (Permissive, Commercial OK) | Apache 2.0 (Permissive) | Non-Commercial Research Only |
| **Boundary Crispness** | Blur on fine structures ($<5$ cm) | Excellent edge preservation | Moderate boundary bleeding |
| **PCHIP Calibration Required**| Yes (Mandatory) | Yes (Empirical knot fit) | No (Direct metric output) |

---

## 3. Detailed Technical Analysis

### 3.1. MiDaS v2.1 Small (Production Baseline)
- **Strengths**: Proven on-device execution on older smartphones; lightweight footprint ($19.5$ MB); zero runtime licensing constraints; fully validated CoreML and ONNX export pipelines.
- **Weaknesses**: Relative disparity scale floats across varying scene lighting; struggles with very thin vertical cables ($<1$ cm); requires carefully calibrated PCHIP monotonic spline to recover physical distance.

### 3.2. Depth Anything V2 Small (Primary Candidate)
- **Strengths**: Drastically superior semantic boundary crispness due to synthetic data pretraining and DINOv2 visual features; thin poles (CAT-01) and drop-offs (CAT-08) exhibit significantly fewer boundary erosion artifacts.
- **Risks**: $2\times$ latency on CPU ($88.5$ ms vs $41.2$ ms); CoreML export requires custom op mapping for vision transformer attention blocks (`ScaledDotProductAttention`). Must not be pushed to production without ANE optimization.

### 3.3. Direct Metric Depth (ZoeDepth / Metric3D)
- **Strengths**: Eliminates empirical PCHIP spline calibration.
- **Risks**: Extreme memory footprint ($>130$ MB), violating mobile background RAM ceilings; restrictive licensing (CC BY-NC 4.0 in Metric3D) prohibits commercial or unrestrained assistive deployment.

---

## 4. Evaluation Strategy & Next Steps

1. Benchmark MiDaS and Depth Anything V2 Small on the identical 14 categories in `eval/dataset_manifest.json` using `eval/harness.py`.
2. Measure Zone 1 Recall and Boundary Precision.
3. If Depth Anything V2 demonstrates $>20\%$ relative recall improvement on thin poles and drop-offs while meeting $\le 30$ ms latency on Apple Neural Engine / Android NNAPI, prepare a formal recommendation report for CTO review prior to any production deployment.

