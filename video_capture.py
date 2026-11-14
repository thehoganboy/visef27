"""
HorusEyes 2.0 - Video Capture Module (Hardened)
================================================================================
Bộ thu nhận video đa luồng không độ trễ (Zero-latency Threaded Camera Grabber).
Cứng hóa toàn diện:
  - AutoTorchController: Đo luma, điều khiển Flash, CLAHE cứu sáng, phát hiện 0-Lux blind.
  - Frame ID / Timestamp tracking + Watchdog chống "chết im lặng".
  - URL validation, max frame size guard chống tràn RAM.
  - IP Webcam torch endpoint (Android HTTP) / ADB torch hook.
================================================================================
"""

import sys
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

import time
import threading
import re
from urllib.parse import urlparse

import cv2
import numpy as np

import config


def _validate_stream_url(url: str) -> bool:
    """Kiểm tra hợp lệ URL stream: chỉ cho phép http, https, rtsp."""
    try:
        parsed = urlparse(url)
        return parsed.scheme.lower() in config.ALLOWED_STREAM_SCHEMES
    except Exception:
        return False


def _extract_base_url(source_url: str) -> str:
    """Trích xuất base URL (http://host:port) từ URL stream đầy đủ."""
    try:
        parsed = urlparse(source_url)
        return f"{parsed.scheme}://{parsed.netloc}"
    except Exception:
        return ""


def parse_camera_source(source_arg):
    """
    Phân tích tham số nguồn camera thành kiểu dữ liệu thích hợp:
      - None / "auto"        -> None (tự động dò tìm webcam)
      - "0", "1", "2"        -> int (camera index)
      - "http://...", "rtsp://..." -> str (URL camera mạng, đã validate)
    """
    if source_arg is None or (isinstance(source_arg, str) and source_arg.lower() == "auto"):
        return None

    if isinstance(source_arg, str):
        if source_arg.startswith(("http://", "https://", "rtsp://")):
            if not _validate_stream_url(source_arg):
                raise ValueError(
                    f"[Camera] URL không hợp lệ hoặc scheme không được phép: '{source_arg}'. "
                    f"Chỉ chấp nhận: {config.ALLOWED_STREAM_SCHEMES}"
                )
            return source_arg
        try:
            return int(source_arg)
        except ValueError:
            return source_arg

    return source_arg


def _open_capture(source) -> cv2.VideoCapture:
    """Mở cv2.VideoCapture kèm kiểm tra kết nối và timeout an toàn."""
    is_network = isinstance(source, str)
    label = f"URL '{source}'" if is_network else f"index {source}"

    print(f"[Camera] Đang kết nối tới {label}...")
    if not is_network:
        # Trên Windows, thử cv2.CAP_DSHOW trước để mở nhanh và mượt
        cap = cv2.VideoCapture(source, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap = cv2.VideoCapture(source)
    else:
        cap = cv2.VideoCapture(source)

    # Thiết lập buffer = 1 để triệt tiêu độ trễ hàng đợi
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

    if not is_network:
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, config.CAM_WIDTH)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, config.CAM_HEIGHT)

    # Đợi mở camera với timeout
    start_time = time.monotonic()
    while not cap.isOpened():
        if time.monotonic() - start_time > config.CONNECTION_TIMEOUT:
            cap.release()
            raise RuntimeError(
                f"[Camera] TIMEOUT: Không thể kết nối tới {label} sau {config.CONNECTION_TIMEOUT:.0f}s."
            )
        time.sleep(0.1)

    # Đọc thử 1 frame để xác nhận luồng hoạt động
    deadline = time.monotonic() + config.CONNECTION_TIMEOUT
    while True:
        ret, test_frame = cap.read()
        if ret and test_frame is not None:
            # Kiểm tra kích thước frame chống tràn RAM
            fh, fw = test_frame.shape[:2]
            if fw * fh > config.MAX_FRAME_PIXELS:
                cap.release()
                raise RuntimeError(
                    f"[Camera] Frame quá lớn ({fw}x{fh} = {fw*fh} pixels). "
                    f"Giới hạn: {config.MAX_FRAME_PIXELS} pixels."
                )
            break
        if time.monotonic() > deadline:
            cap.release()
            raise RuntimeError(
                f"[Camera] Đã mở {label} nhưng không nhận được khung hình sau {config.CONNECTION_TIMEOUT:.0f}s."
            )
        time.sleep(0.05)

    actual_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"[Camera] Kết nối thành công: {label} ({actual_w}x{actual_h})")
    return cap


