# HORUSEYES 2.0 — PHASE 01B-B0 EVALUATION PROTOCOL & METRICS SPECIFICATION
**Work Package:** WP-01B-B0  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Scope:** Mathematical Formulations, Experimental Procedures & VISEF Metric Standards  

---

## 1. Evaluation Methodology

Assistive mobility systems require evaluation beyond generic computer vision benchmarks (e.g. mean Absolute Relative Error $\text{AbsRel}$ or $\delta < 1.25$). A system that reports a $10\%$ depth error on distant walls but misses a pole at $60$ cm is catastrophic for a blind pedestrian.

Evaluation is therefore structured around **Perceptual Safety Metrics** mapped to actionable walking envelopes:

```
Zone 1 (Immediate Danger) : Z in [13 cm, 80 cm]   -> Critical obstacle avoidance
Zone 2 (Caution Corridor) : Z in (80 cm, 150 cm]  -> Trajectory planning & awareness
Zone 3 (Distant Scene)    : Z in (150 cm, 350 cm] -> Far-field orientation
```

---

## 2. Core Quantitative Metrics

### 2.1. Spatial Detection Recall & Precision
For a given ground-truth obstacle $O_{gt}$ with 3D centroid $(X_{gt}, Y_{gt}, Z_{gt})$ present in the traversal corridor:
$$\text{Recall}_{Zone} = \frac{TP_{Zone}}{TP_{Zone} + FN_{Zone}}$$
$$\text{Precision}_{Zone} = \frac{TP_{Zone}}{TP_{Zone} + FP_{Zone}}$$
- **True Positive ($TP$)**: Predicted obstacle overlaps ground-truth bounding envelope and estimated distance $|Z_{pred} - Z_{gt}| \le \tau_{dist}(Z_{gt})$, where:
  $$\tau_{dist}(Z) = \max(15.0 \text{ cm}, 0.20 \cdot Z)$$
- **False Negative ($FN$)**: Ground-truth obstacle in corridor ($Z \le 200$ cm, $|X| \le 40$ cm) undetected.
- **False Positive ($FP$)**: Warning emitted in an empty corridor ($Z_{gt} > 300$ cm).

### 2.2. Zone Classification Accuracy
Evaluates whether the continuous estimated distance maps into the correct safety zone:
$$\text{Acc}_{Zone} = \frac{1}{N} \sum_{i=1}^N \mathbb{I}(\text{Zone}(Z_{pred}^{(i)}) == \text{Zone}(Z_{gt}^{(i)}))$$

### 2.3. Metric Distance Bias and Absolute Error
$$\text{MAE}_{Zone} = \frac{1}{|S_{Zone}|} \sum_{i \in S_{Zone}} |Z_{pred}^{(i)} - Z_{gt}^{(i)}|$$
$$\text{Bias}_{Zone} = \frac{1}{|S_{Zone}|} \sum_{i \in S_{Zone}} (Z_{pred}^{(i)} - Z_{gt}^{(i)})$$
A negative bias ($\text{Bias} < 0$) indicates conservative estimation (estimating the hazard closer than reality), which is preferred in safety-critical robotics over optimistic estimation ($\text{Bias} > 0$).

### 2.4. Kinematic & TTC Estimation Accuracy
For an approaching obstacle with constant physical approach speed $v_{true} = 100$ cm/s:
$$\text{MAE}_{v_z} = \frac{1}{M} \sum_{k=1}^M |\hat{v}_z^{(k)} - v_{true}|$$
$$\text{TTC Error} = |\widehat{\text{TTC}} - \text{TTC}_{true}| = \left|\frac{Z_{pred}}{\hat{v}_z} - \frac{Z_{gt}}{v_{true}}\right|$$

### 2.5. Auditory Ergonomics: Thrashing Index ($\mathcal{TI}$)
To quantify cognitive overload from oscillating warnings, the Thrashing Index measures cue flips across a window of $W = 30$ frames (1 second):
$$\mathcal{TI} = \frac{1}{W-1} \sum_{k=1}^{W-1} \mathbb{I}(\text{CueMode}_k \ne \text{CueMode}_{k-1})$$
- Ideal stable warning: $\mathcal{TI} = 0.0$.
- Unacceptable thrashing: $\mathcal{TI} > 0.30$ (cue switches more than 9 times per second).

---

## 3. Standardized Controlled Test Conditions

| Experiment ID | Test Variable | Variations / Levels | Target Metric |
|:---|:---|:---|:---|
| **EXP-01** | Obstacle Material | Matte wood, brushed aluminum, glossy plastic, black cloth, transparent acrylic | Detection Recall in Zone 1 |
| **EXP-02** | Obstacle Diameter | $2.5$ cm, $5.0$ cm, $10.0$ cm, $30.0$ cm, broad wall ($>100$ cm) | Minimum observable diameter |
| **EXP-03** | Ambient Illumination | $500$ lux (daylight), $50$ lux (indoor dim), $5$ lux (twilight), $0.1$ lux (night) | AutoTorch trigger latency & SNR |
| **EXP-04** | User Walking Speed | Stationary ($0$ cm/s), Slow ($60$ cm/s), Normal ($110$ cm/s), Fast ($150$ cm/s) | $v_z$ convergence time ($N \le 4$ frames) |
| **EXP-05** | Camera Mount Stability | Chest-harness locked, Neck-lanyard swinging, Handheld walking | Evasion false-positive rejection rate |

---

## 4. Execution Pipeline & Reproducibility Command

All evaluations run via the standardized harness in `eval/harness.py`:
```bash
python -m eval.harness \
  --manifest eval/dataset_manifest.json \
  --adapter midas_small \
  --output reports/eval_results_midas.json
```
The harness outputs machine-readable JSON results and per-stage diagnostic attributions.

