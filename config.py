"""
HorusEyes 2.0 - Configuration Module
================================================================================
Tập trung toàn bộ hằng số cấu hình, tham số hình học, ngưỡng TTC,
và tham số tổng hợp âm thanh không gian 3D Binaural cho HorusEyes 2.0.
================================================================================
"""

# ── Camera & Video Stream ─────────────────────────────────────────────────────
CAM_WIDTH          = 640
CAM_HEIGHT         = 480
MAX_FRAME_WIDTH    = 640                 # Auto-resize khung hình trước khi đưa vào MiDaS
MAX_FRAME_HEIGHT   = 1080                # Giới hạn chiều cao tối đa chống tràn RAM
MAX_FRAME_PIXELS   = 1920 * 1080         # Giới hạn tổng pixel tối đa trước cấp phát bộ nhớ
CAM_INDICES_TO_TRY = [0, 1, 2]          # Fallback dò webcam khi không truyền --source
CONNECTION_TIMEOUT = 5.0                 # Giây — timeout kết nối camera mạng
DEFAULT_FPS        = 30
DEFAULT_SOURCE     = "0"                 # Webcam mặc định hoặc URL IP Camera
ALLOWED_STREAM_SCHEMES = ("http", "https", "rtsp")  # Chỉ cho phép các scheme hợp lệ

# ── Low-Light & Auto-Torch (Cơ chế phòng thủ 0-Lux) ─────────────────────────
LUX_DARK_ON_THRESHOLD      = 28.0       # Mean luma Y < 28 → kích hoạt chế độ 0-Lux / bật Flash
LUX_BRIGHT_OFF_THRESHOLD   = 75.0       # Hysteresis tắt Flash khi môi trường đã sáng trở lại
FLASH_HOLD_MIN_SECONDS     = 5.0        # Thời gian giữ Flash tối thiểu giữa 2 lần chuyển đổi
FLASH_AE_SETTLE_FRAMES     = 5          # Số frame bỏ qua biến thiên vận tốc sau khi bật/tắt Flash
LUX_ENHANCEMENT_THRESHOLD  = 45.0       # Mean Y < 45 → áp dụng CLAHE cứu sáng
LUX_ZERO_BLIND_THRESHOLD   = 10.0       # Mean Y < 10 sau khi đã bật Flash+CLAHE → cảm biến mù
LUX_DARK_CONFIRM_FRAMES    = 8          # Số frame liên tiếp tối đen để xác nhận bật Flash
CLAHE_CLIP_LIMIT           = 2.5        # CLAHE clip limit cho cân bằng sáng cục bộ
CLAHE_GRID_SIZE            = (8, 8)     # CLAHE tile grid size

# ── MiDaS Model ───────────────────────────────────────────────────────────────
MIDAS_REPO         = "intel-isl/MiDaS"
MIDAS_MODEL        = "MiDaS_small"

# ── ONNX Model SHA-256 Hash Verification ──────────────────────────────────────
# Bảng hash SHA-256 xác thực tính toàn vẹn file .onnx trước khi nạp
ONNX_SHA256_HASHES = {
    # Tự động cập nhật khi build: sha256sum midas_small_*.onnx
    # Đặt None để bỏ qua kiểm tra (chế độ dev)
    "midas_small_128.onnx": None,
    "midas_small_160.onnx": None,
    "midas_small_192.onnx": None,
    "midas_small_256.onnx": None,
    "model-small.onnx": None,
    "model-small-int8.onnx": None,
}

# ── Hiệu chuẩn độ sâu Metric Monotonic (PCHIP Spline / NYU Depth V2) ──────────
# Các mốc (knot nodes) bám sát trung vị thực nghiệm NYU Depth V2 [13cm - 350cm]:
CALIBRATION_NODES = [
    (135.0,  350.0), # Phòng sâu / vô cực (>3.5m)
    (175.0,  300.0), # 3.0m: Tường xa, cuối phòng
    (235.0,  250.0), # 2.5m: Ngưỡng an toàn tuyệt đối (Clear Corridor)
    (295.0,  200.0), # 2.0m: Cửa ra vào xa, trần nhà
    (375.0,  150.0), # 1.5m: Vách tường 1.5m / Ngưỡng lưu ý
    (505.0,  100.0), # 1.0m: Cánh cửa 1.0m, bậc cầu thang
    (560.0,   70.0), # 70cm: Ngưỡng cảnh báo va chạm
    (650.0,   50.0), # 50cm: Bức tường phẳng 50cm, tay vịn 50cm
    (800.0,   30.0), # 30cm: Ngưỡng DANGER (bàn tay cự ly 28-30cm)
    (950.0,   20.0), # 20cm: Vật cản tiếp cận khẩn cấp
    (1200.0,  13.0), # 13cm: CRITICAL SATURATION (Chạm sát thấu kính)
]
DEFAULT_DIST_SCALE = 1.00                # Hệ số bù tiêu cự camera (chỉnh phím [ / ])

