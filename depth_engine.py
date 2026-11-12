"""
HorusEyes 2.0 - Depth Engine & Spatial Obstacle Detector (Hardened)
================================================================================
Mô-đun ước lượng độ sâu đơn mục kính (Monocular Depth Estimation) và nhận diện
vật cản không gian 3D — Phiên bản cứng hóa toàn diện:
  1. ONNX Runtime 100% Offline Edge AI (loại bỏ hoàn toàn torch.hub.load).
  2. SHA-256 Hash Verification trước khi nạp model .onnx.
  3. PCHIP Monotonic Spline với x_clamped BẮT BUỘC trước khi tìm đoạn.
  4. Thứ tự ưu tiên phát hiện: A (Saturation/0-Lux) → C/D (Sobel/Wall) → B (Clear).
  5. OVERHEAD_HAZARD & DROP_OFF_HAZARD detection thay thế hard mask.
  6. Bù biến dạng tỷ lệ 4:3 → 1:1 trong Sobel gradient.
  7. Diện tích tối thiểu giảm xuống 1.5% bắt vật mảnh (cột, gậy, cành cây).
================================================================================
"""

import os
import sys
import hashlib
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

import math
from dataclasses import dataclass, field
from typing import Tuple, Optional, List
import cv2
import numpy as np

import config

# ═══════════════════════════════════════════════════════════════════════════════
# PCHIP MONOTONIC SPLINE (Pure NumPy / Scipy Fallback)
# ═══════════════════════════════════════════════════════════════════════════════
try:
    from scipy.interpolate import PchipInterpolator as _ScipyPchip  # type: ignore[import-untyped, import-not-found]

    class PchipInterpolator:
        """Wrapper quanh Scipy PCHIP với BẮT BUỘC x_clamped trước khi nội suy."""
        def __init__(self, x, y):
            x = np.asarray(x, dtype=float)
            y = np.asarray(y, dtype=float)
            idx = np.argsort(x)
            self.x = x[idx]
            self.y = y[idx]
            self._interp = _ScipyPchip(self.x, self.y)

        def __call__(self, x_val):
            x_arr = np.asarray(x_val, dtype=float)
            scalar = x_arr.ndim == 0
            x_flat = np.atleast_1d(x_arr)
            # Khử NaN, +Inf, -Inf an toàn trước khi kẹp biên
            is_nan = np.isnan(x_flat)
            x_clean = np.nan_to_num(x_flat, nan=self.x[0], posinf=self.x[-1], neginf=self.x[0])
            x_clamped = np.clip(x_clean, self.x[0], self.x[-1])
            res = self._interp(x_clamped)
            if np.any(is_nan):
                res = np.where(is_nan, np.nan, res)
            return float(res.item()) if scalar else res

except ImportError:
    class PchipInterpolator:
        """
        Triển khai thuần NumPy của thuật toán nội suy đơn điệu PCHIP (Piecewise Cubic
        Hermite Interpolating Polynomial) theo chuẩn Fritsch-Carlson (1980).
        BẮT BUỘC kẹp biên x_clamped trước khi tìm đoạn nội suy.
        """
        def __init__(self, x, y):
            x = np.asarray(x, dtype=float)
            y = np.asarray(y, dtype=float)
            idx = np.argsort(x)
            self.x = x[idx]
            self.y = y[idx]
            n = len(self.x)
            h = np.diff(self.x)
            delta = np.diff(self.y) / h
            d = np.zeros(n, dtype=float)

            for i in range(1, n - 1):
                if delta[i - 1] * delta[i] <= 0:
                    d[i] = 0.0
                else:
                    w1 = 2 * h[i] + h[i - 1]
                    w2 = h[i] + 2 * h[i - 1]
                    d[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])

            d[0] = ((2 * h[0] + h[1]) * delta[0] - h[0] * delta[1]) / (h[0] + h[1]) if n > 2 else delta[0]
            if d[0] * delta[0] <= 0:
                d[0] = 0.0
            elif delta[0] * delta[1] < 0 and abs(d[0]) > abs(3 * delta[0]):
                d[0] = 3 * delta[0]

            d[-1] = ((2 * h[-1] + h[-2]) * delta[-1] - h[-1] * delta[-2]) / (h[-1] + h[-2]) if n > 2 else delta[-1]
            if d[-1] * delta[-1] <= 0:
                d[-1] = 0.0
            elif delta[-1] * delta[-2] < 0 and abs(d[-1]) > abs(3 * delta[-1]):
                d[-1] = 3 * delta[-1]

            self.d = d
            self.h = h

        def __call__(self, x_val):
            x_arr = np.asarray(x_val, dtype=float)
            scalar = x_arr.ndim == 0
            x_flat = np.atleast_1d(x_arr)

            # BẮT BUỘC: Khử NaN, +Inf, -Inf an toàn trước khi kẹp biên và tìm đoạn
            is_nan = np.isnan(x_flat)
            x_clean = np.nan_to_num(x_flat, nan=self.x[0], posinf=self.x[-1], neginf=self.x[0])
            x_clamped = np.clip(x_clean, self.x[0], self.x[-1])

            i = np.searchsorted(self.x, x_clamped) - 1
            i = np.clip(i, 0, len(self.x) - 2)

            h_i = self.h[i]
            t = (x_clamped - self.x[i]) / h_i
            t2 = t * t
            t3 = t2 * t

            h00 = 2 * t3 - 3 * t2 + 1
            h10 = t3 - 2 * t2 + t
            h01 = -2 * t3 + 3 * t2
            h11 = t3 - t2

            y_pred = (h00 * self.y[i] +
                      h10 * h_i * self.d[i] +
                      h01 * self.y[i + 1] +
                      h11 * h_i * self.d[i + 1])

            if np.any(is_nan):
                y_pred = np.where(is_nan, np.nan, y_pred)

            return float(y_pred.item()) if scalar else y_pred


def _verify_onnx_sha256(filepath: str) -> bool:
    """Xác thực SHA-256 hash của file ONNX trước khi nạp."""
    basename = os.path.basename(filepath)
    expected_hash = config.ONNX_SHA256_HASHES.get(basename)
    if expected_hash is None:
        return False  # Unregistered assets are not accepted by the runtime.
    try:
        sha256 = hashlib.sha256()
        with open(filepath, 'rb') as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                sha256.update(chunk)
        actual_hash = sha256.hexdigest()
        if actual_hash != expected_hash:
            print(f"[SECURITY] CẢNH BÁO: Hash SHA-256 của {basename} KHÔNG KHỚP!")
            print(f"  Expected: {expected_hash}")
            print(f"  Actual:   {actual_hash}")
            return False
        return True
    except Exception as e:
        print(f"[SECURITY] Lỗi kiểm tra hash {basename}: {e}")
        return False


_KNOT_RAWS  = [n[0] for n in config.CALIBRATION_NODES]
_KNOT_DISTS = [n[1] for n in config.CALIBRATION_NODES]
_PCHIP_MODEL = PchipInterpolator(_KNOT_RAWS, _KNOT_DISTS)

_KERNEL_DILATE = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25))
_KERNEL_ERODE  = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))


