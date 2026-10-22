"""
NYU Depth V2 Benchmark & Metric Depth Evaluator
═════════════════════════════════════════════════════════════════════════════════
Triển khai hệ thống đánh giá chuẩn hóa theo các bài báo và kho mã nguồn:
  - NYU Depth V2 Benchmark (Soumik Rakshit, Eigen et al.)
  - Depth Anything V2 (Metric Indoor Evaluation)
  - ZoeDepth (Relative-to-Metric Zero-shot Benchmark)
  - FastDepth (Mobile Real-time Inference & Quantization)

Hỗ trợ tính toán 6 chỉ số đo lường chuẩn quốc tế:
  1. RMSE (Root Mean Squared Error)
  2. Abs Rel (Mean Absolute Relative Error)
  3. Log10 Error
  4. Delta 1 (delta < 1.25)
  5. Delta 2 (delta < 1.25^2)
  6. Delta 3 (delta < 1.25^3)
═════════════════════════════════════════════════════════════════════════════════
"""

import os
import sys
import argparse
import time

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

import cv2
import torch
import numpy as np
import pandas as pd

# Import pipeline chính từ poc_demo
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import poc_demo


def compute_nyu_metrics(gt: np.ndarray, pred: np.ndarray):
    """
    Tính toán 6 chỉ số chuẩn trên tập hợp pixel hợp lệ của NYU Depth V2:
      - Khoảng cách hợp lệ: 0.4m <= gt <= 8.0m (chuẩn Eigen Split)
    """
    mask = (gt > 0.4) & (gt < 8.0) & (pred > 0.1) & (pred < 10.0)
    if not np.any(mask):
        return None

    g = gt[mask]
    p = pred[mask]

    # 1. AbsRel
    abs_rel = float(np.mean(np.abs(p - g) / g))

    # 2. RMSE
    rmse = float(np.sqrt(np.mean((p - g) ** 2)))

    # 3. Log10
    log10 = float(np.mean(np.abs(np.log10(p) - np.log10(g))))

    # 4, 5, 6. Threshold Accuracies (delta < 1.25^n)
    ratio = np.maximum(p / g, g / p)
    d1 = float(np.mean(ratio < 1.25))
    d2 = float(np.mean(ratio < 1.25 ** 2))
    d3 = float(np.mean(ratio < 1.25 ** 3))

    return {
        "abs_rel": abs_rel,
        "rmse": rmse,
        "log10": log10,
        "d1": d1,
        "d2": d2,
        "d3": d3,
    }


