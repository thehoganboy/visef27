"""
HorusEyes 2.0 - Telemetry HUD Visualization Module (Hardened)
================================================================================
Render giao diện telemetry HUD side-by-side thời gian thực (RGB + Depth Heatmap):
  1. Bố cục trực quan hai nửa màn hình:
     - Nửa trái: RGB panel (không tự động lật gương; hỗ trợ --mirror-display riêng)
       + Corner brackets khóa mục tiêu + HUD thông số + Lighting status.
     - Nửa phải: Depth Heatmap (MAGMA colormap) + Vòng tròn đánh dấu cự ly.
  2. Bổ sung các tính năng điều khiển trực quan:
     - Trạng thái START / STOP (Running / Paused watermark).
     - Trạng thái Âm thanh (Audio ON / MUTED).
     - Trạng thái Đèn Flash & Độ sáng Luma Y (Low-Light & Auto-Torch monitor).
     - Cảnh báo 0-Lux Blind (Sensor Blocked / Pitch Black) khi môi trường tối hoàn toàn.
     - Phân vùng 3 Sector (LEFT - CENTER - RIGHT) dạng thẻ tinh gọn.
     - Mũi tên dẫn hướng né thoát an toàn (Safe Escape Direction).
================================================================================
"""

import time
from typing import Optional, Dict
import cv2
import numpy as np

import config
from depth_engine import ObstacleDetectionResult
from motion_ttc import KinematicsResult
from auditory_budget import BudgetDecision


