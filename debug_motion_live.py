#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HorusEyes 2.0 - Live Kinematics & Motion Tracking Diagnostic Tool
================================================================================
Công cụ kiểm thử trực quan và debug tầng Động học (Kinematics & Motion Tracking):
  1. Hỗ trợ chạy trực tiếp với Camera thực tế (Webcam/DroidCam/IP Camera).
  2. Tự động chuyển đổi sang Synthetic Generator nếu không có camera hoặc chạy test.
  3. In Telemetry chi tiết mỗi 5 frame lên terminal:
     [ID: #xx] d: ... | dd: ... | dt: ... | vz_raw: ... | vz_smooth: ... | TTC: ... | STATUS: ...
  4. Hiển thị OpenCV GUI thời gian thực:
     - Vector Arrow đỏ hướng vào tâm khi vật đang lao tới (vz >= +5.0 cm/s).
     - Vector Arrow xanh hướng ra xa khi vật lùi ra (vz <= -5.0 cm/s).
     - Điểm neo tĩnh (Static Anchor) khi vật đứng yên (|vz| < 5.0 cm/s).
     - Phân định luồng ACTIVE (được cấp ngân sách) vs SUPPRESSED (bị triệt tiêu).
================================================================================
"""

import sys
import os
import time
import argparse
import math
import cv2
import numpy as np

# Đảm bảo in tiếng Việt chuẩn trên console Windows
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

import config
from video_capture import ThreadedCamera
from depth_engine import DepthEstimator
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager
from audio_synth import SpatialAudioEngine


class SyntheticMotionScene:
    """
    Tạo chuỗi khung hình tổng hợp mô phỏng chuyển động thực tế:
    - Vật thể #1 (Bên phải): Tiến nhanh vào gần (d = 180cm -> 30cm, vz > 50cm/s), dừng lại, lùi ra xa.
    - Vật thể #2 (Bên trái): Đứng yên tại cự ly 110cm (vz = 0cm/s).
    """

    def __init__(self, width: int = 640, height: int = 480):
        self.width = width
        self.height = height
        self.frame_idx = 0
        self.start_time = time.perf_counter()

    def get_frame(self) -> np.ndarray:
        self.frame_idx += 1
        t = (time.perf_counter() - self.start_time)

        # Nền xám tối
        frame = np.full((self.height, self.width, 3), 40, dtype=np.uint8)

        # Chu kỳ 6 giây: 0-2.5s tiến vào, 2.5-3.5s dừng lại, 3.5-6.0s lùi ra
        cycle_t = t % 6.0
        if cycle_t < 2.5:
            # Tiến vào: d từ 180cm xuống 35cm
            ratio = cycle_t / 2.5
            dist1 = 180.0 - 145.0 * ratio
        elif cycle_t < 3.5:
            # Dừng lại ở 35cm
            dist1 = 35.0
        else:
            # Lùi ra: d từ 35cm lên 180cm
            ratio = (cycle_t - 3.5) / 2.5
            dist1 = 35.0 + 145.0 * ratio

        # Kích thước bbox tỉ lệ nghịch với khoảng cách (càng gần càng to)
        size1 = int(np.clip(160.0 * (100.0 / max(dist1, 20.0)), 60, 240))
        cx1 = int(self.width * 0.70)
        cy1 = int(self.height * 0.50)
        x1_min = max(0, cx1 - size1 // 2)
        y1_min = max(0, cy1 - size1 // 2)
        x1_max = min(self.width, cx1 + size1 // 2)
        y1_max = min(self.height, cy1 + size1 // 2)

        # Độ sáng tỉ lệ với độ gần (để MiDaS ước lượng depth tương ứng)
        lum1 = int(np.clip(255.0 - (dist1 / 250.0) * 180.0, 60, 255))
        cv2.rectangle(frame, (x1_min, y1_min), (x1_max, y1_max), (lum1, lum1, lum1), -1)
        cv2.putText(frame, "TARGET #1 (DYNAMIC)", (x1_min, max(20, y1_min - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)

        # Vật thể #2: Tĩnh ở 110cm (bên trái)
        dist2 = 110.0
        size2 = int(160.0 * (100.0 / dist2))
        cx2 = int(self.width * 0.28)
        cy2 = int(self.height * 0.50)
        x2_min = max(0, cx2 - size2 // 2)
        y2_min = max(0, cy2 - size2 // 2)
        x2_max = min(self.width, cx2 + size2 // 2)
        y2_max = min(self.height, cy2 + size2 // 2)

        lum2 = int(255.0 - (dist2 / 250.0) * 180.0)
        cv2.rectangle(frame, (x2_min, y2_min), (x2_max, y2_max), (lum2, lum2, lum2), -1)
        cv2.putText(frame, "TARGET #2 (STATIC 110cm)", (x2_min, max(20, y2_min - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, (180, 180, 180), 1)

        return frame


def draw_motion_overlay(
    canvas_bgr: np.ndarray,
    obs_res,
    kin_res,
    decision
) -> np.ndarray:
    """
    Vẽ Bounding Box, Vector Arrow vận tốc và thông tin động học lên từng vật cản.
    """
    h, w = canvas_bgr.shape[:2]
    out = canvas_bgr.copy()

    track_details = kin_res.track_details if kin_res.track_details else {}
    active_id = decision.active_obstacle_id

    for obs in obs_res.all_obstacles:
        is_active = (obs.id == active_id)
        trk = track_details.get(obs.id, {})

        vz_raw = trk.get("vz_raw", 0.0)
        vz_smooth = trk.get("vz_smooth", 0.0)
        delta_d = trk.get("delta_d", 0.0)
        delta_t = trk.get("delta_t", 0.0)
        ttc = trk.get("ttc", float("inf"))
        dist_cm = obs.dist_cm
        bx, by, bw, bh = obs.bbox
        cx, cy = obs.x, obs.y

        # ── 1. Chọn màu Bounding Box ──
        if is_active:
            if dist_cm <= config.DIST_CRITICAL_CM or (ttc <= config.TTC_CRITICAL and vz_smooth >= 10.0):
                box_col = (0, 0, 255)       # Đỏ: Nguy hiểm khẩn cấp
            elif dist_cm < config.DIST_WARNING_CM or (ttc <= config.TTC_WARNING and vz_smooth >= 5.0):
                box_col = (0, 140, 255)     # Cam: Cảnh báo
            else:
                box_col = (0, 255, 120)     # Xanh lục: Active an toàn
            thick = 2
        else:
            box_col = (130, 130, 130)       # Xám: Bị triệt tiêu (Suppressed)
            thick = 1

        cv2.rectangle(out, (bx, by), (bx + bw, by + bh), box_col, thick)

        # ── 2. Vẽ Vector Arrow Động học (Velocity Vector Arrow) ──
        if vz_smooth >= config.VZ_MIN_APPROACH_CM_S:
            # Đang lao tới (APPROACHING) -> Mũi tên đỏ hướng xuống/vào phía người dùng
            arrow_len = int(np.clip(vz_smooth * 0.7, 22, 90))
            arrow_col = (0, 0, 255) if is_active else (80, 80, 220)
            cv2.arrowedLine(out, (cx, cy), (cx, cy + arrow_len), arrow_col, 3, tipLength=0.35)
            # Điểm tâm
            cv2.circle(out, (cx, cy), 4, arrow_col, -1)
            status_text = f"vz: +{vz_smooth:.1f}cm/s | TTC: {ttc:.2f}s"
            status_col = (0, 0, 255) if is_active else (180, 180, 180)
        elif vz_smooth <= -config.VZ_MIN_APPROACH_CM_S:
            # Đang lùi xa (RECEDING) -> Mũi tên xanh dương/cyan hướng lên/ra xa
            arrow_len = int(np.clip(abs(vz_smooth) * 0.7, 22, 90))
            arrow_col = (255, 190, 0) if is_active else (180, 160, 80)
            cv2.arrowedLine(out, (cx, cy), (cx, cy - arrow_len), arrow_col, 2, tipLength=0.35)
            cv2.circle(out, (cx, cy), 3, arrow_col, -1)
            status_text = f"vz: {vz_smooth:.1f}cm/s | RECEDING"
            status_col = (255, 200, 0) if is_active else (180, 180, 180)
        else:
            # Đứng yên (STATIC) -> Biểu tượng neo tròn xám
            anchor_col = (0, 255, 200) if (is_active and dist_cm < 50.0) else (150, 150, 150)
            cv2.circle(out, (cx, cy), 6, anchor_col, 1)
            cv2.line(out, (cx - 8, cy), (cx + 8, cy), anchor_col, 1)
            cv2.line(out, (cx, cy - 8), (cx, cy + 8), anchor_col, 1)
            status_text = f"vz: 0.0cm/s | STATIC"
            status_col = anchor_col

        # ── 3. Nhãn ID & Thông số ──
        role_tag = "[ACTIVE STREAM]" if is_active else "[SUPPRESSED]"
        tag_col = (0, 255, 100) if is_active else (140, 140, 140)

        header_label = f"#{obs.id} {role_tag} {dist_cm:.1f}cm"
        cv2.putText(out, header_label, (bx, max(18, by - 6)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, tag_col, 1, cv2.LINE_AA)

        cv2.putText(out, status_text, (bx, by + bh + 16),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.38, status_col, 1, cv2.LINE_AA)

    # ── 4. Mũi tên né thoát an toàn (Safe-Direction Escape) ──
    if kin_res.threat_level != "SAFE":
        safe_dir = kin_res.safe_direction
        esc_col = (0, 255, 0)
        mid_y = int(h * 0.10)
        if safe_dir == "RIGHT":
            esc_txt = "SAFE ESCAPE: -> RIGHT"
            cv2.arrowedLine(out, (w // 2 - 40, mid_y), (w // 2 + 50, mid_y), esc_col, 3, tipLength=0.35)
        else:
            esc_txt = "SAFE ESCAPE: <- LEFT"
            cv2.arrowedLine(out, (w // 2 + 40, mid_y), (w // 2 - 50, mid_y), esc_col, 3, tipLength=0.35)

        (tw, th), _ = cv2.getTextSize(esc_txt, cv2.FONT_HERSHEY_SIMPLEX, 0.48, 2)
        cv2.rectangle(out, (w // 2 - tw // 2 - 6, mid_y + 8), (w // 2 + tw // 2 + 6, mid_y + 28), (0, 0, 0), -1)
        cv2.putText(out, esc_txt, (w // 2 - tw // 2, mid_y + 23),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.48, esc_col, 2, cv2.LINE_AA)

    return out


def render_dashboard(
    rgb_overlay: np.ndarray,
    depth_norm: np.ndarray,
    obs_res,
    kin_res,
    decision,
    fps: float,
    latency_ms: float
) -> np.ndarray:
    """
    Tạo canvas kép Side-by-Side (RGB Kinematics bên trái, Depth Heatmap bên phải).
    """
    h, w = rgb_overlay.shape[:2]

    # Depth colormap (INFERNO)
    depth_colored = cv2.applyColorMap(depth_norm, cv2.COLORMAP_INFERNO)

    # Ghép ngang side-by-side
    combined = np.hstack([rgb_overlay, depth_colored])

    # HUD Panel ở góc trên bên trái
    hud_overlay = combined.copy()
    cv2.rectangle(hud_overlay, (8, 8), (380, 130), (10, 10, 10), -1)
    cv2.addWeighted(hud_overlay, 0.70, combined, 0.30, 0, combined)

    # Dòng 1: FPS & Latency
    cv2.putText(combined, f"FPS: {fps:4.1f} | Pipeline Latency: {latency_ms:4.1f}ms",
                (16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.44, (0, 255, 255), 1, cv2.LINE_AA)

    # Dòng 2: Mối nguy chính & Vận tốc
    act_id = decision.active_obstacle_id
    ttc_str = f"{decision.ttc:.2f}s" if decision.ttc < float("inf") else "inf"
    vz_str = f"{kin_res.primary_velocity_z:+.1f}cm/s"
    cv2.putText(combined, f"Active #{act_id} | Dist: {decision.dist_cm:4.1f}cm | vz: {vz_str} | TTC: {ttc_str}",
                (16, 48), cv2.FONT_HERSHEY_SIMPLEX, 0.42, (255, 255, 255), 1, cv2.LINE_AA)

    # Dòng 3: Ngân sách & Điểm ưu tiên
    cv2.putText(combined, f"Stream Budget: 1 Active / {decision.suppressed_count} Suppressed | Score: {decision.priority_score:.2f}",
                (16, 68), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (180, 220, 255), 1, cv2.LINE_AA)

    # Dòng 4: Chế độ thính giác & Âm lượng né tránh
    cue_str = f"Cue: {decision.cue_mode} | Pan: {decision.pan:+.2f} | Hyst Vol: {decision.volume_factor:.2f}x"
    cue_col = (0, 255, 100) if decision.cue_mode == "SHARP_PING" else ((0, 165, 255) if decision.cue_mode == "ACOUSTIC_BLUR" else (140, 140, 140))
    cv2.putText(combined, cue_str, (16, 88), cv2.FONT_HERSHEY_SIMPLEX, 0.40, cue_col, 1, cv2.LINE_AA)

    # Dòng 5: Hành lang an toàn
    sec = kin_res.threats
    sec_str = f"Corridors: L:{sec['LEFT'].dist_cm:.0f}cm | C:{sec['CENTER'].dist_cm:.0f}cm | R:{sec['RIGHT'].dist_cm:.0f}cm"
    cv2.putText(combined, sec_str, (16, 108), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (200, 200, 200), 1, cv2.LINE_AA)

    # Phím tắt điều khiển
    cv2.putText(combined, "['q': Quit | 's': Toggle Synthetic | 'm': Mute]",
                (w + 16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (0, 255, 200), 1, cv2.LINE_AA)

    return combined


def main():
    parser = argparse.ArgumentParser(description="HorusEyes 2.0 - Live Kinematics Debug Tool")
    parser.add_argument("--source", "-s", type=str, default=None, help="Camera index or stream URL")
    parser.add_argument("--synthetic", action="store_true", help="Chạy chế độ mô phỏng tổng hợp (Synthetic scene)")
    parser.add_argument("--no-audio", action="store_true", help="Tắt tổng hợp âm thanh")
    parser.add_argument("--max-frames", type=int, default=0, help="Dừng sau N frames (dùng cho automated test)")
    parser.add_argument("--headless", action="store_true", help="Không mở cửa sổ OpenCV GUI")
    args = parser.parse_args()

    print("=" * 80)
    print("  HORUSEYES 2.0 — LIVE KINEMATICS & MOTION TRACKING DIAGNOSTIC")
    print("=" * 80)

    # 1. Khởi tạo Pipeline
    print("[+] Đang khởi tạo các module thị giác & động học...")
    depth_est = DepthEstimator(device="cpu")
    kinematics = KinematicsEngine()
    budget = AuditoryBudgetManager()

    audio_engine = None
    if not args.no_audio:
        try:
            audio_engine = SpatialAudioEngine()
            print("[+] Audio Engine: Đã kích hoạt 3D Binaural Callback.")
        except Exception as e:
            print(f"[!] Cảnh báo: Không thể khởi tạo audio ({e}). Tiếp tục ở chế độ silent.")

    # 2. Khởi tạo nguồn video
    synthetic_mode = args.synthetic
    synthetic_gen = SyntheticMotionScene(config.CAM_WIDTH, config.CAM_HEIGHT)
    cam = None

    if not synthetic_mode:
        src = args.source if args.source is not None else config.DEFAULT_SOURCE
        try:
            print(f"[+] Đang kết nối nguồn video '{src}'...")
            cam = ThreadedCamera(src)
            print("[*] Camera đã kết nối thành công.")
        except Exception as e:
            print(f"[!] Không thể mở camera ({e}). Tự động chuyển sang chế độ SYNTHETIC!")
            synthetic_mode = True

    if synthetic_mode:
        print("[*] Chế độ hoạt động: SYNTHETIC MOTION GENERATOR (Vật động tiến sát & Vật tĩnh 110cm)")
    else:
        print("[*] Chế độ hoạt động: LIVE CAMERA STREAM")

    print("[*] Nhấn 'q' hoặc ESC trong cửa sổ để thoát.")
    print("=" * 80)

    frame_count = 0
    fps_ema = 30.0
    t_prev = time.perf_counter()

    try:
        while True:
            t_loop_start = time.perf_counter()

            # Lấy khung hình
            if synthetic_mode:
                frame_bgr = synthetic_gen.get_frame()
                time.sleep(0.033)  # Giả lập 30 FPS
            else:
                frame_bgr = cam.read()
                if frame_bgr is None:
                    print("[!] Không nhận được khung hình từ camera. Tạm nghỉ 10ms...")
                    time.sleep(0.010)
                    continue
                # Lật ngang selfie nếu bật trong config
                if config.FLIP_HORIZONTAL:
                    frame_bgr = cv2.flip(frame_bgr, 1)

            frame_count += 1
            now = time.perf_counter()

            # Pipeline xử lý
            depth_norm, depth_raw = depth_est.infer_depth(frame_bgr)
            obs_res = depth_est.detect_obstacle(depth_norm, depth_raw)
            kin_res = kinematics.compute(obs_res, now)
            decision = budget.coordinate(obs_res, kin_res)

            if audio_engine is not None:
                audio_engine.update_state(decision)

            # Tính FPS & Độ trễ
            t_pipeline_end = time.perf_counter()
            dt_loop = max(0.001, t_pipeline_end - t_prev)
            t_prev = t_pipeline_end
            curr_fps = 1.0 / dt_loop
            fps_ema = 0.20 * curr_fps + 0.80 * fps_ema
            latency_ms = (t_pipeline_end - t_loop_start) * 1000.0

            # ── In Telemetry Động học lên terminal mỗi 5 frames ──
            if frame_count % 5 == 0:
                print(f"\n[FRAME #{frame_count:04d} | FPS: {fps_ema:4.1f} | Latency: {latency_ms:4.1f}ms] "
                      f"Active: #{decision.active_obstacle_id} (Score: {decision.priority_score:.2f}) | "
                      f"Cue: {decision.cue_mode:13s} | Pan: {decision.pan:+.2f}")
                print("-" * 100)

                track_details = kin_res.track_details if kin_res.track_details else {}
                for o in obs_res.all_obstacles:
                    trk = track_details.get(o.id, {})
                    vz_raw = trk.get("vz_raw", 0.0)
                    vz_sm = trk.get("vz_smooth", 0.0)
                    dd = trk.get("delta_d", 0.0)
                    dt = trk.get("delta_t", 0.0)
                    ttc = trk.get("ttc", float("inf"))
                    ttc_s = f"{ttc:5.2f}s" if ttc < float("inf") else "  inf "

                    is_act = (o.id == decision.active_obstacle_id)
                    if vz_sm >= config.VZ_MIN_APPROACH_CM_S:
                        status = "APPROACHING (ACTIVE)" if is_act else "APPROACHING (SUPPRESSED)"
                    elif vz_sm <= -config.VZ_MIN_APPROACH_CM_S:
                        status = "RECEDING    (ACTIVE)" if is_act else "RECEDING    (SUPPRESSED)"
                    else:
                        status = "STATIC      (ACTIVE)" if is_act else "STATIC      (SUPPRESSED)"

                    print(f"  [ID: #{o.id:02d}] d:{o.dist_cm:5.1f}cm | dd:{dd:+5.1f}cm | dt:{dt:5.3f}s | "
                          f"vz_raw:{vz_raw:+5.1f}cm/s | vz_smooth:{vz_sm:+5.1f}cm/s | TTC: {ttc_s} | STATUS: {status}")

            # ── Vẽ OpenCV GUI & Hiển thị ──
            if not args.headless:
                overlay_rgb = draw_motion_overlay(frame_bgr, obs_res, kin_res, decision)
                dashboard = render_dashboard(overlay_rgb, depth_norm, obs_res, kin_res, decision, fps_ema, latency_ms)
                cv2.imshow("HorusEyes 2.0 - Live Kinematics Telemetry", dashboard)

                key = cv2.waitKey(1) & 0xFF
                if key in [ord('q'), 27]:  # 'q' hoặc ESC
                    print("\n[*] Người dùng bấm thoát.")
                    break
                elif key == ord('s'):
                    synthetic_mode = not synthetic_mode
                    print(f"\n[*] Đổi chế độ: {'SYNTHETIC' if synthetic_mode else 'LIVE CAMERA'}")
                elif key == ord('m'):
                    if audio_engine is not None:
                        is_muted = audio_engine.is_muted
                        audio_engine.set_muted(not is_muted)
                        print(f"\n[*] Audio Mute: {not is_muted}")

            if args.max_frames > 0 and frame_count >= args.max_frames:
                print(f"\n[*] Đã đạt giới hạn {args.max_frames} frames. Dừng kiểm thử.")
                break

    except KeyboardInterrupt:
        print("\n[*] Ngắt bởi người dùng (Ctrl+C).")
    finally:
        if cam is not None:
            cam.release()
        if audio_engine is not None:
            audio_engine.stop()
        if not args.headless:
            cv2.destroyAllWindows()
        print("[*] Đã giải phóng toàn bộ tài nguyên an toàn.")


if __name__ == "__main__":
    main()
