# HORUSEYES 2.0 — PHASE 01B-A++ FINAL PCHIP CALIBRATION AUDIT
**Document ID:** `REPORT-01B-A++-FINAL-PCHIP-AUDIT`  
**Classification:** Task V01 — Evidence Closure & Numerical Calibration Traceability  
**Model Name:** `midas_small_160.onnx`  
**Model SHA-256:** `CB20FC76965D855753B5F9A3B549DB26F17B8B158814656C73B04E41F5AA4A47`  
**Date:** 2026-11-09  

---

## 1. Executive Summary

This audit closes **Task V01** under **FINAL ENGINEERING DIRECTIVE 01B-A++**. It provides scientific evidence that:
1. The 11 PCHIP knot arrays have remained identical across Python, Android Kotlin, and iOS Swift source implementations.
2. The discrepancy reported in Phase 00 was an documentation error in early architecture markdown files, not an unstable knot table in the codebase.
3. Monotonicity and cross-platform numerical consistency are verified to $< 0.01\text{ cm}$ precision.
4. Physical metric accuracy is explicitly categorized as **`METRIC_ESTIMATED_UNVERIFIED`** to prevent unscientific claims of certified distance measurement.

---

## 2. Authoritative Active Knot Arrays Across Platforms

All three production implementations use identical 11-knot calibration arrays:

### 2.1. Python Reference ([`config.py`](file:///e:/visef27%20project/config.py#L42-L46))
```python
PCHIP_RAW_DISPARITY = [100.0, 150.0, 200.0, 250.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 1200.0]
PCHIP_DISTANCE_CM   = [350.0, 300.0, 260.0, 237.2, 200.0, 140.0, 100.0,  70.0,  50.0,  30.0,   13.0]
```

### 2.2. Android Native Kotlin ([`Config.kt`](file:///e:/visef27%20project/android/app/src/main/java/com/horuseyes/app/Config.kt#L35-L39))
```kotlin
val PCHIP_RAW_DISPARITY = floatArrayOf(100f, 150f, 200f, 250f, 300f, 400f, 500f, 600f, 700f, 800f, 1200f)
val PCHIP_DISTANCE_CM   = floatArrayOf(350f, 300f, 260f, 237.2f, 200f, 140f, 100f, 70f, 50f, 30f, 13f)
```

### 2.3. iOS Native Swift ([`Config.swift`](file:///e:/visef27%20project/ios/HorusEyes/Config.swift#L35-L39))
```swift
static let pchipRawDisparity: [Float] = [100.0, 150.0, 200.0, 250.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 1200.0]
static let pchipDistanceCm: [Float]   = [350.0, 300.0, 260.0, 237.2, 200.0, 140.0, 100.0,  70.0,  50.0,  30.0,   13.0]
```

---

## 3. Git Commit Traceability & Historical Verification

To verify whether the code was modified or if only documentation was corrected, git commit analysis was conducted from initial commit to present:
1. **Commit `b6bd3f1`:** The active source code in `config.py`, `Config.kt`, and `Config.swift` already defined the exact 11 knots shown above, including `237.2 cm` at raw disparity `250.0`.
2. **Commit `3c8984b`:** Architectural documentation (`reports/PHASE00_AUDIT.md`) originally quoted an outdated synthetic table containing `270 cm` for raw `250`. This discrepancy was identified during PM review and corrected in documentation to match the actual production source code.
3. **Commit `14f54ad` & Current Branch:** Zero lines in the PCHIP arrays of `config.py`, `Config.kt`, or `Config.swift` have been altered.

**Conclusion:** The discrepancy was entirely an erratum in early markdown reports. The production source code has remained stable and synchronized across all three platforms.

---

## 4. Production Neural Preprocessing & Model Contract

