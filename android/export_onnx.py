#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HorusEyes 2.0 - Parity ONNX exporter for Android
================================================================================
Exports the EXACT weights used by the desktop demo (torch.hub intel-isl/MiDaS
'MiDaS_small') to ONNX with the EXACT input geometry produced by the desktop
`small_transform` for an upright portrait 480x640 camera frame:

    small_transform: Resize(256, keep_aspect_ratio=True, ensure_multiple_of=32,
                     resize_method="upper_bound", INTER_CUBIC) + ImageNet norm
    480x640 (W x H) portrait  ->  192 x 256 (W x H)  ->  tensor [1, 3, 256, 192]

Then verifies ONNX Runtime output against PyTorch on real images.

Usage:
    python android/export_onnx.py
================================================================================
"""
import os
import sys
import glob

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import numpy as np
import cv2
import torch

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(CURRENT_DIR)
TARGET_ONNX_PATH = os.path.join(CURRENT_DIR, "app", "src", "main", "assets", "midas_small.onnx")

IN_H, IN_W = 256, 192  # portrait input, identical to small_transform on a 480x640 upright frame


def main():
    model = torch.hub.load("intel-isl/MiDaS", "MiDaS_small", trust_repo=True).eval()
    transform = torch.hub.load("intel-isl/MiDaS", "transforms", trust_repo=True).small_transform

    dummy = torch.randn(1, 3, IN_H, IN_W)
    os.makedirs(os.path.dirname(TARGET_ONNX_PATH), exist_ok=True)
    tmp_path = TARGET_ONNX_PATH + ".tmp"
    torch.onnx.export(
        model, dummy, tmp_path,
        input_names=["image"], output_names=["depth"],
        opset_version=13, do_constant_folding=True, dynamo=False,
    )
    print(f"[+] Exported ONNX -> {tmp_path} ({os.path.getsize(tmp_path) / 1e6:.1f} MB)")

    # ── Verify against PyTorch with the real desktop preprocessing ──
    import onnxruntime as ort
    sess = ort.InferenceSession(tmp_path, providers=["CPUExecutionProvider"])
    imgs = sorted(glob.glob(os.path.join(PROJECT_ROOT, "data", "nyu2_test", "*_colors.png")))[:6]
    imgs += sorted(glob.glob(os.path.join(PROJECT_ROOT, "data", "rgbd_dataset_freiburg3_walking_static", "rgb", "*.png")))[::200][:4]
    worst = 0.0
    for p in imgs:
        bgr = cv2.imread(p)
        # Upright portrait crop (3:4) scaled to 480x640, as the tablet camera delivers
        h, w = bgr.shape[:2]
        cw = int(h * 3 / 4)
        x0 = (w - cw) // 2
        portrait = cv2.resize(bgr[:, x0:x0 + cw], (480, 640), interpolation=cv2.INTER_LINEAR)
        rgb = cv2.cvtColor(portrait, cv2.COLOR_BGR2RGB)
        x = transform(rgb)
        assert tuple(x.shape) == (1, 3, IN_H, IN_W), f"unexpected transform shape {tuple(x.shape)}"
        with torch.inference_mode():
            ref = model(x).squeeze().numpy()
        out = sess.run(None, {"image": x.numpy()})[0].squeeze()
        rel = float(np.abs(out - ref).max() / max(1e-6, np.abs(ref).max()))
        worst = max(worst, rel)
        print(f"    {os.path.basename(p):28s} torch p50={np.median(ref):7.2f} onnx p50={np.median(out):7.2f} max_rel_err={rel:.2e}")

    if worst > 1e-3:
        print(f"[!] ONNX output deviates from PyTorch (max rel err {worst:.2e}). Aborting.")
        os.remove(tmp_path)
        sys.exit(1)

    os.replace(tmp_path, TARGET_ONNX_PATH)
    print(f"[*] VERIFIED (max rel err {worst:.2e}). Installed -> {TARGET_ONNX_PATH}")


if __name__ == "__main__":
    main()