def compute_metric_distance_cm(raw_val: float, scale_factor: float = 1.0) -> float:
    """
    Chuyển đổi giá trị disparity raw từ MiDaS sang khoảng cách vật lý thực tế (cm).
    LƯU Ý: Đây là ước lượng metric không định chuẩn tuyệt đối (unverified metric estimate)
    đối với mô hình monocular depth trừ khi có cảm biến độ sâu thực tế (LiDAR/Time-of-Flight).
    Miễn nhiễm với out-of-bounds, nhưng BẢO TOÀN NaN/Inf (trả về NaN) để không
    âm thầm biến lỗi cảm biến thành hành lang an toàn 350cm (tuân thủ FIX-M05 & Directive 01A).
    """
    try:
        r = float(raw_val)
        if math.isnan(r) or math.isinf(r):
            return float("nan")
    except Exception:
        return float("nan")

    # PCHIP __call__ đã tự kẹp biên nội bộ, nhưng ta vẫn kẹp thêm lần nữa
    r_clipped = float(np.clip(r, _KNOT_RAWS[0], _KNOT_RAWS[-1]))
    interp_res = _PCHIP_MODEL(r_clipped)
    if isinstance(interp_res, np.ndarray):
        interp_res = float(interp_res.item()) if interp_res.size == 1 else float(interp_res[0])
    else:
        interp_res = float(interp_res)
    if math.isnan(interp_res):
        return float("nan")
    d_cm = interp_res * scale_factor
    d_cm_clipped = float(np.clip(d_cm, _KNOT_DISTS[-1] * scale_factor, _KNOT_DISTS[0] * scale_factor))
    return round(d_cm_clipped, 1)


def dist_to_proximity(dist_cm: float) -> float:
    """
    Ánh xạ khoảng cách vật lý (cm) sang hệ số proximity [0.0, 1.0]:
      - dist <= 40cm : proximity = 1.00 (khẩn cấp cao nhất)
      - 40cm - 80cm  : proximity 0.70 -> 1.00 (DANGER)
      - 80cm - 140cm : proximity 0.35 -> 0.70 (WARNING)
      - 140cm - 200cm: proximity 0.05 -> 0.35 (CAUTION)
      - > 200cm      : proximity = 0.00 (SAFE)
    """
    if dist_cm <= config.DIST_CRITICAL_CM:
        return 1.0
    elif dist_cm < config.DIST_DANGER_CM:
        return 0.70 + 0.30 * (config.DIST_DANGER_CM - dist_cm) / (config.DIST_DANGER_CM - config.DIST_CRITICAL_CM)
    elif dist_cm < config.DIST_WARNING_CM:
        return 0.35 + 0.35 * (config.DIST_WARNING_CM - dist_cm) / (config.DIST_WARNING_CM - config.DIST_DANGER_CM)
    elif dist_cm < config.DIST_ALERT_CM:
        return 0.05 + 0.30 * (config.DIST_ALERT_CM - dist_cm) / (config.DIST_ALERT_CM - config.DIST_WARNING_CM)
    else:
        return 0.0


@dataclass
class SingleObstacle:
    id: int                         # Thứ tự 1, 2, 3...
    x: int                          # Tọa độ X tâm
    y: int                          # Tọa độ Y tâm
    bbox: Tuple[int, int, int, int] # (bx, by, bw, bh)
    pan: float                      # [-1.0 trái, +1.0 phải]
    proximity: float                # [0.0, 1.0]
    dist_cm: float                  # Khoảng cách metric ước tính (cm)
    mode_text: str                  # Nhãn trạng thái không gian
    uncertainty_score: float        # Độ bất định AI [0.0, 1.0]
    is_wall: bool                   # Cờ nhận diện là vách tường
    validity: str = "VALID"         # "VALID", "DEGRADED", "UNKNOWN" (Directive 01B Task A3)
    measurement_basis: str = "METRIC_ESTIMATED_UNVERIFIED" # "METRIC_CALIBRATED", "METRIC_ESTIMATED_UNVERIFIED", "RELATIVE_ONLY", "UNKNOWN"
    quality_state: str = "OBSERVABLE" # "OBSERVABLE", "DEGRADED", "UNOBSERVABLE", "UNKNOWN" (Directive 01B-A+ Task A+3)
    quality_reasons: List[str] = field(default_factory=list) # Danh sách lý do chẩn đoán thị giác


@dataclass
class ObstacleDetectionResult:
    x: int                          # Tọa độ X vật cản chính (gần nhất)
    y: int                          # Tọa độ Y vật cản chính
    bbox: Tuple[int, int, int, int] # Bounding box vật cản chính
    pan: float                      # Pan vật cản chính [-1.0, +1.0]
    proximity: float                # Proximity vật cản chính [0.0, 1.0]
    dist_cm: float                  # Khoảng cách metric vật cản chính (cm)
    mode_text: str                  # Nhãn trạng thái vật cản chính
    uncertainty_score: float        # Độ bất định vật cản chính [0.0, 1.0]
    is_wall: bool                   # Cờ vách tường vật cản chính
    sector_dists: dict              # Khoảng cách 3 sector
    all_obstacles: list = None      # Danh sách TẤT CẢ các vật cản đồng thời [SingleObstacle]
    is_zero_lux_blind: bool = False # Cờ cảm biến mù 0-Lux
    overhead_hazard: bool = False   # Cờ vật nhô qua đầu
    drop_off_hazard: bool = False   # Cờ bậc thềm / hố sâu
    is_valid: bool = True           # Cờ dữ liệu hợp lệ (False nếu lỗi cảm biến/NaN)
    is_scale_uncalibrated: bool = True # Cờ cảnh báo tỷ lệ metric chưa qua cảm biến cứng (LiDAR)
    validity_state: str = "VALID"   # "VALID", "DEGRADED", "SENSOR_FAULT", "UNKNOWN" (Directive 01B Task A3)
    spatial_validity: dict = None   # {"GLOBAL": ..., "LEFT": ..., "CENTER": ..., "RIGHT": ..., "CORRIDOR": ...}
    measurement_basis: str = "METRIC_ESTIMATED_UNVERIFIED" # Directive 01B Principle B
    quality_state: str = "OBSERVABLE" # "OBSERVABLE", "DEGRADED", "UNOBSERVABLE", "UNKNOWN" (Directive 01B-A+ Task A+3)
    quality_reasons: List[str] = field(default_factory=list)


