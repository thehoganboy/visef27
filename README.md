# VAMPIOR · HorusEyes

VAMPIOR is an on-device assistive perception research prototype for ViSEF 2026–2027. The iPhone app combines obstacle depth, motion and time to collision with an uncertainty-aware budget of one spatial audio cue. Use a sighted spotter for walking trials and continue using your usual mobility aid.

## iPhone 14 Pro

Install the unsigned `HorusEyes_iPhone14Pro.ipa` from the matched GitHub Actions artifact using Sideloadly. The app requires iOS 16 or later and camera permission. Select MiDaS, LiDAR or Stereo, then tap **Bắt đầu**. Tap **Tạm dừng** to suspend guidance and silence audio.

- **MiDaS** uses a local Core ML model and the existing PCHIP metric calibration.
- **LiDAR** uses ARKit scene depth and its confidence map.
- **Stereo** uses two physical rear cameras. Open **Camera options → Research diagnostics** to inspect synchronized capture, disparity and calibration status. Factory estimates appear only in diagnostics. The phone enables measured Stereo guidance after a compatible profile passes checks.

### Stereo calibration

1. Open **Camera options → Acquire calibration dataset**. Fill in the actual inner corner counts and measured square size of a flat, matte asymmetric checkerboard.
2. Use both previews. Capture 20–25 fitting poses across the shared field with varied distance, position and tilt. Take separate centered reference captures near 50, 100, 200 and 300 cm using independently measured distances.
3. Share the JSONL dataset to a workstation. Fit the profile, then select **Import calibration profile** in Camera options.

```sh
python -m pip install "numpy<2" "opencv-python-headless==4.11.0.86"
python ios/scripts/fit_stereo_calibration.py stereo-dataset.jsonl --out StereoCalibration.json
```

If the app reports a format, lens position or intrinsics mismatch, confirm the current capture configuration and acquire a new dataset for that configuration. The [engineering acceptance report](report/engineering/acceptance.md) contains the independent field procedure and CSV evaluation commands.

### iOS build

For a macOS build, use the same commands and pinned inputs as the [unsigned IPA workflow](.github/workflows/build_ios_ipa.yml). Export the Core ML model with `python ios/scripts/export_coreml.py` after preparing the pinned model inputs, run `xcodegen generate` from `ios/`, then build the HorusEyes Release target for `iphoneos`. The workflow verifies the bundled model, executable architecture and archive.

## Desktop and Android

From the repository root, install the desktop dependencies and run the offline app.

```sh
python -m pip install -r python/requirements.txt
python main.py --source 0
python -m pytest -q
python -m testing.ios.test_stereo_calibration_fixture
python -m testing.tools.replay_demo --frames 12
```

Space or S toggles perception. Q or Escape closes the application. Use `--no-audio` to run silently. Historical benchmark instructions and calibration rationale are in the [desktop archive](report/archive/DESKTOP_README_2_0.md). Run relocated benchmark modules from the repository root with `python -m testing.benchmarks.<module>`.

For Android, use JDK 17 and Android SDK 34. From `android/`, run `./gradlew :app:testDebugUnitTest :app:assembleDebug` on macOS/Linux or `gradlew.bat :app:testDebugUnitTest :app:assembleDebug` on Windows. See the [Android guide](android/README.md).

## Repository

| Path | Contents |
| --- | --- |
| `ios/`, `android/`, `python/` | Platform runtimes and packaging |
| `testing/` | Portable iOS regressions, Python tests, benchmarks and diagnostics |
| `data/`, `models/` | Research inputs, evaluation records and model variants |
| `report/` | Research, historical evaluation and engineering acceptance |

[Dependency and cleanup manifest](report/engineering/repository-dependencies.md) · [Dataset provenance](data/README.md) · [Model inventory](models/README.md)
