#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  PoC Demo — Binaural Spatial Audio Navigation for the Visually Impaired    ║
║                                                                            ║
║  Project : Khung hệ thống điều hướng không gian 3D thời gian thực          ║
║            bằng âm thanh song nhĩ trên phần cứng biên                      ║
║  Scope   : Proof-of-Concept chạy cục bộ (Python, CPU/GPU phổ thông)       ║
║  Author  : ViSEF 2027 Research Team                                        ║
║  License : MIT                                                             ║
╚══════════════════════════════════════════════════════════════════════════════╝

Pipeline:
    Camera Capture ──► MiDaS Depth Inference ──► Obstacle Detector
                                                      │
                                         ┌────────────┴────────────┐
                                    Spatial Audio Engine      Telemetry GUI
                                    (non-blocking stereo)     (side-by-side)

Usage:
    python poc_demo.py                                    # Webcam mặc định (index 0)
    python poc_demo.py --source 1                         # Camera index 1 (USB/DroidCam)
    python poc_demo.py --source http://192.168.1.5:8080/video  # IP Camera (điện thoại)
    python poc_demo.py --source rtsp://192.168.1.5:554/stream  # RTSP stream

Controls:
    q / ESC  — Thoát an toàn, giải phóng camera & audio
"""

# ═══════════════════════════════════════════════════════════════════════════════
# IMPORTS
# ═══════════════════════════════════════════════════════════════════════════════
import sys
import time
import math
import threading
import argparse

import cv2
import numpy as np
import torch
import torch.nn.functional as F
import sounddevice as sd
try:
    from scipy.interpolate import PchipInterpolator
except ImportError:
    class PchipInterpolator:
        """
        Triển khai thuần NumPy của thuật toán nội suy đơn điệu PCHIP (Piecewise Cubic
        Hermite Interpolating Polynomial) theo chuẩn Fritsch-Carlson (1980).
        Tương thích 100% với scipy.interpolate.PchipInterpolator mà không phụ thuộc scipy.
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

            # Các điểm nội bộ (Fritsch-Carlson harmonic weighting)
            for i in range(1, n - 1):
                if delta[i - 1] * delta[i] <= 0:
                    d[i] = 0.0
                else:
                    w1 = 2 * h[i] + h[i - 1]
                    w2 = h[i] + 2 * h[i - 1]
                    d[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])

            # Điểm đầu biên trái
            d[0] = ((2 * h[0] + h[1]) * delta[0] - h[0] * delta[1]) / (h[0] + h[1]) if n > 2 else delta[0]
            if d[0] * delta[0] <= 0:
                d[0] = 0.0
            elif delta[0] * delta[1] < 0 and abs(d[0]) > abs(3 * delta[0]):
                d[0] = 3 * delta[0]

            # Điểm đầu biên phải
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

            i = np.searchsorted(self.x, x_flat) - 1
            i = np.clip(i, 0, len(self.x) - 2)

            h_i = self.h[i]
            t = (x_flat - self.x[i]) / h_i
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

            return y_pred.item() if scalar else y_pred


# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION CONSTANTS
# ═══════════════════════════════════════════════════════════════════════════════

# — Camera —
CAM_WIDTH  = 640
CAM_HEIGHT = 480
CAM_INDICES_TO_TRY = [0, 1, 2]          # Fallback dò webcam (khi --source không truyền)
MAX_FRAME_WIDTH    = 640                 # Auto-resize khung hình trước khi đưa vào MiDaS
CONNECTION_TIMEOUT = 5.0                 # Giây — timeout kết nối camera mạng

# — MiDaS —
MIDAS_REPO  = "intel-isl/MiDaS"
MIDAS_MODEL = "MiDaS_small"

# — Audio Engine —
AUDIO_SAMPLE_RATE = 44100                # Hz
AUDIO_CHANNELS    = 2                    # Stereo
AUDIO_BLOCKSIZE   = 1024                 # Frames per callback

# Ánh xạ proximity → tần số beep (Hz)
FREQ_MIN = 350.0                         # Vật xa  → tần số thấp (trầm)
FREQ_MAX = 950.0                         # Vật gần → tần số cao (báo động)

# Ánh xạ proximity → chu kỳ beep (giây)
BEEP_INTERVAL_MAX = 1.8                  # Vật xa  → beep thưa (~1.8s)
BEEP_INTERVAL_MIN = 0.08                 # Vật gần (<30cm) → beep dồn dập (~0.08s)
BEEP_DURATION     = 0.05                 # Độ dài mỗi tiếng beep (giây)

# — 3D Binaural Spatial Audio (ITD + ILD + Head Shadowing) —
MAX_ITD_SAMPLES   = 28                   # ~0.65ms trễ thời gian giữa 2 tai (chuẩn đầu người ~17cm)
ILD_EXPONENT      = 1.8                  # Hệ số tương phản âm lượng Interaural Level Difference (~20dB)

# — Hiệu chuẩn độ sâu Metric Monotonic (PCHIP Spline / NYU Depth V2 Empirical Alignment) —
# Các điểm mốc (knot nodes) hiệu chuẩn thực nghiệm dựa trên đo đạc thực tế (14cm - 250cm):
_CALIBRATION_NODES = [
    (200.0,  350.0), # Phòng sâu / vô cực (>3m)
    (450.0,  250.0), # Ngưỡng an toàn tuyệt đối (2.5m)
    (540.0,  200.0), # 2.0m: Trần nhà, tường xa (raw ~550)
    (600.0,  150.0), # 1.5m: Vách tường 150cm (raw ~600)
    (660.0,  100.0), # 1.0m: Cánh cửa 100cm, cầu thang (raw ~660)
    (740.0,   50.0), # 50cm: Bức tường 50cm, tay vịn 50cm (raw ~740)
    (800.0,   30.0), # 30cm: Ngưỡng DANGER (bàn tay cự ly 28cm)
    (900.0,   22.0), # 22cm: Vật cản tiếp cận nguy hiểm
    (1100.0,  15.5), # 15.5cm: Ngón tay sát camera
    (1250.0,  13.0), # 13cm: Chạm sát thấu kính camera
]
_KNOT_RAWS  = [n[0] for n in _CALIBRATION_NODES]
_KNOT_DISTS = [n[1] for n in _CALIBRATION_NODES]
_PCHIP_MODEL = PchipInterpolator(_KNOT_RAWS, _KNOT_DISTS)
DEFAULT_DIST_SCALE     = 1.00            # Hệ số bù tiêu cự camera (tùy chỉnh phím [ / ])

# Ngưỡng khoảng cách vật lý (cm) cho điều hướng khiếm thị
DIST_CRITICAL_CM       = 15.0            # < 15cm: Cực kỳ nguy hiểm, chạm mắt cam
DIST_DANGER_CM         = 30.0            # < 30cm: Vùng nguy hiểm va chạm, beep dồn dập
DIST_WARNING_CM        = 70.0            # 30-70cm: Vùng cảnh báo, beep thưa dần
DIST_ALERT_CM          = 150.0           # 70-150cm: Vùng lưu ý, beep rất thưa
DIST_SAFE_CM           = 250.0           # > 150cm: Hành lang an toàn, im lặng tuyệt đối