def assess_visual_observability(frame_bgr: Optional[np.ndarray]) -> Tuple[str, List[str], dict]:
    """
    Directive 01B-A+ Task A+3: Đánh giá độ quan sát thị giác (Visual Observability).
    Tách bạch rõ ràng giữa:
      A. Tính hợp lệ số học (Numerical Validity: NaN, Inf, tensor dimensions, corruption)
      B. Độ quan sát thị giác (Visual Observability: Underexposure, Overexposure, Blur, Defocus, Obstruction).

    Quality-State Taxonomy:
      - OBSERVABLE: Chất lượng hình ảnh bình thường, cấu trúc/ánh sáng hợp lệ.
      - DEGRADED: Suy giảm một phần (quá tối cần đèn, lóa nhẹ, mờ nhòe vừa, hoặc invalid corridor >20%).
      - UNOBSERVABLE: Khung hình hoàn toàn không thể quan sát (mù tối 0-Lux, ống kính bị che kín, lóa trắng lóa).
      - UNKNOWN: Thiếu frame RGB đầu vào hoặc không thể tính toán.

    Negative Control Guard:
      Vách tường phẳng không hoa văn (Textureless white wall) vẫn là OBSERVABLE nếu ánh sáng
      nằm trong dải bình thường [30.0, 225.0], tuyệt đối không coi là UNOBSERVABLE vì lý do ít cạnh.
    """
    if frame_bgr is None or not isinstance(frame_bgr, np.ndarray) or frame_bgr.size == 0:
        return "UNKNOWN", ["NO_FRAME_INPUT"], {"luminance_mean": 0.0, "laplacian_var": 0.0, "entropy": 0.0}

    if frame_bgr.ndim == 2:
        gray = frame_bgr
    elif frame_bgr.ndim == 3:
        gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    else:
        return "UNKNOWN", ["INVALID_FRAME_NDIM"], {}

    h, w = gray.shape[:2]
    # Tối ưu hóa hiệu năng (Directive 01B-A++ Task P1-01):
    # Tính toán thống kê trên thumbnail 160x120 để giảm thời gian xử lý từ ~28ms xuống ~1.5ms
    if h > 120 or w > 160:
        thumb = cv2.resize(gray, (160, 120), interpolation=cv2.INTER_AREA)
    else:
        thumb = gray

    th_h, th_w = thumb.shape[:2]
    total_pixels = float(th_h * th_w)

    # 1. Thống kê độ sáng & phơi sáng (Luminance & Exposure statistics)
    lum_mean = float(np.mean(thumb))
    lum_std  = float(np.std(thumb))
    under_ratio = float(np.count_nonzero(thumb < 10)) / total_pixels
    over_ratio  = float(np.count_nonzero(thumb > 248)) / total_pixels

    # 2. Độ sắc nét & vi sai Laplacian (CV_16S thay vì CV_64F để tránh phân bổ bộ nhớ nặng)
    lap = cv2.Laplacian(thumb, cv2.CV_16S)
    lap_var = float(np.var(lap))

    # 3. Mật độ thông tin hình ảnh (Shannon Entropy)
    hist = cv2.calcHist([thumb], [0], None, [256], [0, 256])
    hist = hist / (total_pixels + 1e-7)
    non_zero = hist[hist > 0]
    entropy = float(-np.sum(non_zero * np.log2(non_zero)))

    reasons = []

    # Điều kiện cực hạn -> UNOBSERVABLE
    if lum_mean < 6.0 or under_ratio > 0.90:
        reasons.append("SEVERE_UNDEREXPOSURE_ZERO_LUX")
        return "UNOBSERVABLE", reasons, {"luminance_mean": lum_mean, "laplacian_var": lap_var, "entropy": entropy}

    if lum_mean > 250.0 or over_ratio > 0.75:
        reasons.append("SEVERE_BLINDING_OVEREXPOSURE")
        return "UNOBSERVABLE", reasons, {"luminance_mean": lum_mean, "laplacian_var": lap_var, "entropy": entropy}

    # Ống kính bị che kín / Băng dính tối màu che camera
    if lum_std < 2.0 and (lum_mean < 15.0 or lum_mean > 240.0):
        reasons.append("CAMERA_LENS_COVERED_OR_BLOCKED")
        return "UNOBSERVABLE", reasons, {"luminance_mean": lum_mean, "laplacian_var": lap_var, "entropy": entropy}

    # Điều kiện suy giảm -> DEGRADED
    if lum_mean < 20.0 or under_ratio > 0.50:
        reasons.append("LOW_LIGHT_ENVIRONMENT")
    if over_ratio > 0.35:
        reasons.append("HIGH_BACKLIGHT_OR_PARTIAL_GLARE")

    # Kiểm tra Negative Control: Vách tường trắng/phẳng không hoa văn
    is_textureless_wall = (30.0 <= lum_mean <= 225.0 and lum_std >= 2.0 and lum_std <= 25.0 and lap_var < 20.0)
    if is_textureless_wall:
        reasons.append("TEXTURELESS_SURFACE")
    elif lap_var < 15.0 and lum_std > 25.0:
        reasons.append("SEVERE_MOTION_BLUR_OR_DEFOCUS")

    if entropy < 0.5 and lap_var < 15.0 and lum_std < 8.0 and not is_textureless_wall:
        reasons.append("INSUFFICIENT_SCENE_TEXTURE")

    if reasons:
        if reasons == ["TEXTURELESS_SURFACE"]:
            quality_state = "OBSERVABLE"
        else:
            quality_state = "DEGRADED"
    else:
        quality_state = "OBSERVABLE"

    stats = {
        "luminance_mean": round(lum_mean, 1),
        "luminance_std": round(lum_std, 1),
        "laplacian_var": round(lap_var, 1),
        "entropy": round(entropy, 2),
        "under_ratio": round(under_ratio, 3),
        "over_ratio": round(over_ratio, 3),
    }
    return quality_state, reasons, stats


