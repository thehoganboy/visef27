"""
HorusEyes 2.0 - Main Orchestrator Pipeline (Hardened)
================================================================================
Đề tài NCKH KHKT (ViSEF):
"Khung điều phối ngân sách thính giác nhận thức độ bất định phục vụ
hỗ trợ tránh va chạm thời gian thực tại biên" (HorusEyes 2.0).

Cứng hóa toàn diện:
  1. Loại bỏ cv2.flip(frame, 1) trên đầu vào Depth: Camera hướng ra thế giới thực
     (bên trái ảnh = bên trái thực tế), hỗ trợ --mirror-display riêng cho laptop testing.
  2. Zero-latency Threaded Camera Grabber tích hợp AutoTorch, Frame ID, Watchdog is_healthy().
  3. Báo lỗi hệ thống SYSTEM_FAULT_TONE (440Hz -> 330Hz) khi camera mất kết nối hoặc 0-Lux blind.
  4. Auditory Earcons xác nhận thao tác (Pause/Resume, Mute/Unmute, Flash On/Off).
  5. Định kỳ kiểm tra stream.active để tự động khôi phục driver âm thanh.
  6. Passthrough frame_id & ae_settle_counter vào Kinematics Engine.
================================================================================
"""

import sys
import time
import argparse
import cv2
import numpy as np

# Hỗ trợ in tiếng Việt trên console Windows
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

import config
from video_capture import ThreadedCamera
from depth_engine import DepthEstimator
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager, BudgetDecision
from audio_synth import SpatialAudioEngine
from telemetry_gui import TelemetryHUD


