# VAMPIOR 3.3 Stereo metric depth

Executable commit `3028014ffbf7b609c95e55ef8b58917a932c4c4b` on `feature/ios-trimode-depth-prototype`. Final CI passed the Swift suites, the OpenCV calibration fixture, native iPhoneOS release compilation and arm64 IPA archive validation. Extract `HorusEyes_iPhone14Pro.ipa` from the artifact ZIP for Sideloadly. [Source diff](https://github.com/thehoganboy/visef27/compare/9479e80a60180ba04db5eb4a46ae8c4c5969d0d6...3028014ffbf7b609c95e55ef8b58917a932c4c4b) · [CI](https://github.com/thehoganboy/visef27/actions/runs/43713674272) · [Unsigned IPA](https://github.com/thehoganboy/visef27/actions/runs/43713674272/artifacts/14162010011)

- Synthetic 112×72 disparity fixture had 6,144/8,064 valid pixels (76.2%) versus 1,734/8,064 (21.5%) for the prior stride-2 matcher. Integer-shift MAE was 0.012 px. The 5.40 px shift returned a 5.247 px median. Processing the fixture took 3.9 ms on the macOS CI runner.
- Synthetic checkerboard fitting used 22 poses. Estimated baseline was 19.950 mm for a 20 mm fixture, with 0.104 px reprojection RMS and 0.034 px held-out vertical epipolar RMS. Held-out geometric errors at 50/100/200/300 cm were −0.094/−2.648/−6.953/+13.710 cm. These errors are from simulated image corners and illustrate the sensitivity at low disparity. No simulated profile was written or shipped.
- The initial dense fixture failed when edge refinement removed consistent matches in the high-texture scene. The final solver requires tighter disparity agreement across high-contrast neighbors and passed the revised regression run.

## Evidence and scope

The iPhone 14 Pro 3.2 CSV recorded Wide/Ultra Wide at 29.998 paired FPS, 244 accepted pairs, 5.435 ms P95 skew, and zero reported camera drops. All 244 pairs came from separate synchronizer callbacks. Across 51 processed Stereo frames, disparity-match min/median/max was 0/91/301 and metric coverage was 0%. All 51 withheld guidance. The 3.3 change retains that capture architecture. No original image pairs, physical checkerboard observations, or independent measurements accompanied the CSV.

3.3 fits checkerboard intrinsics, distortion, and millimeter-scale relative pose with OpenCV. Import checks capture identity, estimated pose, overlap, reprojection, held-out epipolar residuals, and independent range references. Live use further requires matching camera IDs, format, factory geometry, intrinsics and focus. The app retains original-resolution luma and metadata. In-app capture screens for skew, focus and board-like texture. The workstation checks actual shared corners, blur, clipping, and pose diversity.

Dense disparity uses a Swift CPU implementation with rolling Census/photometric cost aggregation and a bounded disparity-major cost volume. It uses subpixel fitting, uniqueness, reverse consistency, and local depth agreement across edges. Virtual-camera framing favors shared FOV and retains invalid warp margins. Metal and Accelerate were considered. The portable CPU solver keeps the analysis reproducible, with phone throughput still to be measured. The app exposes disparity and metric grayscale previews separately. For metric samples it propagates match and observed calibration-scale uncertainty. At 300 cm, 2 px disparity with 0.25 px uncertainty implies about 37.5 cm of depth uncertainty before the scale term and is rejected. These are screening estimates, with statistical calibration still pending.

Metric samples register to the displayed portrait camera. Unsupported pixels remain missing. Stereo clearance uses a conservative range bound, the existing 24-bin validity requirements, and a contiguous 55 cm body-plus-margin envelope at 75 cm. Two recent observations must support an AVAILABLE heading. The existing same-frame confirmed STOP path stays in effect. CSV adds decision reason, central body coverage, target ROI coverage, and target ROI uncertainty. MiDaS and LiDAR retain their established thresholds and guidance paths.

## Calibration procedure

1. Open **Stereo β → diagnostics → Acquire calibration dataset** after paired delivery is ready. Use a flat matte asymmetric checkerboard with a white border, such as 8×5 inner corners. Measure the square size in millimeters and enter the actual value. A larger board helps at 300 cm, provided the full board fits in both cameras at 50 cm. Keep the phone and board still for each shot. The first shot locks focus. Capture 20–25 fitting pairs with different angles, tilts, positions and ranges across the shared field. Aim for at least 15 accepted pairs after offline screening.
2. Capture held-out reference shots using the four separate reference choices near 50, 100, 200 and 300 cm. Bring the board close to perpendicular to the optical axis and center it, keeping the full board visible. Enter the ruler or laser distance to the plane along the Wide camera's optical axis. Set the reference datum at the camera plane and record the measurement method. Hold out these images from fitting. Export the calibration JSONL.
3. Run the fitter on the workstation. The optional NPZ contains rectification maps and the overlap mask. [OpenCV calibration documentation](https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html) The RMS values and the reference reconstruction error describe the fitted checkerboard geometry. Live dense-matcher accuracy requires a separate device trial.

```sh
python -m pip install "numpy<2" "opencv-python-headless==4.11.0.86"
python ios/scripts/fit_stereo_calibration.py stereo-dataset.jsonl --out StereoCalibration.json --maps StereoMaps.npz
```

4. In the app select **Import calibration profile** from the Stereo diagnostics menu and choose the resulting JSON. The app validates the file and restarts Stereo. Confirm that the live pair, frame dimensions and lens focus stay compatible. Capture a new dataset if they change. Uncalibrated disparity is in pixels and carries no metric guidance.

### Example schema only

This example uses empty arrays and nulls and is deliberately invalid as a calibration profile. Use the fitter to obtain the numeric values from physical data.

```json
{
  "pair": ["camera A ID", "camera B ID"],
  "captureSignature": ["camera A signature", "camera B signature"],
  "left": {"width": null, "height": null, "position": null, "intrinsics": [], "fittedIntrinsics": [], "distortion": []},
  "right": {"width": null, "height": null, "position": null, "intrinsics": [], "fittedIntrinsics": [], "distortion": []},
  "factoryExtrinsicsColumnsMM": [],
  "fittedExtrinsicsColumnsMM": [],
  "baselineMM": null,
  "trainingPairs": null,
  "reprojectionRMSPx": null,
  "epipolarRMSPx": null,
  "overlapFraction": null,
  "references": [{"measuredCM": null, "stereoCM": null}]
}
```

## Device acceptance

Repeat 50, 100, 200 and 300 cm against independently measured planes. Take repeated static, walking-motion, low-light, low-texture and occlusion trials. Keep a sighted spotter and log a blocked or clear corridor label before each run. Use exported central ROI depth for MAE, RMSE, bias and P95 absolute error, recording valid-only error and the fraction missing separately. Report disparity density, overlap, confidence and corridor coverage by scene. Count false AVAILABLE, missed hazards and unnecessary STOP. Measure pair/processing FPS, P50/P95 latency, visible label stability, switch failures and pressure. Retest the 3.2 capture setup under the same conditions. The 3.2 CSV provides a capture baseline and no metric error baseline.

Gate A has physical evidence for the 3.2 acquisition configuration and needs a 3.3 regression run on the phone. Gates B–F have synthetic, code or build evidence and require live disparity, a physical user-supplied calibration and independent field measurements for hardware acceptance. No calibrated phone depth, safety result, phone latency or installation is claimed.
