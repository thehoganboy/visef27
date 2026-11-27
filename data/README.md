# Research data and fixtures

| Directory | Provenance and usage |
| --- | --- |
| `raw/` | Original controlled-benchmark CSV and JSON from the Phase 01B test harness. Preserve both representations and the original fields. See the [controlled benchmark](../testing/benchmarks/benchmark_controlled_p1_f03.py) for units and generation. |
| `calibration/` | PCHIP calibration figures from the desktop research pipeline. Distance is recorded in centimeters. Physical Stereo profiles are acquired on the phone and kept locally. |
| `evaluation/` | Processed benchmark summaries, plots, NYU example images and annotated demo replay. See the [evaluation reports](../report/evaluation) for protocols. |
| `fixtures/demo/` | Recorded RGB images and replay metadata. The desktop replayer and iOS Core ML parity check load these images directly. |
| `fixtures/*.json` | Synthetic expected scenarios for regression tests. Distances are in centimeters and angles in degrees where indicated. |

Keep full NYU and TUM distributions and new field recordings under ignored `data/external/` or `data/local/`. Preserve an external dataset's source, release identifier, checksum, units and test conditions alongside each run. Use approved access-controlled storage for recordings that contain identifiable people. The archived results and fixtures retain their upstream names and bytes.