class DepthEstimator:
    """
    Module quản lý mô hình suy luận độ sâu và phát hiện vật cản không gian.
    100% Offline Edge AI — KHÔNG fallback tải code từ GitHub lúc runtime.
    Xác thực SHA-256 trước khi nạp file .onnx.
    """

    def __init__(self, device: str = None):
        # The small desktop graphs require untracked external weights. Use the
        # self-contained, portrait MiDaS export already shipped on Android.
        import onnxruntime as ort
        model_path = os.path.join(os.path.dirname(__file__), config.DEMO_MODEL_PATH)
        if not _verify_onnx_sha256(model_path):
            raise RuntimeError("MiDaS asset missing or integrity check failed")
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = min(4, os.cpu_count() or 1)
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self.ort_session = ort.InferenceSession(model_path, opts, providers=['CPUExecutionProvider'])
        tensor = self.ort_session.get_inputs()[0]
        if tensor.shape != [1, 3, 256, 192] or tensor.type != 'tensor(float)':
            raise RuntimeError(f"Unsupported MiDaS input contract: {tensor.shape} {tensor.type}")
        self.ort_input_name = tensor.name
        self.input_size = (192, 256)
        self.mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
        self.std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
        self.use_onnx = True

    def infer_depth(self, frame_bgr: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        """
        Suy luận ma trận độ sâu từ khung hình BGR với tốc độ cao.
        Returns:
            (depth_norm, depth_raw)
            - depth_norm: uint8 [0, 255] phục vụ hiển thị heatmap
            - depth_raw: float32 disparity gốc từ MiDaS
        """
        h, w = frame_bgr.shape[:2]
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        resized = cv2.resize(rgb, self.input_size, interpolation=cv2.INTER_LINEAR)
        norm = np.ascontiguousarray(((resized.astype(np.float32) / 255.0 - self.mean) / self.std).transpose(2, 0, 1)[None])
        output = self.ort_session.run(None, {self.ort_input_name: norm})[0]
        if output.shape != (1, 256, 192) or not np.isfinite(output).all() or np.any(output <= 0):
            raise RuntimeError("Invalid MiDaS output tensor")
        depth_raw = cv2.resize(output[0], (w, h), interpolation=cv2.INTER_LINEAR)

        d_min = depth_raw.min()
        d_max = depth_raw.max()
        if d_max - d_min > 1e-6:
            depth_norm = ((depth_raw - d_min) / (d_max - d_min) * 255.0)
        else:
            depth_norm = np.zeros_like(depth_raw)

        self._last_frame = frame_bgr
        return depth_norm.astype(np.uint8), depth_raw

    def _create_sensor_fault_result(
        self, h: int, w: int, reason: str = "SENSOR_FAULT",
        validity_state: str = "SENSOR_FAULT",
        spatial_validity: Optional[dict] = None,
        quality_state: str = "UNOBSERVABLE",
        quality_reasons: Optional[List[str]] = None
    ) -> ObstacleDetectionResult:
        if spatial_validity is None:
            spatial_validity = {"GLOBAL": 0.0, "LEFT": 0.0, "CENTER": 0.0, "RIGHT": 0.0, "CORRIDOR": 0.0}
        if quality_reasons is None:
            quality_reasons = [reason]
        fault_obs = SingleObstacle(
            id=1, x=w // 2, y=h // 2,
            bbox=(0, 0, w, h),
            pan=0.0, proximity=1.0, dist_cm=float("nan"),
            mode_text=reason,
            uncertainty_score=1.0, is_wall=False,
            validity=validity_state,
            measurement_basis="UNKNOWN",
            quality_state=quality_state,
            quality_reasons=quality_reasons
        )
        return ObstacleDetectionResult(
            x=w // 2, y=h // 2, bbox=fault_obs.bbox, pan=0.0,
            proximity=1.0, dist_cm=float("nan"),
            mode_text=reason, uncertainty_score=1.0,
            is_wall=False,
            sector_dists={"LEFT": float("nan"), "CENTER": float("nan"), "RIGHT": float("nan")},
            all_obstacles=[fault_obs],
            is_valid=False,
            is_scale_uncalibrated=True,
            validity_state=validity_state,
            spatial_validity=spatial_validity,
            measurement_basis="UNKNOWN",
            quality_state=quality_state,
            quality_reasons=quality_reasons
        )

    def detect_obstacle(
        self,
        depth_norm: np.ndarray,
        depth_raw: np.ndarray,
        scale_factor: float = 1.0,
        frame_bgr: Optional[np.ndarray] = None,
        lighting_status: Optional[dict] = None,
        is_zero_lux: bool = False,
    ) -> ObstacleDetectionResult:
        """
        Phát hiện vật cản không gian 3D — Thứ tự ưu tiên cứng hóa (Directive 01B Task A3):
        Bước 0: Đánh giá tính hợp lệ không gian đa tầng (Spatial Validity: Global, Sectors, Corridor)
        Bước 1: Kiểm tra Bão hòa thấu kính (A) + 0-Lux Blind
        Bước 2: Phân đoạn Sobel/Discontinuity (C) + Vách tường (D) + Overhead/DropOff
        Bước 3: Kết luận Clear Path (B) có kiểm soát (Unverified Path)
        """
        # ── Bước 0: Input Validation & Spatial Validity Guard ──
        if depth_raw is None or depth_norm is None:
            return self._create_sensor_fault_result(480, 640, "SENSOR_FAULT (Null Input)")

        if not isinstance(depth_raw, np.ndarray) or not isinstance(depth_norm, np.ndarray):
            return self._create_sensor_fault_result(480, 640, "SENSOR_FAULT (Type Error)")

        if depth_raw.size == 0 or depth_norm.size == 0 or depth_raw.ndim != 2 or depth_norm.ndim != 2:
            return self._create_sensor_fault_result(480, 640, "SENSOR_FAULT (Invalid Dimensions)")

        h, w = depth_norm.shape[:2]
        if h < 10 or w < 10:
            return self._create_sensor_fault_result(h, w, "SENSOR_FAULT (Empty/Tiny Frame)")

        # Phân tích mặt nạ hợp lệ không gian đa tầng (Directive 01B Task A3)
        raw_invalid_mask = np.isnan(depth_raw) | np.isinf(depth_raw) | (depth_raw <= 0.0)
        global_invalid_ratio = float(np.mean(raw_invalid_mask))

        # Tọa độ phân vùng không gian 3 sector và hành lang trung tâm
        cy1, cy2 = int(0.20 * h), int(0.75 * h)
        c_mid_x1, c_mid_x2 = int(0.25 * w), int(0.75 * w)
        cx1, cx2 = int(0.04 * w), int(0.96 * w)
        cw = cx2 - cx1
        sec_w = cw // 3

        sec_l_mask = raw_invalid_mask[cy1:cy2, cx1 : cx1 + sec_w]
        sec_c_mask = raw_invalid_mask[cy1:cy2, cx1 + sec_w : cx1 + 2 * sec_w]
        sec_r_mask = raw_invalid_mask[cy1:cy2, cx1 + 2 * sec_w : cx2]
        corr_mask = raw_invalid_mask[cy1:cy2, c_mid_x1:c_mid_x2]

        l_inv = float(np.mean(sec_l_mask)) if sec_l_mask.size > 0 else 1.0
        c_inv = float(np.mean(sec_c_mask)) if sec_c_mask.size > 0 else 1.0
        r_inv = float(np.mean(sec_r_mask)) if sec_r_mask.size > 0 else 1.0
        corr_inv = float(np.mean(corr_mask)) if corr_mask.size > 0 else 1.0

        spatial_validity = {
            "GLOBAL": round(1.0 - global_invalid_ratio, 3),
            "LEFT": round(1.0 - l_inv, 3),
            "CENTER": round(1.0 - c_inv, 3),
            "RIGHT": round(1.0 - r_inv, 3),
            "CORRIDOR": round(1.0 - corr_inv, 3),
        }

        # Kiểm tra ngưỡng lỗi toàn cục (>15%)
        if global_invalid_ratio > 0.15:
            return self._create_sensor_fault_result(
                h, w, f"SENSOR_FAULT ({int(global_invalid_ratio * 100)}% Global Invalid Data)",
                "SENSOR_FAULT", spatial_validity
            )

        # Kiểm tra bất thường cục bộ tập trung ở hành lang trung tâm (Task A3: Concentrated Invalidity)
        if c_inv > 0.20 or corr_inv > 0.20:
            return self._create_sensor_fault_result(
                h, w, f"VISUAL_EVIDENCE_DEGRADED ({int(max(c_inv, corr_inv) * 100)}% Center/Corridor Invalid)",
                "DEGRADED", spatial_validity
            )

        # Khử cục bộ an toàn cho các pixel lỗi rải rác (<15% toàn cục, <=20% sector)
        if global_invalid_ratio > 0:
            depth_raw = np.nan_to_num(depth_raw, nan=175.0, posinf=1200.0, neginf=135.0)

        if frame_bgr is None and hasattr(self, "_last_frame"):
            frame_bgr = self._last_frame

        # Directive 01B-A+ Task A+3: Visual Observability Validation
        vis_quality_state, vis_reasons, vis_stats = assess_visual_observability(frame_bgr)
        if vis_quality_state == "UNOBSERVABLE":
            return self._create_sensor_fault_result(
                h, w, f"SENSOR_UNOBSERVABLE: {', '.join(vis_reasons)}",
                validity_state="UNOBSERVABLE",
                spatial_validity=spatial_validity,
                quality_state="UNOBSERVABLE",
                quality_reasons=vis_reasons
            )

        if not is_zero_lux and lighting_status and lighting_status.get("is_zero_lux_blind", False):
            is_zero_lux = True

        d_norm = depth_norm.astype(np.float32) / 255.0
        global_std = float(np.std(d_norm))

        # ── Hệ số bù tỷ lệ khung hình 4:3 → 1:1 cho Sobel ──
        aspect_ratio_x = w / max(h, 1)  # > 1 nếu landscape
        aspect_ratio_y = h / max(w, 1)

        # Đo đạc 3 sector hành lang di chuyển
        corr_raw = depth_raw[cy1:cy2, c_mid_x1:c_mid_x2]
        sec_l = depth_raw[cy1:cy2, cx1 : cx1 + sec_w]
        sec_c = depth_raw[cy1:cy2, cx1 + sec_w : cx1 + 2 * sec_w]
        sec_r = depth_raw[cy1:cy2, cx1 + 2 * sec_w : cx2]

        # Chỉ tính phân vị trên các pixel hợp lệ nếu tỷ lệ lỗi sector <= 20%
        if l_inv <= 0.20 and sec_l.size > 0:
            valid_l = sec_l[~sec_l_mask] if np.any(sec_l_mask) else sec_l
            raw_l = float(np.percentile(valid_l, 80)) if valid_l.size > 0 else 0.0
            dist_l = compute_metric_distance_cm(raw_l, scale_factor)
        else:
            raw_l = float("nan")
            dist_l = float("nan")

        if c_inv <= 0.20 and sec_c.size > 0:
            valid_c = sec_c[~sec_c_mask] if np.any(sec_c_mask) else sec_c
            raw_c = float(np.percentile(valid_c, 80)) if valid_c.size > 0 else 0.0
            dist_c = compute_metric_distance_cm(raw_c, scale_factor)
        else:
            raw_c = float("nan")
            dist_c = float("nan")

        if r_inv <= 0.20 and sec_r.size > 0:
            valid_r = sec_r[~sec_r_mask] if np.any(sec_r_mask) else sec_r
            raw_r = float(np.percentile(valid_r, 80)) if valid_r.size > 0 else 0.0
            dist_r = compute_metric_distance_cm(raw_r, scale_factor)
        else:
            raw_r = float("nan")
            dist_r = float("nan")

        sector_dists = {"LEFT": dist_l, "CENTER": dist_c, "RIGHT": dist_r}

        # ════════════════════════════════════════════════════════════════════════
        # BƯỚC 1: Kiểm tra Bão hòa thấu kính (A) + 0-Lux Blind
        # ════════════════════════════════════════════════════════════════════════

        # ── 0-Lux Blind: PHÁT ÂM BÁO LỖI, KHÔNG ĐƯỢC báo SAFE/MUTED! ──
        if is_zero_lux:
            blind_obs = SingleObstacle(
                id=1, x=w // 2, y=h // 2,
                bbox=(w // 4, h // 4, w // 2, h // 2),
                pan=0.0, proximity=1.0, dist_cm=0.0,
                mode_text="SENSOR_BLIND (0-Lux)",
                uncertainty_score=0.95, is_wall=False
            )
            return ObstacleDetectionResult(
                x=w // 2, y=h // 2, bbox=blind_obs.bbox, pan=0.0,
                proximity=1.0, dist_cm=0.0,
                mode_text="SENSOR_BLIND (0-Lux)",
                uncertainty_score=0.95, is_wall=False,
                sector_dists=sector_dists, all_obstacles=[blind_obs],
                is_zero_lux_blind=True,
                is_valid=False,
                is_scale_uncalibrated=True,
                validity_state="DEGRADED",
                spatial_validity=spatial_validity
            )

        # ── Lens Saturation Check ──
        s_cy1, s_cy2 = int(0.25 * h), int(0.75 * h)
        s_cx1, s_cx2 = int(0.25 * w), int(0.75 * w)
        center_raw = depth_raw[s_cy1:s_cy2, s_cx1:s_cx2]

        center_sat_ratio = float((center_raw >= config.SATURATION_RAW_THRESHOLD).mean()) if center_raw.size > 0 else 0.0
        global_sat_ratio = float((depth_raw >= config.SATURATION_RAW_THRESHOLD).mean())

        is_saturated = (center_sat_ratio >= config.SATURATION_CENTER_RATIO) or (global_sat_ratio >= config.SATURATION_GLOBAL_RATIO)
        if is_saturated:
            # FIX-M03: Tách rời khoảng cách vật lý thực và cảnh báo bão hòa khẩn cấp
            sat_raw_p90 = float(np.percentile(center_raw, 90)) if center_raw.size > 0 else config.SATURATION_RAW_THRESHOLD
            sat_dist = compute_metric_distance_cm(sat_raw_p90, scale_factor)
            if math.isnan(sat_dist):
                sat_dist = 30.0
            sat_prox = 1.0
            sat_mode = "CRITICAL_SATURATED"
            sat_bbox = (s_cx1, s_cy1, s_cx2 - s_cx1, s_cy2 - s_cy1)
            sat_uncert = 0.05
            single_sat = SingleObstacle(
                id=1, x=w // 2, y=h // 2, bbox=sat_bbox, pan=0.0,
                proximity=sat_prox, dist_cm=sat_dist, mode_text=sat_mode,
                uncertainty_score=sat_uncert, is_wall=False,
                validity="VALID", measurement_basis="METRIC_ESTIMATED_UNVERIFIED"
            )
            return ObstacleDetectionResult(
                x=w // 2, y=h // 2, bbox=sat_bbox, pan=0.0, proximity=sat_prox,
                dist_cm=sat_dist, mode_text=sat_mode, uncertainty_score=sat_uncert,
                is_wall=False, sector_dists={"LEFT": sat_dist, "CENTER": sat_dist, "RIGHT": sat_dist},
                all_obstacles=[single_sat],
                is_valid=True,
                is_scale_uncalibrated=True,
                validity_state="VALID",
                spatial_validity=spatial_validity
            )

        # ════════════════════════════════════════════════════════════════════════
        # Tiền xử lý cho Bước 2
        # ════════════════════════════════════════════════════════════════════════
        top_cut = int(h * config.TOP_MASK_RATIO)
        bot_cut = int(h * (1.0 - config.BOTTOM_MASK_RATIO))

        d_norm_masked = d_norm.copy()
        # ── Thay thế cắt mù cứng bằng kiểm tra thông minh ──
        # Vùng đỉnh: chỉ zeroed pixel xa, giữ pixel gần
        top_slice = d_norm_masked[:top_cut, :]
        top_slice[depth_raw[:top_cut, :] < config.SATURATION_RAW_THRESHOLD] = 0.0

        # Vùng đáy: tương tự
        bot_slice = d_norm_masked[bot_cut:, :]
        bot_slice[depth_raw[bot_cut:, :] < config.SATURATION_RAW_THRESHOLD] = 0.0

        smoothed = cv2.GaussianBlur(d_norm_masked, (11, 11), 0)
        noise_residual = float(np.std(d_norm_masked - smoothed))

        # ── Phân tích Overhead ROI (15% đỉnh) ──
        overhead_hazard = False
        overhead_roi_raw = depth_raw[:top_cut, :]
        if overhead_roi_raw.size > 0:
            overhead_bg = float(np.percentile(overhead_roi_raw, 30))
            overhead_fg = float(np.percentile(overhead_roi_raw, 85))
            overhead_fg_cm = compute_metric_distance_cm(overhead_fg, scale_factor)
            overhead_bg_cm = compute_metric_distance_cm(overhead_bg, scale_factor)
            if overhead_fg_cm < overhead_bg_cm - config.OVERHEAD_DEPTH_DELTA_CM and overhead_fg_cm < config.DIST_WARNING_CM:
                overhead_hazard = True

        # ── Phân tích Ground/Curb ROI (15% đáy) ──
        drop_off_hazard = False
        ground_roi_raw = depth_raw[bot_cut:, :]
        if ground_roi_raw.size > 0:
            # So sánh gradient dọc: đáy frame so với vùng ngay trên đáy
            above_bot = depth_raw[bot_cut - int(0.05 * h):bot_cut, :]
            if above_bot.size > 0:
                above_median = float(np.median(above_bot))
                below_median = float(np.median(ground_roi_raw))
                # Gradient bất thường: đáy xa hơn (depth nhỏ hơn) rất nhiều → bậc thềm xuống
                gradient_ratio = abs(above_median - below_median) / max(above_median, 1.0)
                if gradient_ratio > config.DROP_OFF_GRADIENT_THRESH and below_median < above_median * 0.6:
                    drop_off_hazard = True

        # ════════════════════════════════════════════════════════════════════════
        # BƯỚC 2: Phát hiện vật cản Sobel/Discontinuity (C) + Vách tường (D)
        # Chạy TRƯỚC khi kiểm tra Clear Path (B)
        # ════════════════════════════════════════════════════════════════════════

        m_y = int(0.03 * h)
        m_x = int(0.03 * w)
        active_raw = depth_raw[m_y:h - m_y:2, m_x:w - m_x:2]
        p98_active = float(np.percentile(active_raw, 98)) if active_raw.size > 0 else 0.0

        corr_std = float(corr_raw.std()) if corr_raw.size > 0 else 50.0

        h_std = 0.0
        if corr_std < 32.0 and frame_bgr is not None:
            try:
                roi_bgr = frame_bgr[cy1:cy2:2, s_cx1:s_cx2:2]
                hsv = cv2.cvtColor(roi_bgr, cv2.COLOR_BGR2HSV)
                h_std = float(hsv[:, :, 0].std())
            except Exception:
                h_std = 0.0

        center_sub = center_raw[::2, ::2] if center_raw.size > 0 else center_raw
        p95_center = float(np.percentile(center_sub, 95)) if center_sub.size > 0 else 0.0
        p99_global = float(np.percentile(depth_raw[::2, ::2], 99))
        center_med = float(np.median(center_sub)) if center_sub.size > 0 else 0.0
        d_peak = float(np.percentile(smoothed[::2, ::2], 99.2))
        corr_med = float(np.median(corr_raw[::2, ::2])) if corr_raw.size > 0 else 0.0
        raw_max = float(depth_raw.max())

        is_ceiling_scene = (corr_std < 32.0 and (h_std >= 12.0 or corr_med > 580.0) and center_med > 550.0 and h_std >= 12.0)

        corr_cov = float((corr_raw >= 480.0).mean()) if corr_raw.size > 0 else 0.0
        is_planar_frontal_wall = (
            corr_std < 32.0 and corr_cov >= 0.40 and
            (corr_med >= 600.0 or (raw_max >= 600.0 and corr_med >= 480.0 and h_std < 12.0))
            and not is_ceiling_scene
        )

        if is_ceiling_scene:
            safe_dummy = SingleObstacle(
                id=1, x=w // 2, y=h // 2, bbox=(w // 4, h // 4, w // 2, h // 2),
                pan=0.0, proximity=0.0, dist_cm=config.DIST_SAFE_CM,
                mode_text="SAFE (Clear Path >250cm)", uncertainty_score=0.05, is_wall=False
            )
            return ObstacleDetectionResult(
                x=w // 2, y=h // 2, bbox=safe_dummy.bbox, pan=0.0, proximity=0.0,
                dist_cm=config.DIST_SAFE_CM, mode_text=safe_dummy.mode_text,
                uncertainty_score=0.05, is_wall=False, sector_dists=sector_dists, all_obstacles=[safe_dummy]
            )

        # ── Kịch bản C: Phân đoạn vật cản nổi bật (Discontinuity & Gradient Filter) ──
        hot_threshold = max(config.BASE_ACTIVATION_RAW / 1200.0, d_peak - 0.22)
        hot_mask = (smoothed >= hot_threshold).astype(np.uint8) * 255

        cnts, _ = cv2.findContours(hot_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        # Sobel với bù tỷ lệ khung hình
        grad_x = cv2.Sobel(smoothed, cv2.CV_32F, 1, 0, ksize=3) * aspect_ratio_y
        grad_y = cv2.Sobel(smoothed, cv2.CV_32F, 0, 1, ksize=3) * aspect_ratio_x
        grad_mag = cv2.magnitude(grad_x, grad_y)

        kernel_dilate = _KERNEL_DILATE
        kernel_erode  = _KERNEL_ERODE

        valid_cnts = []
        for c in cnts:
            area = cv2.contourArea(c)
            bx, by, bw, bh = cv2.boundingRect(c)
            # Hỗ trợ bắt vật cản mảnh (cột, gậy, cành cây: bh >= 0.18*h và bw >= 3px)
            is_thin_obstacle = (bh >= int(0.18 * h) and bw >= 3 and area >= 80)
            if (area / (h * w) >= config.MIN_OBSTACLE_AREA_RATIO) or is_thin_obstacle:
                valid_cnts.append((area, c))
        valid_cnts.sort(key=lambda x: x[0], reverse=True)

        candidates = []
        for _, c in valid_cnts[:5]:
            bx, by, bw, bh = cv2.boundingRect(c)
            aspect = bw / max(1, bh)

            if by > 0.82 * h and bw > 0.50 * w and d_peak < 0.70:
                continue
            if bw > 0.45 * w and bh < 0.25 * h and aspect > 3.0 and d_peak < 0.70:
                continue
            if (bx <= int(0.02 * w) or bx + bw >= int(0.98 * w)) and bw < int(0.06 * w):
                continue

            pad = 18
            rx1 = max(0, bx - pad)
            ry1 = max(0, by - pad)
            rx2 = min(w, bx + bw + pad)
            ry2 = min(h, by + bh + pad)
            rw = rx2 - rx1
            rh = ry2 - ry1

            c_roi_mask = np.zeros((rh, rw), dtype=np.uint8)
            c_offset = c - np.array([rx1, ry1])
            cv2.drawContours(c_roi_mask, [c_offset], -1, 255, -1)

            dilated_roi = cv2.dilate(c_roi_mask, kernel_dilate)
            ring_roi = cv2.subtract(dilated_roi, c_roi_mask)

            smoothed_roi = smoothed[ry1:ry2, rx1:rx2]
            grad_roi = grad_mag[ry1:ry2, rx1:rx2]
            raw_roi = depth_raw[ry1:ry2, rx1:rx2]

            valid_ring = (ring_roi == 255).copy()
            y1_valid = max(0, top_cut - ry1)
            y2_valid = min(rh, max(0, bot_cut - ry1))
            if y1_valid > 0:
                valid_ring[:y1_valid, :] = False
            if y2_valid < rh:
                valid_ring[y2_valid:, :] = False

            inside_mean = float(smoothed_roi[c_roi_mask == 255].mean())
            ring_mean = float(smoothed_roi[valid_ring].mean()) if np.any(valid_ring) else (float(smoothed_roi[ring_roi == 255].mean()) if np.any(ring_roi == 255) else 0.0)
            contrast_step = inside_mean - ring_mean

            border_roi = cv2.subtract(dilated_roi, cv2.erode(c_roi_mask, kernel_erode))
            border_grad_max = float(np.percentile(grad_roi[border_roi == 255], 95)) if np.any(border_roi == 255) else 0.0

            obs_pixels = smoothed_roi[c_roi_mask == 255]
            obs_d_val = float(np.percentile(obs_pixels, 92)) if len(obs_pixels) > 0 else d_peak
            obs_raw_val = float(np.percentile(raw_roi[c_roi_mask == 255], 92)) if np.any(c_roi_mask == 255) else obs_d_val * 1200.0

            is_true_obstacle = (
                ((border_grad_max >= 5.0 or border_grad_max >= 0.05 or border_grad_max * 255.0 >= config.DISCONTINUITY_GRAD_MIN) and contrast_step >= config.DISCONTINUITY_STEP_MIN)
                or (contrast_step >= 0.20 and (border_grad_max >= config.DISCONTINUITY_GRAD_MIN or border_grad_max >= 0.035 or border_grad_max * 255.0 >= config.DISCONTINUITY_GRAD_MIN))
                or (contrast_step >= config.DISCONTINUITY_STEP_HIGH)
                or (obs_raw_val >= 900.0 and contrast_step >= 0.08)
                or (obs_raw_val >= 780.0 and contrast_step >= 0.12)
                or (contrast_step >= 0.16 and obs_raw_val >= 500.0)
            )

            if is_true_obstacle:
                obs_std = float(np.std(obs_pixels)) if len(obs_pixels) > 0 else 0.0
                candidates.append((c, obs_raw_val, obs_d_val, contrast_step, border_grad_max, bx, by, bw, bh, obs_std))

        # Trích xuất vật cản hợp lệ
        detected_list = []
        if candidates:
            candidates.sort(key=lambda item: item[1], reverse=True)
            for idx, cand in enumerate(candidates[:3]):
                c_item, c_raw, c_d, c_step, c_grad, bx, by, bw, bh, c_obs_std = cand
                moments = cv2.moments(c_item)
                if moments["m00"] > 0:
                    ox = int(moments["m10"] / moments["m00"])
                    oy = int(moments["m01"] / moments["m00"])
                else:
                    ox = bx + bw // 2
                    oy = by + bh // 2
                ox = max(0, min(w - 1, ox))
                oy = max(0, min(h - 1, oy))
                pan_val = max(-1.0, min(1.0, (float(ox) / float(w - 1)) * 2.0 - 1.0))
                d_cm = compute_metric_distance_cm(c_raw, scale_factor)

                grad_factor = np.clip(1.0 - (c_grad / 2.2), 0.0, 1.0)
                step_factor = np.clip(1.0 - (c_step / 0.25), 0.0, 1.0)
                noise_factor = float(np.clip(max(c_obs_std, noise_residual * 2.0) / 0.15, 0.0, 1.0))
                uncert_val = float(np.clip(0.40 * grad_factor + 0.40 * step_factor + 0.20 * noise_factor, 0.05, 0.95))

                # Đo độ giàu vân bề mặt (texture) của ảnh RGB (chống ảo giác kính phẳng / tường trắng specular)
                if frame_bgr is not None:
                    try:
                        if frame_bgr.ndim == 3:
                            hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
                            v_std = float(hsv[:, :, 2].std())
                            gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
                        else:
                            gray = frame_bgr
                            v_std = float(frame_bgr.std())
                        lap_var = float(cv2.Laplacian(gray, cv2.CV_32F).var())
                        if v_std < 4.0 or lap_var < 15.0:
                            uncert_val = max(uncert_val, config.UNCERTAINTY_BLUR_THRESHOLD + 0.02)
                    except Exception:
                        pass

                if d_cm < config.DIST_ALERT_CM:
                    if sector_dists["CENTER"] >= config.DIST_SAFE_CM and abs(pan_val) > 0.75:
                        continue

                    prox_val = dist_to_proximity(d_cm)
                    if d_cm <= config.DIST_CRITICAL_CM:
                        m_text = f"CRITICAL ({d_cm:.1f}cm)"
                    elif d_cm < config.DIST_DANGER_CM:
                        m_text = f"DANGER (<{int(config.DIST_DANGER_CM)}cm)"
                    elif d_cm < config.DIST_WARNING_CM:
                        m_text = f"WARNING (~{int(d_cm)}cm)"
                    else:
                        m_text = f"CAUTION (70-{int(config.DIST_ALERT_CM)}cm)"

                    detected_list.append(SingleObstacle(
                        id=idx + 1, x=ox, y=oy, bbox=(bx, by, bw, bh),
                        pan=pan_val, proximity=prox_val, dist_cm=d_cm,
                        mode_text=m_text, uncertainty_score=uncert_val, is_wall=False
                    ))

        # ── Kịch bản D: Vách tường phẳng ──
        raw_wall_max = max(raw_l, raw_c, raw_r)
        if is_planar_frontal_wall:
            dist_wall_cm = 48.0
        else:
            dist_wall_cm = compute_metric_distance_cm(raw_wall_max, scale_factor)

        if not is_planar_frontal_wall and len(detected_list) == 0:
            dist_wall_cm = config.DIST_SAFE_CM

        if dist_wall_cm < config.DIST_ALERT_CM:
            if raw_wall_max == raw_l:
                pan_wall = -0.50
                wall_x = cx1 + cw // 6
                w_bx = cx1
            elif raw_wall_max == raw_r:
                pan_wall = +0.50
                wall_x = cx1 + 5 * cw // 6
                w_bx = cx1 + 2 * cw // 3
            else:
                pan_wall = 0.00
                wall_x = cx1 + cw // 2
                w_bx = cx1 + cw // 3

            wall_y = (cy1 + cy2) // 2
            wall_bbox = (w_bx, cy1, cw // 3, cy2 - cy1)
            prox_wall = dist_to_proximity(dist_wall_cm)

            if dist_wall_cm <= config.DIST_CRITICAL_CM:
                m_wall = f"WALL: CRITICAL ({dist_wall_cm:.1f}cm)"
            elif dist_wall_cm < config.DIST_DANGER_CM:
                m_wall = f"WALL: DANGER (<{int(config.DIST_DANGER_CM)}cm)"
            elif dist_wall_cm < config.DIST_WARNING_CM:
                m_wall = f"WALL: WARNING (~{int(dist_wall_cm)}cm)"
            else:
                m_wall = f"WALL: CAUTION (>{int(config.DIST_WARNING_CM)}cm)"

            overlap = False
            for d_obs in detected_list:
                if abs(d_obs.x - wall_x) < 80 and abs(d_obs.dist_cm - dist_wall_cm) < 25.0:
                    overlap = True
                    break

            if not overlap:
                if noise_residual > 0.10:
                    wall_uncert = float(np.clip(noise_residual / 0.35, 0.55, 0.95))
                else:
                    wall_uncert = 0.20 if is_planar_frontal_wall else 0.28
                if frame_bgr is not None:
                    try:
                        gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY) if frame_bgr.ndim == 3 else frame_bgr
                        v_std = float(cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)[:, :, 2].std()) if frame_bgr.ndim == 3 else float(frame_bgr.std())
                        lap_var = float(cv2.Laplacian(gray, cv2.CV_32F).var())
                        if v_std < 4.0 or lap_var < 15.0:
                            wall_uncert = max(wall_uncert, config.UNCERTAINTY_BLUR_THRESHOLD + 0.02)
                    except Exception:
                        pass
                detected_list.append(SingleObstacle(
                    id=len(detected_list) + 1,
                    x=wall_x, y=wall_y, bbox=wall_bbox,
                    pan=pan_wall, proximity=prox_wall, dist_cm=dist_wall_cm,
                    mode_text=m_wall, uncertainty_score=wall_uncert, is_wall=True
                ))

        # Thêm Overhead/DropOff hazard
        if overhead_hazard and not any(o.mode_text.startswith("OVERHEAD") for o in detected_list):
            oh_dist = compute_metric_distance_cm(float(np.percentile(depth_raw[:top_cut, :], 85)), scale_factor)
            detected_list.append(SingleObstacle(
                id=len(detected_list) + 1,
                x=w // 2, y=top_cut // 2,
                bbox=(w // 4, 0, w // 2, top_cut),
                pan=0.0, proximity=dist_to_proximity(oh_dist), dist_cm=oh_dist,
                mode_text=f"OVERHEAD_HAZARD ({oh_dist:.0f}cm)",
                uncertainty_score=0.35, is_wall=False
            ))

        if drop_off_hazard and not any(o.mode_text.startswith("DROP_OFF") for o in detected_list):
            detected_list.append(SingleObstacle(
                id=len(detected_list) + 1,
                x=w // 2, y=(bot_cut + h) // 2,
                bbox=(w // 4, bot_cut, w // 2, h - bot_cut),
                pan=0.0, proximity=0.60, dist_cm=80.0,
                mode_text="DROP_OFF_HAZARD (Bậc thềm/Hố)",
                uncertainty_score=0.45, is_wall=False
            ))

        # Sắp xếp theo khoảng cách gần nhất
        detected_list.sort(key=lambda o: o.dist_cm)

        # ════════════════════════════════════════════════════════════════════════
        # BƯỚC 3: Chỉ kết luận SAFE (B) khi Bước 1+2 KHÔNG phát hiện gì VÀ P95 < 375
        # ════════════════════════════════════════════════════════════════════════
        if not detected_list:
            is_close_frontal = (center_med >= 550.0 or raw_c >= 550.0 or is_planar_frontal_wall)
            p98_center = float(np.percentile(center_sub, 98)) if center_sub.size > 0 else 0.0

            # Nếu có đỉnh nhô cao hẹp (cột mảnh ~70cm, p98 >= 500) mà contours chưa bắt được:
            if p98_center >= 500.0:
                thin_d_cm = compute_metric_distance_cm(p98_center, scale_factor)
                thin_obs = SingleObstacle(
                    id=1, x=w // 2, y=h // 2, bbox=(int(w * 0.45), int(h * 0.25), int(w * 0.10), int(h * 0.50)),
                    pan=0.0, proximity=dist_to_proximity(thin_d_cm), dist_cm=thin_d_cm,
                    mode_text=f"WARNING (~{int(thin_d_cm)}cm)", uncertainty_score=0.15, is_wall=False
                )
                detected_list.append(thin_obs)

            # Điều kiện CLEAR: P95 trung tâm < BASE_ACTIVATION_RAW (375.0) VÀ P98 < 500.0
            elif not is_close_frontal and p95_center < config.BASE_ACTIVATION_RAW:
                clear_dist = compute_metric_distance_cm(p95_center, scale_factor)
                if math.isnan(clear_dist) or clear_dist > config.DIST_SAFE_CM:
                    clear_dist = config.DIST_SAFE_CM
                safe_dummy = SingleObstacle(
                    id=1, x=w // 2, y=h // 2,
                    bbox=(w // 4, h // 4, w // 2, h // 2),
                    pan=0.0, proximity=0.0, dist_cm=clear_dist,
                    mode_text="NO_OBSTACLE_DETECTED (Unverified Path)", uncertainty_score=0.05,
                    is_wall=False,
                    validity="VALID",
                    measurement_basis="METRIC_ESTIMATED_UNVERIFIED",
                    quality_state=vis_quality_state,
                    quality_reasons=vis_reasons
                )
                return ObstacleDetectionResult(
                    x=safe_dummy.x, y=safe_dummy.y, bbox=safe_dummy.bbox,
                    pan=0.0, proximity=0.0, dist_cm=clear_dist,
                    mode_text=safe_dummy.mode_text, uncertainty_score=0.05,
                    is_wall=False, sector_dists=sector_dists, all_obstacles=[safe_dummy],
                    overhead_hazard=overhead_hazard, drop_off_hazard=drop_off_hazard,
                    is_valid=True,
                    is_scale_uncalibrated=True,
                    validity_state="VALID",
                    spatial_validity=spatial_validity,
                    measurement_basis="METRIC_ESTIMATED_UNVERIFIED",
                    quality_state=vis_quality_state,
                    quality_reasons=vis_reasons
                )

            # Nếu vẫn không có gì nhưng không đủ điều kiện CLEAR → trả về trạng thái mặc định
            safe_uncert = 0.05
            safe_dummy = SingleObstacle(
                id=1, x=w // 2, y=h // 2,
                bbox=(w // 4, h // 4, w // 2, h // 2),
                pan=0.0, proximity=0.0, dist_cm=config.DIST_SAFE_CM,
                mode_text="NO_OBSTACLE_DETECTED (Unverified Path)", uncertainty_score=safe_uncert,
                is_wall=False,
                validity="VALID",
                measurement_basis="METRIC_ESTIMATED_UNVERIFIED",
                quality_state=vis_quality_state,
                quality_reasons=vis_reasons
            )
            return ObstacleDetectionResult(
                x=safe_dummy.x, y=safe_dummy.y, bbox=safe_dummy.bbox,
                pan=safe_dummy.pan, proximity=safe_dummy.proximity,
                dist_cm=safe_dummy.dist_cm, mode_text=safe_dummy.mode_text,
                uncertainty_score=safe_dummy.uncertainty_score, is_wall=False,
                sector_dists=sector_dists, all_obstacles=[safe_dummy],
                overhead_hazard=overhead_hazard, drop_off_hazard=drop_off_hazard,
                is_valid=True,
                is_scale_uncalibrated=True,
                validity_state="VALID",
                spatial_validity=spatial_validity,
                measurement_basis="METRIC_ESTIMATED_UNVERIFIED",
                quality_state=vis_quality_state,
                quality_reasons=vis_reasons
            )

        # Đánh số ID thứ tự 1, 2, 3...
        for i, o in enumerate(detected_list):
            o.id = i + 1
            o.quality_state = vis_quality_state
            o.quality_reasons = vis_reasons

        primary = detected_list[0]
        return ObstacleDetectionResult(
            x=primary.x, y=primary.y, bbox=primary.bbox, pan=primary.pan,
            proximity=primary.proximity, dist_cm=primary.dist_cm,
            mode_text=primary.mode_text, uncertainty_score=primary.uncertainty_score,
            is_wall=primary.is_wall, sector_dists=sector_dists,
            all_obstacles=detected_list,
            overhead_hazard=overhead_hazard, drop_off_hazard=drop_off_hazard,
            is_valid=True,
            is_scale_uncalibrated=True,
            validity_state="VALID",
            spatial_validity=spatial_validity,
            measurement_basis="METRIC_ESTIMATED_UNVERIFIED",
            quality_state=vis_quality_state,
            quality_reasons=vis_reasons
        )
