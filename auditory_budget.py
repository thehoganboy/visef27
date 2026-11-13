"""
HorusEyes 2.0 - Auditory Budget Coordinator Module (Hardened)
================================================================================
Điều phối ngân sách thính giác cực hạn (Auditory Budget <= 1 stream):
  1. Ràng buộc cứng: CHỈ cấp phát duy nhất 1 kênh âm thanh cho mối nguy khẩn cấp nhất.
  2. Triệt tiêu hoàn toàn (Total Auditory Suppression) khi không gian an toàn (TTC > 2.5s
     hoặc khoảng cách > 250cm) nhằm chống nghẽn thính giác và mỏi tai cho người khiếm thị.
  3. Cơ chế Hysteresis Lock-in + CRITICAL Preemption:
     - Thưởng +15% điểm ưu tiên cho vật thể đang giữ stream âm thanh (Score * 1.15).
     - CRITICAL Preemption: Khi có vật cản đạt ngưỡng CRITICAL (TTC <= 1.0s hoặc Z <= 40cm),
       LẬP TỨC cấp quyền phát âm ngay trong frame hiện tại, bỏ qua MIN_HOLD_FRAMES và SWITCH_CONFIRM_FRAMES.
  4. Threat Score kết hợp hài hòa động học (1/TTC) và cự ly tĩnh (1/Z^1.5), KHÔNG phạt độ bất định.
  5. Uncertainty Hysteresis: Chuyển sang ACOUSTIC_BLUR khi u >= 0.48, chỉ quay về SHARP_PING khi u <= 0.38.
  6. Cơ chế trễ vòng lặp kín (Closed-Loop Hysteresis): Tự động giảm 50% âm lượng khi
     phát hiện người dùng bắt đầu đổi hướng né (is_evading == True).
================================================================================
"""

from dataclasses import dataclass
from typing import Optional, List
import time
import numpy as np

import config
from depth_engine import ObstacleDetectionResult, SingleObstacle
from motion_ttc import KinematicsResult


@dataclass
class BudgetDecision:
    is_active: bool = False            # True nếu được cấp ngân sách phát âm thanh, False nếu im lặng
    pan: float = 0.0                   # Hướng panning âm thanh [-1.0 trái, +1.0 phải]
    proximity: float = 0.0             # Mức độ gần [0.0, 1.0] điều tiết tần số & nhịp beep
    dist_cm: float = 250.0             # Khoảng cách metric của mối nguy (cm)
    ttc: float = float("inf")          # Time-to-Collision (giây)
    priority_score: float = 0.0        # Điểm ưu tiên cấp phát
    volume_factor: float = 0.0         # Hệ số âm lượng (1.0 hoặc 0.5 khi đang né)
    safe_direction: str = "NONE"       # "STOP" hoặc "NONE" (không tự phát lái né)
    guidance_state: str = "PATH_UNVERIFIED" # "HAZARD_BLOCKED (STOP)", "DROP_OFF_WARNING", "HAZARD_DETECTED", "PATH_UNVERIFIED"
    cue_mode: str = "MUTED"            # "SHARP_PING", "ACOUSTIC_BLUR", "MUTED"
    suppressed_count: int = 0          # Số lượng luồng tiềm năng bị triệt tiêu
    threat_level: str = "UNKNOWN"         # "SAFE", "WARNING", "CRITICAL"
    velocity_z: float = 0.0            # Vận tốc tiếp cận của mối nguy active (cm/s)
    active_obstacle_id: int = 1       # ID của vật cản được cấp ngân sách âm thanh duy nhất
    suppressed_obstacles: list = None # Danh sách các vật cản phụ bị triệt tiêu âm thanh
    source_type: str = "NONE"          # "OBJECT", "SECTOR", "NONE"
    source_id: str = "0"               # Track ID nếu OBJECT, tên sector nếu SECTOR
    source_timestamp: float = 0.0      # Timestamp gốc của phép đo
    measurement_validity: str = "VALID" # "VALID", "UNKNOWN", "INVALID"


