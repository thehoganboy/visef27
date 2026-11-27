# VAMPIOR engineering acceptance

## Baseline

Integration starts at `49d5fb5ad2a20eba493b94fbb382b697c5de44f1`, the fetched tri-mode tip and last verified executable at onboarding. The demo branch at `0a7acb0aaae3448a930ad8f84fb0f58f0089edb6` remains available for comparison. [Baseline CI](https://github.com/thehoganboy/visef27/actions/runs/43717225934) · [Draft demo PR](https://github.com/thehoganboy/visef27/pull/1)

| Area | Baseline evidence | Integration changes |
| --- | --- | --- |
| Physical Stereo capture | The historical iPhone 14 Pro Wide/Ultra Wide run recorded 244 accepted pairs at roughly 30 paired FPS and 5.43 ms P95 skew. The 51 processed frames had 0% metric coverage. Physical distance error and end-to-end latency are unavailable. | Preserved capture and synchronization. Reports geometry, focus, profile match, overlap, disparity, uncertainty rejection, registration, spatial support, temporal confirmation and timing. |
| Stereo metric evidence | Dense matching had 76.2% coverage and 0.012 px integer-shift MAE on the 112×72 synthetic fixture. Uncalibrated disparity produced no metric guidance. | Checks per-camera geometry and profile identity, stores multiple capture profiles, provides bilateral calibration feedback and separates estimated range, profile-validated samples and clearance. |
| LiDAR | Researcher reported plausible distance and unstable overlay. No synchronized raw LiDAR recording or quantified physical tracking baseline was available. | Keeps ARKit's meters and confidence, associates depth components by image overlap, centroid travel and range, preserves thin high-confidence obstacles, and filters only the display. |
| Navigation and lifecycle | Three source paths had differing missing-evidence and stale-state handling. MiDaS could briefly carry its last heading across an unavailable frame. | A single advisory controls speech-free spatial feedback and the UI. Current critical measurements bypass track smoothing. Unknown coverage, stale frames, and source epochs withhold the affected guidance. |
| Layout | Root included the desktop runtime, tests, historical reports and model variants. | Relocated sources, tests, models and reports, updated active dependencies, and removed one byte-identical Android copy of the shared scenario fixture. [Repository manifest](repository-manifest.tsv) |

The portable Census matcher retains left-right consistency and measured support. Synthetic resolution trials compare both CPU tiers. The 72×96 portrait projection uses three columns per directional bin and leaves unobserved cells empty. Object evidence accepts a wider uncertainty range than clearance. Clearance uses observed support and a conservative lower bound over a contiguous 55 cm envelope at 75 cm. Two recent Stereo frames are required for a heading. A current near obstacle can still trigger STOP when the scene has poor overall coverage.

The uncertainty model combines matcher uncertainty, held-out range residuals, rectification residual and a yaw/skew estimate. It does not measure all-axis motion or bound localized distortion. Apple's factory transform describes physical relative pose in millimeters and depends on unstabilized images. The pinhole factory estimate is only a diagnostic and never enters the obstacle or advisory path. ARKit registers scene depth to the same captured image and expresses distance in meters. [Apple camera extrinsics](https://developer.apple.com/documentation/avfoundation/avcapturedevice/extrinsicmatrix%28from%3Ato%3A%29) · [ARKit depth data](https://developer.apple.com/documentation/arkit/ardepthdata)

## Release verification

The source SHA, final build and unsigned IPA are recorded here after GitHub Actions has verified the executable.

## Physical acceptance on iPhone 14 Pro

Use a sighted spotter for all walking trials and retain the participant's normal mobility aid. Start with stationary bench tests. Record app SHA, iOS version, capture configuration, lighting, reference method, route annotation and obstacle geometry. Keep the phone configuration and field procedure fixed when comparing builds.

1. Install the matched arm64 IPA through Sideloadly. Open each mode and check preview, permission and audio output. For Stereo, log camera pair, image formats, accepted/dropped pairs, P95 skew, pressure and processing cadence. Before importing a profile, verify that disparity and any factory estimate carry diagnostic labels and produce no Stereo heading.
2. Follow the [calibration procedure](../../README.md#stereo-calibration). Check blur, clipping and repeated-pose feedback while collecting fitting captures. Record the fitter's rejected pairs, overlap, reprojection RMS and each held-out epipolar and reference result. Import the fitted profile, restart, and verify that it persists for the matching camera configuration.
3. Collect independent live range trials near 50, 100, 200 and 300 cm. Center a matte target that covers the central ROI. Measure the plane from the camera along its optical axis. For each mode and range take at least three 10-second runs, with separate CSVs for static, moving and low-texture conditions. Record missing frames and coverage as well as valid-only errors. The earlier checkerboard corner measurements do not replace live dense-matcher measurements.
4. Record RGB reference video and screen output for stationary and moving obstacle trials. Use synchronized time marks, annotate the same target bounds across frames, and compare ID switches, track fragmentation, occlusion recovery and box/distance jitter. The CSV reports raw component and filtered box data for the same new-build frames. A comparison with the original LiDAR extractor requires matched raw sensor recordings or a repeat of the same controlled trial on the baseline build.
5. Complete the scenario matrix below with identical route labels for each mode. Measure audible warning onset with external A/V, using the video event mark as ground truth. Confirm the alert cannot outlive the accepted source epoch, a pause or a sensor interruption. Capture thermal state, peak memory and battery change in fixed-duration runs under the same conditions.

| Scenarios | Expected field behavior |
| --- | --- |
| Clear observed corridor | Neutral forward advisory only after the source's clearance checks pass. |
| Frontal obstacle; obstacle left; obstacle right | Warning is spatially attributable. A side correction needs current measured space on that side. |
| Close critical obstruction | Immediate warning. A confirmed near frontal obstacle forces STOP even with partial coverage. |
| Large wall or doorway; thin obstacle; multiple obstacles | No heading through confirmed obstruction. Keep discrete visible obstacles when evidence supports them. |
| Moving obstacle; moving phone | Risk reacts to closing motion. Avoid fitting approach across a camera turn or track identity change. |
| Low light; low texture | Withhold unsupported directions. A local confirmed hazard remains actionable. |
| Missing depth; invalid confidence; partial occlusion | Missing cells never count as clearance. Displayed boxes disappear without fresh measurements. |
| Stale observation; camera interruption | Expire the old heading, boxes and cue. Resume only with new valid evidence. |
| All six source transitions; rapid switches; pause/resume; background/foreground | Only the selected source emits guidance. Paused and background states remain silent. Foreground resumes in the paused state. |

Analyze each CSV with the measured range, expected action and trial onset in its `capture_s` clock. The default ROI validity requirement is 20%. Report the chosen threshold and evaluate all trials with the same value.

```sh
python -m testing.benchmarks.evaluate_ios_field trial.csv --source Stereo --truth-cm 100
python -m testing.benchmarks.evaluate_ios_field stationary.csv --source LiDAR --single-stationary-object
python -m testing.benchmarks.evaluate_ios_field blocked.csv --expected CRITICAL
```

Use the tool output for MAE, RMSE, bias, P95 error, valid rate, processing latency, false AVAILABLE, missed critical frames, unnecessary STOP and stationary tracking metrics. It measures software response from the logged capture clock. Use the external A/V onset for acoustic latency. Record hardware acceptance separately once these trials are complete.
