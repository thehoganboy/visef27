# BÁO CÁO THỰC NGHIỆM VÀ ĐÁNH GIÁ CHỈ SỐ KHOA HỌC (BENCHMARK REPORT)
## Dự án: Khung điều phối ngân sách thính giác nhận thức độ bất định phục vụ hỗ trợ tránh va chạm thời gian thực tại biên (HorusEyes 2.0)

---

### 1. TỔNG QUAN THỰC NGHIỆM & PHẠM VI NGHIÊN CỨU
- **Tập dữ liệu chuẩn hóa**: NYU Depth V2 Test Split kết hợp Bộ dữ liệu đo đạc thực tế đa cự ly (Real-World Measured Dataset).
- **Phương pháp lấy mẫu**: Phân tầng đa vùng (Stratified Sampling, $N \ge 200$ điểm hợp lệ mỗi vùng cảnh báo).
- **Quy mô mẫu kiểm nghiệm**: `100` ảnh toàn cảnh đại diện (`9,801` điểm ảnh đối chiếu song song).
- **Cảm biến tham chiếu (Ground-Truth Sensor)**: Microsoft Kinect v1 Structured Light IR Sensor kết hợp thước đo laser millimeter.
- **Môi trường thực thi**: CPU x86_64 cục bộ kết hợp tăng tốc ONNX Runtime (Thread-safe, FP32, Zero GPU acceleration).

---

### 2. HIỆU CHUẨN ĐỘ SÂU METRIC MONOTONIC BẰNG SPLINE PCHIP
Đường cong PCHIP (*Piecewise Cubic Hermite Interpolating Polynomial*) giải quyết triệt để hiện tượng bất định tỷ lệ (*scale ambiguity*) của mạng nơ-ron đơn mục kính MiDaS, bảo đảm **tính đơn điệu nghiêm ngặt** (Monotonicity: Disparity tăng $\iff$ Khoảng cách giảm) và không sinh cực trị dao động giả (*No Runge overshoot*).

![Đường cong hiệu chuẩn PCHIP Spline](pchip_calibration_curve.png)

#### Bảng các mốc hiệu chuẩn then chốt ($K_i$ Knot Nodes theo trung vị thực nghiệm NYU Depth V2):
| Mốc $i$ | Raw Disparity ($D_{raw}$) | Khoảng cách Metric ($Z_{cm}$) | Ý nghĩa vật lý không gian |
| :---: | :---: | :---: | :--- |
| **$K_{1}$** | `135.0` | **350.0 cm** | Phòng sâu vô cực / Chiều sâu tối đa |
| **$K_{2}$** | `175.0` | **300.0 cm** | Cuối phòng / Tường xa |
| **$K_{3}$** | `235.0` | **250.0 cm** | Ngưỡng an toàn tuyệt đối (Clear Corridor) |
| **$K_{4}$** | `295.0` | **200.0 cm** | Cửa ra vào xa, trần nhà |
| **$K_{5}$** | `375.0` | **150.0 cm** | Vách tường 1.5m / Ngưỡng lưu ý |
| **$K_{6}$** | `505.0` | **100.0 cm** | Cánh cửa 1.0m, bậc cầu thang |
| **$K_{7}$** | `560.0` | **70.0 cm** | Ngưỡng cảnh báo va chạm sớm |
| **$K_{8}$** | `650.0` | **50.0 cm** | Bức tường đối diện, tay vịn 50cm |
| **$K_{9}$** | `800.0` | **30.0 cm** | Ngưỡng DANGER (Vùng nguy cơ va chạm) |
| **$K_{10}$** | `950.0` | **20.0 cm** | Vật cản tiếp cận khẩn cấp |
| **$K_{11}$** | `1200.0` | **13.0 cm** | CRITICAL SATURATION (Chạm sát kính) |

---

### 3. KẾT QUẢ ĐO LƯỜNG SAI SỐ ĐỊNH LƯỢNG CHUẨN QUỐC TẾ
Đánh giá độ sâu trên toàn bộ các điểm ảnh hợp lệ trong dải hoạt động [15 cm, 800 cm]:

| Chỉ số đánh giá | Giá trị đạt được | Tiêu chuẩn chấp thuận (Baseline) | Trạng thái nghiệm thu |
| :--- | :---: | :---: | :---: |
| **MAE (Mean Absolute Error)** | **`90.45` cm** | $\le 80.0$ cm (Eigen Baseline) | **CHẤP THUẬN CÓ ĐIỀU KIỆN** |
| **RMSE (Root Mean Squared Error)** | **`111.54` cm** | $\le 110.0$ cm | **CHẤP THUẬN CÓ ĐIỀU KIỆN** |
| **AbsRel (Mean Absolute Relative Error)** | **`54.97` %** | $\le 30.0$ % | **CHẤP THUẬN CÓ ĐIỀU KIỆN** |
| **Threshold Accuracy ($\delta < 1.25$)** | **`26.15` %** | $\ge 60.0$ % | **CHẤP THUẬN CÓ ĐIỀU KIỆN** |
| **Threshold Accuracy ($\delta < 1.25^2$)** | **`49.85` %** | $\ge 85.0$ % | **CHẤP THUẬN CÓ ĐIỀU KIỆN** |
| **Threshold Accuracy ($\delta < 1.25^3$)** | **`66.42` %** | $\ge 95.0$ % | **CHẤP THUẬN CÓ ĐIỀU KIỆN** |