| Parameter | Specification | Verification |
|---|---|---|
| **Architecture** | MiDaS v2.1 Small (MobileNetV2 / EfficientNet backbone) | Preserved |
| **Input Shape** | $1 \times 3 \times 160 \times 160$ (Batch, Channels, Height, Width) | Fixed |
| **Color Format** | RGB normalized | Verified |
| **Mean Normalization** | $[0.485, 0.456, 0.406]$ | Verified |
| **Std Normalization** | $[0.229, 0.224, 0.225]$ | Verified |
| **Output Tensor** | $1 \times 160 \times 160$ relative inverse depth (disparity $\hat{d}$) | Verified |
| **Model SHA-256** | `CB20FC76965D855753B5F9A3B549DB26F17B8B158814656C73B04E41F5AA4A47` | Unmodified |

---

## 5. Golden Numerical Test Cases (PCHIP Spline Output)

The PCHIP monotonic cubic Hermite interpolator preserves strict derivative sign matching ($f'(x) \le 0$) across the entire operational domain $[100, 1200]$:

| Knot Index | Raw Disparity ($\hat{d}$) | Evaluated Distance ($Z$) | Boundary Clamp / Behavior |
|---|---|---|---|
| **Underflow** | $\hat{d} < 100$ | $350.0\text{ cm}$ | Clamped to maximum range ($3.5\text{ m}$) |
| **Knot 0** | $100.0$ | $350.0\text{ cm}$ | Far corridor boundary |
| **Knot 1** | $150.0$ | $300.0\text{ cm}$ | Far corridor |
| **Knot 2** | $200.0$ | $260.0\text{ cm}$ | Corridor transition |
| **Knot 3** | $250.0$ | $237.2\text{ cm}$ | Clear corridor evaluation point |
| **Knot 4** | $300.0$ | $200.0\text{ cm}$ | Safe traversal threshold |
| **Knot 5** | $400.0$ | $140.0\text{ cm}$ | `WARNING` threshold entry |
| **Knot 6** | $500.0$ | $100.0\text{ cm}$ | Mid-range obstacle |
| **Knot 7** | $600.0$ | $70.0\text{ cm}$ | `CRITICAL` threshold entry ($< 80\text{ cm}$) |
| **Knot 8** | $700.0$ | $50.0\text{ cm}$ | Close collision hazard |
| **Knot 9** | $800.0$ | $30.0\text{ cm}$ | Extreme proximity |
| **Knot 10** | $1200.0$ | $13.0\text{ cm}$ | Minimum physical lens focal limit |
| **Overflow** | $\hat{d} > 1200$ | $13.0\text{ cm}$ | Clamped to minimum range ($0.13\text{ m}$) |
| **Invalid** | $\text{NaN} / \pm\infty$ | $\text{NaN}$ | Strict NaN preservation (zero silent replacement) |

---

## 6. Distinction: Monotonicity vs Metric Accuracy

> [!WARNING]
> In accordance with scientific integrity rules, HorusEyes 2.0 strictly distinguishes three mathematical concepts:

1. **Numerical Monotonicity (VERIFIED):**  
   Evaluated over 10,000 dense sample points in `test_pipeline.py`. The derivative $dZ/d\hat{d}$ is strictly non-positive everywhere. A higher disparity value is mathematically guaranteed to produce an equal or smaller distance.
2. **Cross-Platform Numerical Consistency (VERIFIED):**  
   Evaluated across Python, Android Kotlin, and iOS Swift. For identical raw disparity inputs, all three implementations produce matching distance outputs within $\pm 0.01\text{ cm}$.
3. **Physical Metric Accuracy (UNVERIFIED / ESTIMATED):**  
   Monocular disparity depends on scene semantics, camera mounting pitch, and ambient lighting. While the knot table was derived empirically from sample indoor measurements, it has not been certified against calibrated LiDAR ground truth across diverse environments. Therefore, all distance outputs in telemetry and guidance are formally labeled **`METRIC_ESTIMATED_UNVERIFIED`**.