# Ngưỡng khoảng cách vật lý (cm) — dịch ra xa hơn phù hợp thời gian phản xạ con người
DIST_CRITICAL_CM   = 40.0                # < 40cm: Cực kỳ nguy hiểm, khẩn cấp tối đa
DIST_DANGER_CM     = 80.0                # < 80cm: Vùng nguy hiểm va chạm
DIST_WARNING_CM    = 140.0               # 80-140cm: Vùng cảnh báo
DIST_ALERT_CM      = 200.0               # 140-200cm: Vùng lưu ý (CAUTION)
DIST_SAFE_CM       = 250.0               # > 250cm: Hành lang an toàn, im lặng

# ── Geometric Floor/Ceiling Masking ───────────────────────────────────────────
TOP_MASK_RATIO           = 0.15          # Mặt nạ cắt 15% đỉnh ảnh (loại bỏ trần nhà, đèn chùm)
BOTTOM_MASK_RATIO        = 0.15          # Mặt nạ cắt 15% đáy ảnh (loại bỏ sàn chân, mặt bàn)

# ── Overhead & Drop-Off Hazard Detection ──────────────────────────────────────
OVERHEAD_DEPTH_DELTA_CM  = 40.0          # Vật nhô gần hơn nền >= 40cm → OVERHEAD_HAZARD
DROP_OFF_GRADIENT_THRESH = 0.25          # Gradient độ sâu dọc bất thường → DROP_OFF_HAZARD

# ── Base Activation Threshold (Chống báo ảo phòng trống) ─────────────────────
BASE_ACTIVATION_RAW      = 375.0         # Phân vị 95 vùng trung tâm < 375.0 (tương đương đúng 150.0cm trong PCHIP) -> ép im lặng
BASE_ACTIVATION_PEAK     = 520.0         # Phân vị 99 toàn khung hình < 520.0 -> ép im lặng tuyệt đối

# ── Lens Saturation / Close Blocker (Vật cản áp sát thấu kính) ────────────────
SATURATION_CENTER_RATIO  = 0.25          # Pixel áp sát chiếm > 25% vùng trung tâm (50%x50% khung hình)
SATURATION_RAW_THRESHOLD = 800.0         # Raw disparity >= 800 tương đương cự ly sát mắt kính (<30cm)
SATURATION_GLOBAL_RATIO  = 0.60          # Hoặc chiếm > 60% toàn bộ khung hình

# ── Spatial Obstacle Extraction & Segmentation ────────────────────────────────
MIN_OBSTACLE_AREA_RATIO  = 0.015         # Giảm từ 0.2% xuống 1.5% để bắt vật cản mảnh (cột, gậy, cành cây)
DISCONTINUITY_STEP_MIN   = 0.16          # Bước nhảy độ sâu tối thiểu
DISCONTINUITY_GRAD_MIN   = 3.5           # Gradient viền tối thiểu
DISCONTINUITY_STEP_HIGH  = 0.28          # Ngưỡng bước nhảy tương phản cao
PROXIMITY_POWER          = 1.2           # Phi tuyến hóa cảm nhận khoảng cách proximity

# ── Time-To-Collision (TTC) & Kinematics Thresholds ────────────────────────────
TTC_CRITICAL       = 1.0                 # < 1.0s: Cực kỳ nguy cấp -> Âm thanh dồn dập + Panning né
TTC_WARNING        = 2.5                 # 1.0s - 2.5s: Cảnh báo sớm -> Âm thanh theo nhịp
TTC_SAFE           = 4.0                 # > 2.5s hoặc v_z <= 0: An toàn -> Im lặng
TTC_EPSILON        = 0.10                # Tránh chia cho 0 khi tính Priority Score
# ── Mốc dao động & Kích hoạt Track Di Chuyển (Motion Activation Threshold) ─────
MOTION_DISP_THRESHOLD_CM = 12.0       # Mốc dao động tối thiểu (cm): Biến thiên cự ly >= 12.0cm mới bật track di chuyển
MOTION_HISTORY_LEN       = 8          # Chiều dài cửa sổ lưu lịch sử khoảng cách (8 frames ~ 0.27s)
VELOCITY_SMOOTHING       = 0.40       # EMA alpha cho vận tốc tiếp cận v_z (làm mượt tốt hơn)
VZ_DEADBAND_CM_S         = 20.0       # Vùng chết vận tốc: |vz| < 20 cm/s coi là tĩnh tuyệt đối (0.0 cm/s)
VZ_MIN_APPROACH_CM_S     = 20.0       # Đồng bộ với deadband: Ngưỡng vận tốc tiếp cận tối thiểu (+20 cm/s) để kích hoạt TTC
MIN_NET_DISPLACEMENT_CM  = 8.0        # Độ dời tịnh tiến tối thiểu qua cửa sổ trượt (>= 8cm) để xác nhận tiến tới
MOTION_CONFIRM_FRAMES    = 1          # Cần duy trì tiếp cận >= 1 frame (vượt ngưỡng delta d >= 8cm, vz >= 20cm/s)

# ── Ego-Motion Compensation ───────────────────────────────────────────────────
EGO_MOTION_PERCENTILE    = 25           # Phân vị thứ 25 để ước lượng v_ego từ biên nền
USER_WALK_SPEED_CM_S     = 120.0        # Vận tốc đi bộ ước lượng mặc định (cm/s)