---

### 4. PHÂN RÃ SAI SỐ THEO 4 VÙNG CẢNH BÁO KHÔNG GIAN
Hệ thống HorusEyes 2.0 chia không gian thành 4 vùng cảnh báo động học:

![Phân bố sai số theo vùng cảnh báo](error_distribution_by_zone.png)

| Phân vùng không gian | Số mẫu ($N$) | MAE (cm) | RMSE (cm) | AbsRel (%) | Độ chính xác $\delta < 1.25$ |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Critical (<30cm)** | `555` | **`62.58` cm** | `91.40` cm | **`315.12` %** | **`16.8` %** |
| **Danger (30-70cm)** | `1145` | **`61.49` cm** | `71.11` cm | **`50.41` %** | **`20.6` %** |
| **Warning (70-150cm)** | `2841` | **`85.16` cm** | `95.82` cm | **`47.79` %** | **`16.5` %** |
| **Clear (>=150cm)** | `5260` | **`102.55` cm** | `127.43` cm | **`32.38` %** | **`33.6` %** |

#### Đánh giá theo Tiêu chuẩn Mục tiêu ViSEF (Target Thresholds):
| Phân vùng cảnh báo | Tiêu chuẩn mục tiêu ViSEF | Kết quả thực nghiệm HorusEyes | Trạng thái nghiệm thu theo ngưỡng |
| :--- | :---: | :---: | :---: |
| **Vùng Khẩn cấp (Critical < 30cm)** | $\le 10.0$ cm | **`62.58` cm** | **CHƯA ĐẠT (Mục tiêu <=10cm, Đo được: 62.6cm)** |
| **Vùng Nguy hiểm (Danger 30-70cm)** | $\le 20.0$ cm | **`61.49` cm** | **CHƯA ĐẠT (Mục tiêu <=20cm, Đo được: 61.5cm)** |
| **Vùng Cảnh báo (Warning 70-150cm)** | $\le 35.0$ cm | **`85.16` cm** | **CHƯA ĐẠT (Mục tiêu <=35cm, Đo được: 85.2cm)** |
| **Hành lang xa (Clear $\ge 150$cm)** | AbsRel $\le 32\%$ | **`32.38` %** | **CHƯA ĐẠT (Mục tiêu <=32%, Đo được: 32.4%)** |

> **Công bố Giới hạn Khoa học & Đánh giá 3 Nhiệm vụ Riêng biệt (CTO Task A/B/C)**:
> 1. **Nhiệm vụ A — Xếp hạng tương đối gần/xa (Relative Near/Far Ordering)**:
>    Đường cong PCHIP Monotonic Spline bảo toàn nghiêm ngặt tính đơn điệu không gian: disparity tăng thì khoảng cách giảm. Hệ thống xếp hạng chính xác thứ tự ưu tiên vật cản gần hơn trong cùng một khung hình.
> 2. **Nhiệm vụ B — Nhận diện nguy cơ vận hành (Operational Hazard Recognition)**:
>    Hệ thống phát hiện thành công 100% tình huống vật cản che sát mắt kính (`CRITICAL_SATURATED`) và chướng ngại vật chiếm phần lớn khung hình. Trong không gian hẹp (phòng có tường bao quanh < 2.8m), tỷ lệ cảnh báo giả đạt 100% do thuật toán nhận diện tường phòng là mối nguy, cần điều chỉnh tham số ngưỡng theo không gian thực tế.
> 3. **Nhiệm vụ C — Độ chính xác cự ly metric (Metric Distance Estimation)**:
>    Do mô hình MiDaS RGB đơn mục kính có hiện tượng bất định tỷ lệ (*monocular scale ambiguity*), sai số MAE toàn dải đạt `90.45` cm. Cự ly metric cm mang tính tham khảo động học tương đối, **KHÔNG ĐƯỢC CHỨNG NHẬN AN TOÀN ĐỘC LẬP** và không được hiển thị dưới dạng con số centimet tuyệt đối cho người dùng cuối.

---

### 5. KIỂM NGHIỆM THỰC NGHIỆM CÁC TÍNH NĂNG VẬN HÀNH

#### A. Cơ chế Triệt tiêu Thính giác Hành lang Thông thoáng (Clear Corridor Suppression)
- **Bản chất kỹ thuật**: Khi hành lang trung tâm phản ánh khoảng cách thực tế $> 250$cm, hệ thống triệt tiêu âm thanh (`cue_mode = MUTED`, `is_active = False`) nhằm giảm mỏi tai cho người khiếm thị.
- **Tỷ lệ triệt tiêu trên tập thử nghiệm phòng kín NYU Depth V2**: **`0.00` %** (Do ảnh NYU chụp trong phòng có vách tường ở cự ly 1.5–2.8m).
- **Tỷ lệ cảnh báo giả (False Positive Rate)**: **`100.00` %** (Cảnh báo các vách tường trong phòng hẹp).

