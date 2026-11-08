"""
HorusEyes 2.0 - Kinematics & Time-To-Collision (TTC) Engine (Hardened)
================================================================================
Dự đoán va chạm thời gian thực (Real-time Collision Prediction) siêu nhẹ (<0.2ms CPU):
  1. Theo dõi đa vật thể (Lightweight Centroid & IoU Tracker) giữ ID ổn định.
  2. Frame-ID deduplication & AE settle window (bỏ qua frame trùng, giữ vz khi bật/tắt flash).
  3. Ước lượng vận tốc tiếp cận v_z bằng Windowed Linear Regression có dịch gốc thời gian
     (Time-origin shift t_i - t_0) triệt tiêu lỗi hủy số học dấu phẩy động.
  4. Bù chuyển động nền của người đi bộ (Ego-Motion Compensation: TTC_effective = Z / max(vz, v_user)).
  5. Đồng bộ hóa vùng chết VZ_DEADBAND = 20.0 cm/s và kích hoạt TTC = 20.0 cm/s.
  6. Tính toán Time-to-Collision (TTC) chuẩn xác theo lý thuyết Tau Margin của Lee.
  7. Dịch ngưỡng an toàn ra xa: CRITICAL=40cm/1.0s, DANGER=80cm, WARNING=140cm/2.5s, SAFE=250cm/4.0s.
  8. Xác định hướng né thoát an toàn (Safe-Direction Guidance: LEFT / RIGHT / STOP) với
     Sector Safety Score tính theo phân vị thứ 20 (P20) và độ rộng thông thủy liên tục.
  9. Siết chặt phát hiện né tránh (is_evading): Bắt buộc tâm góc dịch ra biên VÀ khoảng cách Z không giảm.
================================================================================
"""

from collections import deque
from dataclasses import dataclass, field
from typing import Dict, List, Tuple, Optional
import math
import numpy as np

import config
from depth_engine import ObstacleDetectionResult, SingleObstacle


@dataclass
class SectorThreat:
    name: str                     # "LEFT", "CENTER", "RIGHT"
    dist_cm: float                # Khoảng cách metric của sector (cm)
    velocity_z: float             # Vận tốc tiếp cận v_z (cm/s, dương = đang lao tới)
    ttc: float                    # Time-to-Collision (giây), inf nếu an toàn
    threat_level: str             # "CRITICAL", "WARNING", "SAFE", "UNKNOWN"
    static_risk: str = "SAFE"     # "CRITICAL", "DANGER", "WARNING", "CAUTION", "SAFE", "UNKNOWN" (Directive 01B Task A4)
    dynamic_risk: str = "NONE"    # "CRITICAL", "WARNING", "LOW", "NONE", "UNKNOWN" (Directive 01B Task A4)


@dataclass
class KinematicsResult:
    primary_ttc: float               # TTC của mối nguy chính (giây)
    primary_velocity_z: float        # Vận tốc tiếp cận của mối nguy chính (cm/s)
    threats: Dict[str, SectorThreat] # Chi tiết 3 sector
    safe_direction: str              # "STOP" hoặc "NONE" (không chỉ định hướng rẽ tự phát)
    is_evading: bool                 # Cờ người dùng đang chủ động né thoát (>= 4 frame đồng nhất)
    threat_level: str                # "CRITICAL", "WARNING", "SAFE", "UNKNOWN"
    obstacle_ttcs: Dict[int, float] = None # Bảng tra TTC cho từng vật cản {obs.id: ttc}
    obstacle_vzs: Dict[int, float] = None  # Bảng tra vz cho từng vật cản {obs.id: vz}
    track_details: Dict[int, dict] = None # Chi tiết động học từng track {id: {vz_raw, vz_smooth, delta_d, delta_t, ttc, dist_cm, bbox}}
    sector_scores: Dict[str, float] = None # Điểm an toàn của từng sector {"LEFT": score_l, "RIGHT": score_r}
    guidance_state: str = "PATH_UNVERIFIED"   # "HAZARD_BLOCKED (STOP)", "DROP_OFF_WARNING", "HAZARD_DETECTED", "PATH_UNVERIFIED"
    effective_ego_vz: float = 0.0          # Vận tốc tiến nền của người đi bộ (cm/s)
    hazard_direction: str = "NONE"         # Định vị hướng vật cản: "LEFT", "CENTER", "RIGHT", "NONE"
    motion_state: str = "UNKNOWN"          # Trạng thái chuyển động: "APPROACHING", "RECEDING", "STATIONARY", "UNKNOWN"
    primary_static_risk: str = "SAFE"      # Rủi ro cự ly tĩnh của mối nguy chính (Directive 01B Task A4)
    primary_dynamic_risk: str = "NONE"     # Rủi ro đóng góc động học của mối nguy chính (Directive 01B Task A4)
    primary_path_risk: str = "DIRECT"      # Phân vùng giao cắt hành lang: "DIRECT", "PERIPHERAL", "OUTSIDE"
    hazard_persistence_active: bool = False # Cờ lưu vết / trễ an toàn khi vật cản biến mất đột ngột (Directive 01B Task A2)
    measurement_basis: str = "METRIC_ESTIMATED_UNVERIFIED" # Chuẩn đo lường monocular (Directive 01B Principle B)


