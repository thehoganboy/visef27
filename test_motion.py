"""
HorusEyes 2.0 - Real-time Motion & Multi-Obstacle Dynamics Simulator
================================================================================
Kịch bản mô phỏng kiểm thử động học di chuyển & theo dõi đa vật cản:
  1. Mô phỏng vật cản lao tới (Looming Approach): Khoảng cách giảm từ 150cm -> 20cm,
     vận tốc v_z dương, TTC giảm dần từ 2.5s -> 0.3s, nhịp bíp tăng tốc dồn dập.
  2. Mô phỏng 2 VẬT CẢN ĐỒNG THỜI (Multi-Obstacle Auditory Budgeting):
     - Vật 1 (bên trái cự ly 70cm) và Vật 2 (bên phải cự ly 25cm).
     - Hệ thống phát hiện và bám vết CẢ 2 VẬT trên màn hình.
     - Điều phối ngân sách: Vật 2 (nguy cấp hơn) được cấp kênh âm thanh duy nhất [ACTIVE TARGET],
       Vật 1 tự động bị triệt tiêu âm thanh [SUPPRESSED: Budget Exceeded].
     - Mũi tên dẫn hướng né thoát an toàn: SAFE ESCAPE: <- LEFT.
  3. Mô phỏng vật lùi xa (Retreating Threat): v_z âm, TTC = inf, hệ thống tự động ngắt âm thanh (MUTED).
================================================================================
"""

import sys
import time
import cv2
import numpy as np

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

import config
from depth_engine import DepthEstimator, SingleObstacle, ObstacleDetectionResult, dist_to_proximity
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager
from audio_synth import SpatialAudioEngine
from telemetry_gui import TelemetryHUD