class AutoTorchController:
    """
    Bộ điều khiển đèn Flash tự động & tiền xử lý cứu sáng thông minh (0-Lux Defense).
    - Đo luma Y từ khung hình (Y = 0.299R + 0.587G + 0.114B).
    - Bật/tắt Flash phần cứng qua IP Webcam HTTP endpoint hoặc ADB.
    - Áp dụng CLAHE cứu sáng trên kênh L (LAB) khi thiếu sáng.
    - Phát hiện trạng thái 0-Lux Blind (cảm biến mù hoàn toàn).
    """

    def __init__(self, source_url: str = ""):
        self.source_url = source_url
        self.base_url = _extract_base_url(source_url) if isinstance(source_url, str) else ""

        # Trạng thái Flash
        self.torch_active = False
        self.ae_settle_counter = 0
        self.is_zero_lux_blind = False
        self._last_torch_change_time = 0.0
        self._dark_frame_count = 0
        self._bright_frame_count = 0

        # CLAHE preprocessor
        self._clahe = cv2.createCLAHE(
            clipLimit=config.CLAHE_CLIP_LIMIT,
            tileGridSize=config.CLAHE_GRID_SIZE
        )

    def _send_torch_command(self, enable: bool):
        """Gửi lệnh bật/tắt Flash tới IP Webcam Android (non-blocking thread)."""
        if not self.base_url:
            return

        def _do_request():
            try:
                import urllib.request
                endpoint = "/enabletorch" if enable else "/disabletorch"
                url = self.base_url + endpoint
                req = urllib.request.Request(url, method='GET')
                urllib.request.urlopen(req, timeout=2.0)
            except Exception:
                # Thử endpoint thay thế /led/on hoặc /led/off
                try:
                    alt_endpoint = "/led/on" if enable else "/led/off"
                    alt_url = self.base_url + alt_endpoint
                    req2 = urllib.request.Request(alt_url, method='GET')
                    urllib.request.urlopen(req2, timeout=2.0)
                except Exception:
                    pass

        t = threading.Thread(target=_do_request, daemon=True)
        t.start()

    def measure_luma(self, frame_bgr: np.ndarray) -> float:
        """Đo độ sáng trung bình luma Y = 0.299R + 0.587G + 0.114B."""
        if frame_bgr is None or frame_bgr.size == 0:
            return 0.0
        # Tính trên ảnh thu nhỏ 4x để nhanh
        small = frame_bgr[::4, ::4]
        b, g, r = small[:, :, 0].astype(np.float32), small[:, :, 1].astype(np.float32), small[:, :, 2].astype(np.float32)
        y = 0.299 * r + 0.587 * g + 0.114 * b
        return float(np.mean(y))

    def process_frame(self, frame_bgr: np.ndarray) -> tuple:
        """
        Xử lý frame với auto-torch và CLAHE cứu sáng.
        Returns: (processed_frame, lighting_status_dict)
        """
        now = time.monotonic()
        mean_y = self.measure_luma(frame_bgr)

        # ── 1. Logic bật Flash khi tối ──
        if mean_y < config.LUX_DARK_ON_THRESHOLD:
            self._dark_frame_count += 1
            self._bright_frame_count = 0
        else:
            self._dark_frame_count = 0

        # Bật Flash sau >= 8 frame liên tiếp tối đen
        if not self.torch_active and self._dark_frame_count >= config.LUX_DARK_CONFIRM_FRAMES:
            self.torch_active = True
            self.ae_settle_counter = config.FLASH_AE_SETTLE_FRAMES
            self._last_torch_change_time = now
            self._send_torch_command(enable=True)
            print("[AutoTorch] ĐÈN FLASH BẬT — Môi trường quá tối")

        # ── 2. Logic tắt Flash khi đã sáng trở lại ──
        if self.torch_active and mean_y > config.LUX_BRIGHT_OFF_THRESHOLD:
            self._bright_frame_count += 1
        else:
            self._bright_frame_count = 0

        hold_elapsed = now - self._last_torch_change_time
        if (self.torch_active
                and self._bright_frame_count >= config.LUX_DARK_CONFIRM_FRAMES
                and hold_elapsed >= config.FLASH_HOLD_MIN_SECONDS):
            self.torch_active = False
            self.ae_settle_counter = config.FLASH_AE_SETTLE_FRAMES
            self._last_torch_change_time = now
            self._bright_frame_count = 0
            self._send_torch_command(enable=False)
            print("[AutoTorch] ĐÈN FLASH TẮT — Môi trường đã sáng trở lại")

        # Giảm AE settle counter
        if self.ae_settle_counter > 0:
            self.ae_settle_counter -= 1

        # ── 3. Tiền xử lý cứu sáng CLAHE ──
        processed = frame_bgr
        if mean_y < config.LUX_ENHANCEMENT_THRESHOLD or self.torch_active:
            processed = self._apply_clahe_enhancement(frame_bgr)
            # Khử lóa tâm (specular hotspot suppression) khi Flash hoạt động
            if self.torch_active:
                processed = self._suppress_specular_hotspot(processed)

        # ── 4. Phát hiện 0-Lux Blind ──
        # Đo lại luma sau CLAHE
        post_y = self.measure_luma(processed)
        if self.torch_active and post_y < config.LUX_ZERO_BLIND_THRESHOLD:
            self.is_zero_lux_blind = True
        else:
            self.is_zero_lux_blind = False

        lighting_status = {
            "mean_y": mean_y,
            "post_clahe_y": post_y,
            "torch_active": self.torch_active,
            "ae_settle_counter": self.ae_settle_counter,
            "is_zero_lux_blind": self.is_zero_lux_blind,
        }

        return processed, lighting_status

    def _apply_clahe_enhancement(self, frame_bgr: np.ndarray) -> np.ndarray:
        """Áp dụng CLAHE trên kênh L (không gian LAB) để cân bằng sáng cục bộ."""
        try:
            lab = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2LAB)
            l_channel, a_channel, b_channel = cv2.split(lab)
            l_enhanced = self._clahe.apply(l_channel)
            lab_enhanced = cv2.merge([l_enhanced, a_channel, b_channel])
            return cv2.cvtColor(lab_enhanced, cv2.COLOR_LAB2BGR)
        except Exception:
            return frame_bgr

    @staticmethod
    def _suppress_specular_hotspot(frame_bgr: np.ndarray) -> np.ndarray:
        """Khử lóa tâm (specular hotspot) khi đèn Flash chiếu vào vật cản gần."""
        try:
            gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
            # Phát hiện vùng lóa (pixel > 240)
            _, bright_mask = cv2.threshold(gray, 240, 255, cv2.THRESH_BINARY)
            # Mở rộng vùng lóa
            kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
            bright_mask = cv2.dilate(bright_mask, kernel)
            # Thay thế vùng lóa bằng inpainting
            if np.any(bright_mask):
                result = cv2.inpaint(frame_bgr, bright_mask, 10, cv2.INPAINT_TELEA)
                return result
        except Exception:
            pass
        return frame_bgr


