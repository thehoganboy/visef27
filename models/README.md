# MiDaS model artifacts

The Android FP32 asset is the offline desktop runtime model and the reference for iOS Core ML parity. Android selects its packaged FP32 or INT8 model by asset name. The six files in this directory are preserved research variants. The master benchmark selects the 160-pixel variant by default and accepts the other filenames through its model option. Their hashes differ, so every variant was retained.

Check all eight hashes from the repository root with `sha256sum -c models/SHA256SUMS`. The [Android exporter](../android/export_onnx.py) refreshes the mobile FP32 asset. The [iOS build workflow](../.github/workflows/build_ios_ipa.yml) pins the MiDaS architecture, EfficientNet architecture and weight hash, then verifies Core ML parity using recorded RGB fixtures.