class AuditoryBudgetManager:
    """
    Bộ điều phối ngân sách thính giác cực hạn theo chuẩn ViSEF 2.0.
    Tích hợp CRITICAL Preemption, Hysteresis Lock-in, và Uncertainty Hysteresis.
    """

    def __init__(self):
        self.total_suppressed_events = 0

        # Trạng thái Hysteresis Lock-in
        self.current_active_id: Optional[int] = None
        self.active_hold_counter: int = 0
        self.pending_switch_id: Optional[int] = None
        self.pending_switch_counter: int = 0

        # Trạng thái Uncertainty Hysteresis
        self.current_cue_mode: str = "MUTED"
        self.UNRESOLVED_REMINDER_DURATION_SEC: float = 1.5  # Directive 01B-A++ Task P1-F02: Cấu hình thời lượng nhắc nhở độc lập với FPS (s)

        self.HYSTERESIS_BOOST = 1.15       # +15% ưu tiên giữ vật thể đang active
        self.MIN_HOLD_FRAMES = 5           # Giữ tối thiểu 5 frame trước khi nhường quyền
        self.SWITCH_CONFIRM_FRAMES = 3     # Vật thể mới phải vượt trội trong ít nhất 3 frame

    @staticmethod
    def _compute_threat_score(ttc: float, proximity: float, dist_cm: float = 250.0, uncertainty: float = 0.0) -> float:
        """
        Tính điểm ưu tiên đe dọa (Threat Score):
        - Kết hợp hài hòa giữa nguy cơ động học (1 / TTC) và nguy cơ cự ly tĩnh (1 / Z^1.5).
        - Tuyệt đối KHÔNG nhân phạt (1 - 0.5 * u): vật cản có độ bất định cao (kính/cột mảnh)
          càng cần được cảnh báo ưu tiên.
        """
        if ttc < float("inf") and ttc > 0.0:
            kinetic = 1.0 / max(ttc, config.TTC_EPSILON)
        else:
            kinetic = 0.0

        # Nguy cơ cự ly tĩnh: Tỷ lệ nghịch phi tuyến với cự ly Z
        safe_dist = max(10.0, float(dist_cm))
        static_risk = (80.0 / safe_dist) ** 1.5
        prox_bias = 0.25 * proximity

        return kinetic + static_risk + prox_bias

    def coordinate(
        self,
        obs_res: ObstacleDetectionResult,
        kinematics_res: KinematicsResult,
        current_timestamp: Optional[float] = None
    ) -> BudgetDecision:
        """
        Quyết định cấp phát luồng âm thanh duy nhất dựa trên kết quả phát hiện và động học TTC.
        Bao gồm cơ chế CRITICAL Preemption vượt quyền ngay lập tức.
        """
        dist_cm = obs_res.dist_cm
        ttc = kinematics_res.primary_ttc
        threat_level = kinematics_res.threat_level
        safe_dir = kinematics_res.safe_direction
        uncert = obs_res.uncertainty_score
        is_evading = kinematics_res.is_evading

        all_obs = obs_res.all_obstacles if obs_res.all_obstacles else []
        if not all_obs:
            all_obs = [
                SingleObstacle(
                    id=1,
                    x=obs_res.x,
                    y=obs_res.y,
                    bbox=obs_res.bbox,
                    pan=obs_res.pan,
                    proximity=obs_res.proximity,
                    dist_cm=obs_res.dist_cm,
                    mode_text=obs_res.mode_text,
                    uncertainty_score=obs_res.uncertainty_score,
                    is_wall=obs_res.is_wall,
                )
            ]

        # ── 1. Quy tắc Triệt tiêu thính giác (Suppression Filter) ──
        # Im lặng tuyệt đối nếu:
        # - Trạng thái SAFE
        # - Hoặc khoảng cách >= DIST_SAFE_CM (250cm)
        # - Hoặc nhãn SAFE (Clear Path)
        # - Hoặc TTC > TTC_WARNING (2.5s) và khoảng cách >= DIST_ALERT_CM (200cm)
        # Ngoại lệ: Không triệt tiêu nếu là lỗi cảm biến / suy giảm thị giác (SENSOR_FAULT / DEGRADED / UNOBSERVABLE) hoặc đang lưu vết trễ (Coasting)
        is_sensor_fault = (
            obs_res.mode_text == "SENSOR_BLIND (0-Lux)"
            or not getattr(obs_res, "is_valid", True)
            or getattr(obs_res, "validity_state", "") in ["SENSOR_FAULT", "DEGRADED", "UNOBSERVABLE"]
            or getattr(obs_res, "quality_state", "") in ["DEGRADED", "UNOBSERVABLE"]
            or getattr(kinematics_res, "threat_level", "") == "SENSOR_FAULT"
            or getattr(kinematics_res, "guidance_state", "") == "CAMERA_STALLED"
        )
        is_coasting = getattr(kinematics_res, "hazard_persistence_active", False)
        hazard_state = getattr(kinematics_res, "hazard_state", "OBSERVED_LOW_RISK")

        if is_sensor_fault or threat_level in {"SENSOR_FAULT", "UNKNOWN", "INITIALIZING"}:
            now_ts = getattr(kinematics_res, "timestamp", 0.0) or (current_timestamp if current_timestamp is not None else time.perf_counter())
            return BudgetDecision(is_active=True, proximity=0.4, volume_factor=0.35,
                                  dist_cm=float("nan"), cue_mode="SYSTEM_FAULT_TONE",
                                  threat_level="SENSOR_FAULT" if is_sensor_fault else "UNKNOWN",
                                  guidance_state="PERCEPTION_UNAVAILABLE",
                                  source_type="NONE", source_id="0",
                                  source_timestamp=now_ts, measurement_validity="INVALID")

        # ── Directive 01B-A++ Task P1-F02: Monotonic Time-Based Bounded Reminder Policy (FPS-Independent) ──
        if hazard_state == "LOST_UNRESOLVED" or threat_level == "UNRESOLVED_HAZARD":
            lost_ts = getattr(kinematics_res, "lost_unresolved_timestamp", 0.0)
            now_ts = getattr(kinematics_res, "timestamp", 0.0)
            if now_ts <= 0.0:
                now_ts = current_timestamp if current_timestamp is not None else time.perf_counter()

            if lost_ts > 0.0 and now_ts >= lost_ts:
                elapsed_unresolved = now_ts - lost_ts
            else:
                elapsed_unresolved = 0.0

            # Bounded reminder window: phát âm nhắc nhở trong thời lượng thực cố định (1.5s), độc lập hoàn toàn với FPS
            # Tránh âm CRITICAL kéo dài vô tận, nhưng TUYỆT ĐỐI KHÔNG chuyển thành MUTED / SAFE!
            if elapsed_unresolved <= self.UNRESOLVED_REMINDER_DURATION_SEC:
                self.current_cue_mode = "CAUTION_REMINDER"
                return BudgetDecision(
                    is_active=True,
                    pan=0.0,
                    proximity=0.40,
                    dist_cm=dist_cm,
                    ttc=float("inf"),
                    priority_score=15.0,
                    volume_factor=0.35, # Âm lượng nhắc nhở dịu nhẹ, không chói tai
                    safe_direction="NONE",
                    guidance_state="PATH_UNRESOLVED",
                    threat_level="UNRESOLVED_HAZARD",
                    cue_mode="CAUTION_REMINDER",
                    suppressed_count=0,
                    active_obstacle_id=0,
                    suppressed_obstacles=[],
                    source_type="NONE",
                    source_id="0",
                    source_timestamp=now_ts,
                    measurement_validity="INVALID"
                )
            else:
                # Sau thời hạn 1.5s, chuyển sang standby im lặng, nhưng TUYỆT ĐỐI GIỮ NGUYÊN guidance_state là PATH_UNRESOLVED
                self.current_cue_mode = "STANDBY_UNRESOLVED"
                return BudgetDecision(
                    is_active=False,
                    pan=0.0,
                    proximity=0.0,
                    dist_cm=dist_cm,
                    ttc=float("inf"),
                    priority_score=0.0,
                    volume_factor=0.0,
                    safe_direction="NONE",
                    guidance_state="PATH_UNRESOLVED",
                    threat_level="UNRESOLVED_HAZARD",
                    cue_mode="STANDBY_UNRESOLVED",
                    suppressed_count=0,
                    active_obstacle_id=0,
                    suppressed_obstacles=[],
                    source_type="NONE",
                    source_id="0",
                    source_timestamp=now_ts,
                    measurement_validity="INVALID"
                )

        if threat_level == "SAFE" and not is_sensor_fault and not is_coasting and (
            threat_level == "SAFE"
            or dist_cm >= config.DIST_SAFE_CM
            or obs_res.mode_text.startswith("SAFE")
            or (dist_cm >= config.DIST_ALERT_CM and ttc > config.TTC_WARNING)
        ):
            now_ts = getattr(kinematics_res, "timestamp", 0.0) or (current_timestamp if current_timestamp is not None else time.perf_counter())
            self.current_active_id = None
            self.active_hold_counter = 0
            self.pending_switch_id = None
            self.pending_switch_counter = 0
            self.current_cue_mode = "MUTED"
            return BudgetDecision(
                is_active=False,
                pan=0.0,
                proximity=0.0,
                dist_cm=dist_cm,
                ttc=float("inf"),
                priority_score=0.0,
                volume_factor=0.0,
                safe_direction=safe_dir,
                guidance_state=getattr(kinematics_res, "guidance_state", "PATH_UNVERIFIED"),
                cue_mode="MUTED",
                suppressed_count=max(len(all_obs), 3),
                active_obstacle_id=0,
                suppressed_obstacles=all_obs,
                source_type="NONE",
                source_id="0",
                source_timestamp=now_ts,
                measurement_validity="VALID"
            )

        # ── 2. Tính điểm ưu tiên (Priority Score) cho từng vật cản ──
        active_candidate: Optional[SingleObstacle] = None
        if self.current_active_id is not None:
            active_candidate = next((o for o in all_obs if o.id == self.current_active_id), None)

        active_is_safe = False
        if active_candidate is not None:
            act_ttc = kinematics_res.obstacle_ttcs.get(active_candidate.id, float("inf")) if kinematics_res.obstacle_ttcs else ttc
            if act_ttc > config.TTC_WARNING and active_candidate.dist_cm >= config.DIST_WARNING_CM:
                active_is_safe = True
        else:
            active_is_safe = True

        scored_candidates = []
        for o in all_obs:
            o_ttc = kinematics_res.obstacle_ttcs.get(o.id, float("inf")) if kinematics_res.obstacle_ttcs else float("inf")
            raw_score = self._compute_threat_score(o_ttc, o.proximity, o.dist_cm, o.uncertainty_score)

            # Áp dụng Hysteresis Boost (+15%) nếu vật thể này đang nắm giữ stream
            is_active_obj = (self.current_active_id is not None and o.id == self.current_active_id)
            effective_score = raw_score * self.HYSTERESIS_BOOST if is_active_obj else raw_score
            scored_candidates.append((effective_score, raw_score, o, o_ttc))

        if scored_candidates:
            scored_candidates.sort(key=lambda item: item[0], reverse=True)
            top_eff_score, top_raw_score, top_obs, top_ttc = scored_candidates[0]

            # ── Kiểm tra CRITICAL Preemption (Vượt quyền tức thời) ──
            # Nếu top candidate đạt ngưỡng CRITICAL (TTC <= 1.0s hoặc Z <= 40cm),
            # lập tức cấp quyền ngay trong frame hiện tại, bỏ qua MIN_HOLD_FRAMES & SWITCH_CONFIRM
            is_top_critical = (
                top_ttc <= config.TTC_CRITICAL or
                top_obs.dist_cm <= config.DIST_CRITICAL_CM
            )

            if is_top_critical and (self.current_active_id != top_obs.id):
                # Preemption triggered!
                self.current_active_id = top_obs.id
                self.active_hold_counter = 1
                self.pending_switch_id = None
                self.pending_switch_counter = 0
                winner_obs = top_obs
                winner_ttc = top_ttc
                winner_score = top_raw_score
            elif self.current_active_id is None or active_candidate is None or active_is_safe:
                # Không có stream active hoặc vật cũ đã an toàn -> Cấp ngay cho top candidate
                self.current_active_id = top_obs.id
                self.active_hold_counter = 1
                self.pending_switch_id = None
                self.pending_switch_counter = 0
                winner_obs = top_obs
                winner_ttc = top_ttc
                winner_score = top_raw_score
            elif top_obs.id == self.current_active_id:
                # Vật cũ vẫn dẫn đầu -> Tăng bộ đếm hold
                self.active_hold_counter += 1
                self.pending_switch_id = None
                self.pending_switch_counter = 0
                winner_obs = top_obs
                winner_ttc = top_ttc
                winner_score = top_raw_score
            else:
                # Vật mới dẫn đầu điểm số -> Xác nhận chống chattering
                if self.pending_switch_id == top_obs.id:
                    self.pending_switch_counter += 1
                else:
                    self.pending_switch_id = top_obs.id
                    self.pending_switch_counter = 1

                can_switch = (
                    (self.pending_switch_counter >= self.SWITCH_CONFIRM_FRAMES) or
                    (self.active_hold_counter >= self.MIN_HOLD_FRAMES and self.pending_switch_counter >= 2)
                )

                if can_switch:
                    self.current_active_id = top_obs.id
                    self.active_hold_counter = 1
                    self.pending_switch_id = None
                    self.pending_switch_counter = 0
                    winner_obs = top_obs
                    winner_ttc = top_ttc
                    winner_score = top_raw_score
                else:
                    # Giữ nguyên stream cho vật cũ
                    self.active_hold_counter += 1
                    winner_obs = active_candidate
                    winner_ttc = kinematics_res.obstacle_ttcs.get(active_candidate.id, float("inf")) if kinematics_res.obstacle_ttcs else float("inf")
                    winner_score = self._compute_threat_score(
                        winner_ttc, active_candidate.proximity, active_candidate.dist_cm, active_candidate.uncertainty_score
                    )

            suppressed_list = [o for o in all_obs if o.id != winner_obs.id]
            active_id = winner_obs.id
            active_dist = winner_obs.dist_cm
            active_pan = winner_obs.pan
            active_prox = winner_obs.proximity
            active_uncert = winner_obs.uncertainty_score
            best_ttc = winner_ttc
            best_score = winner_score
            src_type = "OBJECT"
            src_id = str(active_id)
            meas_val = "VALID" if (np.isfinite(active_dist) and active_dist > 0) else "UNKNOWN"
        else:
            best_score = self._compute_threat_score(ttc, obs_res.proximity, dist_cm, uncert)
            best_ttc = ttc
            suppressed_list = []
            active_id = 1
            active_dist = dist_cm
            active_pan = obs_res.pan
            active_prox = obs_res.proximity
            active_uncert = uncert
            self.current_active_id = active_id
            self.active_hold_counter = 1
            src_type = "SECTOR"
            src_id = "SECTOR_CENTER"
            meas_val = "VALID" if (np.isfinite(dist_cm) and dist_cm > 0) else "UNKNOWN"

        priority_score = round(float(best_score), 2)

        # ── 3. Điều phối Panning 3D (Định vị Mối nguy - FIX-M01 & TASK 01A-2) ──
        # Âm thanh bắt buộc phải định vị trực tiếp vị trí vật cản trong không gian (active_pan)
        # TUYỆT ĐỐI KHÔNG đảo pan sang tai đối diện để gợi ý né tránh tự phát khi chưa kiểm chứng hành lang!
        if safe_dir == "STOP" or getattr(kinematics_res, "guidance_state", "") == "HAZARD_BLOCKED (STOP)":
            pan = 0.0
        else:
            pan = float(np.clip(active_pan, -1.0, 1.0))

        # ── 4. Bảo toàn Âm lượng Cảnh báo Toàn phần (Directive 01B Task A2) ──
        # KHÔNG tự động giảm âm lượng cảnh báo (-6dB) chỉ vì xoay đầu / xoay camera.
        # Cảnh báo mối nguy trong hành lang bắt buộc giữ nguyên 100% âm lượng (1.0).
        volume_factor = 1.0

        # ── 5. Mã hóa âm học theo độ bất định AI có Hysteresis ──
        blur_thresh = getattr(config, "UNCERTAINTY_BLUR_THRESHOLD", 0.48)
        sharp_thresh = getattr(config, "UNCERTAINTY_SHARP_THRESHOLD", 0.38)

        if active_uncert >= blur_thresh:
            cue_mode = "ACOUSTIC_BLUR"
        elif active_uncert <= sharp_thresh:
            cue_mode = "SHARP_PING"
        else:
            cue_mode = self.current_cue_mode if self.current_cue_mode in ["SHARP_PING", "ACOUSTIC_BLUR"] else "SHARP_PING"
        self.current_cue_mode = cue_mode

        total_suppressed = len(suppressed_list) + 2

        active_vz = kinematics_res.obstacle_vzs.get(active_id, 0.0) if kinematics_res.obstacle_vzs else kinematics_res.primary_velocity_z
        if active_vz <= 0.0:
            best_ttc = float("inf")

        now_ts = getattr(kinematics_res, "timestamp", 0.0) or (current_timestamp if current_timestamp is not None else time.perf_counter())

        return BudgetDecision(
            is_active=True,
            pan=pan,
            proximity=active_prox,
            dist_cm=active_dist,
            ttc=best_ttc,
            priority_score=priority_score,
            volume_factor=volume_factor,
            safe_direction=safe_dir,
            guidance_state=getattr(kinematics_res, "guidance_state", "PATH_UNVERIFIED"),
            cue_mode=cue_mode,
            suppressed_count=total_suppressed,
            threat_level=threat_level,
            velocity_z=active_vz,
            active_obstacle_id=active_id,
            suppressed_obstacles=suppressed_list,
            source_type=src_type,
            source_id=src_id,
            source_timestamp=now_ts,
            measurement_validity=meas_val
        )