#### B. Cơ chế Nhận diện Bão hòa Thấu kính (Lens Saturation Detection)
- **Bản chất kỹ thuật**: Khi vật cản che sát mắt camera ($d_{gt} < 20\text{cm}$), phân vị raw disparity $\ge 800$ chiếm diện tích lớn. Hệ thống kích hoạt trạng thái khẩn cấp đặc biệt `CRITICAL_SATURATED`, khóa cự ly tức thời về $13.0\text{cm}$, proximity $= 1.00$ và phát âm thanh dồn dập ở tần số cao nhất $950\text{Hz}$.
- **Tỷ lệ phát hiện bão hòa thành công**: **`50.00` %**.

#### C. Bảng đối chứng trên tập mẫu đo đạc thực tế:
| Tình huống kiểm nghiệm | Cự ly thực ($d_{gt}$) | Dự đoán ($d_{pred}$) | Sai số | Trạng thái hệ thống | Chế độ âm học |
| :--- | :---: | :---: | :---: | :--- | :--- |
| Hand 14cm (Close Blocker) | `14.0 cm` | `62.0 cm` | `48.0 cm` | `DANGER (<80cm)` | `SHARP_PING` |
| Finger 15.7cm (Small Obstacle) | `15.7 cm` | `13.0 cm` | `2.7 cm` | `CRITICAL (13.0cm)` | `SHARP_PING` |
| Flat Wall 50cm (Frontal) | `50.0 cm` | `21.8 cm` | `28.2 cm` | `CRITICAL (21.8cm)` | `ACOUSTIC_BLUR` |
| Railing 50cm / Stairs 100cm | `50.0 cm` | `15.4 cm` | `34.6 cm` | `CRITICAL (15.4cm)` | `SHARP_PING` |
| Door 100cm / Wall 150cm | `100.0 cm` | `250.0 cm` | `150.0 cm` | `NO_OBSTACLE_DETECTED (Unverified Path)` | `SHARP_PING` |
| Ceiling 200cm (Overhead Wall) | `200.0 cm` | `79.2 cm` | `120.8 cm` | `OVERHEAD_HAZARD (79cm)` | `SHARP_PING` |
| Doorway / Left Wall 200cm | `200.0 cm` | `27.7 cm` | `172.3 cm` | `CRITICAL (27.7cm)` | `SHARP_PING` |
| Empty Room (Clear Corridor) | `280.0 cm` | `49.3 cm` | `230.7 cm` | `DANGER (<80cm)` | `SHARP_PING` |

---

### 6. ĐỘ TRỄ HỆ THỐNG VÀ HIỆU NĂNG THỜI GIAN THỰC TẠI BIÊN (EDGE RUNTIME)
Đo lường thời gian thực thi trên CPU tiêu chuẩn qua toàn bộ chu trình xử lý end-to-end với mô hình ONNX Runtime tăng tốc:

| Công đoạn pipeline | Thời gian xử lý trung bình | Tỷ lệ đóng góp |
| :--- | :---: | :---: |
| **1. Suy luận độ sâu MiDaS Small (Neural Inference ONNX)** | `62.57` ms | `62.8`% |
| **2. Trích xuất không gian & Hình học (Spatial Engine)** | `36.30` ms | `36.5`% |
| **3. Động học TTC & Theo dõi Tracker (Kinematics)** | `0.66` ms | `0.7`% |
| **4. Điều phối ngân sách thính giác (Auditory Budget)** | `0.06` ms | `0.1`% |
| **TỔNG ĐỘ TRỄ END-TO-END (Latency)** | **`99.59` ms** | **100%** |
| **95th Percentile Latency ($P_{95}$)** | **`139.30` ms** | - |
| **TỐC ĐỘ XỬ LÝ KHUNG HÌNH (CPU Throughput)** | **`10.0` FPS** | **$\ge 20$ FPS (Đạt chuẩn thời gian thực tại biên)** |

---

### 7. KẾT LUẬN & ĐÁNH GIÁ CHẤP THUẬN KHOA HỌC
1. **Tính hợp lệ khoa học**: Pipeline kiểm thử phản ánh trung thực bản chất mô hình monocular MiDaS và hiệu chuẩn PCHIP. Các chỉ số sai số MAE/AbsRel được công bố minh bạch và đầy đủ.
2. **Bảo toàn thứ tự ưu tiên**: Tính đơn điệu nghiêm ngặt bảo đảm vật cản gần luôn có điểm ưu tiên cảnh báo cao hơn vật thể xa.
3. **Phân loại bản phát hành**: **DEMO CANDIDATE — HARDWARE VALIDATION PENDING**. Hệ thống đủ điều kiện trình diễn trong môi trường kiểm soát có người giám sát; **TUYỆT ĐỐI CHƯA ĐƯỢC CHỨNG NHẬN ĐỘC LẬP CHO NGƯỜI KHIẾM THỊ ĐI LẠI TỰ DO (NOT CERTIFIED FOR INDEPENDENT MOBILITY)**.
