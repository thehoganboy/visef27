#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HorusEyes 2.0 — MiDaS to Core ML (DepthModel.mlpackage) Exporter
Target: iPhone 14 / iPhone 14 Pro (Apple A15/A16 Bionic — 16-core Apple Neural Engine)
Precision: Float16 / Float32 ML Program
Input:  'x' (Color Image 256x256 RGB, ImageNet normalized)
Output: 'depth' / 'var_...' (MultiArray Float32 [1, 256, 256])
"""

import os
import sys
import shutil
import traceback
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(line_buffering=True, encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(line_buffering=True, encoding="utf-8")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ios_dir = os.path.dirname(script_dir)
    target_package = os.path.join(ios_dir, "HorusEyes", "DepthModel.mlpackage")
    os.makedirs(os.path.dirname(target_package), exist_ok=True)

    print("[*] HorusEyes CoreML Exporter initializing...", flush=True)
    print(f"[*] Target destination: {target_package}", flush=True)

    try:
        import coremltools as ct
        import torch
        import torch.hub
        print(f"[+] Loaded coremltools {ct.__version__}, PyTorch {torch.__version__}", flush=True)
    except ImportError as e:
        print(f"[!] FATAL: coremltools or torch not installed: {e}", flush=True)
        sys.exit(1)

    # Force PyTorch torch.hub to always trust repos in non-interactive CI environments
    _orig_hub_load = torch.hub.load
    def _always_trusted_hub_load(*args, **kwargs):
        kwargs["trust_repo"] = True
        return _orig_hub_load(*args, **kwargs)
    torch.hub.load = _always_trusted_hub_load

    in_h, in_w = 256, 256

    print("[*] Loading PyTorch MiDaS_small model...", flush=True)
    model = None

    # Source 1: intel-isl/MiDaS
    try:
        print("[*] Trying torch.hub.load('intel-isl/MiDaS', 'MiDaS_small')...", flush=True)
        model = torch.hub.load("intel-isl/MiDaS", "MiDaS_small", trust_repo=True)
        print("[+] Loaded MiDaS_small from intel-isl/MiDaS successfully.", flush=True)
    except Exception as ex1:
        print(f"[!] intel-isl attempt failed: {ex1}", flush=True)
        traceback.print_exc()

    # Source 2: isl-org/MiDaS
    if model is None:
        try:
            print("[*] Trying torch.hub.load('isl-org/MiDaS', 'MiDaS_small')...", flush=True)
            model = torch.hub.load("isl-org/MiDaS", "MiDaS_small", trust_repo=True)
            print("[+] Loaded MiDaS_small from isl-org/MiDaS successfully.", flush=True)
        except Exception as ex2:
            print(f"[!] isl-org attempt failed: {ex2}", flush=True)
            traceback.print_exc()

    # Source 3: Direct Download checkpoint & manual instantiate
    if model is None:
        try:
            weights_url = "https://github.com/isl-org/MiDaS/releases/download/v2_1/midas_v21_small_256.pt"
            weights_path = os.path.join(script_dir, "midas_v21_small_256.pt")
            if not os.path.exists(weights_path):
                print(f"[*] Downloading weights directly from {weights_url}...", flush=True)
                urllib.request.urlretrieve(weights_url, weights_path)
                print(f"[+] Downloaded {os.path.getsize(weights_path)} bytes to {weights_path}", flush=True)

            hub_dir = torch.hub.get_dir()
            for root, dirs, files in os.walk(hub_dir):
                if "midas_net_custom.py" in files:
                    parent_dir = os.path.dirname(root)
                    if parent_dir not in sys.path:
                        sys.path.insert(0, parent_dir)
                    from midas.midas_net_custom import MidasNet_small
                    model = MidasNet_small(None, features=64, backbone="efficientnet_lite3", exportable=True, non_negative=True, blocks={'expand': True})
                    state_dict = torch.load(weights_path, map_location="cpu")
                    model.load_state_dict(state_dict)
                    print("[+] Loaded MidasNet_small from local files + downloaded weights.", flush=True)
                    break
        except Exception as ex3:
            print(f"[!] Fallback attempt failed: {ex3}", flush=True)
            traceback.print_exc()

    if model is None:
        print("[!] FATAL: All methods to load MiDaS_small model failed!", flush=True)
        sys.exit(1)

    model.eval()

    print("[*] Tracing PyTorch model with check_trace=False, strict=False...", flush=True)
    example_input = torch.rand(1, 3, in_h, in_w)
    traced_model = torch.jit.trace(model, example_input, check_trace=False, strict=False)
    print("[+] Tracing succeeded.", flush=True)

    print("[*] Converting PyTorch traced model to Core ML MLProgram...", flush=True)
    mlmodel = None

    # Method 1: ct.ImageType with ImageNet normalization
    try:
        print("[*] Attempting conversion with ct.ImageType (RGB, normalized)...", flush=True)
        image_input = ct.ImageType(
            name="x",
            shape=(1, 3, in_h, in_w),
            color_layout=ct.colorlayout.RGB,
            scale=0.01735207,
            bias=[-2.1179, -2.0357, -1.8044]
        )
        mlmodel = ct.convert(
            traced_model,
            inputs=[image_input],
            compute_units=ct.ComputeUnit.ALL,
            minimum_deployment_target=ct.target.iOS16,
            convert_to="mlprogram"
        )
        print("[+] Converted successfully with ct.ImageType.", flush=True)
    except Exception as conv_err1:
        print(f"[!] ImageType conversion failed: {conv_err1}", flush=True)
        traceback.print_exc()

    # Method 2: ct.TensorType fallback
    if mlmodel is None:
        try:
            print("[*] Attempting conversion with ct.TensorType fallback...", flush=True)
            tensor_input = ct.TensorType(name="x", shape=(1, 3, in_h, in_w))
            mlmodel = ct.convert(
                traced_model,
                inputs=[tensor_input],
                compute_units=ct.ComputeUnit.ALL,
                minimum_deployment_target=ct.target.iOS16,
                convert_to="mlprogram"
            )
            print("[+] Converted successfully with ct.TensorType.", flush=True)
        except Exception as conv_err2:
            print(f"[!] TensorType conversion failed: {conv_err2}", flush=True)
            traceback.print_exc()

    # Method 3: NeuralNetwork format fallback
    if mlmodel is None:
        try:
            print("[*] Attempting conversion with convert_to='neuralnetwork' fallback...", flush=True)
            mlmodel = ct.convert(
                traced_model,
                inputs=[ct.TensorType(name="x", shape=(1, 3, in_h, in_w))],
                compute_units=ct.ComputeUnit.ALL,
                minimum_deployment_target=ct.target.iOS16
            )
            print("[+] Converted successfully with neuralnetwork format.", flush=True)
        except Exception as conv_err3:
            print(f"[!] NeuralNetwork conversion failed: {conv_err3}", flush=True)
            traceback.print_exc()

    if mlmodel is None:
        print("[!] FATAL: All Core ML conversion attempts failed!", flush=True)
        sys.exit(1)

    mlmodel.author = "HorusEyes Safety-Critical CV Team"
    mlmodel.short_description = "MiDaS Small Monocular Depth Estimation for Vision Impaired Navigation"

    if os.path.exists(target_package):
        if os.path.isdir(target_package):
            shutil.rmtree(target_package)
        else:
            os.remove(target_package)

    mlmodel.save(target_package)
    print(f"[+] Saved DepthModel.mlpackage successfully to {target_package}", flush=True)

    # Double check package presence
    if not os.path.exists(target_package):
        print(f"[!] FATAL: Target package {target_package} does not exist after save!", flush=True)
        sys.exit(1)

    print("[+] Core ML export completed successfully and verified.", flush=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as fatal_e:
        print(f"[!] Top-level Unhandled Exception: {fatal_e}", flush=True)
        traceback.print_exc()
        sys.exit(1)