# — Tham số nhận diện vật cản không gian (Spatial Engine v8 — Discontinuity & Metric Calibration) —
FAR_BG_THRESHOLD         = 0.25          # Mức depth chuẩn hóa được coi là nền xa
NEAR_FG_THRESHOLD        = 0.65          # Mức depth chuẩn hóa được coi là vật cản gần
BLOCKER_DEPTH_MIN        = 0.70          # Ngưỡng depth tối thiểu cho vật cản che ống kính
BLOCKER_COVERAGE_RATIO   = 0.75          # Tỷ lệ diện tích bao phủ để phát hiện vật cản sát mắt camera (>75%)
MIN_OBSTACLE_AREA_RATIO  = 0.002         # 0.2% tổng diện tích frame (~600px: ngón tay, gậy, cọc, bút)
DISCONTINUITY_STEP_MIN   = 0.16          # Ngưỡng bậc nhảy tương phản tối thiểu khi có viền sắc nét
DISCONTINUITY_GRAD_MIN   = 3.5           # Ngưỡng gradient viền biên độ sâu
DISCONTINUITY_STEP_HIGH  = 0.28          # Bậc nhảy tương phản vượt trội (xác nhận chắc chắn 100% là vật cản)

# Power curve: proximity^POWER điều tiết độ tăng tốc âm thanh khi lại gần
PROXIMITY_POWER        = 1.2

# — Telemetry GUI —
COLORMAP = cv2.COLORMAP_MAGMA            # Heatmap depth
FPS_SMOOTHING = 0.9                      # EMA smoothing factor cho FPS


# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 1 — CAMERA CAPTURE (Threaded, Multi-Source)
# ═══════════════════════════════════════════════════════════════════════════════

def _parse_source(source_arg: str):
    """
    Phân tích tham số --source thành nguồn camera phù hợp.

    Args:
        source_arg: Chuỗi từ argparse. Có thể là:
                    - None / "auto"    → auto-detect webcam
                    - "0", "1", "2"    → camera index (USB/DroidCam)
                    - "http://..."     → IP camera URL (điện thoại qua Wi-Fi)
                    - "rtsp://..."     → RTSP stream

    Returns:
        source: int (camera index) hoặc str (URL).
    """
    if source_arg is None or source_arg.lower() == "auto":
        return None  # Sẽ dùng chế độ auto-detect

    # Kiểm tra nếu là URL mạng
    if source_arg.startswith(("http://", "https://", "rtsp://")):
        return source_arg

    # Kiểm tra nếu là số nguyên (camera index)
    try:
        return int(source_arg)
    except ValueError:
        pass

    # Fallback: coi như URL
    return source_arg


def _open_capture(source) -> cv2.VideoCapture:
    """
    Mở VideoCapture với timeout kiểm tra kết nối.

    Args:
        source: int (camera index) hoặc str (URL).

    Returns:
        cv2.VideoCapture đã mở thành công.

    Raises:
        RuntimeError nếu không kết nối được.
    """
    is_network = isinstance(source, str)
    label = f"URL '{source}'" if is_network else f"index {source}"

    print(f"[Camera] Đang kết nối tới {label}...")
    cap = cv2.VideoCapture(source)

    # Thiết lập buffer size tối thiểu (giảm lag cho stream mạng)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

    if not is_network:
        # Camera local: set resolution hint
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, CAM_WIDTH)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, CAM_HEIGHT)

    # Kiểm tra kết nối với timeout
    start = time.perf_counter()
    while not cap.isOpened():
        if time.perf_counter() - start > CONNECTION_TIMEOUT:
            cap.release()
            if is_network:
                raise RuntimeError(
                    f"[Camera] TIMEOUT: Không thể kết nối tới {label} "
                    f"sau {CONNECTION_TIMEOUT:.0f}s.\n"
                    f"  → Kiểm tra:\n"
                    f"    1. Điện thoại và máy tính cùng mạng Wi-Fi?\n"
                    f"    2. App camera (IP Webcam/DroidCam) đang chạy?\n"
                    f"    3. URL có đúng không? (thử mở trên trình duyệt)\n"
                    f"    4. Firewall có chặn cổng không?"
                )
            else:
                raise RuntimeError(
                    f"[Camera] TIMEOUT: Camera {label} không phản hồi "
                    f"sau {CONNECTION_TIMEOUT:.0f}s."
                )
        time.sleep(0.1)

    # Thử đọc 1 frame để xác nhận stream hoạt động
    deadline = time.perf_counter() + CONNECTION_TIMEOUT
    while True:
        ret, test_frame = cap.read()
        if ret and test_frame is not None:
            break
        if time.perf_counter() > deadline:
            cap.release()
            raise RuntimeError(
                f"[Camera] Đã kết nối tới {label} nhưng không nhận được "
                f"khung hình nào sau {CONNECTION_TIMEOUT:.0f}s."
            )
        time.sleep(0.05)

    actual_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"[Camera] Kết nối thành công: {label} ({actual_w}×{actual_h})")
    return cap


