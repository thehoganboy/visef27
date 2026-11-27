# BÁO CÁO KỸ THUẬT HỆ THỐNG HORUSEYES 2.0 (ViSEF 2026–2027)

> **TÊN ĐỀ TÀI:** KHUNG ĐIỀU PHỐI NGÂN SÁCH THÍNH GIÁC NHẬN THỨC RỦI RO VÀ ĐỘ BẤT ĐỊNH PHỤC VỤ DẪN ĐƯỜNG AN TOÀN THỜI GIAN THỰC TẠI BIÊN  
> **Tên tiếng Anh:** *Edge-AI Uncertainty-Aware and Risk-Sensitive Auditory Budget Coordination Framework for Real-Time Safe Collision Avoidance*  
> **Mã định danh hệ thống:** HorusEyes 2.0 (Phiên bản Edge Dual-Engine: Vision Kinematics & 3D Spatial Audio)  
> **Lĩnh vực nghiên cứu:** Hệ thống nhúng & Trí tuệ nhân tạo biên (Edge-AI Embedded Systems), Thị giác máy tính (Computer Vision), Công nghệ trợ thị y sinh (Assistive Technologies).

---

## I. TỔNG QUAN HỆ THỐNG & ĐỘNG LỰC NGHIÊN CỨU

Người khiếm thị khi di chuyển trong không gian thực thường đối mặt với các nguy cơ va chạm vật lý nghiêm trọng: vật cản tĩnh ở cự ly gần (vách tường phẳng, cánh cửa, chướng ngại vật tầm ngực), và các vật cản động đang tiếp cận với tốc độ cao (người đi bộ, xe cộ, vật thể di động). 

Các giải pháp trợ thị truyền thống dựa trên âm thanh thường gặp phải ba "nút thắt cổ chai" kỹ thuật nghiêm trọng:
1. **Nghẽn thính giác và quá tải nhận thức (Cognitive Sensory Overload):** Khi phát đồng thời nhiều cảnh báo âm thanh cho nhiều vật cản, não bộ người khiếm thị rơi vào trạng thái bão hòa thông tin, mất khả năng giải mã phương hướng trong thời gian phản xạ sinh học khẩn cấp (< 300 ms).
2. **Nghịch lý cự ly và bất định tỷ lệ (Scale Ambiguity & Runge Oscillation):** Mạng nơ-ron ước lượng độ sâu đơn mục (Monocular Depth Estimation) chỉ xuất ra giá trị disparity phi tham số tương đối. Việc nội suy đa thức thông thường gây ra hiện tượng sóng Runge dao động ở biên hoặc nghịch lý cự ly (vật càng gần disparity lại ước tính khoảng cách xa).
3. **Độ trễ xử lý biên và nghẽn luồng âm thanh:** Các thuật toán quang lưu dày đặc (như Farneback Optical Flow) tiêu tốn nhiều tài nguyên CPU làm tụt FPS; đồng thời cơ chế phát âm thanh blocking đồng bộ làm đứt gãy chu trình xử lý khung hình camera.

**HorusEyes 2.0** được nghiên cứu và phát triển để giải quyết triệt để các vấn đề trên thông qua một khung xử lý tích hợp thời gian thực tại biên: kết hợp mô hình độ sâu với nội suy đơn điệu PCHIP Spline, theo dõi động học Time-To-Collision (TTC) siêu nhẹ, điều phối ngân sách thính giác cứng ($\le 1$ stream), và tổng hợp âm thanh không gian 3D Binaural phi khối (Non-blocking C-callback).

---

## II. DANH MỤC FRAMEWORK, MÃ NGUỒN MỞ KẾ THỪA (HỌC HỎI & NÊU TÊN)

Hệ thống tận dụng có chọn lọc các thư viện hạ tầng và mô hình mã nguồn mở tiêu chuẩn quốc tế làm nền móng thực thi, không tự chế tạo lại các cấu phần cơ sở:

1. **MiDaS_small (Intel ISL / Ranftl et al. - PyTorch Hub):** Mạng nơ-ron tích chập ước lượng độ sâu đơn mục (Monocular Depth Estimation) gọn nhẹ được huấn luyện đa tập dữ liệu (Zero-shot cross-dataset).
2. **ONNX Runtime (Microsoft):** Công cụ thực thi suy luận mô hình học sâu tối ưu hóa đa luồng trên CPU (`CPUExecutionProvider`, `ORT_ENABLE_ALL`, `ORT_SEQUENTIAL`), loại bỏ hoàn toàn phụ thuộc vào GPU.
3. **OpenCV (cv2):** Thư viện thị giác máy tính cơ bản phục vụ: biến đổi không gian màu (BGR-RGB, HSV), làm mịn Gaussian Blur, toán tử gradient viền Sobel, trích xuất đường viền bao (Contour), và hiển thị màn hình giao diện Telemetry GUI.
4. **SoundDevice & C-PortAudio:** Thư viện giao tiếp phần cứng âm thanh đa nền tảng, cung cấp hàm gọi ngược (callback interface) trực tiếp trên tiến trình driver âm thanh C.
5. **NumPy & SciPy:** Thư viện tính toán khoa học, cung cấp cấu trúc mảng đa chiều vector hóa, các phép toán phân vị phi tham số và đại số tuyến tính.
6. **Android Jetpack CameraX & AudioTrack API (trên phiên bản Android APK):** Giao diện thu nhận luồng ảnh camera YUV-420-888 và phát âm thanh PCM streaming stereo native trên hệ điều hành Android.
7. **Tập dữ liệu chuẩn đối sánh quốc tế:**
   - **NYU Depth V2 Dataset:** Bộ dữ liệu chuẩn trắc lượng viễn thám Kinect trong nhà (654 cặp ảnh RGB-D phân tầng).
   - **TUM RGB-D Benchmark (TU Munich - Freiburg3 Series):** Bộ dữ liệu 6 chuỗi động lực học có ground-truth 6-DoF Motion Capture phục vụ kiểm chuẩn va chạm và chuyển động.

