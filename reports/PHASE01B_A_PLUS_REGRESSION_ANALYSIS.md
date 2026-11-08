# HORUSEYES 2.0 — PHASE 01B-A+ REGRESSION ANALYSIS & CI TRIAGE REPORT
**Work Package:** WP-01B-A+  
**Author:** Senior Computer Vision & Safety-Critical Systems Engineer  
**Date:** 2026-11-08  
**Target Review Branch:** `fix/01b-a-plus-safety`  
**Classification:** Verification & Historical CI Audit  

---

## 1. Scenario Regression Verification (Scenarios 01 – 19)

To ensure no unintended side effects were introduced by WP-01B-A+ safety patches, all previously approved scenarios (01 to 16) were evaluated side-by-side with the new scenarios (17 to 19):

| Scenario ID | Test Purpose | Pre-A+ Status | Post-A+ Status | Regression Assessment |
|:---|:---|:---:|:---:|:---|
| **SC-01** | Clear corridor ($>2.5$ m) | PASS | PASS | Zero regression. Raw 250 maps to 237.2 cm. Cue remains muted. |
| **SC-02** | Lens saturation ($<15$ cm) | PASS | PASS | Zero regression. Saturation raw 1200 produces 13 cm emergency beep. |
| **SC-03** | Thin pole survival ($2\%$ area) | PASS | PASS | Zero regression. Pole detected at 70 cm with high salience. |
| **SC-04** | Drop-off & overhead hazard | PASS | PASS | Zero regression. Both ceiling overhang and stair drop-off detected. |
| **SC-05** | Specular wall uncertainty | PASS | PASS | Zero regression. High uncertainty ($1.00$) triggers acoustic blur. |
| **SC-06A** | Stationary camera + stationary obstacle | PASS | PASS | Zero regression. $v_z = 0$, $TTC = \infty$, static threat = `WARNING`. |
| **SC-06B** | Stationary camera + approaching obstacle | PASS | PASS | Zero regression. $v_z = 100$ cm/s, $TTC = 0.85$ s, threat = `CRITICAL`. |
| **SC-06C** | Moving camera + stationary obstacle | PASS | PASS | Zero regression. $v_{rel} = 80$ cm/s, $TTC = 1.15$ s, threat = `CRITICAL`. |
| **SC-06D** | Rotating camera + stationary obstacle | PASS | PASS | Zero regression. $v_z = 0$, zero false forward velocity spikes. |
| **SC-07** | CRITICAL preemption of WARNING | PASS | PASS | Zero regression. Close critical obstacle preempts distant warning. |
| **SC-08** | Anti-thrashing cue stability | PASS | PASS | Zero regression. Single obstacle maintains constant ID and cue. |
| **SC-09** | Sector P20 narrow obstacle rejection | PASS | PASS | Zero regression. Detailed analysis in Section 2 below. |
| **SC-10** | False evasion immunity | PASS | PASS | Hardened: `is_evading` remains False during camera rotation. |
| **SC-11** | Zero-lux flash & AE blanking | PASS | PASS | Zero regression. Torch activates, AE settle blanks false spikes. |
| **SC-12** | Camera freeze watchdog | PASS | PASS | Zero regression. $1.2$ s frozen frame triggers `SYSTEM_FAULT`. |
| **SC-13** | 50% NaN/Inf sensor fault | PASS | PASS | Zero regression. Preserves NaN, triggers `SENSOR_FAULT`. |
| **SC-14** | Concentrated corridor invalidity | PASS | PASS | Zero regression. 63% central invalidity flags `DEGRADED`. |
| **SC-15** | Phone rotation vs body evasion | PASS | PASS | Hardened: Coasting maintains threat level across rotation. |
| **SC-16** | Stationary obstacle at 30 cm | PASS | PASS | Zero regression. Static risk is `CRITICAL` despite $v_z = 0$. |
| **SC-17** | Visual Observability vs Numerical Validity | NEW | PASS | Validates covered lens, glare, and plain wall negative control. |
| **SC-18** | Monotonic timestamp hazard coasting | NEW | PASS | Threat remains `CRITICAL` for 0.60 s; cleanly expires at 0.75 s. |
| **SC-19** | Peripheral corridor candidate ($Z=50$ cm) | NEW | PASS | Threat is `WARNING`, volume is $1.0$, evasion unresolved. |

---

## 2. Technical In-Depth Analysis: Scenario 09

