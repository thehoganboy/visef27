# Repository dependencies

- iOS uses XcodeGen source discovery for `ios/HorusEyes`. The workflow compiles standalone tests from `testing/ios`, checks the OpenCV fitter, generates Core ML from pinned sources, compares it with the Android FP32 asset on recorded fixtures, then verifies the arm64 IPA.
- Android keeps Gradle's native source sets and tests under `android/app/src`. CameraX, ONNX Runtime and Android resource linking resolve the existing native paths.
- The desktop launcher loads `python.main`. The runtime loads the byte-verified Android FP32 model using a repository-relative path. Test modules and research tools import the same runtime package. The older PyTorch prototype is available under `testing/tools`.
- The [manifest](repository-manifest.tsv) classifies every tracked file from the integration baseline. [Data provenance](../../data/README.md) and [model hashes](../../models/SHA256SUMS) record the retained research inputs.

The migration preserves the source bytes of models and collected data. Historical reports retain their original evidence and dates. Benchmark and replay commands write new outputs under ignored `artifacts/`. The representative reports on the same topic were retained with their original filenames because they document different stages.