def parse_args():
    parser = argparse.ArgumentParser(
        description="HorusEyes 2.0 — Auditory Budget Collision Avoidance (ViSEF)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ví dụ sử dụng:
  python main.py                                       # Webcam mặc định (tự dò index 0, 1, 2)
  python main.py --source 0                            # Webcam index 0
  python main.py --source 1                            # Camera USB index 1 (DroidCam USB)
  python main.py --source http://192.168.1.5:8080/video  # IP Camera (điện thoại Wi-Fi)
  python main.py --mirror-display                      # Lật gương GUI (khi test bằng webcam trước laptop)
  python main.py --no-audio                            # Chế độ kiểm thử hình ảnh không âm thanh
        """,
    )
    parser.add_argument(
        "--source", "-s",
        type=str,
        default=None,
        help="Nguồn video: camera index (0, 1, 2) hoặc URL (http/rtsp). Mặc định: tự động dò tìm.",
    )
    parser.add_argument(
        "--device", "-d",
        type=str,
        default=None,
        help="Thiết bị tính toán: 'cuda' hoặc 'cpu' (mặc định: tự động phát hiện).",
    )
    parser.add_argument(
        "--mirror-display",
        action="store_true",
        help="Lật gương màn hình hiển thị GUI (phù hợp khi người nghiên cứu tự kiểm thử bằng webcam mặt trước laptop).",
    )
    parser.add_argument(
        "--no-audio",
        action="store_true",
        help="Vô hiệu hóa âm thanh (chỉ kiểm thử thuật toán thị giác và HUD).",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    print("=" * 80)
    print("  HORUSEYES 2.0 — PROOF-OF-CONCEPT SYSTEM (ViSEF 2027) [HARDENED]")
    print("  Khung điều phối ngân sách thính giác nhận thức độ bất định")
    print("=" * 80)
    print(f"[*] Nguồn camera:     {args.source if args.source is not None else 'Auto-detect'}")
    print(f"[*] Mirror display:   {'BẬT (--mirror-display)' if args.mirror_display else 'TẮT (Camera hướng ngoại thế giới thực)'}")
    print(f"[*] Chế độ âm thanh:  {'TẮT (--no-audio)' if args.no_audio else 'BẬT (3D Binaural PortAudio Callback)'}")
    print("=" * 80)

    # 1. Khởi tạo Camera
    print("\n[1/5] Khởi động Threaded Camera Grabber...")
    try:
        cam = ThreadedCamera(source=args.source)
        cam.start()
    except RuntimeError as e:
        print(f"\n[LỖI KHỞI TẠO CAMERA] {e}")
        sys.exit(1)

    # 2. Khởi tạo Depth Estimator
    print("\n[2/5] Đang tải mô hình Depth AI (MiDaS_small)...")
    depth_estimator = DepthEstimator(device=args.device)

    # 3. Khởi tạo Kinematics Engine
    print("\n[3/5] Khởi tạo Kinematics & TTC Prediction Engine...")
    kinematics_engine = KinematicsEngine()

    # 4. Khởi tạo Auditory Budget Manager
    print("\n[4/5] Khởi tạo Bộ điều phối ngân sách thính giác (Budget <= 1 stream)...")
    budget_manager = AuditoryBudgetManager()

    # 5. Khởi tạo Audio Engine
    audio_engine = None
    if not args.no_audio:
        print("\n[5/5] Khởi động 3D Binaural Spatial Audio Synthesizer...")
        audio_engine = SpatialAudioEngine()
        audio_engine.start()
    else:
        print("\n[5/5] Bỏ qua âm thanh theo cờ --no-audio.")

    hud = TelemetryHUD()

    print("\n" + "=" * 80)
    print("  HỆ THỐNG ĐÃ SẴN SÀNG HOẠT ĐỘNG THỜI GIAN THỰC (>= 30 FPS CPU)!")
    print("  Phím điều khiển:")
    print("    - [SPACE] hoặc 's':  BẮT ĐẦU / TẠM DỪNG (START / STOP) [Có âm Earcon]")
    print("    - 'm':               BẬT / TẮT ÂM THANH (MUTE TOGGLE)   [Có âm Earcon]")
    print("    - '[' hoặc ']':      CĂN CHỈNH TIÊU CỰ (- / + 0.05x)")
    print("    - 'r':               ĐẶT LẠI HỆ SỐ CĂN CHỈNH VỀ 1.00x")
    print("    - 'q' hoặc ESC:      Thoát chương trình an toàn")
    print("=" * 80 + "\n")

    window_name = "HorusEyes 2.0 — Auditory Budget Collision Avoidance (ViSEF)"
    cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)

    fps = 0.0
    prev_time = time.perf_counter()
    scale_factor = config.DEFAULT_DIST_SCALE
    is_paused = False
    is_muted = False

    smoothed_pan  = 0.0
    smoothed_prox = 0.0

    last_depth_norm = None
    last_obs_res = None
    last_kinematics_res = None
    last_decision = None

    prev_torch_active = False
    watchdog_warn_counter = 0

    cam.reset_watchdog()
    try:
        while True:
            loop_start = time.perf_counter()

            # B1. Thu nhận khung hình mới nhất từ threaded grabber
            frame, frame_id, frame_ts, lighting_status = cam.read()
            if frame is None:
                time.sleep(0.005)
                continue

            # B2. Kiểm tra Watchdog camera & 0-Lux Blind
            cam_healthy = cam.is_healthy()
            is_zero_lux_blind = lighting_status.get("is_zero_lux_blind", False)

            if not cam_healthy or is_zero_lux_blind:
                if audio_engine is not None:
                    audio_engine.set_fault_mode("SYSTEM_FAULT")
                watchdog_warn_counter += 1
                if watchdog_warn_counter % 30 == 1:
                    if not cam_healthy:
                        print("\n[WATCHDOG CẢNH BÁO] Camera không phản hồi quá 500ms! Đang phát âm báo lỗi.")
                    else:
                        print("\n[0-LUX CẢNH BÁO] Môi trường 0-Lux mù hoàn toàn! Đang phát âm báo lỗi.")
            else:
                watchdog_warn_counter = 0
                if audio_engine is not None and getattr(audio_engine._state, "fault_mode", "NONE") == "SYSTEM_FAULT":
                    audio_engine.set_fault_mode("NONE")

            # B3. Kiểm tra thay đổi trạng thái Flash để phát Earcon
            torch_active = lighting_status.get("torch_active", False)
            if torch_active != prev_torch_active:
                if audio_engine is not None:
                    audio_engine.play_earcon("FLASH_ON" if torch_active else "FLASH_OFF")
                prev_torch_active = torch_active

            # B4. Định kỳ kiểm tra sức khỏe audio stream
            if audio_engine is not None:
                audio_engine.check_stream_health()

            # B5. Xử lý thuật toán thị giác & động học (KHÔNG lật gương ảnh gốc)
            if not is_paused:
                # Suy luận bản đồ độ sâu trên khung hình thực tế
                depth_norm, depth_raw = depth_estimator.infer_depth(frame)
                last_depth_norm = depth_norm

                # Nhận diện vật cản không gian 3D
                obs_res = depth_estimator.detect_obstacle(
                    depth_norm, depth_raw, scale_factor=scale_factor, lighting_status=lighting_status, is_zero_lux=is_zero_lux_blind
                )
                last_obs_res = obs_res

                # Làm mịn temporal cho âm thanh (Fast Attack, Smooth Release)
                if obs_res.proximity > smoothed_prox:
                    smoothed_prox = obs_res.proximity
                else:
                    smoothed_prox = smoothed_prox * 0.70 + obs_res.proximity * 0.30

                smoothed_pan = smoothed_pan * 0.65 + obs_res.pan * 0.35

                # Động học chuyển động & TTC (truyền frame_id và ae_settle_counter)
                ae_settle = lighting_status.get("ae_settle_counter", 0)
                kinematics_res = kinematics_engine.compute(
                    obs_res, frame_ts, frame_id=frame_id, ae_settle_counter=ae_settle
                )
                last_kinematics_res = kinematics_res

                # Điều phối ngân sách thính giác cực hạn (Auditory Budget <= 1 stream)
                decision = budget_manager.coordinate(obs_res, kinematics_res)
                last_decision = decision

                # Cập nhật Audio Synthesizer (non-blocking)
                if audio_engine is not None:
                    if is_muted or not decision.is_active:
                        muted_dec = BudgetDecision(
                            threat_level="SAFE",
                            cue_mode="MUTED",
                            dist_cm=float("inf"),
                            is_active=False
                        )
                        audio_engine.update_decision(muted_dec)
                    else:
                        decision.pan = smoothed_pan
                        decision.proximity = smoothed_prox
                        audio_engine.update_decision(decision)
            else:
                # Khi đang PAUSED: Mute âm thanh hoàn toàn
                if audio_engine is not None:
                    muted_dec = BudgetDecision(
                        threat_level="SAFE",
                        cue_mode="MUTED",
                        dist_cm=float("inf"),
                        is_active=False
                    )
                    audio_engine.update_decision(muted_dec)

                depth_norm = last_depth_norm if last_depth_norm is not None else np.zeros((frame.shape[0], frame.shape[1]), dtype=np.uint8)
                obs_res = last_obs_res if last_obs_res is not None else depth_estimator.detect_obstacle(depth_norm, depth_norm.astype(np.float32))
                kinematics_res = last_kinematics_res if last_kinematics_res is not None else kinematics_engine.compute(obs_res, frame_ts)
                decision = last_decision if last_decision is not None else budget_manager.coordinate(obs_res, kinematics_res)

            # B6. Tính toán FPS và độ trễ chu trình
            loop_end = time.perf_counter()
            dt = max(1e-6, loop_end - prev_time)
            prev_time = loop_end
            instant_fps = 1.0 / dt
            fps = fps * config.FPS_SMOOTHING + instant_fps * (1.0 - config.FPS_SMOOTHING)
            latency_ms = (loop_end - loop_start) * 1000.0

            # B7. Render giao diện Telemetry Side-by-Side
            canvas = hud.render(
                frame_rgb=frame,
                depth_norm=depth_norm,
                obs_res=obs_res,
                kinematics_res=kinematics_res,
                decision=decision,
                fps=fps,
                latency_ms=latency_ms,
                scale_factor=scale_factor,
                is_paused=is_paused,
                is_muted=is_muted,
                lighting_status=lighting_status,
                mirror_display=args.mirror_display,
            )

            cv2.imshow(window_name, canvas)

            # B8. Bắt phím điều khiển
            key = cv2.waitKey(1) & 0xFF
            if key in (ord('q'), ord('Q'), 27):  # 'q' hoặc ESC
                print("\n[Hệ thống] Nhận lệnh thoát từ người dùng.")
                break
            elif key in (32, ord('s'), ord('S')):  # SPACE hoặc 's'
                is_paused = not is_paused
                status_str = "TẠM DỪNG (PAUSED)" if is_paused else "ĐANG CHẠY (RUNNING)"
                print(f"[Điều khiển] Trạng thái: {status_str}")
                if audio_engine is not None:
                    audio_engine.play_earcon("PAUSE")
            elif key in (ord('m'), ord('M')):  # 'm'
                is_muted = not is_muted
                audio_str = "TẮT (MUTED)" if is_muted else "BẬT (ACTIVE)"
                print(f"[Điều khiển] Âm thanh: {audio_str}")
                if audio_engine is not None:
                    audio_engine.play_earcon("MUTE")
            elif key == ord('['):
                scale_factor = max(0.50, scale_factor - 0.05)
                print(f"[Calib] Hệ số tiêu cự: {scale_factor:.2f}x")
            elif key == ord(']'):
                scale_factor = min(2.00, scale_factor + 0.05)
                print(f"[Calib] Hệ số tiêu cự: {scale_factor:.2f}x")
            elif key in (ord('r'), ord('R')):
                scale_factor = config.DEFAULT_DIST_SCALE
                print(f"[Calib] Đã đặt lại hệ số tiêu cự: {scale_factor:.2f}x")

    except KeyboardInterrupt:
        print("\n[Hệ thống] Bị gián đoạn bởi KeyboardInterrupt.")
    finally:
        print("[Hệ thống] Đang giải phóng tài nguyên...")
        if audio_engine is not None:
            audio_engine.stop()
        cam.release()
        cv2.destroyAllWindows()
        print("[Hệ thống] Hoàn tất tắt chương trình an toàn.")


if __name__ == "__main__":
    main()
