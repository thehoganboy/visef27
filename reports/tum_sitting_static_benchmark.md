# BÁO CÁO THỰC NGHIỆM ĐỘNG HỌC & TRÁNH VA CHẠM THỜI GIAN THỰC (ViSEF 2027)
## Đề tài: Khung điều phối ngân sách thính giác nhận thức độ bất định phục vụ hỗ trợ tránh va chạm thời gian thực tại biên (HorusEyes 2.0)
**Tập dữ liệu chuẩn**: TUM RGB-D Benchmark (`rgbd_dataset_freiburg3_sitting_static`)  
**Thời gian thực hiện**: 2026-11-13 02:29:38

---

## 1. TÓM TẮT THÔNG SỐ KỸ THUẬT & DỮ LIỆU ĐẦU VÀO

| Thông số | Giá trị thực nghiệm | Ghi chú kỹ thuật |
| :--- | :--- | :--- |
| **Tên tệp dữ liệu** | `rgbd_dataset_freiburg3_sitting_static` | Chuẩn TUM RGB-D Benchmark quốc tế |
| **Tổng số khung hình** | **40 frames** | Đầy đủ chuỗi chuyển động liên tục |
| **Độ phân giải khung hình** | `640 x 480` pixels | Chuẩn camera VGA cảm biến biên |
| **Kiến trúc mạng nơ-ron** | `MiDaS_small` ONNX Runtime Mobile | Input `1x3x256x192` Self-contained |

---

## 2. KẾT QUẢ ĐỐI CHIẾU 5 TIÊU CHÍ KỸ THUẬT (PASS / FAIL CRITERIA)

| Tiêu chuẩn kỹ thuật | Chỉ số quan sát thực nghiệm | Ngưỡng yêu cầu ViSEF | Kết quả |
| :--- | :--- | :--- | :---: |
| **1. Phân biệt Vật động vs Vật tĩnh** | Tỷ lệ dập tắt vật tĩnh: **45.2%**<br>Tỷ lệ cấp quyền người tới gần: **66.7%** | Triệt tiêu tĩnh $\ge 75\%$<br>Cấp quyền động $\ge 60\%$ | **CẦN TỐI ƯU (FAIL)** |
| **2. Tính đúng đắn của logic TTC** | Số vi phạm ($v_z \le 0$ nhưng gán TTC hữu hạn): **0**<br>Số khung hình TTC hữu hạn: **6 frames** | **0 vi phạm & Phát hiện tiếp cận dương** | **ĐẠT (PASS)** |
| **3. Ổn định luồng Tracking & Kháng giằng co** | Tỷ lệ hoán đổi ID: **2.5%**<br>Số track ID duy trì: **2 IDs** | $\le 20.0\%$ (chống rung giật luồng) | **ĐẠT (PASS)** |
| **4. Định vị không gian & Hướng né** | Cảnh báo mối nguy Trái/Phải: **15/6 frames**<br>Chỉ dẫn điều hướng khả dụng: **12 frames** | Định vị chính xác không phát lái tự động | **ĐẠT (PASS)** |
| **5. Hiệu năng xử lý thời gian thực biên** | Độ trễ trung bình: **323.61 ms** (P95: **558.58 ms**)<br>Tốc độ xử lý: **3.1 FPS** | Đo đạc trung thực trên CPU | **ĐẠT (PASS)** |

### KẾT LUẬN TỔNG QUAN: **CHƯA ĐẠT ĐẦY ĐỦ TIÊU CHUẨN**

---

## 3. PHÂN TÍCH ĐỘNG HỌC CHI TIẾT (KINEMATICS & TIME-TO-COLLISION)

* **Phổ vận tốc tiếp cận $v_z$**:
  * Vận tốc tiếp cận dương lớn nhất: **+110.5 cm/s**
  * Vận tốc tiếp cận dương trung bình khi đang tiến lại gần: **+84.0 cm/s**.
  * Phát hiện vật thể tĩnh trong phòng: Ghi nhận **42 lượt** với $|v_z| < 5.0\text{ cm/s}$.
* **Đặc tính Time-To-Collision (TTC)**:
  * Khoảng thời gian va chạm ngắn nhất ghi nhận: **0.50 giây**.
  * Trung vị TTC hữu hạn quan sát được: **0.60 giây**.
  * Thời điểm đầu tiên phát hiện TTC hữu hạn: **1341845689.50184s**.
  * **Tính nghiêm ngặt của lý thuyết Tau**: 100% các khung hình có $v_z \le 0$ đều được gán `TTC = inf`, không xảy ra bất kỳ báo động sai nào.

---

## 4. HIỆU QUẢ CỦA BỘ ĐIỀU PHỐI NGÂN SÁCH THÍNH GIÁC

* **Ràng buộc cứng ngân sách âm thanh**: **100.0%** khung hình tuân thủ quy tắc tối đa duy nhất 1 luồng âm thanh hoạt động (`MAX_ACTIVE_STREAMS = 1`).
* **Giảm tải mỏi thính giác (Auditory Relief)**:
  * Số khung hình im lặng an toàn (`MUTED`): **0/40 frames** (**0.0%**).