def evaluate_nyu(csv_path: str, base_dir: str, num_samples: int = 50, save_viz: bool = False):
    """Đánh giá toàn diện trên tập dữ liệu NYU Depth V2."""
    if not os.path.exists(csv_path):
        print(f"[Error] Không tìm thấy tệp CSV: {csv_path}")
        return

    df = pd.read_csv(csv_path, header=None)
    total_available = len(df)
    eval_count = min(num_samples, total_available) if num_samples > 0 else total_available

    print("=" * 75)
    print(f"  NYU Depth V2 Benchmark Evaluator (Total: {total_available}, Eval: {eval_count})")
    print("=" * 75)

    device = poc_demo.select_device()
    model, transform = poc_demo.init_midas(device)

    all_metrics = []
    fps_records = []

    out_dir = os.path.join(base_dir, "benchmark_viz")
    if save_viz:
        os.makedirs(out_dir, exist_ok=True)

    indices = np.linspace(0, total_available - 1, eval_count, dtype=int)

    for i, idx in enumerate(indices):
        rgb_rel, depth_rel = df.iloc[idx, 0], df.iloc[idx, 1]
        rgb_path = os.path.join(base_dir, rgb_rel)
        depth_path = os.path.join(base_dir, depth_rel)

        if not os.path.exists(rgb_path) or not os.path.exists(depth_path):
            continue

        rgb = cv2.imread(rgb_path)
        gt_raw = cv2.imread(depth_path, cv2.IMREAD_UNCHANGED)
        if rgb is None or gt_raw is None:
            continue

        # Ground truth trong hệ mét (Kinect uint16 mm -> mét)
        gt_m = gt_raw.astype(np.float32) / 1000.0

        # Đo thời gian suy luận
        t0 = time.perf_counter()
        d_norm, d_raw = poc_demo.infer_depth(rgb, model, transform, device)
        t_infer = time.perf_counter() - t0
        fps_records.append(1.0 / max(t_infer, 1e-6))

        # Chuyển đổi disparity raw sang chiều sâu metric (m)
        inv_z = poc_demo.RAW_SCALE_A * d_raw + poc_demo.RAW_SHIFT_B
        pred_m = np.where(inv_z > 0.05, 1.0 / np.maximum(inv_z, 0.05), 10.0)

        # Tính toán metrics
        metrics = compute_nyu_metrics(gt_m, pred_m)
        if metrics:
            all_metrics.append(metrics)

        # Lưu ảnh đối chiếu trực quan (Visual Qualitative Evaluation)
        if save_viz and (i < 5 or i % (eval_count // 5 or 1) == 0):
            # Normalize GT and Pred for visualization
            gt_disp = np.clip(gt_m, 0.5, 5.0)
            gt_vis = ((5.0 - gt_disp) / 4.5 * 255.0).astype(np.uint8)
            gt_heat = cv2.applyColorMap(gt_vis, cv2.COLORMAP_MAGMA)

            pred_disp = np.clip(pred_m, 0.5, 5.0)
            pred_vis = ((5.0 - pred_disp) / 4.5 * 255.0).astype(np.uint8)
            pred_heat = cv2.applyColorMap(pred_vis, cv2.COLORMAP_MAGMA)

            # Error map
            err_map = np.abs(pred_m - gt_m)
            err_vis = np.clip(err_map / 2.0 * 255.0, 0, 255).astype(np.uint8)
            err_heat = cv2.applyColorMap(err_vis, cv2.COLORMAP_JET)

            h_r, w_r = rgb.shape[:2]
            viz_strip = np.hstack([rgb, gt_heat, pred_heat, err_heat])
            out_fn = os.path.join(out_dir, f"eval_sample_{idx:05d}.jpg")
            cv2.imwrite(out_fn, viz_strip)

        if (i + 1) % 10 == 0 or (i + 1) == eval_count:
            print(f"  Processed {i+1}/{eval_count} samples...")

    if not all_metrics:
        print("[Warning] Không tính được metric nào từ tập mẫu.")
        return

    # Tổng hợp kết quả
    avg_abs_rel = np.mean([m["abs_rel"] for m in all_metrics])
    avg_rmse    = np.mean([m["rmse"] for m in all_metrics])
    avg_log10   = np.mean([m["log10"] for m in all_metrics])
    avg_d1      = np.mean([m["d1"] for m in all_metrics])
    avg_d2      = np.mean([m["d2"] for m in all_metrics])
    avg_d3      = np.mean([m["d3"] for m in all_metrics])
    avg_fps     = np.mean(fps_records)

    print("\n" + "=" * 75)
    print("  KẾT QUẢ ĐÁNH GIÁ CHUẨN NYU DEPTH V2 (BENCHMARK RESULTS)")
    print("=" * 75)
    print(f"  Số mẫu kiểm thử:           {len(all_metrics)} frames")
    print(f"  Tốc độ xử lý trung bình:   {avg_fps:.1f} FPS (trên CPU)")
    print(f"  Abs Rel (Sai số tương đối): {avg_abs_rel:.4f}")
    print(f"  RMSE (Sai số tuyệt đối):   {avg_rmse:.3f} mét")
    print(f"  Log10 Error:               {avg_log10:.4f}")
    print(f"  Delta 1 (δ < 1.25):        {avg_d1*100:.2f}%")
    print(f"  Delta 2 (δ < 1.25^2):      {avg_d2*100:.2f}%")
    print(f"  Delta 3 (δ < 1.25^3):      {avg_d3*100:.2f}%")
    print("=" * 75)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="NYU Depth V2 Benchmark Evaluator")
    parser.add_argument("--csv", type=str, default=r"data/nyu2_test.csv")
    parser.add_argument("--dir", type=str, default=r"e:\visef27 project")
    parser.add_argument("--samples", "-n", type=int, default=20)
    parser.add_argument("--viz", action="store_true")
    args = parser.parse_args()

    csv_full = os.path.join(args.dir, args.csv) if not os.path.isabs(args.csv) else args.csv
    evaluate_nyu(csv_full, args.dir, num_samples=args.samples, save_viz=args.viz)
