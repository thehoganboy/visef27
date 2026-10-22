#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script tạo tệp HTML báo cáo khoa học kỹ thuật chuẩn mực và xuất sang PDF chất lượng cao.
"""

import os
import sys
import base64
import subprocess

if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

def get_base64_image(image_path):
    if os.path.exists(image_path):
        with open(image_path, "rb") as f:
            encoded = base64.b64encode(f.read()).decode("utf-8")
            ext = os.path.splitext(image_path)[1].lower().replace(".", "")
            mime = "image/png" if ext == "png" else "image/jpeg"
            return f"data:{mime};base64,{encoded}"
    return ""

def main():
    pchip_img_b64 = get_base64_image(os.path.join("reports", "pchip_calibration_curve.png"))
    err_img_b64 = get_base64_image(os.path.join("reports", "error_distribution_by_zone.png"))
    tum_img_b64 = get_base64_image(os.path.join("reports", "tum_telemetry_curves.png"))

    template_file = os.path.join(os.path.dirname(__file__), "report_template.html")
    if not os.path.exists(template_file):
        print(f"[ERROR] Không tìm thấy file {template_file}")
        return

    with open(template_file, "r", encoding="utf-8") as f:
        html_content = f.read()

    html_content = html_content.replace("__PCHIP_IMG_B64__", pchip_img_b64)
    html_content = html_content.replace("__ERR_IMG_B64__", err_img_b64)
    html_content = html_content.replace("__TUM_IMG_B64__", tum_img_b64)

    html_path = os.path.abspath(os.path.join(os.getcwd(), "Bao_Cao_Ky_Thuat_HorusEyes_2.0.html"))
    pdf_path = os.path.abspath(os.path.join(os.getcwd(), "Bao_Cao_Ky_Thuat_HorusEyes_2.0.pdf"))

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_content)

    print(f"[*] Đã tạo thành công tệp HTML: {html_path}")

    # Gọi Google Chrome headless để kết xuất PDF
    chrome_path = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
    if not os.path.exists(chrome_path):
        chrome_path = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

    print(f"[*] Đang thực thi công cụ in PDF qua: {chrome_path}...")
    cmd = [
        chrome_path,
        "--headless",
        "--disable-gpu",
        "--no-sandbox",
        f"--print-to-pdf={pdf_path}",
        f"file:///{html_path.replace(os.sep, '/')}"
    ]

    res = subprocess.run(cmd, capture_output=True, text=True)
    if os.path.exists(pdf_path) and os.path.getsize(pdf_path) > 0:
        print(f"[SUCCESS] ĐÃ XUẤT THÀNH CÔNG TỆP PDF: {pdf_path}")
        print(f"[*] Kích thước tệp: {os.path.getsize(pdf_path):,} bytes")
    else:
        print(f"[ERROR] Xuất PDF thất bại. Chi tiết lỗi: {res.stderr}")

if __name__ == "__main__":
    main()
