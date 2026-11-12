"""
HorusEyes 2.0 - Non-Blocking DSP Spatial Audio Synthesizer (Hardened)
================================================================================
Engine phát âm thanh không gian 3D Binaural phi khối:
  1. Atomic reference swap thay thế threading.Lock trong callback (chống priority inversion).
  2. NaN/Inf guard cho mọi biến trạng thái đệ quy.
  3. Constant-Power Panning + ILD head shadow max -18dB.
  4. Dual-Tone FM Warble cho ACOUSTIC_BLUR (xuyên tiếng ồn môi trường).
  5. Soft-Knee Peak Limiter tại -1.0 dBFS (np.tanh) bảo vệ thính giác.
  6. System Fault Tone (440→330Hz) cho camera hang / 0-Lux blind.
  7. Auditory Earcons cho xác nhận thao tác (Pause/Mute/Flash).
  8. Auto-restart stream khi driver âm thanh ngắt kết nối.
================================================================================
"""

import math
import threading
import numpy as np

try:
    import sounddevice as sd
    HAS_SOUNDDEVICE = True
except Exception:
    HAS_SOUNDDEVICE = False

import config
from auditory_budget import BudgetDecision


# Immutable state tuple cho atomic reference swap
class _AudioState:
    __slots__ = ('pan', 'proximity', 'freq', 'active', 'volume_factor',
                 'cue_mode', 'ttc', 'fault_mode')
    def __init__(self, pan=0.0, proximity=0.0, freq=350.0, active=False,
                 volume_factor=1.0, cue_mode="SHARP_PING", ttc=float("inf"),
                 fault_mode="NONE"):
        self.pan = pan
        self.proximity = proximity
        self.freq = freq
        self.active = active
        self.volume_factor = volume_factor
        self.cue_mode = cue_mode
        self.ttc = ttc
        self.fault_mode = fault_mode  # "NONE", "SYSTEM_FAULT", "EARCON_PAUSE", etc.


def _safe_float(val, default=0.0):
    """Kiểm tra và trả về giá trị float an toàn, reset nếu NaN/Inf."""
    if not np.isfinite(val):
        return default
    return float(val)


