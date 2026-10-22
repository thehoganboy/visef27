"""
================================================================================
HorusEyes 2.0 - Xuat Bieu Do Hieu Chuan Cu Ly Don Dieu PCHIP Spline (ViSEF)
================================================================================
Muc tieu:
  1. Kiem tra xac nhan tinh don dieu nghich bien ngat cua 11 moc nut (Monotonicity Assertion).
  2. Xuat bieu do PCHIP chat luong cao (300 DPI) phong cach toi gian, chuan muc khoa hoc.
  3. Luu file tai: reports/pchip_calibration_curve_vn.png.

Nguyen tac thiet ke (Minimalist & High-Impact):
  - Loai bo hoan toan cac hat nhieu phan tan khong can thiet.
  - Lam noi bat 4 dai phan vung rui ro mau pastel.
  - Duong cong noi suy PCHIP mau do dam muot ma tuyet doi.
  - 11 moc nut hieu chuan thuc nghiem danh dau ro rang kem nhan cu ly truc quan.
================================================================================
"""

import os
import sys
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

import numpy as np
import matplotlib
import matplotlib.pyplot as plt
try:
    from scipy.interpolate import PchipInterpolator  # type: ignore[import-untyped, import-not-found]
except ImportError:
    from depth_engine import PchipInterpolator

# Import cau hinh goc tu du an (khong sua codebase)
try:
    import config
    CALIBRATION_NODES = config.CALIBRATION_NODES
except Exception:
    CALIBRATION_NODES = [
        (135.0,  350.0),
        (175.0,  300.0),
        (235.0,  250.0),
        (295.0,  200.0),
        (375.0,  150.0),
        (505.0,  100.0),
        (560.0,   70.0),
        (650.0,   50.0),
        (800.0,   30.0),
        (950.0,   20.0),
        (1200.0,  13.0),
    ]


def verify_monotonicity(raw_nodes: np.ndarray, z_nodes: np.ndarray, pchip: PchipInterpolator, n_samples: int = 500):
    """
    Kiem tra xac nhan tinh don dieu nghich bien ngat 100% cua mo hinh PCHIP.
    """
    print("=" * 70)
    print(" KIEM THU TINH DON DIEU NGHICH BIEN NGAT (MONOTONICITY ASSERTION TEST)")
    print("=" * 70)
    
    # 1. Kiem tra so luong moc nut
    assert len(raw_nodes) == 11, f"[FAIL] So luong moc nut khong dung: {len(raw_nodes)} != 11"
    assert len(z_nodes) == 11, f"[FAIL] So luong moc culy khong dung: {len(z_nodes)} != 11"
    print(f"[*] So luong moc nut hieu chuan: {len(raw_nodes)} diem nút (K_1 -> K_11)")

    # 2. Kiem tra raw_nodes tang dan ngat
    diff_raw = np.diff(raw_nodes)
    assert np.all(diff_raw > 0), "[FAIL] raw_nodes khong tang dan ngat!"
    print(f"[*] raw_nodes tang dan ngat: min delta = {np.min(diff_raw):.1f}, max delta = {np.max(diff_raw):.1f}")

    # 3. Kiem tra z_nodes giam dan ngat
    diff_z = np.diff(z_nodes)
    assert np.all(diff_z < 0), "[FAIL] z_nodes khong giam dan ngat!"
    print(f"[*] z_nodes giam dan ngat: min delta = {np.max(diff_z):.1f}, max delta = {np.min(diff_z):.1f}")

    # 4. Kiem tra dao ham tren 500 diem noi suy
    eval_x = np.linspace(raw_nodes[0], raw_nodes[-1], n_samples)
    eval_y = pchip(eval_x)
    
    # Dao ham giai tich (analytical derivative)
    dydx = pchip.derivative()(eval_x)
    assert np.all(dydx < 0), f"[FAIL] Phat hien dao ham >= 0! Max dZ/dD = {np.max(dydx):.6e}"
    
    # Sai phan roi rac (discrete step)
    step_diff = np.diff(eval_y)
    assert np.all(step_diff < 0), f"[FAIL] Phat hien buoc nhay culy >= 0! Max diff = {np.max(step_diff):.6e}"

    print(f"[*] Doan danh gia noi suy: {n_samples} diem trong khoang [{raw_nodes[0]:.1f}, {raw_nodes[-1]:.1f}]")
    print(f"[*] Dao ham dZ/dD cuc dai (it am nhat): {np.max(dydx):.6f} (< 0)")
    print(f"[*] Dao ham dZ/dD cuc tieu (am nhat):    {np.min(dydx):.6f} (< 0)")
    print("[SUCCESS] 100% MOI DOAN CON NGHICH BIEN NGAT (dZ/dD < 0) - PASSED!\n")