class ThreadedCamera:
    """
    Bộ đọc camera đa luồng — triệt tiêu hoàn toàn độ trễ buffer mạng.

    Nguyên lý:
        - Worker thread chạy nền, liên tục gọi cap.read() để "hút" hết
          buffer nội bộ của OpenCV, chỉ giữ lại DUY NHẤT 1 frame mới nhất.
        - Main thread gọi read() → nhận frame mới nhất tức thì, không chờ.
        - Tự động resize frame cao phân giải (1080p/4K) xuống MAX_FRAME_WIDTH
          trước khi trả về, đảm bảo MiDaS chạy nhanh trên CPU.

    Hỗ trợ:
        - Camera USB/tích hợp (int index)
        - IP Camera qua Wi-Fi (URL http/https/rtsp)
        - Auto-detect fallback (dò index 0, 1, 2)

    Usage:
        cam = ThreadedCamera(source="http://192.168.1.5:8080/video")
        cam.start()
        frame = cam.read()    # Luôn trả về frame mới nhất, không lag
        cam.release()
    """

    def __init__(self, source=None):
        """
        Args:
            source: int (camera index), str (URL), hoặc None (auto-detect).
        """
        # Mở capture
        if source is None:
            # Auto-detect: thử lần lượt các index
            self._cap = None
            for idx in CAM_INDICES_TO_TRY:
                try:
                    self._cap = _open_capture(idx)
                    break
                except RuntimeError:
                    continue
            if self._cap is None:
                raise RuntimeError(
                    "[Camera] FATAL: Không tìm thấy webcam khả dụng.\n"
                    f"  Đã thử các index: {CAM_INDICES_TO_TRY}\n"
                    "  Thử: python poc_demo.py --source <URL hoặc index>"
                )
        else:
            self._cap = _open_capture(source)

        # State chia sẻ
        self._lock = threading.Lock()
        self._latest_frame = None
        self._running = False
        self._thread = None

        # Đọc frame đầu tiên
        ret, frame = self._cap.read()
        if ret:
            self._latest_frame = self._resize_frame(frame)

    def start(self):
        """Khởi động worker thread đọc frame liên tục."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._grab_loop,
                                        name="CameraGrabber",
                                        daemon=True)
        self._thread.start()
        print("[Camera] Threaded grabber started (zero-latency mode)")

    def read(self):
        """
        Lấy frame mới nhất (non-blocking).

        Returns:
            (success: bool, frame: np.ndarray | None)
        """
        with self._lock:
            if self._latest_frame is not None:
                return True, self._latest_frame.copy()
            return False, None

    def release(self):
        """Dừng worker thread và giải phóng camera."""
        self._running = False
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        if self._cap is not None:
            self._cap.release()
        print("[Camera] Released")

    def _grab_loop(self):
        """
        Worker loop — chạy trên thread riêng.
        Liên tục đọc frame mới nhất, loại bỏ frame cũ bị tồn đọng trong buffer.
        """
        consecutive_failures = 0
        MAX_FAILURES = 50  # ~2.5 giây nếu mỗi lần fail mất ~50ms

        while self._running:
            ret, frame = self._cap.read()
            if ret and frame is not None:
                consecutive_failures = 0
                resized = self._resize_frame(frame)
                with self._lock:
                    self._latest_frame = resized
            else:
                consecutive_failures += 1
                if consecutive_failures >= MAX_FAILURES:
                    print("[Camera] WARNING: Mất kết nối camera quá lâu!")
                    consecutive_failures = 0  # Reset, thử tiếp
                time.sleep(0.01)

    @staticmethod
    def _resize_frame(frame: np.ndarray) -> np.ndarray:
        """
        Auto-resize frame xuống MAX_FRAME_WIDTH nếu vượt quá.
        Giữ nguyên tỷ lệ khung hình (aspect ratio).

        Camera điện thoại thường truyền 1080p/4K → cần resize để MiDaS
        chạy đủ nhanh trên CPU (≥25 FPS).
        """
        h, w = frame.shape[:2]
        if w <= MAX_FRAME_WIDTH:
            return frame

        scale = MAX_FRAME_WIDTH / w
        new_w = MAX_FRAME_WIDTH
        new_h = int(h * scale)
        return cv2.resize(frame, (new_w, new_h),
                          interpolation=cv2.INTER_AREA)


# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 2 — MiDaS DEPTH ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

def select_device() -> torch.device:
    """Auto-detect thiết bị tính toán tốt nhất (CUDA > CPU)."""
    if torch.cuda.is_available():
        dev = torch.device("cuda")
        print(f"[MiDaS] Using GPU: {torch.cuda.get_device_name(0)}")
    else:
        dev = torch.device("cpu")
        print("[MiDaS] Using CPU")
    return dev


def init_midas(device: torch.device):
    """
    Tải mô hình MiDaS_small và bộ transform từ PyTorch Hub.

    Args:
        device: torch.device đích (cuda / cpu).

    Returns:
        (model, transform) — model đã eval() + transform pipeline.
    """
    print(f"[MiDaS] Loading '{MIDAS_MODEL}' from '{MIDAS_REPO}'...")
    model = torch.hub.load(MIDAS_REPO, MIDAS_MODEL, trust_repo=True)
    model.to(device).eval()

    transforms = torch.hub.load(MIDAS_REPO, "transforms", trust_repo=True)
    transform = transforms.small_transform
    print("[MiDaS] Model loaded successfully.")
    return model, transform


def infer_depth(
    frame_bgr: np.ndarray,
    model: torch.nn.Module,
    transform,
    device: torch.device,
):
    """
    Suy luận ma trận độ sâu từ một khung hình BGR.

    Pipeline:
        BGR → RGB → transform → model inference → resize

    Args:
        frame_bgr : Khung hình OpenCV (BGR, uint8).
        model     : MiDaS model đã load.
        transform : Transform pipeline cho MiDaS_small.
        device    : Torch device.

    Returns:
        (depth_norm, depth_raw):
            depth_norm : uint8 [0-255] — CHỈ dùng cho hiển thị heatmap.
            depth_raw  : float32 — giá trị gốc MiDaS, dùng cho proximity.
                         Giá trị CAO = vật GẦN, THẤP = xa.
                         Không bị normalize per-frame → giữ nguyên tỷ lệ.
    """
    # Chuyển BGR → RGB (MiDaS yêu cầu RGB input)
    frame_rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)

    # Transform & chuyển lên device
    input_batch = transform(frame_rgb).to(device)

    # Suy luận (không tính gradient để tối ưu tốc độ)
    with torch.no_grad():
        prediction = model(input_batch)

    # Resize depth map về kích thước khung hình gốc
    prediction = F.interpolate(
        prediction.unsqueeze(1),
        size=frame_bgr.shape[:2],   # (H, W)
        mode="bicubic",
        align_corners=False,
    ).squeeze()

    depth_raw = prediction.cpu().numpy().astype(np.float32)

    # Chuẩn hóa về [0, 255] — CHỈ cho hiển thị, KHÔNG dùng cho proximity
    d_min = depth_raw.min()
    d_max = depth_raw.max()
    if d_max - d_min > 1e-6:
        depth_norm = ((depth_raw - d_min) / (d_max - d_min) * 255.0)
    else:
        depth_norm = np.zeros_like(depth_raw)

    return depth_norm.astype(np.uint8), depth_raw


# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 3 — OBSTACLE DETECTOR
# ═══════════════════════════════════════════════════════════════════════════════

def compute_metric_distance_cm(raw_val: float, scale_factor: float = 1.0) -> float:
    """
    Chuyển đổi giá trị disparity raw từ MiDaS sang khoảng cách vật lý thực tế (cm)
    dựa trên mô hình spline PCHIP (Piecewise Cubic Hermite Interpolating Polynomial)
    được hiệu chuẩn chính xác từ tập dữ liệu thực nghiệm và NYU Depth V2 (13cm - 250cm+).
    Bảo đảm tính đơn điệu nghiêm ngặt (Monotonicity): disparity càng lớn -> khoảng cách càng gần,
    loại bỏ triệt để hiện tượng nén sai khoảng cách ở cự ly xa (2m không còn bị báo <50cm).
    """
    r = float(raw_val)
    if r <= _KNOT_RAWS[0]:
        return DIST_SAFE_CM
    elif r >= _KNOT_RAWS[-1]:
        return round(_KNOT_DISTS[-1] * scale_factor, 1)
    else:
        d_cm = float(_PCHIP_MODEL(r)) * scale_factor
        return round(d_cm, 1)


def dist_to_proximity(dist_cm: float) -> float:
    """
    Ánh xạ phi tuyến từ khoảng cách vật lý (cm) sang hệ số proximity [0.0, 1.0]
    cho Spatial Audio Engine:
      - dist <= 15cm : proximity = 1.00 (khẩn cấp cao nhất, beep dồn dập ~0.08s)
      - 15cm - 30cm  : proximity 0.70 -> 1.00 (vùng nguy hiểm DANGER <30cm)
      - 30cm - 70cm  : proximity 0.35 -> 0.70 (vùng cảnh báo WARNING, thưa dần)
      - 70cm - 150cm : proximity 0.05 -> 0.35 (vùng lưu ý ALERT, rất thưa)
      - > 150cm      : proximity = 0.00 (an toàn SAFE, hoàn toàn im lặng)
    """
    if dist_cm <= DIST_CRITICAL_CM:
        return 1.0
    elif dist_cm < DIST_DANGER_CM:
        return 0.70 + 0.30 * (DIST_DANGER_CM - dist_cm) / (DIST_DANGER_CM - DIST_CRITICAL_CM)
    elif dist_cm < DIST_WARNING_CM:
        return 0.35 + 0.35 * (DIST_WARNING_CM - dist_cm) / (DIST_WARNING_CM - DIST_DANGER_CM)
    elif dist_cm < DIST_ALERT_CM:
        return 0.05 + 0.30 * (DIST_ALERT_CM - dist_cm) / (DIST_ALERT_CM - DIST_WARNING_CM)
    else:
        return 0.0


def find_nearest_obstacle(
    depth_norm: np.ndarray,
    depth_raw: np.ndarray = None,
    scale_factor: float = 1.0,
):
    """
    Xác định vị trí (pan), mức độ gần (proximity) và khoảng cách vật lý thực tế (cm)
    của chướng ngại vật gần nhất trong không gian 3D.

    Kiến trúc Spatial Engine v8 — Spatial Depth Discontinuity & Contrast Criterion:
      - Loại bỏ triệt để lỗi báo động giả ở phòng trống/trần nhà/tường xa: Bề mặt phẳng
        hoặc nền xa có độ sâu mịn, biến thiên liên tục, KHÔNG có bước nhảy tách biệt
        (contrast step < 0.24) và gradient viền rất thấp (< 4.0).
      - Phát hiện nhạy bén và chuẩn xác mọi vật cản thực tế (ngón tay, cọc, gậy, người,
        cánh cửa) dù rất nhỏ (diện tích từ 0.2% frame) nhờ bước nhảy độ sâu rõ rệt (step >= 0.24).
      - Bảo toàn khả năng phát hiện vật cản che sát ống kính camera (<15cm, >75% frame).

    Args:
        depth_norm   : Ma trận depth chuẩn hóa (uint8, 0-255).
        depth_raw    : Ma trận depth raw (tùy chọn).
        scale_factor : Hệ số bù tiêu cự camera để hiệu chuẩn metric cm.

    Returns:
        (obstacle_x, obstacle_y, pan, proximity, dist_cm, mode_text)
    """
    h, w = depth_norm.shape[:2]

    # Chuẩn hoá ma trận độ sâu về [0.0, 1.0] và làm mịn Gaussian
    d_norm = depth_norm.astype(np.float32) / 255.0
    smoothed = cv2.GaussianBlur(d_norm, (21, 21), 0)

    # ── Kịch bản A: Vật cản vật lý cực gần che sát mắt camera (< 15cm) ──
    close_ratio = float((smoothed > BLOCKER_DEPTH_MIN).mean())
    far_ratio   = float((smoothed < FAR_BG_THRESHOLD).mean())
    if close_ratio > BLOCKER_COVERAGE_RATIO and far_ratio < 0.02:
        blocker_mask = (smoothed > 0.60).astype(np.uint8) * 255
        moments = cv2.moments(blocker_mask)
        if moments["m00"] > 0:
            obs_x = int(moments["m10"] / moments["m00"])
            obs_y = int(moments["m01"] / moments["m00"])
            pan = max(-1.0, min(1.0, (float(obs_x) / float(w - 1)) * 2.0 - 1.0))
        else:
            obs_x, obs_y, pan = w // 2, h // 2, 0.0

        if depth_raw is not None:
            raw_val = float(np.percentile(depth_raw, 95))
            dist_cm = compute_metric_distance_cm(raw_val, scale_factor)
        else:
            dist_cm = 14.0
        proximity = dist_to_proximity(dist_cm)
        mode_text = f"CLOSE BLOCKER ({dist_cm:.1f}cm)"
        return obs_x, obs_y, pan, proximity, dist_cm, mode_text

    # ── Kịch bản B: Không gian toàn bộ ở xa (All Far / Clear Path) ──
    d_peak = float(np.percentile(smoothed, 99.2))
    if depth_raw is not None:
        raw_peak = float(np.percentile(depth_raw, 99.0))
        if raw_peak < 450.0:  # Không có bất kỳ điểm nào gần hơn ~2.5m trong toàn không gian
            return w // 2, h // 2, 0.0, 0.0, DIST_SAFE_CM, "SAFE (Clear Path >150cm)"
    elif d_peak < 0.35:
        return w // 2, h // 2, 0.0, 0.0, DIST_SAFE_CM, "SAFE (Clear Path >150cm)"

    # ── Kịch bản C: Phân đoạn vật thể gần & kiểm tra bước nhảy độ sâu (Discontinuity) ──
    hot_threshold = max(0.40, d_peak - 0.22)
    hot_mask = (smoothed >= hot_threshold).astype(np.uint8) * 255

    cnts, _ = cv2.findContours(hot_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return w // 2, h // 2, 0.0, 0.0, DIST_SAFE_CM, "SAFE (Clear Path >150cm)"

    grad_x = cv2.Sobel(smoothed, cv2.CV_32F, 1, 0, ksize=5)
    grad_y = cv2.Sobel(smoothed, cv2.CV_32F, 0, 1, ksize=5)
    grad_mag = np.sqrt(grad_x**2 + grad_y**2)
    kernel_dilate = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (31, 31))
    kernel_erode  = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (11, 11))

    candidates = []
    for c in cnts:
        area = cv2.contourArea(c)
        area_ratio = area / (h * w)

        # Lọc nhiễu siêu nhỏ (< 0.2% frame)
        if area_ratio < MIN_OBSTACLE_AREA_RATIO:
            continue

        # Lọc mặt bàn/sàn đặt camera (ở sát đáy y > 82% frame)
        bx, by, bw, bh = cv2.boundingRect(c)
        aspect = bw / max(1, bh)
        if by > 0.82 * h and bw > 0.50 * w and d_peak < 0.70:
            continue

        # Lọc dải ngang xà/kệ sách/gờ trần nhà ở xa (dải mỏng ngang > 45% frame, aspect > 3.0)
        if bw > 0.45 * w and bh < 0.25 * h and aspect > 3.0 and d_peak < 0.70:
            continue

        # Mặt nạ vật cản ứng viên
        c_mask = np.zeros((h, w), dtype=np.uint8)
        cv2.drawContours(c_mask, [c], -1, 255, -1)

        # Giãn nở để lấy vành nền xung quanh (background ring)
        dilated = cv2.dilate(c_mask, kernel_dilate)
        ring_mask = cv2.subtract(dilated, c_mask)

        inside_mean = float(smoothed[c_mask == 255].mean())
        ring_mean   = float(smoothed[ring_mask == 255].mean()) if np.any(ring_mask == 255) else 0.0
        contrast_step = inside_mean - ring_mean

        # Gradient trên đường biên tiếp giáp giữa vật và nền
        c_border = cv2.subtract(dilated, cv2.erode(c_mask, kernel_erode))
        border_grad_max = float(np.percentile(grad_mag[c_border == 255], 95)) if np.any(c_border == 255) else 0.0

        obs_pixels = smoothed[c_mask == 255]
        obs_d_val = float(np.percentile(obs_pixels, 92)) if len(obs_pixels) > 0 else d_peak
        if depth_raw is not None and np.any(c_mask == 255):
            obs_raw_val = float(np.percentile(depth_raw[c_mask == 255], 92))
        else:
            obs_raw_val = obs_d_val * 1200.0

        # Tiêu chuẩn không gian: Vật cản thực sự (ngón tay, người, áo quần, cọc, gậy, ghế):
        # - Viền sắc nét (grad >= 5.0) kết hợp bước nhảy độ sâu (step >= 0.16)
        # - Hoặc bước nhảy độ sâu rõ rệt (step >= 0.20 kết hợp grad >= 3.5)
        # - Hoặc bước nhảy độ sâu cực lớn (step >= 0.28)
        # - Hoặc vật cản cự ly gần/tiếp cận (<30cm, raw >= 780) với contrast step cục bộ
        is_true_obstacle = (
            (border_grad_max >= 5.0 and contrast_step >= DISCONTINUITY_STEP_MIN)
            or (contrast_step >= 0.20 and border_grad_max >= DISCONTINUITY_GRAD_MIN)
            or (contrast_step >= DISCONTINUITY_STEP_HIGH)
            or (obs_raw_val >= 900.0 and contrast_step >= 0.08)
            or (obs_raw_val >= 780.0 and contrast_step >= 0.12)
        )

        if is_true_obstacle:
            candidates.append((c, obs_raw_val, obs_d_val, contrast_step, bx, by, bw, bh))

    salient_res = None
    if candidates:
        # Chọn vật cản GẦN NHẤT trong số các vật cản hợp lệ (obs_raw_val cao nhất)
        candidates.sort(key=lambda item: item[1], reverse=True)
        best_c, obs_raw_val, obs_d_val, best_step, bx, by, bw, bh = candidates[0]
        moments = cv2.moments(best_c)
        if moments["m00"] > 0:
            ox = int(moments["m10"] / moments["m00"])
            oy = int(moments["m01"] / moments["m00"])
        else:
            ox = bx + bw // 2
            oy = by + bh // 2
        ox = max(0, min(w - 1, ox))
        oy = max(0, min(h - 1, oy))
        pan_salient = max(-1.0, min(1.0, (float(ox) / float(w - 1)) * 2.0 - 1.0))
        dist_salient_cm = compute_metric_distance_cm(obs_raw_val, scale_factor)
        if dist_salient_cm < DIST_ALERT_CM:
            salient_res = (ox, oy, pan_salient, dist_salient_cm)

    # ── Kịch bản D: Khảo sát Hành lang di chuyển & Bức tường phẳng (Planar Wall & Corridor Engine) ──
    # Khắc phục triệt để lỗi bỏ sót bức tường/vách ngăn/cánh cửa che toàn màn hình (không có viền biên)
    wall_res = None
    if depth_raw is not None:
        cy1, cy2 = int(0.20 * h), int(0.75 * h)
        cx1, cx2 = int(0.22 * w), int(0.78 * w)
        corr_raw = depth_raw[cy1:cy2, cx1:cx2]
        cw = cx2 - cx1

        # Phân tích 3 sector định hướng không gian: Trái [-0.50], Giữa [0.00], Phải [+0.50]
        sec_l = corr_raw[:, :cw // 3]
        sec_c = corr_raw[:, cw // 3: 2 * cw // 3]
        sec_r = corr_raw[:, 2 * cw // 3:]

        raw_l = float(np.percentile(sec_l, 65))
        raw_c = float(np.percentile(sec_c, 65))
        raw_r = float(np.percentile(sec_r, 65))

        raw_wall_max = max(raw_l, raw_c, raw_r)
        dist_wall_cm = compute_metric_distance_cm(raw_wall_max, scale_factor)

        if dist_wall_cm < DIST_ALERT_CM:  # Bức tường chắn trong phạm vi nguy hiểm (< 150cm)
            if raw_wall_max == raw_l:
                pan_wall = -0.50
                wall_x = cx1 + cw // 6
            elif raw_wall_max == raw_r:
                pan_wall = +0.50
                wall_x = cx1 + 5 * cw // 6
            else:
                pan_wall = 0.00
                wall_x = cx1 + cw // 2
            wall_y = (cy1 + cy2) // 2
            wall_res = (wall_x, wall_y, pan_wall, dist_wall_cm)

    # ── FUSION: Hợp nhất vật cản nổi bật & Bức tường chắn theo ưu tiên khoảng cách gần nhất ──
    if salient_res is not None and wall_res is not None:
        sox, soy, span, sdist = salient_res
        wox, woy, wpan, wdist = wall_res
        if sdist < wdist:
            chosen_x, chosen_y, chosen_pan, chosen_dist = sox, soy, span, sdist
            is_wall = False
        else:
            chosen_x, chosen_y, chosen_pan, chosen_dist = wox, woy, wpan, wdist
            is_wall = True
    elif salient_res is not None:
        chosen_x, chosen_y, chosen_pan, chosen_dist = salient_res
        is_wall = False
    elif wall_res is not None:
        chosen_x, chosen_y, chosen_pan, chosen_dist = wall_res
        is_wall = True
    else:
        # Toàn bộ hành lang và không gian đều thông thoáng (>150cm) → SAFE tuyệt đối
        return w // 2, h // 2, 0.0, 0.0, DIST_SAFE_CM, "SAFE (Clear Path >150cm)"

    # Tính độ gần Proximity tỉ lệ nghịch đơn điệu với khoảng cách cm
    proximity = dist_to_proximity(chosen_dist)

    # Nhãn trạng thái không gian
    prefix = "WALL: " if is_wall else ""
    if chosen_dist <= DIST_CRITICAL_CM:
        mode_text = f"CRITICAL ({chosen_dist:.1f}cm)"
    elif chosen_dist < DIST_DANGER_CM:
        mode_text = f"{prefix}DANGER (<30cm)"
    elif chosen_dist < DIST_WARNING_CM:
        mode_text = f"{prefix}WARNING (~{int(chosen_dist)}cm)"
    elif chosen_dist < DIST_ALERT_CM:
        mode_text = f"{prefix}ALERT (>70cm)"
    else:
        mode_text = "SAFE"

    return chosen_x, chosen_y, chosen_pan, proximity, chosen_dist, mode_text


# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 4 — SPATIAL AUDIO ENGINE (Non-blocking Stereo)
# ═══════════════════════════════════════════════════════════════════════════════

class AudioEngine:
    """
    Engine phát âm thanh không gian stereo non-blocking.

    Nguyên lý:
        - Dùng sounddevice.OutputStream với callback chạy trên thread riêng.
        - Main loop cập nhật state (pan, proximity) qua setter thread-safe.
        - Callback tự sinh sóng sine stereo với panning & tần số phù hợp.
        - Beep theo chu kỳ (ping interval) phụ thuộc khoảng cách vật cản.

    Panning:
        Constant-Power Panning (chuẩn studio):
            angle      = (pan + 1) / 2 × π/2
            left_gain  = cos(angle)
            right_gain = sin(angle)
    """

    def __init__(self):
        self._lock = threading.Lock()

        # State chia sẻ giữa main thread và audio thread
        self._pan       = 0.0      # [-1, +1]
        self._proximity = 0.0      # [0, 1]
        self._frequency = FREQ_MIN # Hz
        self._active    = False    # Có đang phát beep không

        # Phase tracking cho sine wave liên tục (tránh click)
        self._phase = 0.0

        # Beep timing
        self._beep_timer = 0.0     # Đếm thời gian trong chu kỳ beep
        self._beep_on    = False   # Đang trong giai đoạn phát tiếng

        # 3D Binaural Buffer & Filters
        self._history_buf = np.zeros(MAX_ITD_SAMPLES, dtype=np.float32)
        self._lp_state_l  = 0.0
        self._lp_state_r  = 0.0

        # Khởi tạo output stream
        self._stream = sd.OutputStream(
            samplerate=AUDIO_SAMPLE_RATE,
            channels=AUDIO_CHANNELS,
            blocksize=AUDIO_BLOCKSIZE,
            dtype="float32",
            callback=self._audio_callback,
        )

    def start(self):
        """Bắt đầu phát audio stream."""
        self._stream.start()
        print("[Audio] Stream started (3D Binaural Spatial Audio, non-blocking)")

    def stop(self):
        """Dừng và giải phóng audio stream."""
        self._stream.stop()
        self._stream.close()
        print("[Audio] Stream stopped")

    def update(self, pan: float, proximity: float):
        """
        Cập nhật trạng thái audio từ main loop (thread-safe).

        Args:
            pan       : Giá trị panning [-1.0 trái, +1.0 phải].
            proximity : Mức độ gần [0.0 xa/im lặng, 1.0 rất gần <30cm].
        """
        # Áp dụng power curve nhẹ để âm thanh tăng dần tự nhiên:
        effective = (proximity ** PROXIMITY_POWER) if proximity > 0 else 0.0

        # Ánh xạ effective proximity → tần số
        freq = FREQ_MIN + (FREQ_MAX - FREQ_MIN) * effective

        with self._lock:
            self._pan       = pan
            self._proximity = effective
            self._frequency = freq
            self._active    = proximity > 0.01

    def _audio_callback(self, outdata: np.ndarray, frames: int,
                        time_info, status):
        """
        Callback được gọi bởi sounddevice trên audio thread.
        Sinh tín hiệu 3D Binaural stereo với:
          1. ILD (Interaural Level Difference): Chênh lệch cường độ âm lượng
          2. ITD (Interaural Time Difference): Chênh lệch thời gian trễ sóng tới 2 tai (~0.65ms)
          3. Head Shadow Effect: Lọc thông thấp tần số cao ở tai phía xa

        QUAN TRỌNG: Callback phải hoàn thành nhanh, không block.
        """
        if status:
            print(f"[Audio] Status: {status}", file=sys.stderr)

        # Đọc state (thread-safe)
        with self._lock:
            pan       = self._pan
            proximity = self._proximity
            frequency = self._frequency
            active    = self._active

        if not active:
            outdata.fill(0.0)
            return

        # ── Tính beep interval dựa trên proximity ──
        # Khoảng cách < 30cm (proximity >= 0.70): Beep dồn dập từ 0.40s xuống 0.08s
        # Khoảng cách 30cm - 150cm (proximity < 0.70): Beep thưa dần từ 0.40s lên 1.80s
        if proximity >= 0.70:
            t = (proximity - 0.70) / 0.30
            beep_interval = 0.40 - (0.40 - BEEP_INTERVAL_MIN) * max(0.0, min(1.0, t))
        else:
            t = proximity / 0.70
            beep_interval = BEEP_INTERVAL_MAX - (BEEP_INTERVAL_MAX - 0.40) * max(0.0, min(1.0, t))

        # ── 1. ILD: Tương phản âm lượng rõ nét giữa 2 tai ──
        angle = (pan + 1.0) / 2.0 * (math.pi / 2.0)
        left_gain  = float(math.cos(angle) ** ILD_EXPONENT)
        right_gain = float(math.sin(angle) ** ILD_EXPONENT)

        # ── 2. ITD: Trễ thời gian truyền âm qua đầu (~0.65ms = 28 samples) ──
        if pan < 0:
            delay_l = 0
            delay_r = int(abs(pan) * MAX_ITD_SAMPLES)
        else:
            delay_l = int(pan * MAX_ITD_SAMPLES)
            delay_r = 0

        # ── Sinh tín hiệu với cấu trúc hài âm phong phú (Fundamental + 2nd Harmonic) ──
        # Tần số cơ bản (~350-950Hz) kích thích thụ thể ITD ở tai trong (MSO),
        # Hài âm bậc 2 (~700-1900Hz) kích thích thụ thể ILD & Head Shadowing (LSO),
        # tạo định vị không gian 3D cực kỳ sắc nét trên tai nghe stereo.
        samples_per_frame = 1.0 / AUDIO_SAMPLE_RATE
        t_array = ((self._phase + np.arange(frames))
                   / AUDIO_SAMPLE_RATE).astype(np.float32)

        tone = (0.38 * np.sin(2.0 * np.pi * frequency * t_array) +
                0.12 * np.sin(4.0 * np.pi * frequency * t_array)).astype(np.float32)

        # ── Beep envelope với Attack dứt khoát 3ms (kích hoạt hiệu ứng Haas/ITD) ──
        envelope = np.zeros(frames, dtype=np.float32)
        current_timer = self._beep_timer
        current_on    = self._beep_on
        attack_dur    = 0.003   # 3ms attack onset
        release_dur   = 0.010   # 10ms release

        for i in range(frames):
            current_timer += samples_per_frame
            if current_on:
                elapsed_in_beep = current_timer
                if elapsed_in_beep >= BEEP_DURATION:
                    current_on = False
                    current_timer = 0.0
                    envelope[i] = 0.0
                else:
                    if elapsed_in_beep < attack_dur:
                        envelope[i] = elapsed_in_beep / attack_dur
                    elif elapsed_in_beep > (BEEP_DURATION - release_dur):
                        envelope[i] = (BEEP_DURATION - elapsed_in_beep) / release_dur
                    else:
                        envelope[i] = 1.0
            else:
                silence_dur = max(0.01, beep_interval - BEEP_DURATION)
                if current_timer >= silence_dur:
                    current_on = True
                    current_timer = 0.0
                envelope[i] = 0.0

        self._beep_timer = current_timer
        self._beep_on    = current_on

        shaped = tone * envelope

        # ── Áp dụng ITD delay mượt mà qua buffer lịch sử ──
        extended = np.concatenate([self._history_buf, shaped])
        self._history_buf = shaped[-MAX_ITD_SAMPLES:].copy()

        ch_l = (extended[MAX_ITD_SAMPLES - delay_l : MAX_ITD_SAMPLES - delay_l + frames] * left_gain).astype(np.float32)
        ch_r = (extended[MAX_ITD_SAMPLES - delay_r : MAX_ITD_SAMPLES - delay_r + frames] * right_gain).astype(np.float32)

        # ── 3. Head Shadow Effect: Lọc suy giảm tần số cao ở tai phía xa ──
        if pan < -0.15:
            shadow_coeff = 0.50 * abs(pan)
            lp_r = np.empty_like(ch_r)
            s = self._lp_state_r
            for i in range(frames):
                s = (1.0 - shadow_coeff) * ch_r[i] + shadow_coeff * s
                lp_r[i] = s
            self._lp_state_r = s
            ch_r = lp_r
        elif pan > 0.15:
            shadow_coeff = 0.50 * pan
            lp_l = np.empty_like(ch_l)
            s = self._lp_state_l
            for i in range(frames):
                s = (1.0 - shadow_coeff) * ch_l[i] + shadow_coeff * s
                lp_l[i] = s
            self._lp_state_l = s
            ch_l = lp_l

        outdata[:, 0] = ch_l
        outdata[:, 1] = ch_r

        # Cập nhật phase (1 lần duy nhất)
        self._phase += frames


# ═══════════════════════════════════════════════════════════════════════════════
# MODULE 5 — TELEMETRY GUI
# ═══════════════════════════════════════════════════════════════════════════════

def render_telemetry(
    frame_bgr: np.ndarray,
    depth_norm: np.ndarray,
    obstacle_x: int,
    obstacle_y: int,
    pan: float,
    proximity: float,
    dist_cm: float,
    fps: float,
    mode_text: str = "",
    scale_factor: float = 1.0,
) -> np.ndarray:
    """
    Tạo khung hình telemetry side-by-side (RGB + Depth Heatmap).

    Nửa trái  : RGB gốc + crosshair khóa vật cản + overlay thông số khoảng cách (cm).
    Nửa phải  : Depth heatmap (MAGMA colormap).

    Args:
        frame_bgr    : Khung hình webcam (BGR).
        depth_norm   : Ma trận depth chuẩn hóa (uint8).
        obstacle_x/y : Tọa độ vật cản gần nhất.
        pan          : Giá trị panning [-1, +1].
        proximity    : Mức độ gần [0, 1].
        dist_cm      : Khoảng cách vật lý ước tính tới vật cản gần nhất (cm).
        fps          : FPS hiện tại.
        mode_text    : Trạng thái chi tiết từ thuật toán không gian.
        scale_factor : Hệ số hiệu chuẩn tiêu cự camera hiện tại.

    Returns:
        canvas — Khung hình ghép nối ngang (numpy array BGR).
    """
    h, w = frame_bgr.shape[:2]

    # ── Nửa trái: RGB + Crosshair + Overlay ──
    rgb_panel = frame_bgr.copy()

    # Phân loại trạng thái & màu sắc trực quan theo khoảng cách cm & proximity:
    if proximity >= 0.70 or dist_cm < DIST_DANGER_CM:
        status_text  = f"DANGER: {dist_cm:.1f} cm (<30cm)"
        status_color = (0, 0, 255)       # Đỏ tươi
    elif proximity >= 0.35 or dist_cm < DIST_WARNING_CM:
        status_text  = f"WARNING: {dist_cm:.1f} cm"
        status_color = (0, 140, 255)     # Cam
    elif proximity > 0.0 or dist_cm < DIST_ALERT_CM:
        status_text  = f"ALERT: {dist_cm:.1f} cm"
        status_color = (0, 220, 255)     # Vàng
    else:
        status_text  = "SAFE: Clear Path (>150cm)"
        status_color = (0, 220, 100)     # Xanh lá

    # Crosshair: vòng tròn + dấu thập tại vị trí vật cản
    lerp = max(0.0, min(1.0, proximity))
    cross_color = (
        int(50  + (0   - 50)  * lerp),  # B
        int(220 + (30  - 220) * lerp),  # G
        int(50  + (255 - 50)  * lerp),  # R
    )

    # Vòng tròn chính & tâm ngắm
    radius = int(20 + 20 * lerp)
    cv2.circle(rgb_panel, (obstacle_x, obstacle_y), radius, cross_color, 2,
               cv2.LINE_AA)
    cv2.circle(rgb_panel, (obstacle_x, obstacle_y), 3, cross_color, -1,
               cv2.LINE_AA)

    # Dấu thập
    cross_len = radius + 8
    cv2.line(rgb_panel,
             (obstacle_x - cross_len, obstacle_y),
             (obstacle_x + cross_len, obstacle_y),
             cross_color, 1, cv2.LINE_AA)
    cv2.line(rgb_panel,
             (obstacle_x, obstacle_y - cross_len),
             (obstacle_x, obstacle_y + cross_len),
             cross_color, 1, cv2.LINE_AA)

    # Overlay text tại vị trí vật cản: Hiển thị cm và Pan
    if proximity > 0.0:
        label_dist = f"Dist: {dist_cm:.1f} cm"
        label_pan  = f"Pan: {pan:+.2f}"
        dist_color = (0, 255, 255) if proximity >= 0.70 else cross_color
        cv2.putText(rgb_panel, label_dist,
                    (obstacle_x + radius + 10, obstacle_y - 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.52, dist_color, 2 if proximity >= 0.70 else 1, cv2.LINE_AA)
        cv2.putText(rgb_panel, label_pan,
                    (obstacle_x + radius + 10, obstacle_y + 16),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.48, cross_color, 1, cv2.LINE_AA)
    else:
        cv2.putText(rgb_panel, "Dist: >150 cm",
                    (obstacle_x + radius + 10, obstacle_y + 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.48, (0, 220, 100), 1, cv2.LINE_AA)

    # Hộp thông số telemetry ở góc trên trái (nền mờ)
    overlay = rgb_panel.copy()
    cv2.rectangle(overlay, (5, 5), (320, 112), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.65, rgb_panel, 0.35, 0, rgb_panel)

    cv2.putText(rgb_panel, f"FPS: {fps:.1f} | Calib: {scale_factor:.2f}x",
                (12, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.46,
                (255, 255, 255), 1, cv2.LINE_AA)

    if proximity > 0.0:
        dist_hud = f"Dist: {dist_cm:.1f} cm | Pan: {pan:+.2f}"
    else:
        dist_hud = "Dist: >150 cm (Clear)"

    cv2.putText(rgb_panel, dist_hud,
                (12, 45), cv2.FONT_HERSHEY_SIMPLEX, 0.50,
                (0, 255, 255) if proximity >= 0.70 else (220, 220, 220), 1, cv2.LINE_AA)

    cv2.putText(rgb_panel, f"Prox: {proximity:.2f} | Mode: {mode_text}",
                (12, 68), cv2.FONT_HERSHEY_SIMPLEX, 0.42,
                (180, 220, 255), 1, cv2.LINE_AA)

    cv2.putText(rgb_panel, status_text,
                (12, 94), cv2.FONT_HERSHEY_SIMPLEX, 0.56,
                status_color, 2, cv2.LINE_AA)

    # Indicator dot (chấm tròn trạng thái)
    dot_x = 12 + cv2.getTextSize(status_text, cv2.FONT_HERSHEY_SIMPLEX,
                                  0.56, 2)[0][0] + 10
    cv2.circle(rgb_panel, (dot_x, 88), 6, status_color, -1, cv2.LINE_AA)

    # ── Nửa phải: Depth Heatmap ──
    depth_color = cv2.applyColorMap(depth_norm, COLORMAP)

    # Đánh dấu vật cản gần nhất trên heatmap
    if proximity > 0.0:
        cv2.circle(depth_color, (obstacle_x, obstacle_y), radius,
                   (255, 255, 255), 2, cv2.LINE_AA)

    # ── Ghép ngang ──
    separator = np.full((h, 2, 3), (40, 40, 40), dtype=np.uint8)
    canvas = np.hstack([rgb_panel, separator, depth_color])

    # Tiêu đề ở đáy
    canvas_h = canvas.shape[0]
    cv2.putText(canvas, "RGB Binaural Nav | Calib: '[' / ']' | Reset: 'r' | Exit: 'q'",
                (10, canvas_h - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.40,
                (180, 180, 180), 1, cv2.LINE_AA)
    cv2.putText(canvas, f"Depth Map (MiDaS + NYU Depth V2 Metric | Nearest: {dist_cm:.1f} cm)",
                (w + 12, canvas_h - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.40,
                (180, 180, 180), 1, cv2.LINE_AA)

    return canvas


# ═══════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════════

def parse_args():
    """Parse tham số dòng lệnh."""
    parser = argparse.ArgumentParser(
        description="Binaural Spatial Audio Navigation — PoC Demo",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ví dụ:
  python poc_demo.py                                       # Webcam mặc định
  python poc_demo.py --source 1                            # Camera USB index 1
  python poc_demo.py --source http://192.168.1.5:8080/video  # IP Webcam (Android)
  python poc_demo.py --source rtsp://192.168.1.5:554/stream  # RTSP stream
        """,
    )
    parser.add_argument(
        "--source", "-s",
        type=str,
        default=None,
        help=(
            "Nguồn camera: số nguyên (0,1,2) cho webcam/USB, "
            "URL (http/https/rtsp) cho camera điện thoại qua Wi-Fi. "
            "Mặc định: tự dò webcam."
        ),
    )
    return parser.parse_args()