# ── Risk-Aware Safe Path Guidance & Sector Safety Score ───────────────────────
SAFETY_W_CLEARANCE       = 0.50        # Trọng số không gian mở & cự ly khả dụng
SAFETY_W_TTC             = 0.35        # Trọng số phạt rủi ro va chạm TTC
SAFETY_W_VZ              = 0.15        # Trọng số phạt vận tốc tiếp cận v_z
SECTOR_HYSTERESIS_MARGIN = 0.10        # Biên chênh lệch tối thiểu để chuyển hướng né (chống rung giật)
SECTOR_DEADLOCK_THRESH   = 0.08        # Ngưỡng tắc nghẽn lưỡng diện kích hoạt STOP (HAZARD_BLOCKED, cự ly < 40cm)

# ── Auditory Budget Coordinator ───────────────────────────────────────────────
MAX_ACTIVE_STREAMS = 1                   # Ngân sách cứng: Tối đa 1 stream âm thanh
HYSTERESIS_DECAY   = 0.50                # Giảm 50% âm lượng khi người dùng đang né tránh
UNCERTAINTY_BLUR_THRESHOLD     = 0.48    # Ngưỡng kích hoạt Acoustic Blur (vượt >= 0.48 mới phát âm nhòe)
UNCERTAINTY_SHARP_THRESHOLD    = 0.38    # Hysteresis: quay về Sharp Ping khi u <= 0.38 (chống nhảy qua lại)

# ── 3D Binaural Spatial Audio Synthesis ───────────────────────────────────────
AUDIO_SAMPLE_RATE  = 44100               # Hz
AUDIO_CHANNELS     = 2                   # Stereo
AUDIO_BLOCKSIZE    = 1024                # Frames per callback
MAX_ITD_SAMPLES    = 28                  # ~0.65ms trễ thời gian giữa 2 tai (chuẩn đầu người 17cm)
ILD_MAX_ATTENUATION_DB = 18.0            # Suy giảm tối đa tai xa (dB) — head shadow
ILD_EXPONENT       = 1.8                 # Hệ số tương phản Interaural Level Difference (~20dB)

FREQ_MIN           = 350.0               # Hz (vật xa -> âm trầm)
FREQ_MAX           = 950.0               # Hz (vật gần -> âm cao báo động)
BEEP_INTERVAL_MAX  = 1.80                # Giây (vật xa -> thưa)
BEEP_INTERVAL_MIN  = 0.08                # Giây (vật gần/TTC ngắn -> dồn dập)
BEEP_DURATION      = 0.05                # Giây mỗi tiếng beep

# ── System Fault Tone (Âm báo lỗi hệ thống) ─────────────────────────────────
FAULT_TONE_FREQ_HI = 440.0              # Hz — xung kép đầu tiên
FAULT_TONE_FREQ_LO = 330.0              # Hz — xung kép thứ hai
FAULT_TONE_DURATION = 0.15              # Giây mỗi xung
FAULT_TONE_GAP     = 0.05               # Khoảng cách giữa 2 xung

# ── Auditory Earcons (Âm xác nhận thao tác) ──────────────────────────────────
EARCON_PAUSE_FREQ      = 600.0          # Hz — Pause/Resume
EARCON_MUTE_FREQ       = 500.0          # Hz — Mute/Unmute
EARCON_FLASH_ON_FREQ   = 800.0          # Hz — Flash bật
EARCON_FLASH_OFF_FREQ  = 400.0          # Hz — Flash tắt
EARCON_DURATION        = 0.08           # Giây

# ── Acoustic Blur DSP (Dual-Tone FM Warble) ───────────────────────────────────
BLUR_FM_DEVIATION_HZ   = 35.0           # Độ lệch điều chế tần số ±35 Hz
BLUR_FM_RATE_HZ        = 18.0           # Nhịp điều chế FM (18 Hz)
BLUR_SUBHARMONIC_GAIN  = 0.15           # Biên độ hài bậc 2 sub-harmonic shimmer

# ── Peak Limiter ──────────────────────────────────────────────────────────────
PEAK_LIMITER_THRESHOLD_DBFS = -1.0       # Soft-knee limiter tại -1.0 dBFS

# ── Sector Partitions ─────────────────────────────────────────────────────────
SECTOR_LEFT_SPLIT  = 0.33                # 0 -> 33%: Vùng Trái
SECTOR_RIGHT_SPLIT = 0.66                # 66% -> 100%: Vùng Phải

# ── Visualization ─────────────────────────────────────────────────────────────
COLORMAP           = 4                   # cv2.COLORMAP_MAGMA
FPS_SMOOTHING      = 0.9                 # EMA cho FPS

# DEMO-READY-01: content integrity of the existing self-contained MiDaS asset.
# This pin identifies repository bytes; it is not proof of physical calibration.
DEMO_MODEL_PATH = "android/app/src/main/assets/midas_small.onnx"
ONNX_SHA256_HASHES["midas_small.onnx"] = "0f6727bda50b289a803b8146cdf531dae409927600f017778d07828ba6f1f82d"
FRAME_TIMEOUT_SEC = 1.0