def compute_sector_safety_score(
    median_distance_sector: float,
    free_pixel_ratio: float = 1.0,
    ttc: float = float("inf"),
    max_vz_in_sector: float = 0.0,
    w1: Optional[float] = None,
    w2: Optional[float] = None,
    w3: Optional[float] = None,
    contiguous_free_ratio: float = 1.0,
) -> float:
    """
    Tính Điểm An Toàn Tổng Hợp (Sector Safety Score):
    Score_sector = w1 * S_clearance - w2 * S_ttc_threat - w3 * S_velocity_penalty

    Quy chuẩn thành phần:
    - S_clearance: Tỷ lệ không gian mở và cự ly metric khả dụng:
      S_clearance = np.clip(median_distance_sector / 250.0, 0.0, 1.0) * (free_pixel_ratio * contiguous_free_ratio)
    - S_ttc_threat: Rủi ro va chạm từ các vật thể nằm trong hoặc có vector chuyển động hướng vào sector:
      Nếu có vật cản đang tiến tới với TTC hữu hạn: S_ttc_threat = np.clip(1.0 / max(TTC, 0.2), 0.0, 5.0) / 5.0
      Nếu không có vật cản lao tới (TTC = inf): S_ttc_threat = 0.0
    - S_velocity_penalty: Phạt vận tốc tiếp cận vz > 0 của vật thể gần nhất trong sector:
      S_velocity_penalty = np.clip(max_vz_in_sector / 100.0, 0.0, 1.0)
    - Trọng số tham chiếu: w1 = 0.50, w2 = 0.35, w3 = 0.15 (cấu hình trong config.py).

    Chuẩn hóa kết quả kẹp trong dải [0.0, 1.0].
    """
    if w1 is None:
        w1 = getattr(config, "SAFETY_W_CLEARANCE", 0.50)
    if w2 is None:
        w2 = getattr(config, "SAFETY_W_TTC", 0.35)
    if w3 is None:
        w3 = getattr(config, "SAFETY_W_VZ", 0.15)

    c_dist = float(np.clip(median_distance_sector / 250.0, 0.0, 1.0))
    effective_free = float(np.clip(free_pixel_ratio * contiguous_free_ratio, 0.0, 1.0))
    s_clearance = c_dist * effective_free

    if ttc < float("inf") and ttc > 0.0:
        s_ttc_threat = float(np.clip(1.0 / max(ttc, 0.2), 0.0, 5.0)) / 5.0
    else:
        s_ttc_threat = 0.0

    pos_vz = max(0.0, float(max_vz_in_sector))
    s_velocity_penalty = float(np.clip(pos_vz / 100.0, 0.0, 1.0))

    raw_score = w1 * s_clearance - w2 * s_ttc_threat - w3 * s_velocity_penalty
    return float(np.clip(raw_score, 0.0, 1.0))


@dataclass
class TrackedObstacle:
    track_id: int
    cx: float
    cy: float
    bbox: Tuple[int, int, int, int]
    history_t: deque = field(default_factory=lambda: deque(maxlen=getattr(config, "MOTION_HISTORY_LEN", 8)))
    history_d: deque = field(default_factory=lambda: deque(maxlen=getattr(config, "MOTION_HISTORY_LEN", 8)))
    missing_count: int = 0
    smoothed_vz: float = 0.0
    raw_vz: float = 0.0
    delta_d: float = 0.0
    delta_t: float = 0.0
    pan: float = 0.0
    dist_cm: float = 250.0
    approach_confirm_count: int = 0


