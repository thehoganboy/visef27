# HorusEyes 2.0 (ViSEF 2026–2027)
> **Đề tài NCKH KHKT:** *"Khung điều phối ngân sách thính giác nhận thức độ bất định phục vụ hỗ trợ tránh va chạm thời gian thực tại biên"*  
> **Core Concept:** Edge-AI Uncertainty-Aware Auditory Budget Collision Avoidance System.

---

## 1. Giới thiệu & Cải Tiến Đột Phá từ `poc_demo.py`

HorusEyes 2.0 đã được tái cấu trúc hoàn chỉnh dựa trên những ưu điểm kỹ thuật thực nghiệm vững chắc từ `poc_demo.py`, giải quyết triệt để các hạn chế về độ trễ, âm thanh và độ nhạy nhận diện:

1. **Tổng hợp âm thanh 3D Binaural siêu tốc (PortAudio Hardware Callback):**
   - Thay thế hoàn toàn cơ chế gọi `sd.play()` gây nghẽn GIL và giật buffer trên Windows.
   - Sử dụng `sd.OutputStream(callback=...)` chạy trực tiếp trên thread C của driver âm thanh (0% CPU overhead cho camera loop).
   - Tích hợp chuẩn âm học 3D Binaural đầy đủ:
     * **ITD (Interaural Time Difference):** Trễ thời gian sóng tới ~0.65ms giữa hai tai.
     * **ILD (Interaural Level Difference):** Tương phản âm lượng ~20dB (hệ số mũ 1.8).
     * **Head Shadow Effect:** Bộ lọc suy giảm tần số cao (Low-Pass Filter) ở tai đối diện.
     * **Envelope Attack 3ms / Release 10ms:** Triệt tiêu hoàn toàn tiếng click/pop.

2. **Động học TTC ổn định & Nhẹ tải CPU (<0.2ms):**
   - Loại bỏ thuật toán Farneback Optical Flow nặng nề (vốn làm tụt FPS và gây nhiễu loạn vận tốc do cảm biến webcam).
   - Chuyển sang theo dõi biến thiên độ sâu metric $Z(t)$ và disparity lọc bằng **EMA (Exponential Moving Average)**.
   - Tính toán Time-to-Collision (TTC) ổn định theo mô hình Tau Margin:
     $$\tau = \frac{Z}{v_z}$$

3. **Spatial Engine v8 & Hiệu chuẩn Metric PCHIP Spline:**
   - Kế thừa trọn vẹn bộ nhận diện 4 kịch bản từ `poc_demo.py`:
     * **Kịch bản A (Close Blocker):** Nhận diện vật cản che sát mắt kính ($<15\,\text{cm}$).
     * **Kịch bản B (Clear Path):** Triệt tiêu âm thanh khi phòng trống hoặc nền xa ($>150\,\text{cm}$).
     * **Kịch bản C (Discontinuity & Gradient Filter):** Nhận diện vật cản nhỏ (ngón tay, bút, gậy, người) nhờ bước nhảy độ sâu cục bộ và gradient biên Sobel.
     * **Kịch bản D (Corridor Planar Wall):** Khảo sát 3 sector hành lang để phát hiện vách tường phẳng/cánh cửa.
   - Hiệu chuẩn độ sâu metric đơn điệu PCHIP (13cm – 350cm) tương thích thực nghiệm và NYU Depth V2.

4. **Điều phối ngân sách thính giác cực hạn (Auditory Budget $\le 1$ Stream):**
   - Ràng buộc cứng: Tối đa 1 stream âm thanh duy nhất cho mối nguy cấp bách nhất.
   - **Triệt tiêu âm học (Total Suppression):** Giữ im lặng tuyệt đối khi an toàn ($TTC > 2.0\,\text{s}$ hoặc $Z > 150\,\text{cm}$).
   - **Mã hóa độ bất định (Uncertainty Sonification):** Tự động chuyển đổi giữa xung sắc nét (`SHARP_PING`) và nhòe phổ (`ACOUSTIC_BLUR`) khi độ bất định $u \ge 0.35$.
   - **Dẫn hướng né tránh (Safe-Direction Guidance):** Khi $TTC \le 0.8\,\text{s}$ hoặc $Z \le 30\,\text{cm}$, âm thanh lệch hẳn sang hướng né an toàn (`SAFE ESCAPE: <- LEFT / RIGHT ->`).
   - **Cơ chế trễ vòng lặp kín (Closed-Loop Hysteresis):** Tự động giảm 50% âm lượng khi người dùng đã chủ động né về hướng an toàn.

