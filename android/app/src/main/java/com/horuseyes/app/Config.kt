package com.horuseyes.app

/**
 * HorusEyes 2.0 - Central System Hyperparameters & Constants (Hardened)
 * Ported with 100% mathematical parity from Python config.py for Android Native Edge execution.
 */
object Config {
    // ── Perception & AI Inference Dimensions ──
    const val INPUT_WIDTH: Int = 192             // Chiều rộng input portrait (192)
    const val INPUT_HEIGHT: Int = 256            // Chiều cao input portrait (256, tỷ lệ 3:4 chuẩn Camera)
    const val CAM_WIDTH: Int = 480               // Độ phân giải CameraX portrait width
    const val CAM_HEIGHT: Int = 640              // Độ phân giải CameraX portrait height

    // ── Low-Light / Auto-Torch & 0-Lux Defense ──
    const val LUX_DARK_ON_THRESHOLD: Float = 28.0f       // Độ sáng luma Y (0-255) kích hoạt 0-Lux / Bật Flash
    const val LUX_BRIGHT_OFF_THRESHOLD: Float = 75.0f    // Ngưỡng tắt Flash chống nhấp nháy
    const val FLASH_HOLD_MIN_SECONDS: Float = 5.0f       // Thời gian giữ Flash tối thiểu giữa 2 lần chuyển đổi
    const val FLASH_AE_SETTLE_FRAMES: Int = 5            // Số frame bỏ qua biến thiên vận tốc chờ Auto-Exposure
    const val LUX_ZERO_BLIND_THRESHOLD: Float = 10.0f    // Dưới 10.0 Y -> Cảm biến bị che đen hoặc 0-Lux tuyệt đối
    const val CLAHE_CLIP_LIMIT: Float = 2.5f

    // ── Geometric Filtering Masks ──
    const val TOP_MASK_RATIO: Float = 0.15f      // Loại bỏ 15% đỉnh ảnh (trần nhà / đèn chùm)
    const val BOTTOM_MASK_RATIO: Float = 0.15f   // Loại bỏ 15% đáy ảnh (mặt sàn cận cảnh)
    const val OVERHEAD_DEPTH_DELTA_CM: Float = 40.0f     // Vật nhô gần hơn nền >= 40cm -> OVERHEAD_HAZARD
    const val DROP_OFF_GRADIENT_THRESH: Float = 0.25f    // Gradient độ sâu dọc bất thường -> DROP_OFF_HAZARD

    // ── Sector Splits ──
    const val SECTOR_LEFT_SPLIT: Float = 0.33f
    const val SECTOR_RIGHT_SPLIT: Float = 0.66f

    // ── Hiệu chuẩn độ sâu Metric Monotonic (PCHIP Spline / NYU Depth V2) ──
    val RAW_KNOTS: FloatArray = floatArrayOf(
        135.0f, 175.0f, 235.0f, 295.0f, 375.0f, 505.0f, 560.0f, 650.0f, 800.0f, 950.0f, 1200.0f
    )
    val CM_KNOTS: FloatArray = floatArrayOf(
        350.0f, 300.0f, 250.0f, 200.0f, 150.0f, 100.0f, 70.0f, 50.0f, 30.0f, 20.0f, 13.0f
    )
    const val DEFAULT_DIST_SCALE: Float = 1.00f

    // ── Lens Saturation Trigger (<15cm Close Blocker) ──
    const val SATURATION_RAW_THRESH: Float = 800.0f
    const val SATURATION_CENTER_RATIO: Float = 0.25f
    const val SATURATION_GLOBAL_RATIO: Float = 0.60f
    const val SATURATION_DIST_CM: Float = 13.0f

    // ── Distance Safety Thresholds (cm) — Cập nhật dịch ngưỡng an toàn ──
    const val DIST_CRITICAL_CM: Float = 40.0f     // < 40cm: Cực kỳ nguy hiểm, khẩn cấp tối đa
    const val DIST_DANGER_CM: Float = 80.0f       // 40 - 80cm: Vùng nguy hiểm va chạm tĩnh
    const val DIST_WARNING_CM: Float = 140.0f     // 80 - 140cm: Vùng cảnh báo tiếp cận
    const val DIST_ALERT_CM: Float = 200.0f       // 140 - 200cm: Vùng lưu ý (CAUTION)
    const val DIST_SAFE_CM: Float = 250.0f        // > 250cm: Không gian an toàn tuyệt đối

    // ── Base Activation & Stable Obstacle Extraction ──
    const val BASE_ACTIVATION_RAW: Float = 375.0f   // Dưới 375.0 (>150cm) -> Không gian thoáng an toàn
    const val BASE_ACTIVATION_PEAK: Float = 520.0f  // Dưới 520 (>90cm) -> Ép im lặng chống báo ảo
    const val MIN_OBSTACLE_AREA_RATIO: Float = 0.015f // Bắt vật cản mảnh (cột, gậy, cành cây: 1.5% ROI)
    const val DISCONTINUITY_STEP_MIN: Float = 0.16f // Bước nhảy tương phản tối thiểu
    const val DISCONTINUITY_GRAD_MIN: Float = 3.5f  // Gradient biên tối thiểu
    const val DISCONTINUITY_STEP_HIGH: Float = 0.28f // Bước nhảy tương phản cao
    const val PROXIMITY_POWER: Float = 1.2f