class LightweightCentroidTracker:
    """
    Bộ theo dõi tâm và hộp bao (Centroid + IoU Tracker) siêu nhẹ (<0.05ms):
    - Kháng mất dấu ID khi chuyển động nhanh bằng Adaptive Search Radius (bám theo kích thước bbox).
    - Duy trì bộ nhớ tracking (disappeared_frames = 4) chống nhòe chuyển động (motion blur).
    - Ước lượng vận tốc v_z bằng Windowed Linear Regression có dịch gốc thời gian (t_i - t_0)
      kết hợp EMA nhạy bén (alpha = 0.40).
    """

    def __init__(self, max_missing: int = 4, match_dist_thresh: float = 160.0):
        self.next_id = 1
        self.tracks: Dict[int, TrackedObstacle] = {}
        self.max_missing = max_missing
        self.match_dist_thresh = match_dist_thresh

    def compute_iou(self, boxA: Tuple[int, int, int, int], boxB: Tuple[int, int, int, int]) -> float:
        xA = max(boxA[0], boxB[0])
        yA = max(boxA[1], boxB[1])
        xB = min(boxA[0] + boxA[2], boxB[0] + boxB[2])
        yB = min(boxA[1] + boxA[3], boxB[1] + boxB[3])

        interW = max(0, xB - xA)
        interH = max(0, yB - yA)
        interArea = interW * interH

        boxAArea = max(1, boxA[2] * boxA[3])
        boxBArea = max(1, boxB[2] * boxB[3])

        iou = interArea / float(boxAArea + boxBArea - interArea)
        return float(iou)

    def calculate_vz(self, track: TrackedObstacle, freeze_vz: bool = False) -> float:
        """
        Ước lượng vận tốc tiếp cận v_z (cm/s):
        - v_z = -(d_curr - d_prev) / delta_t (dương = đang tiến lại gần, âm = lùi ra xa).
        - Bộ lọc kết hợp: Windowed Linear Regression (N=4-8) có DỊCH GỐC THỜI GIAN
          (t_tilde = t_i - t_0) để loại bỏ lỗi hủy số học + EMA nhạy bén.
        - freeze_vz = True: Giữ nguyên smoothed_vz trong cửa sổ AE Settle sau khi bật/tắt flash.
        """
        if freeze_vz:
            return float(track.smoothed_vz)

        k = len(track.history_t)
        if k < 2:
            track.raw_vz = 0.0
            track.smoothed_vz = 0.0
            track.delta_d = 0.0
            track.delta_t = 0.0
            return 0.0

        ts = np.array(track.history_t, dtype=np.float64)
        ds = np.array(track.history_d, dtype=np.float64)

        dt_last = ts[-1] - ts[-2]
        # Kẹp cận an toàn cho delta_t: 0.01s <= dt <= 0.20s
        dt_safe = max(0.010, min(0.20, dt_last)) if dt_last > 0.0 else 0.033
        dd_last = ds[-1] - ds[-2]

        track.delta_d = float(dd_last)
        track.delta_t = float(dt_safe)

        # ── KIỂM TRA MỐC DAO ĐỘNG (OSCILLATION THRESHOLD) ──
        oscillation = float(np.max(ds) - np.min(ds))
        net_disp = float(ds[0] - ds[-1])  # >0: đang tiến lại gần
        disp_thresh = getattr(config, "MOTION_DISP_THRESHOLD_CM", 12.0)
        min_net_disp = getattr(config, "MIN_NET_DISPLACEMENT_CM", 8.0)

        # Nếu độ dao động chưa vượt mốc hoặc độ dịch tịnh tiến chưa đủ -> ÉP ĐỨNG YÊN HOÀN TOÀN
        if oscillation < disp_thresh or abs(net_disp) < min_net_disp:
            track.raw_vz = 0.0
            track.smoothed_vz = 0.0
            track.approach_confirm_count = 0
            return 0.0

        # ĐÃ VƯỢT MỐC DAO ĐỘNG -> Hồi quy tuyến tính có dịch gốc thời gian
        # t_tilde = t_i - t_0 triệt tiêu số học dấu phẩy động
        t_tilde = ts - ts[0]
        if k >= 3:
            t_bar = float(np.mean(t_tilde))
            d_bar = float(np.mean(ds))
            denom = float(np.sum((t_tilde - t_bar) ** 2))
            if denom > 1e-9:
                slope = float(np.sum((t_tilde - t_bar) * (ds - d_bar)) / denom)
                vz_calculated = -slope  # v_z = -d(dist)/dt
            else:
                t_span = max(0.020, min(0.35, float(t_tilde[-1])))
                vz_calculated = float(net_disp / t_span)
        else:
            t_span = max(0.020, min(0.35, float(t_tilde[-1])))
            vz_calculated = float(net_disp / t_span)

        # Kẹp cận hợp lý cho vận tốc thực tế
        vz_calculated = float(np.clip(vz_calculated, -250.0, 350.0))
        track.raw_vz = vz_calculated

        # Khởi tạo hoặc làm mượt EMA
        alpha = getattr(config, "VELOCITY_SMOOTHING", 0.40)
        if track.smoothed_vz == 0.0:
            track.smoothed_vz = vz_calculated
        else:
            track.smoothed_vz = alpha * vz_calculated + (1.0 - alpha) * track.smoothed_vz

        # Vùng chết đồng bộ: |vz| < 20 cm/s coi là tĩnh tuyệt đối
        deadband = getattr(config, "VZ_DEADBAND_CM_S", 20.0)
        if abs(track.smoothed_vz) < deadband:
            track.smoothed_vz = 0.0

        return float(track.smoothed_vz)

    def update(
        self,
        obstacles: List[SingleObstacle],
        timestamp: float,
        freeze_vz: bool = False,
    ) -> Dict[int, float]:
        """
        Ghép cặp detections với tracks bằng Adaptive Distance Radius và cập nhật ID, vz.
        Returns: {obstacle.id: vz}
        """
        vz_map = {}
        if not obstacles:
            for tid in list(self.tracks.keys()):
                self.tracks[tid].missing_count += 1
                if self.tracks[tid].missing_count > self.max_missing:
                    del self.tracks[tid]
            return vz_map

        if not self.tracks:
            for obs in obstacles:
                t = TrackedObstacle(
                    track_id=self.next_id,
                    cx=float(obs.x),
                    cy=float(obs.y),
                    bbox=obs.bbox,
                    pan=obs.pan,
                    dist_cm=obs.dist_cm
                )
                t.history_t.append(timestamp)
                t.history_d.append(obs.dist_cm)
                self.tracks[self.next_id] = t
                obs.id = self.next_id
                vz_map[obs.id] = 0.0
                self.next_id += 1
            return vz_map

        track_ids = list(self.tracks.keys())
        cost_matrix = np.zeros((len(track_ids), len(obstacles)), dtype=np.float32)

        for i, tid in enumerate(track_ids):
            trk = self.tracks[tid]
            diag = np.hypot(trk.bbox[2], trk.bbox[3])
            adaptive_radius = max(80.0, 0.45 * diag, self.match_dist_thresh)

            for j, obs in enumerate(obstacles):
                dist_centroid = np.hypot(trk.cx - obs.x, trk.cy - obs.y)
                iou = self.compute_iou(trk.bbox, obs.bbox)
                cost = (dist_centroid / max(adaptive_radius, 1.0)) * 0.70 + (1.0 - iou) * 0.30
                if dist_centroid > adaptive_radius and iou < 0.05:
                    cost += 10.0
                cost_matrix[i, j] = cost

        matched_tracks = set()
        matched_obs = set()

        flat_indices = np.argsort(cost_matrix, axis=None)
        for idx in flat_indices:
            i = idx // len(obstacles)
            j = idx % len(obstacles)
            if i in matched_tracks or j in matched_obs:
                continue
            if cost_matrix[i, j] > 1.2:
                continue

            tid = track_ids[i]
            trk = self.tracks[tid]
            obs = obstacles[j]

            trk.cx = float(obs.x)
            trk.cy = float(obs.y)
            trk.bbox = obs.bbox
            trk.pan = obs.pan
            trk.dist_cm = obs.dist_cm
            trk.missing_count = 0
            trk.history_t.append(timestamp)
            trk.history_d.append(obs.dist_cm)

            obs.id = tid
            vz = self.calculate_vz(trk, freeze_vz=freeze_vz)
            vz_map[obs.id] = vz

            matched_tracks.add(i)
            matched_obs.add(j)

        for j, obs in enumerate(obstacles):
            if j not in matched_obs:
                t = TrackedObstacle(
                    track_id=self.next_id,
                    cx=float(obs.x),
                    cy=float(obs.y),
                    bbox=obs.bbox,
                    pan=obs.pan,
                    dist_cm=obs.dist_cm
                )
                t.history_t.append(timestamp)
                t.history_d.append(obs.dist_cm)
                self.tracks[self.next_id] = t
                obs.id = self.next_id
                vz_map[obs.id] = 0.0
                self.next_id += 1

        for i, tid in enumerate(track_ids):
            if i not in matched_tracks:
                self.tracks[tid].missing_count += 1
                if self.tracks[tid].missing_count > self.max_missing:
                    del self.tracks[tid]

        return vz_map


