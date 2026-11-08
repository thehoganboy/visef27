# HORUSEYES 2.0 — PHASE 01B-B0 5-CONDITION ABLATION STUDY PLAN
**Work Package:** WP-01B-B0  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Scope:** VISEF 2026–2027 Scientific Ablation Design & Validation Protocol  

---

## 1. Research Motivation & Scientific Rigor

A central requirement for international science competitions (ISEF / VISEF) is proving that each component of a complex engineering system provides statistically significant, measurable utility. Simply claiming an end-to-end system "works better" is insufficient.

We formulate a 5-Condition Component Ablation Study to rigorously isolate the contribution of:
1. Spatial Proximity.
2. Kinematic Velocity & TTC.
3. Visual Observability & Uncertainty Estimation.
4. Psychoacoustic Auditory Budgeting.
5. The full integrated HorusEyes 2.0 pipeline.

---

## 2. The Five Experimental Conditions

```
[Cond 1: Proximity Only] ──► [Cond 2: + TTC] ──► [Cond 3: + Uncertainty] ──► [Cond 4: + Budget] ──► [Cond 5: Full HorusEyes 2.0]
 - Static depth only          - Adds Kalman v_z    - Adds Observability     - Adds Hysteresis         - All modules active
 - Fixed distance alert       - TTC prediction     - Blur/glare fault tones - Anti-thrashing          - Full safety envelope
 - High false alarms          - Velocity filter    - Plain-wall guard       - Audio limiter           - Validated mobility
```

### Condition 1: Naive Proximity Baseline ($C_1$)
- **Architecture**: Static distance thresholding ($Z \le 120$ cm triggers continuous buzzer).
- **Ablated Elements**: Kinematics disabled; TTC disabled; uncertainty disabled; auditory budgeting disabled.
- **Hypothesis**: High collision avoidance in slow walking, but extreme cognitive noise, false alarms when standing near walls, and failure against fast-approaching obstacles.

### Condition 2: Kinematic TTC Integration ($C_2$)
- **Architecture**: Condition 1 + Kalman filter centroid tracker and dynamic Time-to-Collision ($TTC \le 1.2$ s).
- **Ablated Elements**: Observability assessment disabled; auditory budgeting disabled.
- **Hypothesis**: Drastically reduces warnings for stationary objects when user is standing still; triggers earlier alarms for approaching pedestrians.

### Condition 3: Uncertainty & Observability Aware ($C_3$)
- **Architecture**: Condition 2 + Visual Observability (glare, blur, dark detection) and PCHIP spline uncertainty quantification.
- **Ablated Elements**: Auditory budgeting disabled.
- **Hypothesis**: Prevents silent system blindness in darkness or lens obstruction; informs user of degraded sensor confidence.

### Condition 4: Psychoacoustic Auditory Budgeting ($C_4$)
- **Architecture**: Condition 3 + Priority queue, hysteresis lock-in ($1.5 \times$ priority threshold), and anti-thrashing smoothing.
- **Ablated Elements**: None (Full system without visual telemetry HUD).
- **Hypothesis**: Eliminates auditory thrashing ($\mathcal{TI} < 0.05$); reduces acoustic fatigue by $>60\%$ compared to $C_1$.

### Condition 5: Full HorusEyes 2.0 System ($C_5$)
- **Architecture**: The full multi-tier production system, including peripheral shoulder protection, AutoTorch blanking, and cross-platform mobile parity.

---

## 3. Quantitative Dependent Metrics

| Metric Dimension | Metric Variable | Measurement Tool / Formula | Unit |
|:---|:---|:---|:---:|
| **Safety** | Collision Avoidance Rate ($CAR$) | $\frac{\text{Successful Avoidances}}{\text{Total Hazard Encounters}} \times 100\%$ | $\%$ |
| **Safety** | Advance Warning Time ($AWT$) | $t_{\text{first\_auditory\_cue}} - t_{\text{physical\_contact\_if\_unabated}}$ | Seconds |
| **Cognitive Load** | Auditory Exposure Time ($AET$) | $\frac{\sum \text{Warning Audio Duration}}{\text{Total Navigation Session Duration}} \times 100\%$ | $\%$ |
| **Cognitive Load** | Thrashing Index ($\mathcal{TI}$) | Frequency of cue state flips per second | Flips/s |
| **Reliability** | False Alarm Rate ($FAR$) | False alarms emitted per $100$ meters of traversal | Alarms/$100$m |
| **Human Factors** | Subjective Cognitive Workload | Standardized NASA Task Load Index (NASA-TLX) | Score ($0-100$) |

---

## 4. Experimental Design & Statistical Analysis Protocol

- **Sample Size**: $N = 30$ independent walking trials per condition across standardized indoor and outdoor tracks ($150$ total trials).
- **Testing Track**: $50$-meter indoor corridor populated with random static obstacles (tables, bollards, poles) and dynamic crossing/approaching hazards.
- **Statistical Significance**:
  - One-Way Repeated Measures Analysis of Variance (ANOVA) across the 5 conditions.
  - Post-hoc pairwise comparisons using Tukey's Honestly Significant Difference (HSD) and two-tailed Wilcoxon signed-rank tests for non-parametric metrics.
  - Significance threshold set at $\alpha = 0.01$ with Bonferroni correction for multi-hypothesis testing.
- **Zero Fabrication**: All trials to be logged via automated timestamped telemetry JSON for review.