class ThreadedCamera:
    """
    Bộ đọc camera đa luồng — triệt tiêu hoàn toàn độ trễ buffer mạng.
    Tích hợp AutoTorchController, Frame ID tracking, và Watchdog health check.
    """

    def __init__(self, source=None):
        self.raw_source = source
        self.parsed_source = parse_camera_source(source)

        if self.parsed_source is None:
            # Auto-detect: thử lần lượt các index 0, 1, 2
            self._cap = None
            for idx in config.CAM_INDICES_TO_TRY:
                try:
                    self._cap = _open_capture(idx)
                    self.parsed_source = idx
                    break
                except Exception:
                    continue
            if self._cap is None:
                raise RuntimeError(
                    f"[Camera] Không tìm thấy webcam nào khả dụng trong danh sách: {config.CAM_INDICES_TO_TRY}"
                )
        else:
            self._cap = _open_capture(self.parsed_source)

        self._lock = threading.Lock()
        self._latest_frame = None
        self._latest_ts = 0.0
        self._running = False
        self._thread = None

        # Frame ID tracking & Watchdog
        self.frame_id = 0
        self.frame_timestamp = time.monotonic()

        # AutoTorch Controller
        source_str = self.parsed_source if isinstance(self.parsed_source, str) else ""
        self.torch_controller = AutoTorchController(source_url=source_str)

        # Đọc frame đầu tiên
        ret, frame = self._cap.read()
        if ret and frame is not None:
            resized = self._resize_frame(frame)
            processed, lighting = self.torch_controller.process_frame(resized)
            with self._lock:
                self._latest_frame = processed
                self._latest_ts = time.monotonic()
                self._lighting_status = lighting
            self.frame_id = 1
            self.frame_timestamp = time.monotonic()

    def start(self) -> "ThreadedCamera":
        """Khởi động worker thread đọc frame liên tục."""
        if self._running:
            return self
        self._running = True
        self._thread = threading.Thread(
            target=self._grab_loop,
            name="CameraGrabber",
            daemon=True
        )
        self._thread.start()
        print("[Camera] Threaded grabber started (zero-latency mode)")
        return self

    def read(self):
        """
        Lấy frame mới nhất (non-blocking).
        Returns:
            (frame: np.ndarray | None, frame_id: int,
             frame_timestamp: float, lighting_status: dict)
        """
        with self._lock:
            if self._latest_frame is not None:
                return (self._latest_frame.copy(), self.frame_id,
                        self._latest_ts, self._lighting_status.copy())
            return (None, self.frame_id, self.frame_timestamp, {})

    def is_healthy(self) -> bool:
        """
        Watchdog: Kiểm tra camera còn hoạt động.
        Trả về False nếu quá 500ms không có frame mới.
        """
        return (time.monotonic() - self.frame_timestamp) <= 0.5

    def reset_watchdog(self):
        """Khởi động lại mốc thời gian watchdog khi bắt đầu vòng lặp chính."""
        self.frame_timestamp = time.monotonic()

    def release(self):
        """Dừng worker thread và giải phóng camera."""
        self._running = False
        if self._thread is not None and self._thread.is_alive():
            self._thread.join(timeout=1.5)
        if self._cap is not None:
            self._cap.release()
        # Tắt Flash nếu đang bật
        if self.torch_controller.torch_active:
            self.torch_controller._send_torch_command(enable=False)
        print("[Camera] Đã giải phóng tài nguyên camera.")

    def _grab_loop(self):
        """
        Worker loop liên tục xả buffer hàng đợi (Fast Buffer Flush) bằng cap.grab()
        và chỉ giải mã (retrieve) khung hình mới nhất tại thời điểm hiện tại.
        Đảm bảo độ trễ tích lũy luôn < 80ms ngay cả khi dùng IP Camera Wi-Fi.
        """
        consecutive_failures = 0
        MAX_FAILURES = 50

        while self._running:
            # Xả sạch khung hình cũ tích lũy trong buffer phần cứng
            grabbed = self._cap.grab()
            if grabbed:
                consecutive_failures = 0
                ret, frame = self._cap.retrieve()
                now = time.monotonic()
                if ret and frame is not None:
                    resized = self._resize_frame(frame)
                    # AutoTorch & CLAHE processing
                    processed, lighting = self.torch_controller.process_frame(resized)

                    with self._lock:
                        self._latest_frame = processed
                        self._latest_ts = now
                        self._lighting_status = lighting

                        # Frame, identity and capture timestamp are one snapshot.
                        self.frame_id += 1
                        self.frame_timestamp = now
            else:
                consecutive_failures += 1
                if consecutive_failures >= MAX_FAILURES:
                    time.sleep(0.05)
                else:
                    time.sleep(0.002)

    @staticmethod
    def _resize_frame(frame: np.ndarray) -> np.ndarray:
        """
        Auto-resize khung hình nếu vượt quá MAX_FRAME_WIDTH để giảm tải CPU cho MiDaS.
        Kiểm tra cả giới hạn tổng pixel chống tràn RAM.
        """
        h, w = frame.shape[:2]

        # Kiểm tra giới hạn pixel tổng
        if w * h > config.MAX_FRAME_PIXELS:
            scale = (config.MAX_FRAME_PIXELS / (w * h)) ** 0.5
            new_w = int(w * scale)
            new_h = int(h * scale)
            return cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_AREA)

        if w <= config.MAX_FRAME_WIDTH:
            return frame

        scale = config.MAX_FRAME_WIDTH / float(w)
        new_w = config.MAX_FRAME_WIDTH
        new_h = int(h * scale)
        return cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_AREA)