5. **Giao diện Telemetry Side-by-Side Trực quan:**
   - Khung hình lật gương ngang (`cv2.flip(frame, 1)`) cho tương tác tự nhiên.
   - Bố cục hai nửa màn hình:
     * Nửa trái: RGB + Crosshair khóa mục tiêu + Mũi tên né thoát + HUD thông số (FPS, Dist, TTC, vz, Budget, Cue mode).
     * Nửa phải: Full Depth Heatmap (MAGMA colormap) + Vòng tròn đánh dấu cự ly.

---

## 2. Cấu Trúc Mã Nguồn Module Hóa

```
e:\visef27 project/
├── requirements.txt            # Danh sách dependencies (OpenCV, PyTorch, SoundDevice, Scipy)
├── config.py                   # Tập trung toàn bộ tham số kỹ thuật, ngưỡng TTC và hiệu chuẩn
├── video_capture.py            # Threaded Camera Grabber (zero-latency, auto-fallback, auto-resize)
├── depth_engine.py             # MiDaS_small + Spatial Engine v8 + PCHIP Spline + Uncertainty
├── motion_ttc.py               # Fast Kinematics: Tracking Z(t), v_z, TTC, Safe Escape, Evasion
├── auditory_budget.py          # Bộ điều phối ngân sách thính giác (Budget <= 1 stream, Suppression)
├── audio_synth.py              # 3D Binaural PortAudio Callback Synthesizer (ITD, ILD, Head Shadow)
├── telemetry_gui.py            # Giao diện Side-by-Side (RGB HUD + Depth Heatmap)
├── main.py                     # Vòng lặp điều phối chính (Orchestrator Pipeline)
├── test_pipeline.py            # Kịch bản kiểm thử 6 module tự động
├── test_horuseyes_benchmark.py # Kịch bản kiểm thử toàn diện trên tập ảnh thực tế và đo FPS
└── README.md                   # Tài liệu hướng dẫn chi tiết
```

---

## 3. Cài Đặt Môi Trường

Yêu cầu: Python 3.9 – 3.12 trên Windows/Linux.

```powershell
pip install -r requirements.txt
```

---

## 4. Hướng Dẫn Khởi Chạy

### 4.1. Sử dụng Webcam máy tính mặc định:
```powershell
python main.py
```
*(Hệ thống tự động dò tìm các webcam khả dụng `index 0, 1, 2`)*

Hoặc chỉ định cụ thể index:
```powershell
python main.py --source 0
```

### 4.2. Sử dụng Camera điện thoại qua Wi-Fi (IP Webcam / DroidCam):
1. Cài đặt ứng dụng **IP Webcam** (Android) hoặc **DroidCam**.
2. Kết nối điện thoại và máy tính vào **cùng một mạng Wi-Fi**.
3. Mở ứng dụng $\rightarrow$ Bắt đầu server $\rightarrow$ Nhận địa chỉ IP (ví dụ: `http://192.168.1.15:8080`).
4. Khởi chạy trên máy tính:
```powershell
python main.py --source http://192.168.1.251:4747/video
```

### 4.3. Các phím điều khiển khi đang chạy:
- **`q`** hoặc **`ESC`**: Thoát chương trình an toàn, giải phóng camera và audio.
- **`[`** / **`]`**: Giảm / Tăng hệ số bù tiêu cự metric (`scale_factor`).
- **`r`**: Đặt lại hệ số tiêu cự về mặc định `1.00x`.

---

## 5. Kiểm Thử Hệ Thống (Unit & Benchmark Tests)

### 5.1. Kiểm thử tích hợp 6 module:
```powershell
python test_pipeline.py
```

### 5.2. Chạy Benchmark trên tập dữ liệu ảnh thực tế:
```powershell
python test_horuseyes_benchmark.py
```

Kết quả đo đạc thực tế:
- **Bàn tay cự ly 14cm (Close Blocker):** Nhận diện chính xác 14.0cm, TTC 0.2s, kích hoạt âm cảnh báo tức thời.
- **Ngón tay cự ly 15.7cm:** Nhận diện 15.8cm, phân cấp DANGER, kích hoạt `SHARP_PING`.
- **Cánh cửa 100cm / Vách 150cm:** Nhận diện 108.5cm, phân cấp ALERT, dẫn hướng né sang trái.
- **Trần nhà 200cm / Phòng trống >2.5m:** Phân cấp SAFE, triệt tiêu 100% âm thanh (`CUE: MUTED`), trả lại không gian tĩnh lặng cho người dùng.