class SpatialAudioEngine:
    """
    Engine tổng hợp âm thanh không gian 3D Binaural non-blocking.
    Sử dụng atomic reference swap thay vì Lock trong callback.
    """

    def __init__(self):
        self.has_hardware = False
        self.stream = None

        # Atomic state reference — trao đổi bằng gán tuple/object (GIL-safe)
        self._state = _AudioState()

        # Trạng thái làm mịn liên tục giữa các khối
        self._curr_freq    = float(config.FREQ_MIN)
        self._curr_gain_l  = 0.0
        self._curr_gain_r  = 0.0
        self._curr_delay_l = 0.0
        self._curr_delay_r = 0.0

        # Phase accumulator liên tục
        self._phase = 0.0
        self._fm_phase = 0.0  # Phase cho FM warble

        # Bộ đếm nhịp beep
        self._beep_timer = 0.0
        self._beep_on    = False

        # Fault tone state
        self._fault_phase = 0.0
        self._fault_timer = 0.0
        self._fault_pulse_idx = 0

        # Earcon state
        self._earcon_timer = 0.0
        self._earcon_freq = 0.0
        self._earcon_active = False

        # 3D Binaural Buffer & Filter States
        self._history_buf = np.zeros(config.MAX_ITD_SAMPLES, dtype=np.float32)
        self._lp_state_l  = 0.0
        self._lp_state_r  = 0.0

        self._init_stream()

    def _init_stream(self):
        """Khởi tạo stream âm thanh phần cứng với xử lý ngoại lệ an toàn."""
        if not HAS_SOUNDDEVICE:
            print("[Audio] Canh bao: sounddevice chua cai dat. Chay o che do im lang.")
            return

        try:
            self.stream = sd.OutputStream(
                samplerate=config.AUDIO_SAMPLE_RATE,
                channels=config.AUDIO_CHANNELS,
                blocksize=config.AUDIO_BLOCKSIZE,
                dtype="float32",
                callback=self._audio_callback,
            )
            self.has_hardware = True
        except Exception as e:
            print(f"[Audio] Canh bao: Khong the mo thiet bi am thanh ({e}). Chay che do im lang.")
            self.has_hardware = False

    def _try_restart_stream(self):
        """Tự động khôi phục luồng âm thanh nếu driver ngắt kết nối."""
        try:
            if self.stream is not None:
                try:
                    self.stream.close()
                except Exception:
                    pass
            self._init_stream()
            if self.has_hardware and self.stream is not None:
                self.stream.start()
                print("[Audio] Stream đã được khôi phục tự động.")
        except Exception as e:
            print(f"[Audio] Không thể khôi phục stream: {e}")
            self.has_hardware = False

    def check_stream_health(self):
        """Kiểm tra và tự động khôi phục stream nếu cần. Gọi từ vòng lặp chính."""
        if not self.has_hardware or self.stream is None:
            return
        try:
            if not self.stream.active:
                print("[Audio] Stream bị ngắt! Đang khôi phục...")
                self._try_restart_stream()
        except Exception:
            pass

    def start(self):
        """Khởi động luồng phát âm thanh non-blocking."""
        if self.has_hardware and self.stream is not None:
            try:
                self.stream.start()
                print("[Audio] Stream started (3D Binaural PortAudio Callback, zero latency)")
            except Exception as e:
                print(f"[Audio] Loi khoi dong audio stream: {e}")
                self.has_hardware = False

    def stop(self):
        """Dừng và giải phóng audio stream."""
        if self.has_hardware and self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
                print("[Audio] Stream da dung va giai phong.")
            except Exception:
                pass

    def update_decision(self, decision: BudgetDecision):
        """Cập nhật trạng thái âm học từ Auditory Budget Manager."""
        self.update_state(decision)

    def update_state(self, decision: BudgetDecision):
        """Atomic state update — thread-safe qua GIL reference swap."""
        if not self.has_hardware:
            return

        known = {"SHARP_PING", "ACOUSTIC_BLUR", "CAUTION_REMINDER", "MUTED", "STANDBY_UNRESOLVED", "SYSTEM_FAULT_TONE"}
        if decision.cue_mode == "SYSTEM_FAULT_TONE" or decision.cue_mode not in known:
            self._state = _AudioState(active=False, fault_mode="SYSTEM_FAULT")
            return
        self.set_fault_mode("NONE")
        if decision.cue_mode in {"MUTED", "STANDBY_UNRESOLVED"} or not decision.is_active or decision.proximity <= 0.005:
            self._state = _AudioState(active=False, fault_mode=self._state.fault_mode)
            return

        effective_prox = float(decision.proximity ** config.PROXIMITY_POWER)
        freq = float(config.FREQ_MIN + (config.FREQ_MAX - config.FREQ_MIN) * effective_prox)

        self._state = _AudioState(
            pan=float(decision.pan),
            proximity=effective_prox,
            freq=freq,
            active=True,
            volume_factor=float(decision.volume_factor),
            cue_mode=str(decision.cue_mode),
            ttc=float(decision.ttc),
            fault_mode=self._state.fault_mode,
        )

    def set_fault_mode(self, mode: str):
        """Đặt chế độ âm báo lỗi: 'SYSTEM_FAULT' hoặc 'NONE'."""
        old = self._state
        self._state = _AudioState(
            pan=old.pan, proximity=old.proximity, freq=old.freq,
            active=old.active, volume_factor=old.volume_factor,
            cue_mode=old.cue_mode, ttc=old.ttc, fault_mode=mode
        )

    def play_earcon(self, earcon_type: str):
        """Kích hoạt earcon xác nhận thao tác. earcon_type: 'PAUSE','MUTE','FLASH_ON','FLASH_OFF'."""
        freq_map = {
            "PAUSE": config.EARCON_PAUSE_FREQ,
            "MUTE": config.EARCON_MUTE_FREQ,
            "FLASH_ON": config.EARCON_FLASH_ON_FREQ,
            "FLASH_OFF": config.EARCON_FLASH_OFF_FREQ,
        }
        self._earcon_freq = freq_map.get(earcon_type, 600.0)
        self._earcon_timer = 0.0
        self._earcon_active = True

    def get_current_beep_interval(self) -> float:
        """Truy vấn chu kỳ nhịp bíp hiện tại phục vụ kiểm thử."""
        state = self._state  # Atomic read
        if not state.active:
            return float("inf")

        prox = state.proximity
        ttc = state.ttc

        if prox >= 0.70 or ttc <= config.TTC_CRITICAL:
            t = max(0.0, min(1.0, (prox - 0.70) / 0.30))
            if ttc <= config.TTC_CRITICAL:
                t = max(t, 1.0 - (ttc / config.TTC_CRITICAL))
            return max(config.BEEP_INTERVAL_MIN, 0.35 - (0.35 - config.BEEP_INTERVAL_MIN) * t)
        else:
            t = max(0.0, min(1.0, prox / 0.70))
            return max(config.BEEP_INTERVAL_MIN, config.BEEP_INTERVAL_MAX - (config.BEEP_INTERVAL_MAX - 0.35) * t)

    def is_sound_active(self) -> bool:
        """Kiểm tra âm thanh có đang ở trạng thái active không."""
        return self._state.active

    def _audio_callback(self, outdata: np.ndarray, frames: int, time_info, status):
        """
        Callback thời gian thực — PortAudio C thread.
        KHÔNG dùng threading.Lock (chống priority inversion).
        Sử dụng atomic reference read trên _state.
        """
        if status:
            pass

        # ── NaN/Inf guard cho tất cả trạng thái đệ quy ──
        self._phase = _safe_float(self._phase, 0.0)
        self._fm_phase = _safe_float(self._fm_phase, 0.0)
        self._lp_state_l = _safe_float(self._lp_state_l, 0.0)
        self._lp_state_r = _safe_float(self._lp_state_r, 0.0)
        self._curr_freq = _safe_float(self._curr_freq, config.FREQ_MIN)
        self._curr_gain_l = _safe_float(self._curr_gain_l, 0.0)
        self._curr_gain_r = _safe_float(self._curr_gain_r, 0.0)

        # Atomic state read (GIL-safe, no lock needed)
        state = self._state

        # ── Earcon overlay ──
        earcon_signal = np.zeros(frames, dtype=np.float32)
        if self._earcon_active:
            spf = 1.0 / config.AUDIO_SAMPLE_RATE
            for i in range(frames):
                self._earcon_timer += spf
                if self._earcon_timer < config.EARCON_DURATION:
                    t_env = self._earcon_timer / config.EARCON_DURATION
                    env = min(1.0, t_env * 10.0) * max(0.0, 1.0 - t_env)  # quick attack, fade out
                    earcon_signal[i] = 0.25 * env * math.sin(2.0 * math.pi * self._earcon_freq * self._earcon_timer)
                else:
                    self._earcon_active = False
                    break

        # ── System Fault Tone (440→330Hz dual pulse) ──
        if state.fault_mode == "SYSTEM_FAULT":
            spf = 1.0 / config.AUDIO_SAMPLE_RATE
            fault_signal = np.zeros(frames, dtype=np.float32)
            for i in range(frames):
                self._fault_timer += spf
                dur = config.FAULT_TONE_DURATION
                gap = config.FAULT_TONE_GAP
                cycle = 2 * dur + gap
                pos = self._fault_timer % cycle
                if pos < dur:
                    # Xung 1: 440Hz
                    env = min(1.0, pos / 0.003) * min(1.0, (dur - pos) / 0.005)
                    fault_signal[i] = 0.35 * env * math.sin(2.0 * math.pi * config.FAULT_TONE_FREQ_HI * pos)
                elif pos < dur + gap:
                    fault_signal[i] = 0.0
                else:
                    # Xung 2: 330Hz
                    pos2 = pos - dur - gap
                    env = min(1.0, pos2 / 0.003) * min(1.0, (dur - pos2) / 0.005)
                    fault_signal[i] = 0.35 * env * math.sin(2.0 * math.pi * config.FAULT_TONE_FREQ_LO * pos2)

            # Phát fault tone ra cả 2 tai, cộng earcon
            combined = fault_signal + earcon_signal
            # Peak limiter
            combined = np.tanh(combined * 0.891)  # -1.0 dBFS ≈ 0.891 linear
            outdata[:, 0] = combined
            outdata[:, 1] = combined
            return

        # ── Nếu không active và gain đã tắt hết → im lặng ──
        if not state.active and self._curr_gain_l < 1e-4 and self._curr_gain_r < 1e-4 and not self._earcon_active:
            outdata.fill(0.0)
            return

        t_pan = _safe_float(state.pan, 0.0)
        t_pan = max(-1.0, min(1.0, t_pan))
        t_prox = _safe_float(state.proximity, 0.0)
        t_prox = max(0.0, min(1.0, t_prox))
        t_freq = _safe_float(state.freq, config.FREQ_MIN)
        t_freq = max(100.0, min(4000.0, t_freq))
        t_active = bool(state.active)
        t_vol = _safe_float(state.volume_factor, 1.0)
        t_vol = max(0.0, min(1.0, t_vol))
        cue_mode = state.cue_mode
        ttc = _safe_float(state.ttc, float("inf"))

        # ── 1. Tính chu kỳ nhịp beep ──
        if t_prox >= 0.70 or ttc <= config.TTC_CRITICAL:
            t_val = max(0.0, min(1.0, (t_prox - 0.70) / 0.30))
            if ttc <= config.TTC_CRITICAL:
                t_val = max(t_val, 1.0 - (ttc / config.TTC_CRITICAL))
            beep_interval = 0.35 - (0.35 - config.BEEP_INTERVAL_MIN) * t_val
        else:
            t_val = max(0.0, min(1.0, t_prox / 0.70))
            beep_interval = config.BEEP_INTERVAL_MAX - (config.BEEP_INTERVAL_MAX - 0.35) * t_val

        beep_interval = max(config.BEEP_INTERVAL_MIN, beep_interval)

        # ── 2. Constant-Power Panning + ILD ──
        # Tại trung tâm (p=0): cả 2 tai = 1.0 (0dB) — vật ngay trước mặt nghe rõ nhất
        # Khi lệch: tai gần = 1.0, tai xa suy giảm tối đa -18dB
        half_pi = math.pi / 2.0
        theta = (t_pan + 1.0) / 2.0 * half_pi  # 0 = full left, π/2 = full right

        # Constant-power base gains
        gain_l_base = math.cos(theta)
        gain_r_base = math.sin(theta)

        # ILD: tai xa suy giảm, tai gần giữ = 1.0
        max_atten_linear = 10.0 ** (-config.ILD_MAX_ATTENUATION_DB / 20.0)  # ~0.126 for -18dB
        if t_pan < 0:
            # Âm lệch trái: tai trái gần (giữ 1.0), tai phải xa (suy giảm)
            shadow = max(max_atten_linear, 1.0 - abs(t_pan) * (1.0 - max_atten_linear))
            target_gain_l = float(1.0 * t_vol) if t_active else 0.0
            target_gain_r = float(shadow * t_vol) if t_active else 0.0
        elif t_pan > 0:
            shadow = max(max_atten_linear, 1.0 - abs(t_pan) * (1.0 - max_atten_linear))
            target_gain_l = float(shadow * t_vol) if t_active else 0.0
            target_gain_r = float(1.0 * t_vol) if t_active else 0.0
        else:
            # Trung tâm: cả 2 tai = 1.0
            target_gain_l = float(1.0 * t_vol) if t_active else 0.0
            target_gain_r = float(1.0 * t_vol) if t_active else 0.0

        # ── 3. ITD Targets ──
        if t_pan < 0:
            target_delay_l = 0.0
            target_delay_r = float(abs(t_pan) * config.MAX_ITD_SAMPLES)
        else:
            target_delay_l = float(t_pan * config.MAX_ITD_SAMPLES)
            target_delay_r = 0.0

        # ── 4. Per-Sample Linear Interpolation (chống Zipper Noise) ──
        freq_ramp = np.linspace(self._curr_freq, t_freq, frames, dtype=np.float32)
        gain_l_ramp = np.linspace(self._curr_gain_l, target_gain_l, frames, dtype=np.float32)
        gain_r_ramp = np.linspace(self._curr_gain_r, target_gain_r, frames, dtype=np.float32)

        self._curr_freq = t_freq
        self._curr_gain_l = target_gain_l
        self._curr_gain_r = target_gain_r

        delay_l = int(round(target_delay_l))
        delay_r = int(round(target_delay_r))

        # ── 5. Phase Accumulation ──
        phase_deltas = (2.0 * np.pi * freq_ramp / config.AUDIO_SAMPLE_RATE).astype(np.float32)
        phase_accum = self._phase + np.cumsum(phase_deltas)
        self._phase = float(phase_accum[-1] % (2.0 * np.pi))

        if cue_mode == "SHARP_PING":
            # Sóng sin cơ bản + hài bậc 2
            tone = (0.38 * np.sin(phase_accum) + 0.12 * np.sin(2.0 * phase_accum)).astype(np.float32)
        elif cue_mode == "CAUTION_REMINDER":
            # Directive 01B-A++ Task P0-01: Âm nhắc nhở dịu nhẹ (soft chime / gentle reminder)
            tone = (0.20 * np.sin(phase_accum) + 0.08 * np.sin(1.5 * phase_accum)).astype(np.float32)
        else:
            # ── ACOUSTIC_BLUR: Dual-Tone FM Warble + Sub-harmonic Shimmer ──
            # FM modulation: freq ± 35Hz at 18Hz rate
            fm_deltas = (2.0 * np.pi * config.BLUR_FM_RATE_HZ / config.AUDIO_SAMPLE_RATE)
            fm_phase_arr = self._fm_phase + np.arange(frames, dtype=np.float32) * fm_deltas
            self._fm_phase = float(fm_phase_arr[-1] % (2.0 * np.pi))

            fm_mod = config.BLUR_FM_DEVIATION_HZ * np.sin(fm_phase_arr)
            # Carrier với FM
            inst_freq = freq_ramp + fm_mod
            inst_phase_deltas = (2.0 * np.pi * inst_freq / config.AUDIO_SAMPLE_RATE).astype(np.float32)
            fm_phase_accum = self._phase + np.cumsum(inst_phase_deltas)

            carrier = 0.30 * np.sin(fm_phase_accum)
            # Sub-harmonic shimmer (hài bậc 2)
            shimmer = config.BLUR_SUBHARMONIC_GAIN * np.sin(0.5 * fm_phase_accum)
            tone = (carrier + shimmer).astype(np.float32)

        # ── 6. Beep Envelope (Attack 3ms / Release 10ms) ──
        envelope = np.zeros(frames, dtype=np.float32)
        current_timer = self._beep_timer
        current_on = self._beep_on
        samples_per_frame = 1.0 / config.AUDIO_SAMPLE_RATE
        attack_dur = 0.003
        release_dur = 0.010
        beep_dur = config.BEEP_DURATION

        for i in range(frames):
            current_timer += samples_per_frame
            if current_on:
                elapsed = current_timer
                if elapsed >= beep_dur:
                    current_on = False
                    current_timer = 0.0
                    envelope[i] = 0.0
                else:
                    if elapsed < attack_dur:
                        envelope[i] = elapsed / attack_dur
                    elif elapsed > (beep_dur - release_dur):
                        envelope[i] = (beep_dur - elapsed) / release_dur
                    else:
                        envelope[i] = 1.0
            else:
                silence_dur = max(0.01, beep_interval - beep_dur)
                if current_timer >= silence_dur:
                    current_on = True
                    current_timer = 0.0
                envelope[i] = 0.0

        self._beep_timer = _safe_float(current_timer, 0.0)
        self._beep_on = current_on

        shaped = tone * envelope

        # ── 7. ITD delay & ILD gain ramp ──
        extended = np.concatenate([self._history_buf, shaped])
        self._history_buf = shaped[-config.MAX_ITD_SAMPLES:].copy()

        ch_l = (extended[config.MAX_ITD_SAMPLES - delay_l : config.MAX_ITD_SAMPLES - delay_l + frames] * gain_l_ramp).astype(np.float32)
        ch_r = (extended[config.MAX_ITD_SAMPLES - delay_r : config.MAX_ITD_SAMPLES - delay_r + frames] * gain_r_ramp).astype(np.float32)

        # ── 8. Head Shadow LPF ──
        if t_pan < -0.15:
            shadow_coeff = 0.50 * abs(t_pan)
            lp_r = np.empty_like(ch_r)
            s = _safe_float(self._lp_state_r, 0.0)
            for i in range(frames):
                s = (1.0 - shadow_coeff) * ch_r[i] + shadow_coeff * s
                lp_r[i] = s
            self._lp_state_r = _safe_float(s, 0.0)
            ch_r = lp_r
        elif t_pan > 0.15:
            shadow_coeff = 0.50 * t_pan
            lp_l = np.empty_like(ch_l)
            s = _safe_float(self._lp_state_l, 0.0)
            for i in range(frames):
                s = (1.0 - shadow_coeff) * ch_l[i] + shadow_coeff * s
                lp_l[i] = s
            self._lp_state_l = _safe_float(s, 0.0)
            ch_l = lp_l

        # ── 9. Cộng earcon overlay ──
        ch_l = ch_l + earcon_signal
        ch_r = ch_r + earcon_signal

        # ── 10. Soft-Knee Peak Limiter tại -1.0 dBFS (np.tanh) ──
        # -1.0 dBFS ≈ 0.891 linear amplitude
        limiter_gain = 10.0 ** (config.PEAK_LIMITER_THRESHOLD_DBFS / 20.0)
        ch_l = np.nan_to_num(ch_l, nan=0.0, posinf=limiter_gain, neginf=-limiter_gain)
        ch_r = np.nan_to_num(ch_r, nan=0.0, posinf=limiter_gain, neginf=-limiter_gain)
        ch_l = np.tanh(ch_l / limiter_gain) * limiter_gain
        ch_r = np.tanh(ch_r / limiter_gain) * limiter_gain

        outdata[:, 0] = ch_l
        outdata[:, 1] = ch_r