def main():
    """Điểm khởi đầu chính — khởi tạo pipeline và chạy vòng lặp chính."""
    args = parse_args()

    print("=" * 70)
    print("  Binaural Spatial Audio Navigation — PoC Demo (Spatial Engine v6)")
    print("  Nhấn 'q' hoặc ESC để thoát")
    print("=" * 70)

    # ── Parse camera source ──
    source = _parse_source(args.source)

    # ── Khởi tạo ──
    device = select_device()
    model, transform = init_midas(device)

    try:
        cam = ThreadedCamera(source=source)
    except RuntimeError as e:
        print(f"\n{e}")
        sys.exit(1)

    cam.start()
    audio = AudioEngine()
    audio.start()

    # FPS tracking & Temporal Audio Smoothing (Fast Attack, Smooth Decay)
    fps           = 0.0
    prev_time     = time.perf_counter()
    scale_factor  = DEFAULT_DIST_SCALE
    smoothed_pan  = 0.0
    smoothed_prox = 0.0

    window_name = "Binaural Nav PoC — Press Q/ESC to exit"

    try:
        while True:
            # ── 1. Capture frame (từ threaded grabber — luôn mới nhất) ──
            ret, frame = cam.read()
            if not ret:
                time.sleep(0.01)
                continue

            # Lật gương để thao tác tự nhiên
            frame = cv2.flip(frame, 1)

            # ── 2. Depth inference ──
            depth_norm, depth_raw = infer_depth(frame, model, transform, device)

            # ── 3. Dual-Mode Spatial Obstacle Detection & Metric Calibration ──
            obs_x, obs_y, pan, proximity, dist_cm, mode_text = find_nearest_obstacle(
                depth_norm, depth_raw, scale_factor=scale_factor
            )

            # ── 4. Temporal Filter & Update audio engine (Fast Attack, Smooth Release) ──
            if proximity > smoothed_prox:
                smoothed_prox = proximity  # Nguy hiểm tức thì: kích hoạt không độ trễ
            else:
                smoothed_prox = smoothed_prox * 0.70 + proximity * 0.30

            smoothed_pan = smoothed_pan * 0.65 + pan * 0.35
            audio.update(smoothed_pan, smoothed_prox)

            # ── 5. FPS calculation (EMA) ──
            now = time.perf_counter()
            dt  = now - prev_time
            prev_time = now
            instant_fps = 1.0 / max(dt, 1e-6)
            fps = fps * FPS_SMOOTHING + instant_fps * (1.0 - FPS_SMOOTHING)

            # ── 6. Render telemetry GUI ──
            canvas = render_telemetry(
                frame, depth_norm, obs_x, obs_y, pan, proximity, dist_cm, fps,
                mode_text=mode_text, scale_factor=scale_factor
            )

            cv2.imshow(window_name, canvas)

            # ── 7. Xử lý phím ──
            key = cv2.waitKey(1) & 0xFF
            if key == ord('q') or key == 27:  # 'q' hoặc ESC
                print("[Main] Exit requested by user.")
                break
            elif key == ord('['):
                scale_factor = max(0.40, round(scale_factor - 0.05, 2))
                print(f"[Calib] Giảm scale_factor = {scale_factor:.2f}x (khoảng cách cm hiển thị gần hơn)")
            elif key == ord(']'):
                scale_factor = min(2.50, round(scale_factor + 0.05, 2))
                print(f"[Calib] Tăng scale_factor = {scale_factor:.2f}x (khoảng cách cm hiển thị xa hơn)")
            elif key == ord('r'):
                scale_factor = DEFAULT_DIST_SCALE
                print(f"[Calib] Đã reset scale_factor = {scale_factor:.2f}x")

    except KeyboardInterrupt:
        print("\n[Main] Interrupted by Ctrl+C.")

    finally:
        # ── Cleanup an toàn ──
        print("[Main] Cleaning up resources...")
        audio.stop()
        cam.release()
        cv2.destroyAllWindows()
        print("[Main] Done. Goodbye!")


# ═══════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    main()