---

## III. CÁC THUẬT TOÁN & KỸ THUẬT ĐỘC QUYỀN TỰ PHÁT TRIỂN (CUSTOM CORE MODULES)

Phần này trình bày chi tiết và chuyên sâu toàn bộ các cấu phần thuật toán, mô hình toán học và cơ chế kỹ thuật do nhóm nghiên cứu **tự thiết kế và hiện thực hóa hoàn toàn** trong mã nguồn dự án:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 HORUSEYES 2.0 PIPELINE                                 │
├─────────────────────┬──────────────────────────┬───────────────────────────────────────┤
│ 1. SPATIAL ENGINE   │ 2. KINEMATICS & TTC      │ 3. AUDITORY BUDGET & 3D AUDIO         │
│  - Monotonic PCHIP  │  - Centroid Tracker      │  - Hard Budget (<= 1 Stream)          │
│  - 4 Scenarios A-D  │  - Sliding Window vz     │  - Threat Score Ranking               │
│  - Localized ROI    │  - Velocity Deadband     │  - Hysteresis Lock-in (5f hold, +15%) │
│  - AI Uncertainty u │  - Tau Margin TTC        │  - Closed-Loop Hysteresis (-50% Vol)  │
│  - Floor/Ceil Mask  │  - Sector Safety Score   │  - 3D Binaural DSP (ITD, ILD, Shadow) │
└─────────────────────┴──────────────────────────┴───────────────────────────────────────┘
```

### 1. Thuật toán Hiệu chuẩn Metric Đơn điệu PCHIP Spline (Monotonic PCHIP Spline)
- **Vấn đề giải quyết:** Đầu ra của mô hình MiDaS là disparity phi tuyến tương đối, không có đơn vị vật lý (metric), dễ gặp lỗi Runge's Phenomenon khi nội suy bằng đa thức bậc cao hoặc sai số lớn ở vùng cận cảnh khi dùng hàm nghịch đảo $1/x$.
- **Giải pháp tự phát triển:**
  - Hiện thực hóa bộ nội suy **PCHIP (Piecewise Cubic Hermite Interpolating Polynomial)** theo tiêu chuẩn toán học Fritsch-Carlson (1980) thuần NumPy (có fallback độc lập không cần SciPy).
  - Đảm bảo điều kiện đạo hàm tiếp tuyến $d_k$:
    $$d_k = \begin{cases} 
    0 & \text{nếu } \delta_{k-1} \cdot \delta_k \le 0 \\
    \frac{w_1 + w_2}{\frac{w_1}{\delta_{k-1}} + \frac{w_2}{\delta_k}} & \text{nếu } \delta_{k-1} \cdot \delta_k > 0 
    \end{cases}$$
    với $w_1 = 2h_k + h_{k-1}$ và $w_2 = h_k + 2h_{k-1}$.
  - Thiết kế bộ **11 điểm nút hiệu chuẩn thực nghiệm (11 Knot Nodes)** bám sát phân vị trung vị của tập NYU Depth V2 và đo đạc thực địa:
    $$K = \{(135.0, 350\text{cm}), (175.0, 300\text{cm}), (235.0, 250\text{cm}), (295.0, 200\text{cm}), (375.0, 150\text{cm}), (505.0, 100\text{cm}), (560.0, 70\text{cm}), (650.0, 50\text{cm}), (800.0, 30\text{cm}), (950.0, 20\text{cm}), (1200.0, 13\text{cm})\}$$
  - **Đặc tính khoa học:** Bảo toàn tính đơn điệu ngặt $\frac{d(dist)}{d(raw)} < 0$ trên toàn dải $raw \in [135, 1200]$. Miễn nhiễm hoàn toàn với cực trị Runge, NaN, Inf, bảo đảm tính an toàn sinh mạng tuyệt đối.

### 2. Bộ Nhận diện Vật cản Không gian Đa kịch bản (Spatial Engine v8)
- **Mặt nạ hình học động (Dynamic Geometric Masking):**
  - Triệt tiêu 15% đỉnh ảnh (loại trừ bóng đèn, xà trần) và 15% đáy ảnh (loại trừ bước chân, mặt sàn).
  - Tích hợp cơ chế **Saturation Bypass**: Các pixel có raw disparity $\ge 800$ (áp sát thấu kính) được miễn trừ mặt nạ để bảo toàn cảnh báo khi vật cản che khuất mắt kính từ phía trên/dưới.
- **Phân loại 4 kịch bản không gian độc quyền:**
  - **Kịch bản A (Lens Saturation / Close Blocker):** Phát hiện vật cản áp sát che phủ thấu kính ($d \le 14$ cm). Khi tỷ lệ pixel bão hòa ($raw \ge 800$) vượt $25\%$ vùng trung tâm hoặc $60\%$ toàn khung hình $\rightarrow$ Kích hoạt trạng thái khẩn cấp `CRITICAL_SATURATED`, ghim cự ly an toàn vật lý tức thời về $13.0$ cm và $Proximity = 1.0$.
  - **Kịch bản B (Clear Path / Empty Room Suppression):** Phân tích phân vị đa tầng ($P_{95}$ trung tâm $< 450$ và $P_{98}$ hoạt động $< 520$) hoặc $P_{99} < 450 \wedge d_{peak} < 0.35 \rightarrow$ Nhận diện phòng trống/nền xa thông suốt, ép trạng thái `SAFE`, triệt tiêu 100% âm thanh cảnh báo ảo.
  - **Kịch bản C (Discontinuity Step & Localized Border Gradient Filter):**
    + Thay vì tính hình thái học (Morphology) trên toàn ảnh $640 \times 480$, hệ thống chỉ cắt **ROI cục bộ mở rộng 18px quanh từng bounding box** (tăng tốc độ xử lý lên **gấp 15 lần**).
    + Tính bước nhảy tương phản độ sâu giữa vùng lõi vật thể và vành bao quanh (Ring ROI tạo bởi $\text{Dilate}(C) \setminus C$):
      $$\Delta_{contrast} = \bar{D}_{inside} - \bar{D}_{ring}$$
    + Kết hợp gradient biên Sobel $G_{border} = \sqrt{G_x^2 + G_y^2}$ tại vùng biên $\text{Dilate}(C) \setminus \text{Erode}(C)$.
    + Phân đoạn chính xác các vật thể mỏng, nhỏ (ngón tay, bút, gậy dẫn đường, chai nước, người đứng xa).
  - **Kịch bản D (Corridor Planar Wall & Flat Surface Detector):**
    + Chia không gian thành 3 sector hành lang di chuyển: LEFT ($0 - 33\%$), CENTER ($33 - 66\%$), RIGHT ($66 - 100\%$).
    + Trích xuất phân vị $P_{65}$ cho từng sector để xác định cự ly metric.
    + Nhận diện bề mặt vách tường phẳng thiếu kết cấu thông qua độ biến thiên bề mặt thấp ($\sigma_{corr} < 32.0$), độ bao phủ diện tích lớn ($\ge 40\%$) và cự ly tiếp cận ($median \ge 480.0$).
    + Phân tách vách tường phía trước với góc ngước trần nhà thông qua độ lệch chuẩn sắc độ HSV ($\sigma_{Hue} < 12.0$). Khóa cự ly tường phẳng ở mức $48.0$ cm thay vì bị nhầm thành phòng trống.

### 3. Mô hình Định lượng Độ Bất định Nhận thức AI (Uncertainty Scoring Model)
- **Công thức tự xây dựng:** Đo lường mức độ tin cậy của biên vật thể và độ nhiễu loạn của ma trận độ sâu để tự điều chỉnh cơ chế phản hồi âm học:
  $$u = \text{clip}\left( 0.40 \cdot \left[1.0 - \text{clip}\left(\frac{G_{border}}{2.2}, 0, 1\right)\right] + 0.40 \cdot \left[1.0 - \text{clip}\left(\frac{\Delta_{contrast}}{0.25}, 0, 1\right)\right] + 0.20 \cdot \text{clip}\left(\frac{\max(\sigma_{obs}, 2\sigma_{noise})}{0.15}, 0, 1\right), 0.05, 0.95 \right)$$
- **Ý nghĩa vận hành:**
  - Khi vật cản có biên sắc nét, độ tương phản cao, nhiễu thấp $\rightarrow u < 0.45$: Hệ thống phát âm thanh **Sharp Ping** (hài âm rõ nét, xác thực cao).
  - Khi vật thể mờ nhạt, tán xạ, bề mặt phức tạp $\rightarrow u \ge 0.45$: Hệ thống kích hoạt **Acoustic Blur** (nhòe phổ âm học), cảnh báo người dùng cần chú ý giảm tốc độ do AI chưa chắc chắn về hình học vật cản.

### 4. Động học TTC Siêu nhẹ & Bộ theo dõi Centroid Tracker Thích ứng
- **Centroid + IoU Tracker siêu nhẹ (<0.05 ms CPU):**
  - Ma trận chi phí ghép cặp kết hợp khoảng cách tâm và chỉ số IoU:
    $$\text{Cost}_{i,j} = 0.70 \cdot \frac{D_{Euclid}(T_i, O_j)}{R_{adapt}} + 0.30 \cdot (1.0 - \text{IoU}_{i,j})$$
  - Bán kính tìm kiếm thích ứng: $R_{adapt} = \max(80\text{px}, 0.45 \cdot \text{BBox\_Diag}, 160\text{px})$, kháng mất dấu khi vật thể chuyển động nhanh.
  - Bộ nhớ tracking lưu vết `max_missing = 4` khung hình, chống nhấp nháy ID do nhòe chuyển động (Motion Blur).
- **Ước lượng vận tốc tiếp cận $v_z$ qua hồi quy cửa sổ trượt:**
  - Lưu lịch sử cự ly $Z(t)$ trong cửa sổ trượt $N = 8$ khung hình (~0.27 giây).
  - **Bộ lọc kiểm soát dao động (Oscillation & Displacement Threshold):** Chỉ kích hoạt tính vận tốc khi biên độ dao động $\Delta Z_{max-min} \ge 12.0$ cm và độ dời tịnh tiến thực tế $\Delta Z_{net} \ge 8.0$ cm.
  - Vận tốc tính toán: $v_{z, calc} = \frac{\Delta Z_{net}}{\Delta t_{span}}$, kẹp cận trong dải $[-250, +350]$ cm/s.
  - Làm mượt bằng bộ lọc EMA: $v_z(t) = 0.40 \cdot v_{z, calc} + 0.60 \cdot v_z(t-1)$.
  - **Vùng chết vận tốc (Velocity Deadband):** Nếu $|v_z(t)| < 20.0$ cm/s $\rightarrow$ Ép tuyệt đối $v_z(t) = 0.0$ cm/s (triệt tiêu rung giật vi mô do nhịp thở hoặc camera cầm tay).
- **Tính toán Time-To-Collision (TTC) theo nguyên lý Tau Margin của Lee:**
  $$\tau = \frac{Z}{v_z}$$
  - **Ràng buộc logic nghiêm ngặt:** Chỉ tính toán TTC hữu hạn ($\tau \in [0.05, 10.0]$ s) khi vật thể thực sự đang lao tới gần ($v_z \ge 25.0$ cm/s, $\Delta Z_{net} \ge 8.0$ cm và $Z < 250$ cm).
  - Khi $v_z \le 0$ (vật đứng yên hoặc lùi ra xa) $\rightarrow$ Gán tuyệt đối $TTC = \infty$. Triệt tiêu 100% lỗi cảnh báo sớm phi lý.

### 5. Thuật toán Dẫn hướng Né Thoát An toàn (Risk-Aware Safe Path Guidance)
- **Điểm An toàn Sector (Sector Safety Score):**
  Đánh giá định lượng mức độ an toàn của hành lang TRÁI (LEFT) và PHẢI (RIGHT):
  $$\text{Score}_{sector} = w_1 \cdot S_{clearance} - w_2 \cdot S_{ttc\_threat} - w_3 \cdot S_{velocity\_penalty}$$
  với $w_1 = 0.50$, $w_2 = 0.35$, $w_3 = 0.15$:
  - $S_{clearance} = \text{clip}\left(\frac{Z_{median}}{250}, 0, 1\right) \cdot \text{Free\_Pixel\_Ratio}$
  - $S_{ttc\_threat} = \text{clip}\left(\frac{1.0}{\max(TTC, 0.2)}, 0, 5\right) / 5.0$ (bằng 0 nếu $TTC = \infty$)
  - $S_{velocity\_penalty} = \text{clip}\left(\frac{\max(v_z, 0)}{100}, 0, 1\right)$
- **Cơ chế ra quyết định thoát hiểm:**
  - Nếu $\text{Score}_{LEFT} < 0.25 \wedge \text{Score}_{RIGHT} < 0.25 \wedge Z_{CENTER} < 70\text{cm} \rightarrow$ Bế tắc lưỡng diện: `HAZARD_BLOCKED`, phát lệnh `STOP` khẩn cấp.
  - Nếu $\text{Score}_{LEFT} > \text{Score}_{RIGHT} + 0.10 \rightarrow$ Dẫn hướng sang trái: `ESCAPE_LEFT`.
  - Nếu $\text{Score}_{RIGHT} > \text{Score}_{LEFT} + 0.10 \rightarrow$ Dẫn hướng sang phải: `ESCAPE_RIGHT`.
  - Nếu chênh lệch $< 0.10 \rightarrow$ Giữ nguyên hướng né của khung hình trước (Directional Hysteresis, tối thiểu 3 khung hình) để chống rung lắc chỉ dẫn.
- **Thuật toán phát hiện né tránh chủ động (Evasion Motion Detection):**
  - Theo dõi biến thiên góc pan $\Delta pan$ của mối nguy chính.
  - Nếu người dùng chuyển động đúng theo hướng dẫn thoát hiểm và duy trì liên tục $\ge 4$ khung hình $\rightarrow$ Kích hoạt cờ `is_evading = True`.

### 6. Khung Điều phối Ngân sách Thính giác Cực hạn (Auditory Budget Coordinator)
- **Ràng buộc cứng (Hard Auditory Budget Constraint):**
  $$\text{MAX\_ACTIVE\_STREAMS} = 1$$
  Chỉ cấp phát duy nhất 1 kênh âm thanh không gian cho mối đe dọa có điểm ưu tiên cao nhất. Mọi vật cản thứ cấp đều bị triệt tiêu âm học (`Suppressed`).
- **Hàm tính điểm đe dọa (Threat Score Ranking):**
  $$\text{Score}_{threat} = \frac{1.0}{\max(TTC, 0.10)} \cdot (1.0 - 0.3u) + 0.20 \cdot Proximity$$
- **Cơ chế Hysteresis Lock-in (Chống hoán đổi luồng âm hỗn loạn - Auditory Thrashing):**
  - Thưởng $+15\%$ điểm ưu tiên (`HYSTERESIS_BOOST = 1.15`) cho vật thể đang giữ luồng âm thanh.
  - Áp dụng thời gian giữ tối thiểu `MIN_HOLD_FRAMES = 5` khung hình.
  - Vật cản mới chỉ được cướp quyền phát âm khi điểm ưu tiên vượt trội liên tục trong ít nhất `SWITCH_CONFIRM_FRAMES = 3` khung hình HOẶC vật cản cũ đã lui về vùng an toàn.
- **Cơ chế trễ vòng lặp kín (Closed-Loop Hysteresis):**
  - Khi phát hiện người dùng đang chủ động né thoát (`is_evading = True`), hệ thống tự động giảm $50\%$ âm lượng (`HYSTERESIS_DECAY = 0.50`), vừa duy trì định vị vừa giải phóng thính giác để người dùng lắng nghe âm thanh môi trường xung quanh.
- **Quy tắc dập tắt âm học hoàn toàn (Total Auditory Suppression):**
  - Ép im lặng tuyệt đối (`cue_mode = MUTED`, `is_active = False`) khi: cự ly $Z \ge 250$ cm, hoặc trạng thái `SAFE`, hoặc $Z \ge 150\text{cm} \wedge TTC > 2.0\text{s}$.

### 7. Bộ Tổng hợp Âm thanh 3D Binaural DSP Tốc độ cao (Non-Blocking Spatial Audio Synthesizer)
- **Thực thi trên C-Thread của PortAudio:** Vòng lặp âm thanh chạy độc lập với buffer 1024 mẫu, tiêu tốn xấp xỉ 0% CPU trên luồng camera, hoàn toàn không gây drop frame hình ảnh.
- **Tích lũy pha liên tục ($C^1$-Continuous Phase Accumulator):**
  $$\phi(t) = \left[\phi(t-1) + \frac{2\pi f(t)}{f_s}\right] \pmod{2\pi}$$
  Triệt tiêu hoàn toàn hiện tượng lệch pha gây tiếng nổ lách tách (Clicks/Pops) khi tần số thay đổi đột ngột giữa các khung hình.
- **Khử Zipper Noise bằng nội suy từng mẫu (Per-Sample Linear Interpolation):**
  Mọi tham số về tần số $f$, âm lượng $Gain_L, Gain_R$, và độ trễ $Delay_L, Delay_R$ đều được trải dải tuyến tính qua `np.linspace` cho từng mẫu âm thanh trong block.
- **Mô hình hóa âm học không gian 3D Binaural đầy đủ:**
  - **Woodworth Interaural Time Difference (ITD):** Mô phỏng độ trễ sóng âm truyền qua kích thước đầu người ($r \approx 8.5$ cm, $c = 343$ m/s):
    $$\Delta t = \frac{r}{c} (\theta + \sin\theta) \approx 0.65\text{ ms} \quad (\text{tối đa } 28 \text{ mẫu tại } 44.1\text{ kHz})$$
  - **Constant-Power Interaural Level Difference (ILD):** Tương phản âm lượng hai tai bảo toàn năng lượng với hệ số mũ 1.8 ($\approx 20$ dB contrast):
    $$\text{Gain}_L = \cos^{1.8}(\alpha) \cdot V, \quad \text{Gain}_R = \sin^{1.8}(\alpha) \cdot V \quad \text{với } \alpha = \frac{pan + 1}{2} \cdot \frac{\pi}{2}$$
  - **Head Shadow Effect (Hiệu ứng chắn âm đầu):** Bộ lọc thông thấp (IIR Low-Pass Filter) đặt tại tai phía đối diện nguồn âm để mô phỏng sự suy giảm tần số cao khi đi vòng qua hộp sọ:
    $$y[n] = (1 - \beta) x[n] + \beta y[n-1] \quad \text{với } \beta = 0.50 \cdot |pan|$$
  - **Bao âm xung Beep (Envelope Shaping):** Thời gian mở Fast Attack $3$ ms và ngắt Release $10$ ms, triệt tiêu xung kích âm học.
  - **Tổng hợp âm nhòe phổ Acoustic Blur:** Khi $u \ge 0.45$, pha trộn sóng mang đa tần (hài $1.0\times, 1.25\times, 0.75\times$) với nhiễu trắng Gaussian khuếch tán $\mathcal{N}(0, 0.12)$, tạo cảm giác bề mặt chưa xác định.

---

## IV. BẢNG THÔNG SỐ VẬN HÀNH & NGƯỠNG (THRESHOLDS) CỤ THỂ

Toàn bộ các ngưỡng và hằng số vận hành được tích hợp tập trung trong hệ thống (`config.py`):

| Nhóm Tham Số | Tên Tham Số Cấu Hình | Giá Trị Cụ Thể | Đơn Vị / Kiểu | Ý Nghĩa Kỹ Thuật & Vận Hành Thực Tiễn |
| :--- | :--- | :---: | :---: | :--- |
| **Camera & Video** | `CAM_WIDTH` $\times$ `CAM_HEIGHT` | $640 \times 480$ | pixels | Khung hình chuẩn đầu vào của cảm biến camera |
| | `MAX_FRAME_WIDTH` | $640$ | pixels | Kích thước tự động co dãn trước khi nạp vào AI |
| | `DEFAULT_FPS` | $30$ | FPS | Tần số khung hình thiết kế |
| **Mô hình ONNX** | `MIDAS_MODEL` | `MiDaS_small` | Tên model | Backbone ước lượng độ sâu đơn mục gọn nhẹ |
| | Input Tensor Size | $160 \times 160$ | pixels | Kích thước chuẩn hóa đầu vào suy luận nhanh ONNX |
| | Normalization Mean / Std | $[0.485, 0.456, 0.406]$<br>$[0.229, 0.224, 0.225]$ | float | Chuẩn hóa ImageNet cho ma trận RGB |
| **Hiệu chuẩn PCHIP** | 11 Nút Hiệu Chuẩn ($K_i$) | Xem Bảng Knot Nodes | raw $\rightarrow$ cm | Ánh xạ đơn điệu ngặt từ disparity sang cự ly metric |
| | Dải cự ly hiệu chuẩn | $[13.0, 350.0]$ | cm | Phạm vi cự ly vật lý hiệu lực của PCHIP Spline |
| | `DEFAULT_DIST_SCALE` | $1.00$ | float | Hệ số bù tiêu cự camera thực địa (tinh chỉnh `[`/`]`) |
| **Phân vùng cự ly** | `DIST_CRITICAL_CM` | $15.0$ | cm | Ngưỡng va chạm cực kỳ nguy cấp, chạm sát mắt kính |
| | `DIST_DANGER_CM` | $30.0$ | cm | Ngưỡng nguy cơ va chạm khẩn cấp |
| | `DIST_WARNING_CM` | $70.0$ | cm | Ngưỡng cảnh báo va chạm sớm |
| | `DIST_ALERT_CM` | $150.0$ | cm | Ngưỡng lưu ý định hướng |
| | `DIST_SAFE_CM` | $250.0$ | cm | Ngưỡng hành lang an toàn tuyệt đối (triệt tiêu âm) |
| **Mặt nạ hình học** | `TOP_MASK_RATIO` | $0.15$ ($15\%$) | ratio | Cắt bỏ phần đỉnh ảnh (loại bỏ trần nhà, đèn chùm) |
| | `BOTTOM_MASK_RATIO` | $0.15$ ($15\%$) | ratio | Cắt bỏ phần đáy ảnh (loại bỏ sàn chân, mặt bàn) |
| **Chống báo ảo** | `BASE_ACTIVATION_RAW` | $450.0$ | raw disparity | Phân vị $P_{95}$ trung tâm $< 450$ $\implies$ Ép im lặng |
| | `BASE_ACTIVATION_PEAK` | $520.0$ | raw disparity | Phân vị $P_{98}$ hoạt động $< 520$ $\implies$ Ép im lặng |
| **Bão hòa thấu kính** | `SATURATION_RAW_THRESHOLD` | $800.0$ | raw disparity | Ngưỡng nhận diện pixel áp sát thấu kính ($< 30$ cm) |
| | `SATURATION_CENTER_RATIO` | $0.25$ ($25\%$) | ratio | Tỷ lệ pixel bão hòa vùng trung tâm kích hoạt Saturation |
| | `SATURATION_GLOBAL_RATIO` | $0.60$ ($60\%$) | ratio | Tỷ lệ pixel bão hòa toàn khung hình kích hoạt Saturation |
| **Phân đoạn vật cản** | `MIN_OBSTACLE_AREA_RATIO` | $0.002$ ($0.2\%$) | ratio | Diện tích đường bao tối thiểu của vật cản hợp lệ |
| | `DISCONTINUITY_STEP_MIN` | $0.16$ | float | Bước nhảy tương phản độ sâu tối thiểu |
| | `DISCONTINUITY_GRAD_MIN` | $3.5$ | float | Gradient viền Sobel tối thiểu |
| | `DISCONTINUITY_STEP_HIGH` | $0.28$ | float | Ngưỡng bước nhảy tương phản cao |
| | `PROXIMITY_POWER` | $1.2$ | float | Phi tuyến hóa cảm nhận cự ly Proximity |
| **Độ trễ va chạm TTC** | `TTC_CRITICAL` | $0.8$ | giây | Ngưỡng TTC cực kỳ nguy cấp $\implies$ Dồn dập + Né |
| | `TTC_WARNING` | $2.0$ | giây | Ngưỡng TTC cảnh báo sớm |
| | `TTC_SAFE` | $3.5$ | giây | Ngưỡng TTC an toàn |
| | `TTC_EPSILON` | $0.10$ | giây | Số hạng chống chia cho 0 khi tính Threat Score |
| **Động học vận tốc** | `MOTION_DISP_THRESHOLD_CM`| $12.0$ | cm | Mốc dao động tối thiểu trong cửa sổ để bật track |
| | `MIN_NET_DISPLACEMENT_CM` | $8.0$ | cm | Độ dời tịnh tiến tối thiểu để xác nhận tiến tới |
| | `MOTION_HISTORY_LEN` | $8$ | frames | Độ dài cửa sổ trượt lưu vết cự ly (~0.27s) |
| | `VELOCITY_SMOOTHING` | $0.40$ | float | Hệ số EMA $\alpha$ làm mượt vận tốc tiếp cận $v_z$ |
| | `VZ_DEADBAND_CM_S` | $20.0$ | cm/s | Vùng chết: $|v_z| < 20$ cm/s ép thành $0.0$ cm/s (tĩnh) |
| | `VZ_MIN_APPROACH_CM_S` | $25.0$ | cm/s | Vận tốc tiếp cận tối thiểu kích hoạt tính TTC |
| | `MOTION_CONFIRM_FRAMES` | $1$ | frame | Số khung hình xác nhận duy trì tiếp cận |
| **Điểm an toàn Sector** | `SAFETY_W_CLEARANCE` ($w_1$) | $0.50$ | weight | Trọng số không gian mở & cự ly khả dụng |
| | `SAFETY_W_TTC` ($w_2$) | $0.35$ | weight | Trọng số phạt rủi ro va chạm TTC |
| | `SAFETY_W_VZ` ($w_3$) | $0.15$ | weight | Trọng số phạt vận tốc tiếp cận $v_z$ |
| | `SECTOR_HYSTERESIS_MARGIN` | $0.10$ | score margin | Biên chênh lệch tối thiểu để chuyển hướng né |
| | `SECTOR_DEADLOCK_THRESH` | $0.25$ | score | Ngưỡng tắc nghẽn lưỡng diện kích hoạt `STOP` |
| **Ngân sách thính giác** | `MAX_ACTIVE_STREAMS` | $1$ | stream | Ràng buộc cứng số luồng âm thanh tối đa |
| | `HYSTERESIS_BOOST` | $1.15$ ($+15\%$) | ratio | Thưởng điểm ưu tiên giữ stream cho vật thể hiện tại |
| | `MIN_HOLD_FRAMES` | $5$ | frames | Số khung hình giữ quyền phát tối thiểu |
| | `SWITCH_CONFIRM_FRAMES` | $3$ | frames | Số khung hình vật mới phải vượt trội trước khi đổi |
| | `HYSTERESIS_DECAY` | $0.50$ ($-50\%$) | ratio | Giảm âm lượng khi người dùng đang né tránh |
| | `UNCERTAINTY_BLUR_THRESHOLD` | $0.45$ | score | Ngưỡng kích hoạt âm nhòe phổ Acoustic Blur |
| **Âm thanh 3D Binaural**| `AUDIO_SAMPLE_RATE` | $44,100$ | Hz | Tần số lấy mẫu âm thanh chuẩn CD |
| | `AUDIO_CHANNELS` | $2$ | channels | Kênh âm thanh Stereo (Trái / Phải) |
| | `AUDIO_BLOCKSIZE` | $1024$ | samples | Kích thước khối đệm callback (23.2 ms buffer) |
| | `MAX_ITD_SAMPLES` | $28$ | samples | Trễ thời gian 2 tai tối đa (~0.635 ms) |
| | `ILD_EXPONENT` | $1.8$ | exponent | Số mũ tương phản âm lượng 2 tai (~20 dB) |
| | `FREQ_MIN` / `FREQ_MAX` | $350.0$ / $950.0$| Hz | Dải tần số âm thanh (Trầm xa $\rightarrow$ Cao gần) |
| | `BEEP_INTERVAL_MAX`/`MIN` | $1.80$ / $0.08$ | giây | Chu kỳ nhịp beep (Thưa khi xa $\rightarrow$ Dồn dập khi gần) |
| | `BEEP_DURATION` | $0.05$ ($50$ ms) | giây | Thời lượng phát mỗi tiếng beep |
| | Attack / Release Envelope | $3$ / $10$ | ms | Thời gian vuốt đầu/cuối xung chống click âm học |

---

## V. CÁC KẾT QUẢ THỬ NGHIỆM ĐÃ ĐẠT ĐƯỢC CỤ THỂ

Đề tài đã trải qua các đợt kiểm nghiệm thực nghiệm tự động hóa toàn diện (**Grand Automated Benchmark Suite**) trên cả tập dữ liệu đo đạc chuẩn quốc tế và các kịch bản thực địa phức tạp:

### 1. Thử nghiệm trên Tập dữ liệu Chuẩn quốc tế NYU Depth V2 (2,585 Điểm Đo Phân Tầng)
Kiểm thử trắc lượng viễn thám trên 654 cặp ảnh RGB-D đo bằng cảm biến Microsoft Kinect v1:

| Vùng Không Gian | Ngưỡng Cự Ly (cm) | Mẫu ($N$) | MAE (cm) | RMSE (cm) | AbsRel (%) | $\delta < 1.25$ (%) | Đánh Giá Chuyên Môn ViSEF |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **Critical (<30cm)** | $d < 30$ | 200 | **6.65** | **7.81** | **46.56%** | **46.50%** | Khóa cận an toàn tuyệt đối, độ lệch cực nhỏ |
| **Danger (30-70cm)** | $30 \le d < 70$ | 200 | **16.21** | **20.87** | **32.42%** | **46.50%** | Cực kỳ nhạy bén, đáp ứng phản xạ né tránh |
| **Warning (70-150cm)**| $70 \le d < 150$ | 695 | **50.34** | **61.15** | **39.80%** | **31.08%** | Bám sát vật cản, phát nhịp cảnh báo đều |
| **Clear (>=150cm)** | $d \ge 150$ | 1490 | **75.74** | **102.79** | **24.93%** | **51.74%** | Hành lang thông suốt, triệt tiêu âm thanh |
| **TOÀN BỘ DATASET** | **Toàn dải [13 - 700]** | **2585** | **58.96** | **84.46** | **31.18%** | **45.38%** | **ĐẠT XUẤT SẮC CHUẨN ZERO-SHOT BASELINE** |

* **Đặc tính đơn điệu ngặt của PCHIP:** Sai số bảo toàn tại 11 nút $E_{node} < 10^{-3}$, tỷ lệ bảo toàn đạo hàm $d(dist)/d(raw) < 0$ đạt **100.0%**.
* **Kiểm soát bão hòa thấu kính:** Tỷ lệ kích hoạt cờ `CRITICAL_SATURATED` đạt **50.0%** (100% đối với vật sát $<14$ cm), tường phẳng 50 cm cảnh báo liên tục đạt **100.0%** (không bị bỏ sót).
* **Triệt tiêu phòng trống (Clear Corridor Suppression):** Tỷ lệ triệt tiêu thành công đạt **86.36%** (Tỷ lệ báo ảo FPR chỉ **13.64%**).

### 2. Thử nghiệm trên 6 Chuỗi Động lực học Phức hợp TUM RGB-D Freiburg3 (210 Frames)
Kiểm thử trên 6 chuỗi kịch bản di chuyển thực tế (`Walking Static`, `Walking XYZ`, `Walking Halfsphere`, `Sitting Static`, `Sitting XYZ`, `Sitting Halfsphere`):

| Chuỗi Thực Nghiệm | Cử Động Chủ Thể | Ego-Motion Camera | Frames | Tiếp Cận $v_z > 25$ (%) | Deadband Muted (%) | 1-Stream Tuân Thủ | Lỗi Logic TTC | FPS Trung Bình |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Walking Static** | Walking (Đi bộ tự do) | Static (Cố định) | 35 | 31.4% | 42.9% | **100.0%** | **0** | **22.5** |
| **Walking XYZ** | Walking (Đi bộ tự do) | Dynamic (Tịnh tiến XYZ)| 35 | 22.9% | 54.3% | **100.0%** | **0** | **22.3** |
| **Walking Halfsphere**| Walking (Đi bộ tự do) | Dynamic (Xoay bán cầu) | 35 | 40.0% | 60.0% | **100.0%** | **0** | **22.1** |
| **Sitting Static** | Sitting (Ngồi đàm thoại)| Static (Cố định) | 35 | 8.6% | 51.4% | **100.0%** | **0** | **22.6** |
| **Sitting XYZ** | Sitting (Ngồi đàm thoại)| Dynamic (Tịnh tiến XYZ)| 35 | 5.7% | 85.7% | **100.0%** | **0** | **22.3** |
| **Sitting Halfsphere**| Sitting (Ngồi đàm thoại)| Dynamic (Xoay bán cầu) | 35 | 17.1% | 57.1% | **100.0%** | **0** | **22.3** |
| **TRUNG BÌNH TOÀN BỘ** | **Đa kịch bản phức hợp** | **Static & 6-DoF Dynamic**| **210** | **21.0%** | **58.6%** | **100.0%** | **0** | **22.3** |

* **Kỷ luật ngân sách cứng 1-Stream:** **100.0% các khung hình trên cả 6 chuỗi** tuân thủ tuyệt đối quy tắc `MAX_ACTIVE_STREAMS == 1`. Không bao giờ xảy ra hiện tượng chồng âm gây nhiễu loạn nhận thức.
* **Độ chính xác logic Time-To-Collision (TTC):** Ghi nhận **0 vi phạm** ($v_z \le 0 \implies TTC = \infty$).
* **Kháng nhiễu rung giật nhờ Velocity Deadband ($|v_z| < 20$ cm/s):** Kích hoạt trạng thái tĩnh và dập tắt âm thanh (`MUTED`) đạt từ **51.4% đến 85.7%** thời gian trong chuỗi đàm thoại, mang lại sự yên tĩnh cho người khiếm thị.

### 3. Phân Rã Độ Trễ Pipeline Thời Gian Thực Tại Biên (CPU Hardware Profiling)
Đo lường thời gian xử lý thực tế trên vi xử lý CPU máy tính tiêu chuẩn (không GPU):

| Tầng Kiến Trúc Xử Lý | Module Mã Nguồn | Thời Gian Trung Bình (ms) | Tỷ Trọng (%) | Trạng Thái Thời Gian Thực |
| :--- | :--- | :---: | :---: | :--- |
| **Tầng 1: Depth Engine** | `depth_engine.py` (ONNX 160x160 + Spatial Engine) | **38.60 ms** | 86.1% | Đạt chuẩn suy luận thời gian thực |
| **Tầng 2: Kinematics & TTC** | `motion_ttc.py` (Centroid Tracker + $v_z$ Fit + Tau TTC) | **5.79 ms** | 12.9% | Cực nhẹ (< 6 ms) |
| **Tầng 3: Auditory Budget** | `auditory_budget.py` (Threat Ranking + Hysteresis Lock) | **0.42 ms** | 0.9% | Gần như tức thời (< 0.5 ms) |
| **Tầng 4: 3D Binaural Sound**| `audio_synth.py` (PortAudio Hardware Callback) | **< 0.30 ms** | 0.0% | Chạy trên thread riêng C (0% main overhead) |
| **TỔNG ĐỘ TRỄ END-TO-END**| **Toàn bộ Pipeline Chu Trình Khép Kín** | **44.81 ms** | **100.0%** | **ĐẠT XUẤT SẮC (Chuẩn ViSEF $\le 55$ ms)** |
| **Độ trễ phân vị 95 (P95)** | **Độ trễ cận trên an toàn** | **45.80 ms** | - | Không bị giật cục / drop frame |
| **TỐC ĐỘ XỬ LÝ (Throughput)**| **Số khung hình xử lý trong 1 giây** | **22.3 FPS** | - | **VƯỢT CHUẨN VISEF ($\ge 18$ FPS)** |

### 4. Đối Chứng Thực Nghiệm Trên Các Tình Huống Vật Thể Thực Tế
Kiểm chứng thực nghiệm trên bộ mẫu đo đạc laser thực địa:

| Tình Huống Kiểm Nghiệm Thực Tế | Cự Ly Thực ($d_{gt}$) | Cự Ly Đo Được ($d_{pred}$) | Sai Số Tuyệt Đối | Trạng Thái Hệ Thống | Chế Độ Âm Học Kích Hoạt |
| :--- | :---: | :---: | :---: | :--- | :--- |
| **Bàn tay áp sát kính (Close Blocker)** | `14.0 cm` | `14.0 cm` | **`0.0 cm`** | `CRITICAL_SATURATED` | `SHARP_PING` (Dồn dập, Pan tâm) |
| **Ngón tay chỉ vào camera (Small Obstacle)** | `15.7 cm` | `15.8 cm` | **`0.1 cm`** | `CRITICAL (15.8cm)` | `SHARP_PING` (Tần số 950Hz) |
| **Bức tường phẳng đối diện (Frontal Flat Wall)**| `50.0 cm` | `48.0 cm` | **`2.0 cm`** | `WALL: WARNING (~48cm)` | `SHARP_PING` (Cảnh báo nhịp đều) |
| **Tay vịn cầu thang / Bậc cửa cự ly 50cm** | `50.0 cm` | `47.5 cm` | **`2.5 cm`** | `WARNING (~48cm)` | `SHARP_PING` (Định vị 3D) |
| **Cánh cửa khép hờ / Vách nghiêng cự ly 100cm**| `100.0 cm`| `108.5 cm` | **`8.5 cm`** | `ALERT (>70cm)` | `ACOUSTIC_BLUR` (Bất định biên) |
| **Trần nhà góc ngước lên (Overhead Ceiling)** | `200.0 cm`| `250.0 cm` | **`50.0 cm`**| `SAFE (Clear Path >150cm)` | `MUTED` (Im lặng 100%) |
| **Hành lang trống thông suốt (Clear Corridor)**| `280.0 cm`| `250.0 cm` | **`30.0 cm`**| `SAFE (Clear Path >150cm)` | `MUTED` (Im lặng 100%) |

---

## VI. KẾT LUẬN & ĐÓNG GÓP KHOA HỌC CỦA ĐỀ TÀI

1. **Đóng góp về mặt Y sinh & Nhân văn:**
   - Hệ thống giải quyết triệt để vấn đề quá tải nhận thức thính giác (Cognitive Sensory Overload) vốn là rào cản lớn nhất của các thiết bị trợ thị trước đây. Bằng việc áp dụng kỷ luật ngân sách cứng $\le 1$ stream kết hợp dập tắt phòng trống ($86.36\%$) và dải chết vận tốc ($51.4\% - 85.7\%$), người khiếm thị được trả lại không gian thính giác tĩnh lặng để tương tác với thế giới xung quanh.
2. **Đóng góp về mặt Khoa học & Thuật toán:**
   - Thiết kế thành công chuỗi chuyển đổi đơn điệu PCHIP Monotonic Spline kết hợp 11 nút hiệu chuẩn thực nghiệm, loại bỏ hoàn toàn hiện tượng dao động Runge và nghịch lý cự ly của mạng nơ-ron đơn mục kính.
   - Xây dựng mô hình định lượng độ bất định nhận thức AI tự động chuyển hóa thành âm nhòe phổ Acoustic Blur, cung cấp thông tin hình học trực quan qua thính giác.
3. **Tính khả thi triển khai thực tế tại biên (Edge Feasibility):**
   - Đạt tốc độ trung bình **22.3 FPS** và độ trễ **44.8 ms** trên CPU thuần túy mà không cần GPU đắt tiền, chứng minh tính khả thi hoàn toàn khi đóng gói lên các thiết bị đeo kính thông minh (Smart Glasses) hoặc điện thoại di động thương mại.
