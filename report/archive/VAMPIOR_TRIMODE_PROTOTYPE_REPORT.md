# VAMPIOR 3.0 iOS depth prototype

The prototype is for supervised research. The executable branch is `feature/ios-trimode-depth-prototype`, based on `0a7acb0aaae3448a930ad8f84fb0f58f0089edb6`. Android, Python, the base branch, and PR #1 were untouched.

## Depth modes

| Mode | Implementation | Conditions and limitations |
| --- | --- | --- |
| MiDaS | Default. Existing Core ML inference, PCHIP calibration, guidance, and automatic/manual torch behavior. Depth export identifies its centimeter values as calibrated estimates. | Requires camera permission and the bundled Core ML model. Image geometry follows the existing 65° horizontal field-of-view assumption. |
| LiDAR | ARKit raw `sceneDepth`. Converts meters to centimeters and accepts medium/high confidence. Rotates registered image and depth together into portrait and uses camera intrinsics for angle bins. Uses measured depth directly in the shared navigation and audio path. | Requires runtime scene-depth support. Missing depth, low confidence, or inadequate corridor coverage withholds guidance. Native obstacle, overhead, and drop-off heuristics need field validation. |
| Stereo β | Captures synchronized rear wide/tele pairs in MultiCam where available. Checks capture cost and pressure, reads per-frame intrinsics and factory extrinsics, rectifies a reduced luma grid, and runs textured patch matching with uniqueness and left/right checks. | Metric guidance is **UNAVAILABLE**. Factory intrinsics and extrinsics still require device-specific distortion, focus, alignment, and scale verification. Stereo currently exports match counts. Supported camera combinations are limited to wide/tele. |

Mode changes stop the prior capture path before starting the next one. Capture and guidance epochs invalidate queued work, old observations, and audio. The app stays in the selected mode on failure. Torch control is enabled in MiDaS. LiDAR and Stereo have no validated in-session torch integration.

## Verification and artifact

- Executable commit `03019dcf4bf07eb40fffd7323c6fe0f888b172d7`. [Source and changed files](https://github.com/thehoganboy/visef27/compare/0a7acb0aaae3448a930ad8f84fb0f58f0089edb6...03019dcf4bf07eb40fffd7323c6fe0f888b172d7)
- GitHub Actions passed 28 portable assertions, 6 new native metric observation checks, and all 10 existing regression groups. The existing groups include 67 explicitly counted scenarios plus three groups without a scenario count in their output. Zero failures on the final executable commit. [Verified CI run](https://github.com/thehoganboy/visef27/actions/runs/43628916466)
- Xcode 26.6 built the unsigned iPhoneOS release. CI packaged the compiled MiDaS model and verified arm64 and ZIP integrity. The IPA is 62,051,454 bytes. Download the artifact ZIP and extract `HorusEyes_iPhone14Pro.ipa` for Sideloadly. [Unsigned IPA artifact](https://github.com/thehoganboy/visef27/actions/runs/43628916466/artifacts/14127630402)
- An earlier run passed the Swift tests and Xcode build but failed packaging because the added `lipo` check had its arguments out of order. The final run passed after correcting that command. [Earlier run](https://github.com/thehoganboy/visef27/actions/runs/43628574656)
- Automated lifecycle checks exercise frame acceptance and invalidation. Camera handoffs, torch behavior, audio, signing, and installation still need verification on an iPhone.

## Field evaluation

1. Sign and install the IPA with Sideloadly. Test on a LiDAR-capable iPhone with a supported physical wide/tele pair and on a device lacking those capabilities. Record device model, iOS version, capture mode, mount height, and light level.
2. Mount the phone in portrait. Place a flat target over the central image region at measured camera-plane distances of approximately 0.5, 1, 2, and 3 m. Use tape or a laser rangefinder, keep the target perpendicular to the optical axis, and record actual distances. Capture repeated 10-second trials in each mode without moving the rig between modes.
3. Repeat in a clear indoor corridor, with lateral obstructions and a blocked central corridor, in low light, on textureless surfaces, and during controlled phone or target motion. Include partial occlusion, camera denial, background/foreground restart, and rapid MiDaS → LiDAR → Stereo → MiDaS switching. Use a sighted spotter and a controlled test area.
4. Prepare and share the CSV after each trial or trial group. Pair each timestamp range with the measured distance and human-labeled corridor state. From finite central ROI values compute MAE and RMSE in centimeters. Report missing-value counts with coverage, processed FPS from frame counts and elapsed time, and P50/P95 of processing and end-to-end latency. Compare state distributions per scene, count AVAILABLE on blocked trials as hazard misses, and tally switch success, failure, and superseded requests with their timing. Track stereo diagnostic readiness separately from metric readiness. The journal retains roughly the latest 6,000 events, so export regularly.
5. Before enabling stereo guidance, capture a calibration target across the overlap at several ranges and focus conditions. Measure reprojection and vertical epipolar residuals, establish distortion correction and physical scale, then measure depth error, coverage, and false-clear frequency on held-out scenes.

No physical iPhone measurements were collected. MAE, RMSE, throughput, latency percentiles, hazard-miss rates, and switching reliability remain pending device trials.

## Changed executable files

- `.github/workflows/build_ios_ipa.yml`
- `ios/HorusEyes/UI/ContentView.swift`, `DirectionalAdvisory.swift`
- `ios/HorusEyes/Vision/CameraTorchManager.swift`, `DepthEngine.swift`, `DepthFrame.swift`, `DepthDiagnostics.swift`, `MetricSpatialObservation.swift`, `NativeDepthCapture.swift`
- `ios/tests/BehaviorTests.swift`, `ios/tests/DepthPrototypeTests.swift`

The vision adapters use [ARKit scene depth](https://developer.apple.com/documentation/arkit/arframe/scenedepth), [MultiCam capture](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession), and [AVFoundation camera extrinsics](https://developer.apple.com/documentation/avfoundation/avcapturedevice/extrinsicmatrix(from:to:)).