### Background & Architecture
In Engineering Directive 01A, `FIX-M01` abolished autonomous steering assertions (such as `safe_direction == "LEFT"`), replacing them with direct hazard localization and non-intrusive threat alerting.

In Scenario 09, a synthetic corridor frame is constructed with two distinct elements:
1. A narrow vertical pole in the right sector: synthetic raw disparity $= 600 \implies Z = 59.3$ cm ($pan \approx +0.65$).
2. A broad obstacle in the center sector: synthetic raw disparity $= 650 \implies Z = 50.0$ cm ($pan = 0.00$).

### Mathematical Priority Outcome
- The center obstacle has $Z = 50.0$ cm.
- The right obstacle has $Z = 59.3$ cm.
- The distance-based priority sort evaluates:
  $$Z_{center} = 50.0 \text{ cm} < Z_{right} = 59.3 \text{ cm}$$
- Because $50.0 < 59.3$, the primary obstacle selected by `AuditoryBudgetManager` is the closer hazard: **`CENTER`**.
- `hazard_direction` is correctly reported as `'CENTER'`.
- `safe_direction` is strictly `'NONE'`. No autonomous steering instructions are emitted.
- If the center obstacle is cleared, the right pole immediately becomes primary ($Z = 59.3$ cm), reporting `hazard_direction = 'RIGHT'` and panning audio spatialization to the right ($pan \approx +0.65$).

This proves that priority arbitration is operating strictly according to physical proximity and safety criticality, rather than arbitrary sector ordering.

---

## 3. Analysis of Historical CI Failures (User-Provided Evidence)

The PM and CI monitoring logs recorded failures on the following 4 runs on `main`:

```
┌──────┬─────────┬──────────────────────────────────────────────────────────────┬───────────────┐
│ Run  │ Commit  │ Commit Message                                               │ Failure Cause │
├──────┼─────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ #12  │ 162c5e1 │ Switch to Landscape for Android and iOS; Add live camera...   │ Swift Syntax  │
│ #13  │ 60ed1b4 │ Fix Swift compilation: remove unary plus on Text and fix...   │ Swift Types   │
│ #23  │ b6bd3f1 │ Phase 01A: Implement P0 safety directives, direct hazard...   │ Swift Closure │
│ #26  │ 3c8984b │ Phase 01B-A: Multi-level spatial validity, phone rotation...  │ HTTP 504 (Net)│
└──────┴─────────┴──────────────────────────────────────────────────────────────┴───────────────┘
```

### Detailed Triage:
1. **Run #12 (Commit `162c5e1`) & Run #13 (Commit `60ed1b4`)**:
   - **Root Cause**: During the transition to landscape orientation and AR bounding box rendering, Swift compiler encountered unary plus operators on `Text` and type inference ambiguities on optional session variables in SwiftUI view trees.
   - **Resolution History**: Fully resolved in subsequent commits `1a35d01` and `c2c6db5` by extracting helper views and explicit type annotations.
2. **Run #23 (Commit `b6bd3f1`)**:
   - **Root Cause**: Phase 01A implementation introduced a complex inline `@ViewBuilder` closure in `ios/HorusEyes/ContentView.swift` and referenced `allObstacles.count` on an optional result in `KinematicsEngine.swift`.
   - **Resolution History**: Resolved in commits `6d23224` (extracted `hazardDirectionLabel` helper) and `c834f77` (fixed property access). Run #25 succeeded with a green pass.
3. **Run #26 (Commit `3c8984b`)**:
   - **Root Cause**: Not a code error. GitHub Actions runner encountered an HTTP 504 Gateway Timeout when executing `ios/scripts/export_coreml.py`, which downloaded `midas_v21_small_256.pt` (85.7 MB) from GitHub Releases via `urllib.request.urlretrieve`.
   - **Resolution History**: Resolved in commit `e5e884f` by pre-cloning the MiDaS architecture, adding chunked streaming with custom User-Agent, and adding fallback to local PyTorch caches.
4. **Run #27 Flake (`maxim-lobanov/setup-xcode@v1`)**:
   - **Root Cause**: The external GitHub Action `maxim-lobanov/setup-xcode@v1` timed out connecting to the GitHub API.
   - **Resolution in WP-01B-A+**: Removed this third-party action from `.github/workflows/build_ios_ipa.yml` and directly invoked the runner's native `xcodebuild -version`.
