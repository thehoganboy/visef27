#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HorusEyes 2.0 — MiDaS to Core ML (DepthModel.mlpackage) Exporter
Target: iPhone 14 / iPhone 14 Pro (Apple A15/A16 Bionic — 16-core Apple Neural Engine)
Precision: Float16 / Float32 ML Program
Input:  'image' (Color Image 256x256 RGB, ImageNet normalized)
Output: 'depth' / 'var_...' (MultiArray Float32 [1, 256, 256])
"""

import os
import sys
import shutil
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ios_dir = os.path.dirname(script_dir)
    target_package = os.path.join(ios_dir, "HorusEyes", "DepthModel.mlpackage")
    os.makedirs(os.path.dirname(target_package), exist_ok=True)

    print("[*] HorusEyes CoreML Exporter initializing...")
    print(f"[*] Target destination: {target_package}")

    try:
        import coremltools as ct
        import torch
    except ImportError as e:
        print(f"[!] FATAL: coremltools or torch not installed: {e}")
        sys.exit(1)

    in_h, in_w = 256, 256

    print("[*] Loading PyTorch MiDaS_small model...")
    model = None

    # Source 1: intel-isl/MiDaS
    try:
        print("[*] Trying torch.hub.load('intel-isl/MiDaS', 'MiDaS_small')...")
        model = torch.hub.load("intel-isl/MiDaS", "MiDaS_small", trust_repo=True)
        print("[+] Loaded MiDaS_small from intel-isl/MiDaS.")
    except Exception as ex1:
        print(f"[!] intel-isl attempt failed: {ex1}")

    # Source 2: isl-org/MiDaS
    if model is None:
        try:
            print("[*] Trying torch.hub.load('isl-org/MiDaS', 'MiDaS_small')...")
            model = torch.hub.load("isl-org/MiDaS", "MiDaS_small", trust_repo=True)
            print("[+] Loaded MiDaS_small from isl-org/MiDaS.")
        except Exception as ex2:
            print(f"[!] isl-org attempt failed: {ex2}")

    # Source 3: Direct Download checkpoint & manual instantiate
    if model is None:
        weights_url = "https://github.com/isl-org/MiDaS/releases/download/v2_1/midas_v21_small_256.pt"
        weights_path = os.path.join(script_dir, "midas_v21_small_256.pt")
        if not os.path.exists(weights_path):
            print(f"[*] Downloading weights directly from {weights_url}...")
            urllib.request.urlretrieve(weights_url, weights_path)
            print(f"[+] Downloaded {os.path.getsize(weights_path)} bytes to {weights_path}")

        hub_dir = torch.hub.get_dir()
        found = False
        for root, dirs, files in os.walk(hub_dir):
            if "midas_net_custom.py" in files:
                parent_dir = os.path.dirname(root)
                if parent_dir not in sys.path:
                    sys.path.insert(0, parent_dir)
                try:
                    from midas.midas_net_custom import MidasNet_small
                    model = MidasNet_small(None, features=64, backbone="efficientnet_lite3", exportable=True, non_negative=True, blocks={'expand': True})
                    state_dict = torch.load(weights_path, map_location="cpu")
                    model.load_state_dict(state_dict)
                    print("[+] Loaded MidasNet_small from local files + downloaded weights.")
                    found = True
                    break
                except Exception as ex3:
                    print(f"[!] Local MidasNet_small import error: {ex3}")
        if not found:
            print("[!] Could not construct model from fallback.")

    if model is None:
        print("[!] FATAL: All methods to load MiDaS_small model failed!")
        sys.exit(1)

    model.eval()

    print("[*] Tracing PyTorch model with sample input [1, 3, 256, 256]...")
    example_input = torch.rand(1, 3, in_h, in_w)
    traced_model = torch.jit.trace(model, example_input)

    # CoreML ImageType input with standard MiDaS ImageNet normalization
    # scale = 1.0 / (255.0 * 0.226) approx 0.01735207
    # bias = [-0.485 / 0.229, -0.456 / 0.224, -0.406 / 0.225] = [-2.1179, -2.0357, -1.8044]
    image_input = ct.ImageType(
        name="image",
        shape=(1, 3, in_h, in_w),
        color_layout=ct.colorlayout.RGB,
        scale=0.01735207,
        bias=[-2.1179, -2.0357, -1.8044]
    )

    print("[*] Converting PyTorch traced model to Core ML MLProgram...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[image_input],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram"
    )

    mlmodel.author = "HorusEyes Safety-Critical CV Team"
    mlmodel.short_description = "MiDaS Small Monocular Depth Estimation for Vision Impaired Navigation"
    mlmodel.input_description["image"] = "Color camera frame 256x256 RGB"

    if os.path.exists(target_package):
        if os.path.isdir(target_package):
            shutil.rmtree(target_package)
        else:
            os.remove(target_package)

    mlmodel.save(target_package)
    print(f"[+] Saved DepthModel.mlpackage successfully to {target_package}")

    # Double check package presence
    if not os.path.exists(target_package):
        print(f"[!] FATAL: Target package {target_package} does not exist after save!")
        sys.exit(1)

    print("[+] Core ML export completed successfully and verified.")

if __name__ == "__main__":
    main()