    // ── Kinematics & Collision Prediction (TTC in seconds) ──
    const val TTC_CRITICAL: Float = 1.0f          // < 1.0s: Cực kỳ nguy cấp -> Preemption tức thời
    const val TTC_WARNING: Float = 2.5f           // 1.0s - 2.5s: Cảnh báo sớm
    const val TTC_SAFE: Float = 4.0f              // > 4.0s: An toàn -> Im lặng
    const val TTC_EPSILON: Float = 0.10f

    // ── Risk-Aware Safe Path Guidance & Sector Safety Score ──
    const val SAFETY_W_CLEARANCE: Float = 0.50f
    const val SAFETY_W_TTC: Float = 0.35f
    const val SAFETY_W_VZ: Float = 0.15f
    const val SECTOR_HYSTERESIS_MARGIN: Float = 0.10f
    const val SECTOR_DEADLOCK_THRESH: Float = 0.08f

    // ── Approach Velocity & Motion Activation Threshold ──
    const val MOTION_DISP_THRESHOLD_CM: Float = 12.0f // Mốc dao động tối thiểu để bật track di chuyển (cm)
    const val MOTION_HISTORY_LEN: Int = 8          // Chiều dài cửa sổ lưu lịch sử khoảng cách (8 frames)
    const val VZ_MIN_APPROACH_CM_S: Float = 20.0f  // Đồng bộ với deadband: Ngưỡng tiếp cận tối thiểu (+20 cm/s)
    const val VZ_DEADBAND_CM_S: Float = 20.0f      // Vùng chết triệt tiêu rung lắc (|vz| < 20.0 cm/s -> vz = 0)
    const val MIN_NET_DISPLACEMENT_CM: Float = 8.0f // Độ dịch chuyển tịnh tiến tích lũy tối thiểu (cm)
    const val VELOCITY_SMOOTHING: Float = 0.40f    // Hệ số EMA làm mượt vận tốc (alpha = 0.40)
    const val MOTION_CONFIRM_FRAMES: Int = 1       // Cần duy trì >= 1 frame tiếp cận
    const val USER_WALK_SPEED_CM_S: Float = 120.0f // Vận tốc đi bộ ước lượng (cm/s) cho Ego-Motion

    // ── Spatial Audio Synthesis & Psychoacoustics ──
    const val SAMPLE_RATE: Int = 44100
    const val BEEP_MIN: Float = 0.08f              // Nhịp bíp khẩn cấp nhất (giây)
    const val BEEP_MAX: Float = 1.80f              // Nhịp bíp thưa khi cảnh báo xa (giây)
    const val BASE_FREQ: Float = 350.0f            // Tần số khi vật ở xa (Hz)
    const val CRITICAL_FREQ: Float = 950.0f        // Tần số khi khẩn cấp (Hz)
    const val BEEP_DURATION_MS: Int = 50           // Độ dài xung bíp (ms)
    const val MAX_ITD_SAMPLES: Int = 28            // ~0.65ms trễ thời gian giữa 2 tai
    const val ILD_MAX_ATTENUATION_DB: Float = 18.0f // Head shadow suy giảm tối đa -18dB
    const val ILD_EXPONENT: Float = 1.8f           // Hệ số mũ tương phản ILD (~20dB)
    const val LIMITER_THRESHOLD_DBFS: Float = -1.0f // Soft-knee peak limiter (-1.0 dBFS)

    // ── System Fault Tone & Auditory Earcons ──
    const val FAULT_TONE_FREQ_HI: Float = 440.0f   // Xung kép thứ 1 (Hz)
    const val FAULT_TONE_FREQ_LO: Float = 330.0f   // Xung kép thứ 2 (Hz)
    const val EARCON_PAUSE_FREQ: Float = 600.0f    // Pause/Resume (Hz)
    const val EARCON_MUTE_FREQ: Float = 500.0f     // Mute/Unmute (Hz)
    const val EARCON_FLASH_ON_FREQ: Float = 800.0f // Flash bật (Hz)
    const val EARCON_FLASH_OFF_FREQ: Float = 400.0f// Flash tắt (Hz)

    // ── Acoustic Blur DSP (Dual-Tone FM Warble) ──
    const val BLUR_FM_DEVIATION_HZ: Float = 35.0f  // Độ lệch điều chế FM +-35Hz
    const val BLUR_FM_RATE_HZ: Float = 18.0f       // Nhịp điều chế FM (18Hz)

    // ── Auditory Budget & Cognitive Load Regulation ──
    const val MAX_ACTIVE_STREAMS: Int = 1
    const val HYSTERESIS_BOOST: Float = 1.15f      // +15% ưu tiên giữ mục tiêu đang active
    const val MIN_HOLD_FRAMES: Int = 5             // Giữ tối thiểu 5 frame trước khi nhường quyền
    const val SWITCH_CONFIRM_FRAMES: Int = 3       // Mục tiêu mới phải vượt trội 3 frame
    const val UNCERTAINTY_BLUR_THRESHOLD: Float = 0.48f // Kích hoạt Acoustic Blur khi u >= 0.48
    const val UNCERTAINTY_SHARP_THRESHOLD: Float = 0.38f // Quay về Sharp Ping khi u <= 0.38
    const val HYSTERESIS_DECAY: Float = 0.50f      // Giảm 50% âm lượng khi người dùng đang né tránh
}