def run_motion_simulation():
    print("=" * 80)
    print("  HORUSEYES 2.0 — DYNAMIC MOTION & MULTI-OBSTACLE SIMULATION")
    print("=" * 80)
    print("  Mô phỏng trực quan 2 vật cản và động học tiếp cận TTC theo thời gian thực.")
    print("  Nhấn 'q' hoặc ESC trong cửa sổ video để dừng sớm.")
    print("=" * 80 + "\n")

    kinematics_engine = KinematicsEngine()
    budget_manager = AuditoryBudgetManager()
    audio_engine = SpatialAudioEngine()
    audio_engine.start()
    hud = TelemetryHUD(window_name="HorusEyes 2.0 - Motion & Multi-Obstacle Simulator")

    window_name = "HorusEyes 2.0 - Motion & Multi-Obstacle Simulator"
    cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)

    h, w = config.CAM_HEIGHT, config.CAM_WIDTH
    fps_sim = 30.0
    dt = 1.0 / fps_sim

    # ── GIAI ĐOẠN 1: Một vật cản lao tới từ xa (150cm -> 22cm) ──
    print("[Phase 1/3] Mô phỏng 1 vật cản lao tới (Looming Approach: 150cm -> 22cm)...")
    steps = 90  # 3 giây
    for i in range(steps):
        t_now = time.perf_counter()
        progress = i / float(steps)

        # Khoảng cách giảm dần từ 150cm xuống 22cm
        curr_dist = 150.0 - (150.0 - 22.0) * (progress ** 1.3)
        prox = dist_to_proximity(curr_dist)

        # Bán kính vật thể phình to trên camera
        obj_r = int(25 + 60 * progress)
        cx, cy = int(w * 0.55), int(h * 0.50)

        # Tạo frame RGB giả lập
        frame = np.full((h, w, 3), 40, dtype=np.uint8)
        # Nền hành lang
        cv2.line(frame, (0, 0), (int(w * 0.3), int(h * 0.4)), (80, 80, 80), 2)
        cv2.line(frame, (w, 0), (int(w * 0.7), int(h * 0.4)), (80, 80, 80), 2)
        # Vật cản
        cv2.circle(frame, (cx, cy), obj_r, (230, 230, 230), -1)

        # Tạo depth heatmap giả lập
        depth_norm = np.full((h, w), 30, dtype=np.uint8)
        cv2.circle(depth_norm, (cx, cy), obj_r, int(prox * 255), -1)

        # Tạo cấu trúc Obstacle
        pan = (float(cx) / float(w - 1)) * 2.0 - 1.0
        bx, by, bw, bh = cx - obj_r, cy - obj_r, obj_r * 2, obj_r * 2

        single_obs = SingleObstacle(
            id=1, x=cx, y=cy, bbox=(bx, by, bw, bh), pan=pan,
            proximity=prox, dist_cm=curr_dist,
            mode_text=f"DANGER ({curr_dist:.1f}cm)" if curr_dist < 30 else f"APPROACH ({curr_dist:.1f}cm)",
            uncertainty_score=0.15, is_wall=False
        )

        obs_res = ObstacleDetectionResult(
            x=cx, y=cy, bbox=(bx, by, bw, bh), pan=pan,
            proximity=prox, dist_cm=curr_dist, mode_text=single_obs.mode_text,
            uncertainty_score=0.15, is_wall=False,
            sector_dists={"LEFT": 180.0, "CENTER": curr_dist, "RIGHT": 200.0},
            all_obstacles=[single_obs]
        )

        kin_res = kinematics_engine.compute(obs_res, t_now)
        dec = budget_manager.coordinate(obs_res, kin_res)
        audio_engine.update_decision(dec)

        canvas = hud.render(frame, depth_norm, obs_res, kin_res, dec, fps=fps_sim, latency_ms=12.0)
        cv2.imshow(window_name, canvas)
        if cv2.waitKey(int(dt * 1000)) & 0xFF in (ord('q'), 27):
            break

    # ── GIAI ĐOẠN 2: Hai vật cản cạnh tranh ngân sách (Multi-Obstacle Tracking) ──
    print("\n[Phase 2/3] Mô phỏng 2 VẬT CẢN ĐỒNG THỜI (Multi-Obstacle Auditory Budgeting)...")
    steps = 120  # 4 giây
    for i in range(steps):
        t_now = time.perf_counter()
        progress = i / float(steps)

        # Vật 1: Bên trái ở khoảng 65cm (ít nguy hiểm hơn)
        dist1 = 65.0
        prox1 = dist_to_proximity(dist1)
        cx1, cy1 = int(w * 0.25), int(h * 0.50)
        r1 = 40
        pan1 = (float(cx1) / float(w - 1)) * 2.0 - 1.0

        obs1 = SingleObstacle(
            id=2, x=cx1, y=cy1, bbox=(cx1 - r1, cy1 - r1, r1 * 2, r1 * 2),
            pan=pan1, proximity=prox1, dist_cm=dist1,
            mode_text="WARNING (~65cm)", uncertainty_score=0.20, is_wall=False
        )

        # Vật 2: Bên phải đang lao vào nguy hiểm (40cm -> 18cm)
        dist2 = 40.0 - (40.0 - 18.0) * progress
        prox2 = dist_to_proximity(dist2)
        cx2, cy2 = int(w * 0.75), int(h * 0.50)
        r2 = int(45 + 25 * progress)
        pan2 = (float(cx2) / float(w - 1)) * 2.0 - 1.0

        obs2 = SingleObstacle(
            id=1, x=cx2, y=cy2, bbox=(cx2 - r2, cy2 - r2, r2 * 2, r2 * 2),
            pan=pan2, proximity=prox2, dist_cm=dist2,
            mode_text="CRITICAL (<30cm)", uncertainty_score=0.10, is_wall=False
        )

        # Vẽ frame RGB với cả 2 vật
        frame = np.full((h, w, 3), 40, dtype=np.uint8)
        cv2.circle(frame, (cx1, cy1), r1, (180, 180, 180), -1)
        cv2.circle(frame, (cx2, cy2), r2, (255, 255, 255), -1)

        # Heatmap
        depth_norm = np.full((h, w), 25, dtype=np.uint8)
        cv2.circle(depth_norm, (cx1, cy1), r1, int(prox1 * 255), -1)
        cv2.circle(depth_norm, (cx2, cy2), r2, int(prox2 * 255), -1)

        # Sắp xếp theo độ gần: Vật 2 gần hơn nên đứng đầu danh sách
        all_obs = [obs2, obs1]

        obs_res = ObstacleDetectionResult(
            x=obs2.x, y=obs2.y, bbox=obs2.bbox, pan=obs2.pan,
            proximity=obs2.proximity, dist_cm=obs2.dist_cm,
            mode_text=obs2.mode_text, uncertainty_score=obs2.uncertainty_score,
            is_wall=False,
            sector_dists={"LEFT": dist1, "CENTER": 150.0, "RIGHT": dist2},
            all_obstacles=all_obs
        )

        kin_res = kinematics_engine.compute(obs_res, t_now)
        dec = budget_manager.coordinate(obs_res, kin_res)
        audio_engine.update_decision(dec)

        canvas = hud.render(frame, depth_norm, obs_res, kin_res, dec, fps=fps_sim, latency_ms=12.0)
        cv2.imshow(window_name, canvas)
        if cv2.waitKey(int(dt * 1000)) & 0xFF in (ord('q'), 27):
            break

    # ── GIAI ĐOẠN 3: Vật lùi xa an toàn (Retreating -> Silent) ──
    print("\n[Phase 3/3] Mô phỏng vật lùi xa (Retreating -> Muted Silence)...")
    steps = 90
    for i in range(steps):
        t_now = time.perf_counter()
        progress = i / float(steps)

        # Lùi từ 30cm ra 200cm
        curr_dist = 30.0 + (200.0 - 30.0) * progress
        prox = dist_to_proximity(curr_dist)
        obj_r = max(15, int(70 - 50 * progress))
        cx, cy = int(w * 0.50), int(h * 0.50)

        frame = np.full((h, w, 3), 40, dtype=np.uint8)
        cv2.circle(frame, (cx, cy), obj_r, (160, 160, 160), -1)

        depth_norm = np.full((h, w), 20, dtype=np.uint8)
        cv2.circle(depth_norm, (cx, cy), obj_r, int(prox * 255), -1)

        single_obs = SingleObstacle(
            id=1, x=cx, y=cy, bbox=(cx - obj_r, cy - obj_r, obj_r * 2, obj_r * 2),
            pan=0.0, proximity=prox, dist_cm=curr_dist,
            mode_text="RETREATING" if curr_dist < 150 else "SAFE",
            uncertainty_score=0.10, is_wall=False
        )

        obs_res = ObstacleDetectionResult(
            x=cx, y=cy, bbox=single_obs.bbox, pan=0.0,
            proximity=prox, dist_cm=curr_dist, mode_text=single_obs.mode_text,
            uncertainty_score=0.10, is_wall=False,
            sector_dists={"LEFT": 220.0, "CENTER": curr_dist, "RIGHT": 220.0},
            all_obstacles=[single_obs]
        )

        kin_res = kinematics_engine.compute(obs_res, t_now)
        dec = budget_manager.coordinate(obs_res, kin_res)
        audio_engine.update_decision(dec)

        canvas = hud.render(frame, depth_norm, obs_res, kin_res, dec, fps=fps_sim, latency_ms=12.0)
        cv2.imshow(window_name, canvas)
        if cv2.waitKey(int(dt * 1000)) & 0xFF in (ord('q'), 27):
            break

    audio_engine.stop()
    cv2.destroyAllWindows()
    print("\n" + "=" * 80)
    print("  HOÀN TẤT MÔ PHỎNG ĐỘNG HỌC & MULTI-OBSTACLE TRACKING THÀNH CÔNG!")
    print("=" * 80)


if __name__ == "__main__":
    run_motion_simulation()
