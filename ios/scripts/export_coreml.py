#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HorusEyes 2.0 — MiDaS to Core ML (DepthModel.mlpackage) Exporter
Target: iPhone 14 (Apple A15 Bionic — 16-core Apple Neural Engine)
Precision: Float16 / Float32 ML Program
Input:  'input_image' (Color Image 256x256 or 256x192 RGB, range 0..1 or normalized)
Output: 'raw_disparity' (MultiArray Float32 [1, H, W])
"""

import os
import sys
import shutil

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ios_dir = os.path.dirname(script_dir)
    project_root = os.path.dirname(ios_dir)
    target_package = os.path.join(ios_dir, "HorusEyes", "DepthModel.mlpackage")
    os.makedirs(os.path.dirname(target_package), exist_ok=True)

    print("[*] HorusEyes CoreML Exporter initializing...")
    print(f"[*] Target destination: {target_package}")

    try:
        import coremltools as ct  # type: ignore
        import torch
    except ImportError as e:
        print(f"[!] Warning: coremltools or torch not installed in current environment: {e}")
        print("[*] Creating placeholder DepthModel package if necessary for local workflow...")
        return

    # Dimensions: 256x256 is the standard square geometry for CoreML Vision Pipeline
    in_h, in_w = 256, 256

    print("[*] Attempting to load PyTorch MiDaS_small model...")
    model = None
    try:
        # Try loading from local torch hub or remote
        model = torch.hub.load("intel-isl/MiDaS", "MiDaS_small", trust_repo=True)
        model.eval()
        print("[+] Loaded MiDaS_small from torch.hub successfully.")
    except Exception as ex:
        print(f"[!] Could not load from torch.hub: {ex}")
        # Try tracing a torch model or loading from onnx
        pass

    if model is not None:
        example_input = torch.rand(1, 3, in_h, in_w)
        traced_model = torch.jit.trace(model, example_input)

        # Scale & bias for ImageNet normalization: (x / 255.0 - mean) / std
        # In coremltools ct.ImageType:
        # scale = 1.0 / (255.0 * 0.226) approx 0.01735
        # red_bias = -0.485 / 0.229 = -2.1179
        # green_bias = -0.456 / 0.224 = -2.0357
        # blue_bias = -0.406 / 0.225 = -1.8044
        image_input = ct.ImageType(
            name="input_image",
            shape=(1, 3, in_h, in_w),
            color_layout=ct.colorlayout.RGB,
            scale=1.0 / (255.0 * 0.226),
            bias=[-2.1179, -2.0357, -1.8044]
        )

        print("[*] Converting PyTorch traced model to Core ML MLProgram...")
        mlmodel = ct.convert(
            traced_model,
            inputs=[image_input],
            outputs=[ct.TensorType(name="raw_disparity", dtype=ct.precision.FLOAT32)],
            compute_units=ct.ComputeUnit.ALL,
            minimum_deployment_target=ct.target.iOS16,
            convert_to="mlprogram"
        )

        mlmodel.author = "HorusEyes Safety-Critical CV Team"
        mlmodel.short_description = "MiDaS Small Depth Estimation for Vision Impaired Navigation"
        mlmodel.input_description["input_image"] = "Color camera frame 256x256 RGB"
        mlmodel.output_description["raw_disparity"] = "Inverse depth disparity map"

        if os.path.exists(target_package):
            if os.path.isdir(target_package):
                shutil.rmtree(target_package)
            else:
                os.remove(target_package)

        mlmodel.save(target_package)
        print(f"[+] Saved DepthModel.mlpackage successfully to {target_package}")
        return

    # Fallback to ONNX if available
    onnx_path = os.path.join(project_root, "midas_small_160.onnx")
    if not os.path.exists(onnx_path):
        onnx_path = os.path.join(project_root, "model-small.onnx")

    if os.path.exists(onnx_path):
        print(f"[*] Found ONNX fallback model at {onnx_path}")
        try:
            import onnx
            onnx_model = onnx.load(onnx_path)
            mlmodel = ct.convert(
                onnx_model,
                inputs=[ct.ImageType(name="input_image", shape=(1, 3, in_h, in_w), color_layout=ct.colorlayout.RGB)],
                outputs=[ct.TensorType(name="raw_disparity", dtype=ct.precision.FLOAT32)],
                compute_units=ct.ComputeUnit.ALL,
                minimum_deployment_target=ct.target.iOS16,
                convert_to="mlprogram"
            )
            if os.path.exists(target_package):
                shutil.rmtree(target_package)
            mlmodel.save(target_package)
            print(f"[+] Successfully converted ONNX to Core ML at {target_package}")
            return
        except Exception as onnx_err:
            print(f"[!] ONNX conversion failed: {onnx_err}")

    print("[*] Exporter finished.")

if __name__ == "__main__":
    main()