def draw_corner_rect(img, pt1, pt2, color, thickness=2, corner_len=15):
    """Vẽ bounding box phong cách corner-bracket tinh tế, hiện đại, không choáng khung hình."""
    x1, y1 = pt1
    x2, y2 = pt2
    w = x2 - x1
    h = y2 - y1
    cl_w = min(corner_len, max(1, w // 2))
    cl_h = min(corner_len, max(1, h // 2))

    # Top-left
    cv2.line(img, (x1, y1), (x1 + cl_w, y1), color, thickness, cv2.LINE_AA)
    cv2.line(img, (x1, y1), (x1, y1 + cl_h), color, thickness, cv2.LINE_AA)
    # Top-right
    cv2.line(img, (x2, y1), (x2 - cl_w, y1), color, thickness, cv2.LINE_AA)
    cv2.line(img, (x2, y1), (x2, y1 + cl_h), color, thickness, cv2.LINE_AA)
    # Bottom-left
    cv2.line(img, (x1, y2), (x1 + cl_w, y2), color, thickness, cv2.LINE_AA)
    cv2.line(img, (x1, y2), (x1, y2 - cl_h), color, thickness, cv2.LINE_AA)
    # Bottom-right
    cv2.line(img, (x2, y2), (x2 - cl_w, y2), color, thickness, cv2.LINE_AA)
    cv2.line(img, (x2, y2), (x2, y2 - cl_h), color, thickness, cv2.LINE_AA)


class TelemetryHUD:
    """
    Module render giao diện hiển thị thông tin trực quan Side-by-Side cho HorusEyes 2.0.
    Hỗ trợ chế độ thực (default không mirror) và mirror display riêng cho laptop testing.
    """

    def __init__(self, window_name: str = "HorusEyes 2.0 - Auditory Budget Collision Avoidance"):
        self.window_name = window_name

    def render(
        self,
        frame_rgb: np.ndarray = None,
        depth_norm: np.ndarray = None,
        obs_res: ObstacleDetectionResult = None,
        kinematics_res: KinematicsResult = None,
        decision: BudgetDecision = None,
        fps: float = 0.0,
        latency_ms: float = 0.0,
        scale_factor: float = 1.0,
        is_paused: bool = False,
        is_muted: bool = False,
        lighting_status: Optional[dict] = None,
        mirror_display: bool = False,
        frame_rgb_flipped: np.ndarray = None,
    ) -> np.ndarray:
        """
        Tạo khung hình ghép ngang (Side-by-side: RGB HUD + Depth Heatmap).
        """
        # Tương thích ngược với frame_rgb_flipped
        input_frame = frame_rgb if frame_rgb is not None else frame_rgb_flipped
        if input_frame is None:
            raise ValueError("[TelemetryHUD] frame_rgb không được để trống!")

        h, w = input_frame.shape[:2]

        # Xử lý mirror display riêng cho hiển thị
        if mirror_display:
            rgb_panel = cv2.flip(input_frame, 1)
            map_x = lambda x_val: (w - 1 - x_val)
            map_bbox = lambda b: (w - 1 - (b[0] + b[2]), b[1], b[2], b[3])
        else:
            rgb_panel = input_frame.copy()
            map_x = lambda x_val: x_val
            map_bbox = lambda b: b

        # ── 1. NỬA TRÁI: RGB PANEL ──
        # Phân vùng 3 Sector
        x1 = int(w * config.SECTOR_LEFT_SPLIT)
        x2 = int(w * config.SECTOR_RIGHT_SPLIT)
        cv2.line(rgb_panel, (x1, 0), (x1, h), (40, 45, 55), 1, cv2.LINE_AA)
        cv2.line(rgb_panel, (x2, 0), (x2, h), (40, 45, 55), 1, cv2.LINE_AA)

        # Thanh Sector Badge ở đỉnh
        sector_y = 22
        # LEFT badge (hiển thị sector Trái thực tế)
        cv2.rectangle(rgb_panel, (10, 6), (115, 28), (20, 24, 34), -1)
        cv2.rectangle(rgb_panel, (10, 6), (115, 28), (60, 70, 90), 1)
        cv2.putText(rgb_panel, f"L: {int(obs_res.sector_dists['LEFT'])}cm",
                    (16, sector_y), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (200, 210, 225), 1, cv2.LINE_AA)

        # CENTER badge
        cx_mid = x1 + (x2 - x1) // 2
        cv2.rectangle(rgb_panel, (cx_mid - 55, 6), (cx_mid + 55, 28), (20, 24, 34), -1)
        cv2.rectangle(rgb_panel, (cx_mid - 55, 6), (cx_mid + 55, 28), (60, 70, 90), 1)
        cv2.putText(rgb_panel, f"C: {int(obs_res.sector_dists['CENTER'])}cm",
                    (cx_mid - 48, sector_y), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (200, 210, 225), 1, cv2.LINE_AA)

        # RIGHT badge
        cv2.rectangle(rgb_panel, (w - 125, 6), (w - 20, 28), (20, 24, 34), -1)
        cv2.rectangle(rgb_panel, (w - 125, 6), (w - 20, 28), (60, 70, 90), 1)
        cv2.putText(rgb_panel, f"R: {int(obs_res.sector_dists['RIGHT'])}cm",
                    (w - 118, sector_y), cv2.FONT_HERSHEY_SIMPLEX, 0.40, (200, 210, 225), 1, cv2.LINE_AA)

        # Sector safety scores
        sec_scores = getattr(kinematics_res, "sector_scores", None) or {"LEFT": 0.50, "RIGHT": 0.50}
        l_score = float(sec_scores.get("LEFT", 0.50))
        r_score = float(sec_scores.get("RIGHT", 0.50))
        guidance_state = getattr(kinematics_res, "guidance_state", "")
        is_hazard_blocked = (guidance_state == "HAZARD_BLOCKED" or kinematics_res.safe_direction == "STOP")

        # Màu sắc trạng thái theo mức độ nguy cơ
        dist_cm = obs_res.dist_cm
        proximity = obs_res.proximity
        ttc = kinematics_res.primary_ttc

        if is_hazard_blocked:
            status_text  = "BLOCKED: [STOP - PATH BLOCKED]"
            status_color = (0, 0, 255)
        elif kinematics_res.threat_level == "CRITICAL":
            status_text  = f"CRITICAL: {dist_cm:.0f}cm | TTC: {ttc:.1f}s"
            status_color = (0, 0, 255)
        elif kinematics_res.threat_level == "WARNING":
            status_text  = f"WARNING: {dist_cm:.0f}cm | TTC: {ttc:.1f}s"
            status_color = (0, 150, 255)
        else:
            status_text  = "SAFE: Clear Path (>250cm)"
            status_color = (0, 230, 118)

        # ── Vẽ các vật cản phụ bị triệt tiêu (SUPPRESSED TARGETS) ──
        if decision.suppressed_obstacles:
            for s_obs in decision.suppressed_obstacles:
                sb = map_bbox(s_obs.bbox)
                sbx, sby, sbw, sbh = sb
                sox = map_x(s_obs.x)
                supp_col = (110, 115, 125)
                draw_corner_rect(rgb_panel, (sbx, sby), (sbx + sbw, sby + sbh), supp_col, 1, 10)
                cv2.circle(rgb_panel, (sox, s_obs.y), 10, supp_col, 1, cv2.LINE_AA)
                cv2.putText(rgb_panel, f"#{s_obs.id} [SUPP]: {s_obs.dist_cm:.0f}cm",
                            (sbx, max(15, sby - 5)), cv2.FONT_HERSHEY_SIMPLEX, 0.38, supp_col, 1, cv2.LINE_AA)

        # ── Corner brackets khóa mục tiêu chính (ACTIVE TARGET) ──
        ox, oy = map_x(obs_res.x), obs_res.y
        lerp = max(0.0, min(1.0, proximity))
        cross_color = (
            int(50  + (0   - 50)  * lerp),
            int(230 + (30  - 230) * lerp),
            int(50  + (255 - 50)  * lerp),
        )

        radius = int(18 + 18 * lerp)
        if proximity > 0.0:
            bx, by, bw, bh = map_bbox(obs_res.bbox)
            draw_corner_rect(rgb_panel, (bx, by), (bx + bw, by + bh), cross_color, 2, 18)

            cv2.circle(rgb_panel, (ox, oy), radius, cross_color, 1, cv2.LINE_AA)
            cv2.circle(rgb_panel, (ox, oy), 3, cross_color, -1, cv2.LINE_AA)
            cv2.line(rgb_panel, (ox - 8, oy), (ox + 8, oy), cross_color, 1, cv2.LINE_AA)
            cv2.line(rgb_panel, (ox, oy - 8), (ox, oy + 8), cross_color, 1, cv2.LINE_AA)

            act_id = getattr(decision, "active_obstacle_id", 1)
            pvz = kinematics_res.primary_velocity_z
            min_app = getattr(config, "VZ_MIN_APPROACH_CM_S", 20.0)

            if pvz >= min_app:
                status_tag = "APPROACHING"
                tag_col = (0, 0, 255)
            elif pvz <= -min_app:
                status_tag = "RECEDING"
                tag_col = (255, 180, 0)
            else:
                status_tag = "STATIC"
                tag_col = (0, 230, 118)

            ttc_str = f" | TTC {ttc:.1f}s" if ttc < float("inf") else ""
            badge_title = f"#{act_id} [{status_tag}]: {dist_cm:.0f}cm{ttc_str}"

            (bw_t, bh_t), _ = cv2.getTextSize(badge_title, cv2.FONT_HERSHEY_SIMPLEX, 0.42, 1)
            badge_x = max(10, min(w - bw_t - 20, ox - bw_t // 2))
            badge_y = max(42, by - 12)
            cv2.rectangle(rgb_panel, (badge_x - 6, badge_y - 14), (badge_x + bw_t + 6, badge_y + 4), (15, 20, 30), -1)
            cv2.rectangle(rgb_panel, (badge_x - 6, badge_y - 14), (badge_x + bw_t + 6, badge_y + 4), tag_col, 1)
            cv2.putText(rgb_panel, badge_title, (badge_x, badge_y),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.42, (240, 245, 255), 1, cv2.LINE_AA)

            # Vector arrow vận tốc tiếp cận
            if pvz >= min_app:
                arrow_len = int(np.clip(pvz * 0.7, 20, 70))
                cv2.arrowedLine(rgb_panel, (ox, oy), (ox, oy + arrow_len), (0, 0, 255), 2, tipLength=0.35)
            elif pvz <= -min_app:
                arrow_len = int(np.clip(abs(pvz) * 0.7, 20, 70))
                cv2.arrowedLine(rgb_panel, (ox, oy), (ox, oy - arrow_len), (255, 180, 0), 2, tipLength=0.35)

        # ── Mũi tên dẫn hướng né thoát an toàn / Cảnh báo Deadlock ──
        if is_hazard_blocked:
            flash_on = (int(time.time() * 4) % 2) == 0
            banner_y = int(h * 0.52)
            banner_text = "[STOP - PATH BLOCKED]"
            (bw_txt, bh_txt), _ = cv2.getTextSize(banner_text, cv2.FONT_HERSHEY_SIMPLEX, 0.72, 2)
            bx_txt = w // 2 - bw_txt // 2

            if flash_on:
                cv2.rectangle(rgb_panel, (bx_txt - 14, banner_y - bh_txt - 10), (bx_txt + bw_txt + 14, banner_y + 12), (10, 10, 32), -1)
                cv2.rectangle(rgb_panel, (bx_txt - 14, banner_y - bh_txt - 10), (bx_txt + bw_txt + 14, banner_y + 12), (0, 0, 255), 2)
                cv2.putText(rgb_panel, banner_text, (bx_txt, banner_y),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.72, (0, 0, 255), 2, cv2.LINE_AA)
            else:
                cv2.rectangle(rgb_panel, (bx_txt - 14, banner_y - bh_txt - 10), (bx_txt + bw_txt + 14, banner_y + 12), (10, 10, 20), -1)
                cv2.rectangle(rgb_panel, (bx_txt - 14, banner_y - bh_txt - 10), (bx_txt + bw_txt + 14, banner_y + 12), (0, 0, 150), 1)
                cv2.putText(rgb_panel, banner_text, (bx_txt, banner_y),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.72, (0, 0, 180), 2, cv2.LINE_AA)
        elif kinematics_res.threat_level != "SAFE":
            safe_dir = kinematics_res.safe_direction
            arrow_color = (0, 255, 100)
            arrow_y = int(h * 0.52)
            if safe_dir == "RIGHT":
                esc_text = "SAFE ESCAPE: -> RIGHT"
                cv2.arrowedLine(rgb_panel, (w // 2 - 35, arrow_y), (w // 2 + 55, arrow_y), arrow_color, 3, tipLength=0.3)
            else:
                esc_text = "SAFE ESCAPE: <- LEFT"
                cv2.arrowedLine(rgb_panel, (w // 2 + 35, arrow_y), (w // 2 - 55, arrow_y), arrow_color, 3, tipLength=0.3)

            (ew, eh), _ = cv2.getTextSize(esc_text, cv2.FONT_HERSHEY_SIMPLEX, 0.50, 2)
            cv2.rectangle(rgb_panel, (w // 2 - ew // 2 - 8, arrow_y + 12),
                          (w // 2 + ew // 2 + 8, arrow_y + 36), (15, 20, 30), -1)
            cv2.rectangle(rgb_panel, (w // 2 - ew // 2 - 8, arrow_y + 12),
                          (w // 2 + ew // 2 + 8, arrow_y + 36), arrow_color, 1)
            cv2.putText(rgb_panel, esc_text, (w // 2 - ew // 2, arrow_y + 29),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.50, arrow_color, 2, cv2.LINE_AA)

        # ── Thẻ Telemetry HUD góc trên trái (Glassmorphic Card) ──
        card_w, card_h = 330, 155
        card_x, card_y = 10, 38
        hud_overlay = rgb_panel.copy()
        cv2.rectangle(hud_overlay, (card_x, card_y), (card_x + card_w, card_y + card_h), (12, 17, 26), -1)
        cv2.addWeighted(hud_overlay, 0.80, rgb_panel, 0.20, 0, rgb_panel)
        cv2.rectangle(rgb_panel, (card_x, card_y), (card_x + card_w, card_y + card_h), (56, 189, 248), 1)

        # Hàng 1: Brand + Running/Paused badge + Audio badge
        cv2.putText(rgb_panel, "HORUSEYES 2.0", (card_x + 10, card_y + 18),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.46, (0, 230, 118), 2, cv2.LINE_AA)

        badge_text = "PAUSED" if is_paused else "RUNNING"
        badge_col = (0, 165, 255) if is_paused else (0, 230, 118)
        cv2.putText(rgb_panel, f"[{badge_text}]", (card_x + 155, card_y + 18),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.38, badge_col, 1, cv2.LINE_AA)

        audio_str = "MUTED" if is_muted else "AUDIO ON"
        audio_col = (0, 0, 255) if is_muted else (200, 220, 240)
        cv2.putText(rgb_panel, f"[{audio_str}]", (card_x + 242, card_y + 18),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.36, audio_col, 1, cv2.LINE_AA)

        # Hàng 2: FPS, Độ trễ, Hệ số căn chỉnh
        cv2.putText(rgb_panel, f"FPS: {fps:.0f} | Trễ: {latency_ms:.0f}ms | Calib: {scale_factor:.2f}x",
                    (card_x + 10, card_y + 38), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (226, 232, 240), 1, cv2.LINE_AA)

        # Hàng 3: Lighting status (mean_Y & Flash state)
        if lighting_status:
            mean_y = lighting_status.get("mean_y", 0.0)
            torch_active = lighting_status.get("torch_active", False)
            torch_lbl = "FLASH: ON" if torch_active else "FLASH: OFF"
            torch_col = (0, 255, 255) if torch_active else (150, 160, 175)
            blind = lighting_status.get("is_zero_lux_blind", False)
            blind_lbl = " | 0-LUX BLIND!" if blind else ""
            cv2.putText(rgb_panel, f"Light: {mean_y:.0f} Y | {torch_lbl}{blind_lbl}",
                        (card_x + 10, card_y + 57), cv2.FONT_HERSHEY_SIMPLEX, 0.38, torch_col, 1, cv2.LINE_AA)
        else:
            cv2.putText(rgb_panel, "Light: Normal (Ambient)",
                        (card_x + 10, card_y + 57), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (150, 160, 175), 1, cv2.LINE_AA)

        # Hàng 4: Cự ly, TTC, Vận tốc
        ttc_disp = f"{ttc:.1f}s" if ttc < float("inf") else "inf"
        cv2.putText(rgb_panel, f"Cự ly: {dist_cm:.0f}cm | TTC: {ttc_disp} | vz: {kinematics_res.primary_velocity_z:+.1f}cm/s",
                    (card_x + 10, card_y + 78), cv2.FONT_HERSHEY_SIMPLEX, 0.40,
                    (0, 255, 255) if proximity >= 0.70 else (200, 220, 240), 1, cv2.LINE_AA)

        # Hàng 5: Ngân sách & Cue Mode
        cue_desc = "PING" if decision.cue_mode == "SHARP_PING" else ("BLUR" if decision.cue_mode == "ACOUSTIC_BLUR" else "MUTED")
        cv2.putText(rgb_panel, f"Ngân sách: 1 Active / {decision.suppressed_count} Supp | Cue: {cue_desc}",
                    (card_x + 10, card_y + 98), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (148, 163, 184), 1, cv2.LINE_AA)

        # Hàng 6: Thanh đo Sector Safety Score (L_Score / R_Score)
        score_text = f"L_Score: {l_score:.2f} | R_Score: {r_score:.2f}"
        cv2.putText(rgb_panel, score_text, (card_x + 10, card_y + 118),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.38, (210, 225, 245), 1, cv2.LINE_AA)

        bar_w = 42
        bar_h = 5
        # L Bar
        lx_bar = card_x + 205
        ly_bar = card_y + 112
        cv2.rectangle(rgb_panel, (lx_bar, ly_bar), (lx_bar + bar_w, ly_bar + bar_h), (35, 42, 55), -1)
        l_fill = int(bar_w * np.clip(l_score / 0.50, 0.0, 1.0))
        l_col = (0, 230, 118) if l_score >= 0.35 else ((0, 165, 255) if l_score >= 0.25 else (0, 0, 255))
        if l_fill > 0:
            cv2.rectangle(rgb_panel, (lx_bar, ly_bar), (lx_bar + l_fill, ly_bar + bar_h), l_col, -1)
        cv2.rectangle(rgb_panel, (lx_bar, ly_bar), (lx_bar + bar_w, ly_bar + bar_h), (70, 80, 95), 1)

        # R Bar
        rx_bar = card_x + 265
        ry_bar = card_y + 112
        cv2.rectangle(rgb_panel, (rx_bar, ry_bar), (rx_bar + bar_w, ry_bar + bar_h), (35, 42, 55), -1)
        r_fill = int(bar_w * np.clip(r_score / 0.50, 0.0, 1.0))
        r_col = (0, 230, 118) if r_score >= 0.35 else ((0, 165, 255) if r_score >= 0.25 else (0, 0, 255))
        if r_fill > 0:
            cv2.rectangle(rgb_panel, (rx_bar, ry_bar), (rx_bar + r_fill, ry_bar + bar_h), r_col, -1)
        cv2.rectangle(rgb_panel, (rx_bar, ry_bar), (rx_bar + bar_w, ry_bar + bar_h), (70, 80, 95), 1)

        # Hàng 7: Trạng thái tổng quan
        cv2.putText(rgb_panel, status_text, (card_x + 10, card_y + 140),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, status_color, 1, cv2.LINE_AA)

        # ── 2. NỬA PHẢI: DEPTH HEATMAP ──
        depth_color = cv2.applyColorMap(depth_norm, config.COLORMAP)

        # Đánh dấu các vật cản phụ trên Heatmap
        if decision.suppressed_obstacles:
            for s_obs in decision.suppressed_obstacles:
                sox = map_x(s_obs.x)
                cv2.circle(depth_color, (sox, s_obs.y), 12, (150, 150, 150), 1, cv2.LINE_AA)
                cv2.putText(depth_color, f"#{s_obs.id}", (sox - 6, s_obs.y + 4),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.35, (200, 200, 200), 1, cv2.LINE_AA)

        # Vòng tròn đánh dấu vật cản chính trên Heatmap
        if proximity > 0.0:
            cv2.circle(depth_color, (ox, oy), radius, (255, 255, 255), 2, cv2.LINE_AA)
            cv2.circle(depth_color, (ox, oy), 3, (255, 255, 255), -1, cv2.LINE_AA)
            cv2.putText(depth_color, f"#{getattr(decision, 'active_obstacle_id', 1)}",
                        (ox - 6, oy + 4), cv2.FONT_HERSHEY_SIMPLEX, 0.38, (0, 255, 255), 1, cv2.LINE_AA)

        # ── 3. GHÉP KHUNG HÌNH SIDE-BY-SIDE ──
        separator = np.full((h, 2, 3), (35, 40, 50), dtype=np.uint8)
        canvas = np.hstack([rgb_panel, separator, depth_color])

        # ── 4. CẢNH BÁO 0-LUX BLIND BANNER ──
        if lighting_status and lighting_status.get("is_zero_lux_blind", False):
            cw = canvas.shape[1]
            blind_w, blind_h = 580, 70
            bx_b, by_b = (cw - blind_w) // 2, 80
            cv2.rectangle(canvas, (bx_b, by_b), (bx_b + blind_w, by_b + blind_h), (0, 0, 180), -1)
            cv2.rectangle(canvas, (bx_b, by_b), (bx_b + blind_w, by_b + blind_h), (0, 0, 255), 3)
            cv2.putText(canvas, "[!] CANH BAO: MOI TRUONG 0 LUX - CAM BIEN BI CHE TOI!", (bx_b + 20, by_b + 28),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.52, (255, 255, 255), 2, cv2.LINE_AA)
            cv2.putText(canvas, "DEN FLASH KHONG DU SANG. HE THONG DANG PHAT AM BAO LOI!", (bx_b + 35, by_b + 54),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.44, (255, 220, 220), 1, cv2.LINE_AA)

        # ── 5. LỚP PHỦ TẠM DỪNG (KHI PAUSED) ──
        if is_paused:
            dim_overlay = canvas.copy()
            cv2.rectangle(dim_overlay, (0, 0), (canvas.shape[1], canvas.shape[0]), (0, 0, 0), -1)
            cv2.addWeighted(dim_overlay, 0.65, canvas, 0.35, 0, canvas)

            cw = canvas.shape[1]
            ch = canvas.shape[0]
            banner_w, banner_h = 560, 100
            bx1, by1 = (cw - banner_w) // 2, (ch - banner_h) // 2
            cv2.rectangle(canvas, (bx1, by1), (bx1 + banner_w, by1 + banner_h), (15, 23, 42), -1)
            cv2.rectangle(canvas, (bx1, by1), (bx1 + banner_w, by1 + banner_h), (0, 165, 255), 2)
            cv2.putText(canvas, "|| DA TAM DUNG (PAUSED)", (bx1 + 105, by1 + 42),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.85, (0, 165, 255), 2, cv2.LINE_AA)
            cv2.putText(canvas, "Nhan [SPACE] hoac phim [S] de tiep tuc quet", (bx1 + 75, by1 + 75),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.52, (203, 213, 225), 1, cv2.LINE_AA)

        # ── 6. THANH ĐIỀU KHIỂN ĐÁY MÀN HÌNH (DOCK FOOTER) ──
        canvas_h = canvas.shape[0]
        footer_h = 28
        footer_overlay = canvas.copy()
        cv2.rectangle(footer_overlay, (0, canvas_h - footer_h), (canvas.shape[1], canvas_h), (10, 14, 23), -1)
        cv2.addWeighted(footer_overlay, 0.85, canvas, 0.15, 0, canvas)
        cv2.line(canvas, (0, canvas_h - footer_h), (canvas.shape[1], canvas_h - footer_h), (40, 50, 65), 1)

        footer_text = "[SPACE/S] Start/Stop  |  [M] Bat/Tat am  |  ['[' / ']'] Can chinh (+/-0.05x)  |  [R] Dat lai (1.00x)  |  [Q/ESC] Thoat"
        cv2.putText(canvas, footer_text, (15, canvas_h - 9),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.40, (180, 195, 215), 1, cv2.LINE_AA)

        return canvas