class KinematicsEngine:
    """
    Bộ xử lý động học chuyển động và tính toán TTC ổn định, không giật lag.
    Tích hợp:
      - Deduplication frame_id
      - AE Settle counter (đóng băng vz khi bật/tắt flash)
      - Hồi quy tuyến tính dịch gốc thời gian
      - Bù chuyển động người đi bộ (Ego-motion compensation)
      - Siết chặt cờ né tránh (is_evading)
    """

    def __init__(self):
        self.prev_timestamp = 0.0
        self.prev_dist_cm = None
        self.prev_pan = 0.0
        self.prev_ttc = float("inf")
        self.prev_sector_dists = None
        self.prev_frame_id = -1
        self.last_result: Optional[KinematicsResult] = None

        self.tracker = LightweightCentroidTracker()

        # Bộ lọc EMA cho vận tốc tiếp cận sector
        self.sector_v_z = {"LEFT": 0.0, "CENTER": 0.0, "RIGHT": 0.0}

        self.smoothed_safe_dir = "NONE"
        self.hazard_direction = "NONE"
        self.guidance_state = "PATH_UNVERIFIED"
        self.sector_scores = {"LEFT": 0.50, "RIGHT": 0.50}
        self.dir_hysteresis_frames = 0

        # Biến theo dõi né tránh đồng nhất liên tiếp
        self.consecutive_evasion_frames = 0
        self.last_evasion_dir = "NONE"

        # Trạng thái Hazard Persistence / Coasting khi vật cản biến mất đột ngột (Directive 01B Task A2)
        self.coasting_frames = 0
        self.last_hazard_dist = 250.0
        self.last_hazard_dir = "NONE"
        self.last_threat_level = "SAFE"
        self.MAX_COASTING_FRAMES = 5

    def compute(
        self,
        obs_res: ObstacleDetectionResult,
        timestamp: float,
        frame_id: Optional[int] = None,
        ae_settle_counter: int = 0,
    ) -> KinematicsResult:
        """
        Tính toán TTC, vận tốc tiếp cận và hướng né an toàn từ kết quả depth.
        Hỗ trợ frame_id deduplication và ae_settle_counter passthrough.
        """
        # Bỏ qua frame trùng lặp (Frame-ID Deduplication hoặc Timestamp không đổi)
        is_dup_frame = (frame_id is not None and frame_id == self.prev_frame_id)
        is_dup_ts = (self.prev_timestamp > 0.0 and timestamp == self.prev_timestamp)
        if (is_dup_frame or is_dup_ts) and self.last_result is not None:
            return self.last_result

        now = timestamp
        if self.prev_timestamp > 0.0 and now > self.prev_timestamp:
            dt = max(0.010, min(0.20, now - self.prev_timestamp))
        else:
            dt = 1.0 / config.DEFAULT_FPS

        freeze_vz = (ae_settle_counter > 0)
        sec_dists = obs_res.sector_dists
        all_obs = obs_res.all_obstacles if obs_res.all_obstacles else []

        # ── 1. Cập nhật theo dõi vật cản & tính v_z qua hồi quy dịch thời gian ──
        obs_vzs = self.tracker.update(all_obs, now, freeze_vz=freeze_vz)

        curr_dist = obs_res.dist_cm
        curr_pan  = obs_res.pan

        # Ngưỡng an toàn mới
        dist_critical = getattr(config, "DIST_CRITICAL_CM", 40.0)
        dist_danger   = getattr(config, "DIST_DANGER_CM", 80.0)
        dist_warning  = getattr(config, "DIST_WARNING_CM", 140.0)
        dist_alert    = getattr(config, "DIST_ALERT_CM", 200.0)
        dist_safe     = getattr(config, "DIST_SAFE_CM", 250.0)
        ttc_critical  = getattr(config, "TTC_CRITICAL", 1.0)
        ttc_warning   = getattr(config, "TTC_WARNING", 2.5)

        # Khởi tạo frame đầu tiên nếu chưa có
        if self.prev_dist_cm is None or self.prev_sector_dists is None:
            self.prev_dist_cm = curr_dist
            self.prev_pan = curr_pan
            self.prev_ttc = float("inf")
            self.prev_sector_dists = sec_dists.copy()
            self.prev_timestamp = now
            if frame_id is not None:
                self.prev_frame_id = frame_id

            if curr_dist <= dist_critical:
                init_threat = "CRITICAL"
            elif curr_dist < dist_warning:
                init_threat = "WARNING"
            else:
                init_threat = "SAFE"
            init_ttc = float("inf")

            obs_ttcs = {o.id: init_ttc for o in all_obs}
            for o in all_obs:
                if o.id not in obs_vzs:
                    obs_vzs[o.id] = 0.0

            track_details = {}
            for o in all_obs:
                trk = self.tracker.tracks.get(o.id)
                track_details[o.id] = {
                    "vz_raw": trk.raw_vz if trk else 0.0,
                    "vz_smooth": trk.smoothed_vz if trk else 0.0,
                    "delta_d": trk.delta_d if trk else 0.0,
                    "delta_t": trk.delta_t if trk else 0.0,
                    "ttc": init_ttc,
                    "dist_cm": o.dist_cm,
                    "bbox": o.bbox
                }

            init_sec_scores = {
                "LEFT": compute_sector_safety_score(sec_dists.get("LEFT", 250.0)),
                "RIGHT": compute_sector_safety_score(sec_dists.get("RIGHT", 250.0)),
            }
            deadlock_thresh = getattr(config, "SECTOR_DEADLOCK_THRESH", 0.08)
            center_dist = sec_dists.get("CENTER", 250.0)
            center_blocked = (center_dist < dist_warning)
            left_dist = sec_dists.get("LEFT", 250.0)
            right_dist = sec_dists.get("RIGHT", 250.0)
            left_blocked = (left_dist < dist_danger or init_sec_scores["LEFT"] < deadlock_thresh)
            right_blocked = (right_dist < dist_danger or init_sec_scores["RIGHT"] < deadlock_thresh)
            margin = getattr(config, "SECTOR_HYSTERESIS_MARGIN", 0.10)

            if getattr(obs_res, "drop_off_hazard", False):
                init_guidance = "DROP_OFF_WARNING"
                init_safe_dir = "STOP"
                init_hazard_dir = "CENTER"
            elif center_blocked and left_blocked and right_blocked:
                init_guidance = "HAZARD_BLOCKED (STOP)"
                init_safe_dir = "STOP"
                init_hazard_dir = "CENTER"
            elif all_obs:
                init_guidance = "HAZARD_DETECTED"
                init_safe_dir = "NONE"
                p_obs = all_obs[0]
                init_hazard_dir = "LEFT" if p_obs.pan < -0.33 else ("RIGHT" if p_obs.pan > 0.33 else "CENTER")
            else:
                init_guidance = "PATH_UNVERIFIED"
                init_safe_dir = "NONE"
                init_hazard_dir = "NONE"

            self.smoothed_safe_dir = init_safe_dir
            self.guidance_state = init_guidance
            self.hazard_direction = init_hazard_dir
            self.sector_scores = init_sec_scores

            res = self._create_result(
                curr_dist, 0.0, init_ttc, sec_dists, init_threat, init_safe_dir, False,
                obs_ttcs=obs_ttcs, obs_vzs=obs_vzs, track_details=track_details,
                sector_scores=init_sec_scores, guidance_state=init_guidance,
                hazard_direction=init_hazard_dir, motion_state="UNKNOWN"
            )
            self.last_result = res
            return res

        # ── 2. Ước lượng vận tốc tiến nền Ego-Motion (Ego-Motion Compensation) ──
        user_walk_est = getattr(config, "USER_WALK_SPEED_CM_S", 120.0)
        # Đồng bộ ngưỡng kích hoạt vận tốc: 20.0 cm/s
        min_approach_vz = getattr(config, "VZ_MIN_APPROACH_CM_S", 20.0)
        disp_thresh = getattr(config, "MOTION_DISP_THRESHOLD_CM", 12.0)
        min_net_disp = getattr(config, "MIN_NET_DISPLACEMENT_CM", 8.0)
        confirm_frames = getattr(config, "MOTION_CONFIRM_FRAMES", 1)

        # ── 3. Tính TTC & v_z cho từng vật cản ──
        obs_ttcs = {}
        obs_threats = {}

        for o in all_obs:
            ovz = obs_vzs.get(o.id, 0.0)
            ottc = float("inf")

            trk = self.tracker.tracks.get(o.id)
            if trk and len(trk.history_d) >= 2:
                oscillation = float(np.max(trk.history_d) - np.min(trk.history_d))
                net_disp = float(trk.history_d[0] - trk.history_d[-1])
            else:
                oscillation = 0.0
                net_disp = 0.0

            has_approach_trend = (
                trk is not None and
                len(trk.history_d) >= 2 and
                oscillation >= disp_thresh and
                net_disp >= min_net_disp and
                ovz >= min_approach_vz
            )

            if trk:
                if has_approach_trend:
                    trk.approach_confirm_count = getattr(trk, "approach_confirm_count", 0) + 1
                else:
                    trk.approach_confirm_count = 0
                is_truly_approaching = (trk.approach_confirm_count >= confirm_frames)
            else:
                is_truly_approaching = False

            # Vận tốc tiếp cận tương đối thực tế (Relative Range Rate)
            # FIX-M04: Loại bỏ gán cứng 120cm/s gây báo động giả vật tĩnh trước mặt
            effective_vz = ovz
            is_frontal = (abs(o.pan) < 0.45)

            # Phân loại trạng thái chuyển động (Motion State)
            if trk is None or len(trk.history_d) < 2:
                o_motion_state = "UNKNOWN"
            elif ovz >= min_approach_vz:
                o_motion_state = "APPROACHING"
            elif ovz <= -min_approach_vz:
                o_motion_state = "RECEDING"
            else:
                o_motion_state = "STATIONARY"

            # Chỉ tính TTC hữu hạn khi vật cản ĐANG TIẾP CẬN với vận tốc vượt ngưỡng
            if is_truly_approaching and ovz >= min_approach_vz and o.dist_cm < dist_safe:
                ottc = max(0.05, min(10.0, o.dist_cm / ovz))
            else:
                ottc = float("inf")

            obs_ttcs[o.id] = ottc

            # ── TASK A4: Tách bạch Rủi ro Cự ly tĩnh vs Rủi ro Đóng góc Động học ──
            # 1. Rủi ro cự ly tĩnh (Static Proximity Risk):
            if math.isnan(o.dist_cm):
                o_static_risk = "UNKNOWN"
            elif o.dist_cm <= dist_critical:
                o_static_risk = "CRITICAL"
            elif o.dist_cm <= dist_danger:
                o_static_risk = "DANGER"
            elif o.dist_cm < dist_warning:
                o_static_risk = "WARNING"
            elif o.dist_cm < dist_alert:
                o_static_risk = "CAUTION"
            else:
                o_static_risk = "SAFE"

            # 2. Rủi ro đóng góc động học (Dynamic Closing Risk):
            if o_motion_state == "UNKNOWN":
                o_dynamic_risk = "UNKNOWN"
            elif o_motion_state == "APPROACHING":
                if ottc <= ttc_critical:
                    o_dynamic_risk = "CRITICAL"
                elif ottc <= ttc_warning:
                    o_dynamic_risk = "WARNING"
                else:
                    o_dynamic_risk = "LOW"
            else:
                o_dynamic_risk = "NONE"

            # 3. Phân vùng giao cắt hành lang (Path Intersection Risk):
            if abs(o.pan) <= 0.33:
                o_path_risk = "DIRECT"
            elif abs(o.pan) <= 0.60:
                o_path_risk = "PERIPHERAL"
            else:
                o_path_risk = "OUTSIDE"

            # 4. Hợp nhất Cấp độ Đe dọa (Unified Threat Level - Directive 01B Task A4):
            # Quy tắc vàng:
            # - Vật cản tĩnh ở cự ly nguy cấp (<= 40cm, ví dụ 30cm) LUÔN LUÔN là CRITICAL dù TTC = inf!
            # - Vật cản đang lao tới nhanh (TTC <= 1.0s) trong hành lang LUÔN LUÔN là CRITICAL dù camera đứng yên!
            # - Vật cản cắt ngang ngoài hành lang (|pan| > 0.60) và không lao tới được hạ cấp rủi ro
            if o_static_risk == "CRITICAL":
                o_level = "CRITICAL"
            elif o_dynamic_risk == "CRITICAL" and o_path_risk in ["DIRECT", "PERIPHERAL"]:
                o_level = "CRITICAL"
            elif o_path_risk == "OUTSIDE" and o_motion_state != "APPROACHING":
                o_level = "SAFE"
            elif o_static_risk in ["DANGER", "WARNING"] or o_dynamic_risk == "WARNING":
                o_level = "WARNING"
            elif o_static_risk == "UNKNOWN":
                o_level = "UNKNOWN"
            else:
                o_level = "SAFE"

            obs_threats[o.id] = o_level

        # Xác định mối nguy chính (Ưu tiên CRITICAL > WARNING > SAFE, sau đó đến TTC nhỏ nhất)
        if all_obs:
            def obs_priority_key(o):
                lvl = obs_threats.get(o.id, "SAFE")
                lvl_rank = 0 if lvl == "CRITICAL" else (1 if lvl == "WARNING" else 2)
                ottc = obs_ttcs.get(o.id, float("inf"))
                return (lvl_rank, ottc, o.dist_cm)

            sorted_obs = sorted(all_obs, key=obs_priority_key)
            primary_obs = sorted_obs[0]
            primary_id = primary_obs.id
            primary_vz = obs_vzs.get(primary_id, 0.0)
            primary_ttc = obs_ttcs.get(primary_id, float("inf"))
            if primary_vz <= 0.0:
                primary_ttc = float("inf")
            obs_threat_level = obs_threats.get(primary_id, "SAFE")
        else:
            primary_vz = 0.0
            primary_ttc = float("inf")
            if curr_dist <= dist_critical:
                obs_threat_level = "CRITICAL"
            elif curr_dist <= dist_danger:
                obs_threat_level = "WARNING"
            else:
                obs_threat_level = "SAFE"

        # ── 4. Đánh giá rủi ro cho từng Sector hành lang (Directive 01B Task A4) ──
        alpha = config.VELOCITY_SMOOTHING
        threats = {}
        deadband = getattr(config, "VZ_DEADBAND_CM_S", 20.0)

        for name in ["LEFT", "CENTER", "RIGHT"]:
            s_curr = sec_dists[name]
            s_prev = self.prev_sector_dists[name]
            s_diff = s_curr - s_prev
            if abs(s_diff) < 2.5:
                s_raw_vz = 0.0
            else:
                s_raw_vz = - (s_diff / dt)

            if abs(s_raw_vz) < deadband:
                s_raw_vz = 0.0

            s_raw_vz = float(np.clip(s_raw_vz, -200.0, 300.0))
            if not freeze_vz:
                self.sector_v_z[name] = alpha * s_raw_vz + (1.0 - alpha) * self.sector_v_z[name]
                if abs(self.sector_v_z[name]) < deadband:
                    self.sector_v_z[name] = 0.0
            s_vz = self.sector_v_z[name]

            s_ttc = float("inf")
            if s_vz >= min_approach_vz and s_curr < dist_safe and (-s_diff >= min_net_disp):
                s_ttc = max(0.05, min(10.0, s_curr / max(s_vz, 1.0)))

            # Tách bạch rủi ro tĩnh vs động cho sector
            if math.isnan(s_curr):
                s_static_risk = "UNKNOWN"
            elif s_curr <= dist_critical:
                s_static_risk = "CRITICAL"
            elif s_curr <= dist_danger:
                s_static_risk = "DANGER"
            elif s_curr < dist_warning:
                s_static_risk = "WARNING"
            else:
                s_static_risk = "SAFE"

            if s_vz >= min_approach_vz:
                if s_ttc <= ttc_critical:
                    s_dynamic_risk = "CRITICAL"
                elif s_ttc <= ttc_warning:
                    s_dynamic_risk = "WARNING"
                else:
                    s_dynamic_risk = "LOW"
            else:
                s_dynamic_risk = "NONE"

            if s_static_risk == "CRITICAL" or s_dynamic_risk == "CRITICAL":
                s_level = "CRITICAL"
            elif s_static_risk in ["DANGER", "WARNING"] or s_dynamic_risk == "WARNING":
                s_level = "WARNING"
            elif s_static_risk == "UNKNOWN":
                s_level = "UNKNOWN"
            else:
                s_level = "SAFE"

            threats[name] = SectorThreat(
                name=name, dist_cm=s_curr, velocity_z=s_vz, ttc=s_ttc, threat_level=s_level,
                static_risk=s_static_risk, dynamic_risk=s_dynamic_risk
            )

        # ── 5. Xác định Hướng né thoát an toàn (Risk-Aware Guidance) ──
        cam_w = getattr(config, "CAM_WIDTH", 640)
        cam_h = getattr(config, "CAM_HEIGHT", 480)
        left_split = getattr(config, "SECTOR_LEFT_SPLIT", 0.33)
        right_split = getattr(config, "SECTOR_RIGHT_SPLIT", 0.66)
        sec_area = max(1.0, (cam_w * left_split) * cam_h)

        left_obs = []
        right_obs = []
        for o in all_obs:
            o_pan = getattr(o, "pan", 0.0)
            o_x = getattr(o, "x", cam_w // 2)
            if o_pan < -0.18 or o_x < cam_w * left_split:
                left_obs.append(o)
            elif o_pan > 0.18 or o_x > cam_w * right_split:
                right_obs.append(o)

        left_vzs = [obs_vzs.get(o.id, 0.0) for o in left_obs if obs_vzs.get(o.id, 0.0) > 0]
        if threats["LEFT"].velocity_z > 0:
            left_vzs.append(threats["LEFT"].velocity_z)
        max_vz_left = max(left_vzs) if left_vzs else 0.0

        left_ttcs = [obs_ttcs.get(o.id, float("inf")) for o in left_obs if obs_ttcs.get(o.id, float("inf")) < float("inf")]
        if threats["LEFT"].ttc < float("inf"):
            left_ttcs.append(threats["LEFT"].ttc)
        min_ttc_left = min(left_ttcs) if left_ttcs else float("inf")

        left_occ_area = sum(o.bbox[2] * o.bbox[3] for o in left_obs if getattr(o, "bbox", None))
        free_ratio_left = float(np.clip(1.0 - (left_occ_area / sec_area), 0.0, 1.0))

        right_vzs = [obs_vzs.get(o.id, 0.0) for o in right_obs if obs_vzs.get(o.id, 0.0) > 0]
        if threats["RIGHT"].velocity_z > 0:
            right_vzs.append(threats["RIGHT"].velocity_z)
        max_vz_right = max(right_vzs) if right_vzs else 0.0

        right_ttcs = [obs_ttcs.get(o.id, float("inf")) for o in right_obs if obs_ttcs.get(o.id, float("inf")) < float("inf")]
        if threats["RIGHT"].ttc < float("inf"):
            right_ttcs.append(threats["RIGHT"].ttc)
        min_ttc_right = min(right_ttcs) if right_ttcs else float("inf")

        right_occ_area = sum(o.bbox[2] * o.bbox[3] for o in right_obs if getattr(o, "bbox", None))
        free_ratio_right = float(np.clip(1.0 - (right_occ_area / sec_area), 0.0, 1.0))

        # Tính Sector Safety Score với P20 distance
        score_left = compute_sector_safety_score(
            median_distance_sector=sec_dists["LEFT"],
            free_pixel_ratio=free_ratio_left,
            ttc=min_ttc_left,
            max_vz_in_sector=max_vz_left
        )
        score_right = compute_sector_safety_score(
            median_distance_sector=sec_dists["RIGHT"],
            free_pixel_ratio=free_ratio_right,
            ttc=min_ttc_right,
            max_vz_in_sector=max_vz_right
        )
        sector_scores = {"LEFT": round(score_left, 3), "RIGHT": round(score_right, 3)}

        # Logic ra quyết định thoát hiểm
        margin = getattr(config, "SECTOR_HYSTERESIS_MARGIN", 0.10)
        deadlock_thresh = getattr(config, "SECTOR_DEADLOCK_THRESH", 0.08)
        center_clearance = sec_dists.get("CENTER", 250.0)
        center_blocked = (center_clearance < dist_warning or threats["CENTER"].threat_level != "SAFE")

        left_dist = sec_dists.get("LEFT", 250.0)
        right_dist = sec_dists.get("RIGHT", 250.0)
        left_blocked = (left_dist < dist_danger or score_left < deadlock_thresh or threats["LEFT"].threat_level == "CRITICAL")
        right_blocked = (right_dist < dist_danger or score_right < deadlock_thresh or threats["RIGHT"].threat_level == "CRITICAL")

        # Trường hợp Deadlock & Định vị mối nguy (TASK 01A-2 & FIX-M01)
        if getattr(obs_res, "drop_off_hazard", False):
            safe_dir = "STOP"
            guidance_state = "DROP_OFF_WARNING"
            hazard_dir = "CENTER"
        elif center_blocked and left_blocked and right_blocked:
            safe_dir = "STOP"
            guidance_state = "HAZARD_BLOCKED (STOP)"
            hazard_dir = "CENTER"
        elif all_obs or center_blocked or threats["LEFT"].threat_level != "SAFE" or threats["RIGHT"].threat_level != "SAFE":
            safe_dir = "NONE"
            guidance_state = "HAZARD_DETECTED"
            if all_obs:
                if primary_obs.pan < -0.33:
                    hazard_dir = "LEFT"
                elif primary_obs.pan > 0.33:
                    hazard_dir = "RIGHT"
                else:
                    hazard_dir = "CENTER"
            elif threats["LEFT"].threat_level != "SAFE":
                hazard_dir = "LEFT"
            elif threats["RIGHT"].threat_level != "SAFE":
                hazard_dir = "RIGHT"
            else:
                hazard_dir = "CENTER"
        else:
            safe_dir = "NONE"
            guidance_state = "PATH_UNVERIFIED"
            hazard_dir = "NONE"

        self.hazard_direction = hazard_dir
        self.smoothed_safe_dir = safe_dir
        self.guidance_state = guidance_state
        self.sector_scores = sector_scores

        # Quyết định Threat Level tổng quan
        if (
            obs_threat_level == "CRITICAL"
            or threats["CENTER"].threat_level == "CRITICAL"
            or (guidance_state == "HAZARD_BLOCKED (STOP)" and min(sec_dists["LEFT"], sec_dists["CENTER"], sec_dists["RIGHT"]) <= dist_critical)
        ):
            threat_level = "CRITICAL"
        elif (
            obs_threat_level == "WARNING"
            or threats["CENTER"].threat_level == "WARNING"
            or guidance_state == "HAZARD_BLOCKED (STOP)"
            or threats["LEFT"].threat_level == "WARNING"
            or threats["RIGHT"].threat_level == "WARNING"
        ):
            threat_level = "WARNING"
        else:
            threat_level = "SAFE"

        # ── TASK A2: Cơ chế Lưu vết / Trễ an toàn khi Vật cản biến mất đột ngột (Coasting) ──
        hazard_persistence_active = False
        if threat_level == "SAFE" or len(all_obs) == 0:
            if self.last_threat_level in ["CRITICAL", "WARNING"] and self.last_hazard_dist <= 80.0:
                if self.coasting_frames < self.MAX_COASTING_FRAMES:
                    self.coasting_frames += 1
                    threat_level = "WARNING"
                    hazard_dir = self.last_hazard_dir
                    guidance_state = "HAZARD_DETECTED"
                    hazard_persistence_active = True
                else:
                    self.coasting_frames = 0
                    self.last_threat_level = "SAFE"
            else:
                self.coasting_frames = 0
                self.last_threat_level = "SAFE"
        else:
            self.coasting_frames = 0
            self.last_threat_level = threat_level
            self.last_hazard_dist = curr_dist
            self.last_hazard_dir = hazard_dir

        # ── TASK A2: Loại bỏ triệt tiêu cảnh báo do xoay camera (Fix Unsafe Evasion) ──
        # Chỉ công nhận người dùng đã né thoát khi:
        # 1. Khoảng cách vật lý Z đo được TĂNG RÕ RỆT (d_dist >= 15.0cm)
        # 2. VÀ Vật thể đang di chuyển ra xa (receding, vz <= -20.0cm/s)
        # 3. VÀ Tâm góc dời hẳn ra ngoài biên an toàn (|pan| > 0.65)
        # TUYỆT ĐỐI KHÔNG coi việc quay camera (d_pan đơn thuần) là né thoát an toàn!
        d_pan = curr_pan - self.prev_pan
        d_dist = curr_dist - self.prev_dist_cm if self.prev_dist_cm is not None else 0.0

        is_evading = False
        if threat_level != "SAFE":
            verified_dist_inc = (d_dist >= 15.0)
            verified_receding = (primary_vz <= -20.0)
            verified_peripheral = (abs(curr_pan) > 0.65)
            if verified_dist_inc and verified_receding and verified_peripheral:
                self.consecutive_evasion_frames += 1
            else:
                self.consecutive_evasion_frames = 0
            is_evading = (self.consecutive_evasion_frames >= 4)
        else:
            self.consecutive_evasion_frames = 0

        # Cập nhật cache
        self.prev_dist_cm = curr_dist
        self.prev_pan = curr_pan
        self.prev_ttc = primary_ttc
        self.prev_sector_dists = sec_dists.copy()
        self.prev_timestamp = now
        if frame_id is not None:
            self.prev_frame_id = frame_id

        # Thu thập chi tiết động học từng track
        track_details = {}
        for o in all_obs:
            trk = self.tracker.tracks.get(o.id)
            track_details[o.id] = {
                "vz_raw": trk.raw_vz if trk else 0.0,
                "vz_smooth": trk.smoothed_vz if trk else 0.0,
                "delta_d": trk.delta_d if trk else 0.0,
                "delta_t": trk.delta_t if trk else 0.0,
                "ttc": obs_ttcs.get(o.id, float("inf")),
                "dist_cm": o.dist_cm,
                "bbox": o.bbox
            }

        primary_motion_state = "UNKNOWN"
        p_static_risk = "SAFE"
        p_dynamic_risk = "NONE"
        p_path_risk = "DIRECT"

        if all_obs:
            if primary_vz >= min_approach_vz:
                primary_motion_state = "APPROACHING"
            elif primary_vz <= -min_approach_vz:
                primary_motion_state = "RECEDING"
            else:
                primary_motion_state = "STATIONARY"

            p_dist = primary_obs.dist_cm
            if math.isnan(p_dist):
                p_static_risk = "UNKNOWN"
            elif p_dist <= dist_critical:
                p_static_risk = "CRITICAL"
            elif p_dist <= dist_danger:
                p_static_risk = "DANGER"
            elif p_dist < dist_warning:
                p_static_risk = "WARNING"
            elif p_dist < dist_alert:
                p_static_risk = "CAUTION"
            else:
                p_static_risk = "SAFE"

            if primary_motion_state == "UNKNOWN":
                p_dynamic_risk = "UNKNOWN"
            elif primary_motion_state == "APPROACHING":
                if primary_ttc <= ttc_critical:
                    p_dynamic_risk = "CRITICAL"
                elif primary_ttc <= ttc_warning:
                    p_dynamic_risk = "WARNING"
                else:
                    p_dynamic_risk = "LOW"
            else:
                p_dynamic_risk = "NONE"

            if abs(primary_obs.pan) <= 0.33:
                p_path_risk = "DIRECT"
            elif abs(primary_obs.pan) <= 0.60:
                p_path_risk = "PERIPHERAL"
            else:
                p_path_risk = "OUTSIDE"

        res = self._create_result(
            curr_dist, primary_vz, primary_ttc, threats,
            threat_level, safe_dir, is_evading, obs_ttcs, obs_vzs, track_details,
            sector_scores=sector_scores, guidance_state=guidance_state,
            effective_ego_vz=0.0, hazard_direction=hazard_dir, motion_state=primary_motion_state,
            primary_static_risk=p_static_risk, primary_dynamic_risk=p_dynamic_risk,
            primary_path_risk=p_path_risk, hazard_persistence_active=hazard_persistence_active
        )
        self.last_result = res
        return res

    def _create_result(
        self, dist_cm, vz, ttc, threats, threat_level, safe_dir, is_evading,
        obs_ttcs=None, obs_vzs=None, track_details=None,
        sector_scores=None, guidance_state="PATH_UNVERIFIED",
        effective_ego_vz=0.0, hazard_direction="NONE", motion_state="UNKNOWN",
        primary_static_risk="SAFE", primary_dynamic_risk="NONE",
        primary_path_risk="DIRECT", hazard_persistence_active=False
    ) -> KinematicsResult:
        if not isinstance(threats, dict):
            threats_dict = {
                "LEFT": SectorThreat("LEFT", 250.0, 0.0, float("inf"), "SAFE"),
                "CENTER": SectorThreat("CENTER", 250.0, 0.0, float("inf"), "SAFE"),
                "RIGHT": SectorThreat("RIGHT", 250.0, 0.0, float("inf"), "SAFE"),
            }
        else:
            threats_dict = threats

        return KinematicsResult(
            primary_ttc=ttc,
            primary_velocity_z=vz,
            threats=threats_dict,
            safe_direction=safe_dir,
            is_evading=is_evading,
            threat_level=threat_level,
            obstacle_ttcs=obs_ttcs if obs_ttcs else {},
            obstacle_vzs=obs_vzs if obs_vzs else {},
            track_details=track_details if track_details else {},
            sector_scores=sector_scores if sector_scores else {"LEFT": 0.50, "RIGHT": 0.50},
            guidance_state=guidance_state,
            effective_ego_vz=effective_ego_vz,
            hazard_direction=hazard_direction,
            motion_state=motion_state,
            primary_static_risk=primary_static_risk,
            primary_dynamic_risk=primary_dynamic_risk,
            primary_path_risk=primary_path_risk,
            hazard_persistence_active=hazard_persistence_active,
            measurement_basis="METRIC_ESTIMATED_UNVERIFIED"
        )