def export_clean_pchip_chart(output_path: str = "reports/pchip_calibration_curve_vn.png",
                             show_empirical_scatter: bool = False):
    """
    Ve va xuat bieu do PCHIP Spline toi gian, chuan muc khoa hoc (Minimalist & High-Impact).
    Loai bo hoan toan dam may diem phan tan, tap trung 100% vao duong cong PCHIP va 4 vung rui ro.
    """
    raw_nodes = np.array([pt[0] for pt in CALIBRATION_NODES], dtype=float)
    z_nodes   = np.array([pt[1] for pt in CALIBRATION_NODES], dtype=float)

    # Khoi tao bo noi suy PCHIP Spline
    pchip = PchipInterpolator(raw_nodes, z_nodes)

    # Chay kiem thu xac nhan don dieu
    verify_monotonicity(raw_nodes, z_nodes, pchip, n_samples=500)

    # 500 diem tao duong cong tron tru tuyet doi
    curve_x = np.linspace(raw_nodes[0], raw_nodes[-1], 500)
    curve_y = pchip(curve_x)

    # Cau hinh font chu tieng Viet ro net
    plt.rcParams['font.sans-serif'] = ['Segoe UI', 'DejaVu Sans', 'Arial', 'sans-serif']
    plt.rcParams['font.family'] = 'sans-serif'
    plt.rcParams['axes.unicode_minus'] = False

    fig, ax = plt.subplots(figsize=(10, 6.2), dpi=300)

    # 1. To 4 dai mau phan vung rui ro (pastel diu mat)
    ax.axhspan(0, 30, color='#ffebee', alpha=0.55, zorder=1)
    ax.axhspan(30, 70, color='#fff3e0', alpha=0.55, zorder=1)
    ax.axhspan(70, 150, color='#fffde7', alpha=0.55, zorder=1)
    ax.axhspan(150, 400, color='#e8f5e9', alpha=0.55, zorder=1)

    # Cac duong phan chia ranh gioi vung nhe nhang
    ax.axhline(30, color='#e57373', linestyle=':', linewidth=0.9, alpha=0.6, zorder=2)
    ax.axhline(70, color='#ffb74d', linestyle=':', linewidth=0.9, alpha=0.6, zorder=2)
    ax.axhline(150, color='#81c784', linestyle=':', linewidth=0.9, alpha=0.6, zorder=2)

    # Nhan phan vung truc quan (chu nho thanh lich ben trong dai phan vung)
    ax.text(180, 15, "VÙNG NGUY CẤP (< 30 cm)", fontsize=8.5, fontweight='bold',
            color='#c62828', alpha=0.75, va='center', zorder=2)
    ax.text(180, 50, "VÙNG NGUY HIỂM (30 - 70 cm)", fontsize=8.5, fontweight='bold',
            color='#ef6c00', alpha=0.75, va='center', zorder=2)
    ax.text(180, 110, "VÙNG CẢNH BÁO (70 - 150 cm)", fontsize=8.5, fontweight='bold',
            color='#f57f17', alpha=0.75, va='center', zorder=2)
    ax.text(520, 240, "HÀNH LANG AN TOÀN (≥ 150 cm)", fontsize=9.0, fontweight='bold',
            color='#2e7d32', alpha=0.75, va='center', zorder=2)

    # 2. Dam may diem thuc nghiem NYU Depth V2 (Ground Truth Scatter)
    # Giu dung nguyen tac: alpha cuc thap (< 0.08), hat li ti (s=10) de vua bao toan
    # can cu thuc nghiem goc, vua khong lam roi mat hay che khuat duong cong PCHIP.
    if show_empirical_scatter and os.path.exists("nyu_empirical_points.npz"):
        emp_data = np.load("nyu_empirical_points.npz")
        raw_pts = emp_data["raw"]
        gt_pts = emp_data["gt"]
        ax.scatter(
            raw_pts, gt_pts,
            color='#1976d2',
            alpha=0.07,
            s=10,
            edgecolors='none',
            zorder=3,
            label=r"Điểm thực nghiệm NYU Depth ($Z_{gt}$)"
        )

    # 3. Ve duong cong noi suy don dieu PCHIP
    ax.plot(
        curve_x, curve_y,
        color='#c62828',
        linewidth=2.8,
        zorder=4,
        label=r"Đường nội suy đơn điệu: $f(D_{raw}) \rightarrow Z_{cm}$"
    )

    # 3. Danh dau 11 diem nut hieu chuan thuc nghiem (cham do vien den)
    ax.scatter(
        raw_nodes, z_nodes,
        color='#d32f2f',
        edgecolor='#212121',
        linewidth=1.2,
        s=55,
        zorder=5,
        label=r"11 mốc nút hiệu chuẩn thực nghiệm ($K_i$)"
    )

    # 4. Ghi chu text truc tiep cu ly tai cac moc chinh
    annotations = {
        135.0:  ("350cm", (12, -4), 'left', False),
        295.0:  ("200cm", (12, 6), 'left', False),
        505.0:  ("100cm", (12, 8), 'left', False),
        560.0:  ("70cm", (12, 8), 'left', False),
        650.0:  ("50cm", (12, 8), 'left', False),
        800.0:  ("30cm", (12, 8), 'left', False),
        1200.0: ("13cm (Khóa cận)", (-18, 22), 'right', True)
    }

    for x_k, y_k in zip(raw_nodes, z_nodes):
        if x_k in annotations:
            text_str, offset, ha_align, has_arrow = annotations[x_k]
            arrow_dict = dict(arrowstyle="->", color="#424242", lw=0.8, shrinkA=3, shrinkB=4) if has_arrow else None
            ax.annotate(
                text_str,
                (x_k, y_k),
                textcoords="offset points",
                xytext=offset,
                ha=ha_align,
                fontsize=8.8,
                fontweight='bold',
                color='#1a1a1a',
                bbox=dict(boxstyle="round,pad=0.25", facecolor='white', edgecolor='#bdbdbd', alpha=0.90, lw=0.6),
                arrowprops=arrow_dict,
                zorder=6
            )

    # 5. Thiet lap truc, tieu de va chu giai
    ax.set_title("ĐƯỜNG CONG HIỆU CHUẨN CỰ LY ĐƠN ĐIỆU PCHIP SPLINE",
                 fontsize=12.5, fontweight='bold', pad=14, color='#111111')
    ax.set_xlabel(r"Độ sâu tương đối MiDaS ($D_{raw}$)", fontsize=11, labelpad=9, fontweight='500')
    ax.set_ylabel("Cự ly thực tế Ground Truth (cm)", fontsize=11, labelpad=9, fontweight='500')

    ax.set_xlim(100, 1250)
    ax.set_ylim(0, 380)

    # Luoi toa do nhe nhang
    ax.grid(True, linestyle='--', linewidth=0.6, alpha=0.5, color='#9e9e9e', zorder=1)

    # Legend goc tren ben phai
    ax.legend(
        loc='upper right',
        frameon=True,
        fontsize=9.2,
        framealpha=0.92,
        edgecolor='#b0bec5',
        facecolor='white',
        borderpad=0.8
    )

    # Canh chinh vien
    fig.tight_layout()

    # Dam bao thu muc ton tai
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    fig.savefig(output_path, dpi=300)
    plt.close(fig)

    print("=" * 70)
    print(f"[SUCCESS] Da xuat bieu do PCHIP thanh cong tai: {output_path}")
    print(f"[*] Do phan giai: 300 DPI | Dinh dang: PNG | Kich thuoc: {fig.get_size_inches()} inches")
    print("=" * 70)


if __name__ == "__main__":
    export_clean_pchip_chart()
