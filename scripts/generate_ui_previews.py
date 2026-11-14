import os
import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

def draw_rounded_rect(draw, bbox, radius, fill=None, outline=None, width=1):
    x0, y0, x1, y1 = bbox
    r = radius
    draw.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=fill, outline=outline, width=width)

def render_vampior_mockup(state="RUNNING", threat="NORMAL", angle_deg=0.0, is_pressed=False, dark_scene=True):
    # iPhone 15 Pro resolution mockup aspect: 393 x 852 (points), scaled 2x -> 786 x 1704
    w, h = 393, 852
    img = Image.new('RGB', (w, h), (10, 10, 12)) # #0A0A0C chassis
    draw = ImageDraw.Draw(img)

    # Status Bar
    draw.text((32, 14), "9:41", fill=(255, 255, 255))
    # Dynamic Island
    draw.rounded_rectangle([134, 11, 259, 44], radius=16, fill=(0, 0, 0))

    # Camera Preview Container: margin 14pt, top 58pt, bottom 164pt -> 365 x 630
    cam_x0, cam_y0, cam_x1, cam_y1 = 14, 58, 379, 688
    cam_w = cam_x1 - cam_x0
    cam_h = cam_y1 - cam_y0
    cam_r = 26

    # Create Camera Scene Layer
    cam_img = Image.new('RGBA', (cam_w, cam_h), (20, 22, 28, 255) if dark_scene else (235, 238, 242, 255))
    cam_draw = ImageDraw.Draw(cam_img)

    # Simulated Scene gradient/corridor
    if dark_scene:
        # Hallway perspective lines
        cam_draw.line([(0, cam_h), (cam_w // 2 - 20, cam_h // 2)], fill=(45, 48, 55), width=2)
        cam_draw.line([(cam_w, cam_h), (cam_w // 2 + 20, cam_h // 2)], fill=(45, 48, 55), width=2)
        cam_draw.line([(0, 0), (cam_w // 2 - 20, cam_h // 2)], fill=(35, 38, 44), width=1)
        cam_draw.line([(cam_w, 0), (cam_w // 2 + 20, cam_h // 2)], fill=(35, 38, 44), width=1)
        # Doorway / corridor opening
        cam_draw.rectangle([cam_w // 2 - 35, cam_h // 2 - 60, cam_w // 2 + 35, cam_h // 2 + 60], outline=(60, 65, 75), width=2)
    else:
        # Bright scene perspective
        cam_draw.line([(0, cam_h), (cam_w // 2 - 20, cam_h // 2)], fill=(200, 204, 210), width=2)
        cam_draw.line([(cam_w, cam_h), (cam_w // 2 + 20, cam_h // 2)], fill=(200, 204, 210), width=2)
        cam_draw.rectangle([cam_w // 2 - 35, cam_h // 2 - 60, cam_w // 2 + 35, cam_h // 2 + 60], outline=(180, 185, 195), width=2)

    # Tracking Brackets (Obstacle at x=70, y=200, w=110, h=180)
    if state == "RUNNING":
        bx0, by0, bx1, by1 = 55, 180, 175, 380
        leg = min(26, min(bx1 - bx0, by1 - by0) / 2.8)
        color = (255, 59, 48) if threat == "CRITICAL" else ((255, 149, 0) if threat == "WARNING" else (242, 242, 247))

        corners = [
            (bx0, by0, 1, 1),
            (bx1, by0, -1, 1),
            (bx0, by1, 1, -1),
            (bx1, by1, -1, -1)
        ]

        # Pass 1: Dark outline (7.0pt)
        for (x, y, dx, dy) in corners:
            cam_draw.line([(x + dx * leg, y), (x, y), (x, y + dy * leg)], fill=(0, 0, 0, 220), width=7)
        # Pass 2: Vivid inner colored stroke (4.5pt)
        for (x, y, dx, dy) in corners:
            cam_draw.line([(x + dx * leg, y), (x, y), (x, y + dy * leg)], fill=color, width=4)

    # Directional Guidance Arrow or Status Badge (Centered Horizontally at cx = cam_w / 2)
    cx = cam_w / 2
    cy = cam_h * 0.86

    if state == "RUNNING" and threat != "PAUSED":
        # Perceptual mapping
        visual_angle = max(-45.0, min(45.0, angle_deg * 1.4))
        lateral_shift = max(-35.0, min(35.0, visual_angle * 0.9))

        arrow_cx = cx + lateral_shift
        arrow_cy = cy

        # Arrow points in local coordinates (1.25x larger, 3D perspective pitch)
        # Scaled: width ~76pt, tip to base ~100pt, pitch compressed Y by 0.75
        pts_local = [
            (-16, 32 * 0.75),
            (16, 32 * 0.75),
            (16, -20 * 0.75),
            (38, -20 * 0.75),
            (0, -68 * 0.75),
            (-38, -20 * 0.75),
            (-16, -20 * 0.75)
        ]

        # Rotate points
        rad = math.radians(visual_angle)
        cos_a = math.cos(rad)
        sin_a = math.sin(rad)

        def transform_pt(px, py, ox, oy):
            rx = px * cos_a - py * sin_a
            ry = px * sin_a + py * cos_a
            return (ox + rx, oy + ry)

        # Shadow pass
        shadow_pts = [transform_pt(px, py, arrow_cx, arrow_cy + 6) for (px, py) in pts_local]
        cam_draw.polygon(shadow_pts, fill=(0, 0, 0, 160))

        # Dark border pass
        border_pts = [transform_pt(px, py, arrow_cx, arrow_cy) for (px, py) in pts_local]
        cam_draw.polygon(border_pts, outline=(0, 0, 0, 140), fill=(245, 245, 247))

    else:
        # Glass Status Badge
        badge_w, badge_h = 120, 26
        cam_draw.rounded_rectangle(
            [cx - badge_w, cy - badge_h, cx + badge_w, cy + badge_h],
            radius=18,
            fill=(12, 14, 18, 215),
            outline=(255, 255, 255, 60),
            width=1
        )
        badge_text = "PAUSED" if state == "PAUSED" else ("STOP" if threat == "CRITICAL" else "UNAVAILABLE")
        cam_draw.text((cx - 24, cy - 8), badge_text, fill=(255, 59, 48) if threat == "CRITICAL" else (242, 242, 247))

    # Top-Right Manual Flashlight Button (Enlarged 66x66 pt, P1-01)
    torch_r = 33
    torch_cx = cam_w - 16 - torch_r
    torch_cy = 16 + torch_r
    cam_draw.ellipse(
        [torch_cx - torch_r, torch_cy - torch_r, torch_cx + torch_r, torch_cy + torch_r],
        fill=(25, 28, 35, 215),
        outline=(255, 255, 255, 70),
        width=2
    )
    # Simple torch icon representation (head & body)
    cam_draw.rectangle([torch_cx - 6, torch_cy - 4, torch_cx + 6, torch_cy + 12], fill=(240, 240, 245))
    cam_draw.polygon([(torch_cx - 10, torch_cy - 12), (torch_cx + 10, torch_cy - 12), (torch_cx + 6, torch_cy - 4), (torch_cx - 6, torch_cy - 4)], fill=(240, 240, 245))

    # Mask camera scene into rounded rectangle
    mask = Image.new('L', (cam_w, cam_h), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle([0, 0, cam_w - 1, cam_h - 1], radius=cam_r, fill=255)

    img.paste(cam_img, (cam_x0, cam_y0), mask=mask)

    # Frosted border overlay for camera card
    draw.rounded_rectangle([cam_x0, cam_y0, cam_x1, cam_y1], radius=cam_r, outline=(255, 255, 255, 36), width=1)

    # Large Liquid START / STOP Button:
    # 124pt height, margin 16pt, corner radius 28pt
    btn_x0, btn_y0, btn_x1, btn_y1 = 16, 702, 377, 826
    btn_r = 28

    if is_pressed:
        # Scale 0.96 compression
        bw = btn_x1 - btn_x0
        bh = btn_y1 - btn_y0
        cx_b = (btn_x0 + btn_x1) / 2
        cy_b = (btn_y0 + btn_y1) / 2
        btn_x0 = cx_b - (bw * 0.96) / 2
        btn_x1 = cx_b + (bw * 0.96) / 2
        btn_y0 = cy_b - (bh * 0.96) / 2
        btn_y1 = cy_b + (bh * 0.96) / 2

    if state == "RUNNING":
        # DỪNG (Active System Red Liquid)
        draw.rounded_rectangle([btn_x0, btn_y0, btn_x1, btn_y1], radius=btn_r, fill=(255, 59, 48), outline=(255, 120, 110), width=1)
        # Top specular highlight
        draw.rounded_rectangle([btn_x0 + 6, btn_y0 + 2, btn_x1 - 6, btn_y0 + 18], radius=8, fill=(255, 110, 105))
        # Button text
        draw.text(((btn_x0 + btn_x1) / 2 - 38, (btn_y0 + btn_y1) / 2 - 14), "DỪNG", fill=(255, 255, 255))
    else:
        # CHẠY (Frosted Glass / Platinum Silver)
        draw.rounded_rectangle([btn_x0, btn_y0, btn_x1, btn_y1], radius=btn_r, fill=(230, 230, 235), outline=(255, 255, 255), width=1)
        # Specular highlight
        draw.rounded_rectangle([btn_x0 + 6, btn_y0 + 2, btn_x1 - 6, btn_y0 + 18], radius=8, fill=(250, 250, 255))
        draw.text(((btn_x0 + btn_x1) / 2 - 40, (btn_y0 + btn_y1) / 2 - 14), "CHẠY", fill=(18, 20, 24))

    # Home Bar
    draw.rounded_rectangle([125, 840, 268, 845], radius=3, fill=(140, 140, 145))

    return img

def main():
    os.makedirs("artifacts/previews", exist_ok=True)

    # 1. Running state with Forward 0 deg
    img_fwd = render_vampior_mockup(state="RUNNING", threat="NORMAL", angle_deg=0.0, dark_scene=True)
    img_fwd.save("artifacts/previews/preview_running_fwd.png")

    # 2. Running state with Left Turn (-20 deg -> visual -28 deg + left shift)
    img_left = render_vampior_mockup(state="RUNNING", threat="WARNING", angle_deg=-20.0, dark_scene=True)
    img_left.save("artifacts/previews/preview_running_left.png")

    # 3. Running state with Right Turn (+20 deg -> visual +28 deg + right shift)
    img_right = render_vampior_mockup(state="RUNNING", threat="WARNING", angle_deg=20.0, dark_scene=False)
    img_right.save("artifacts/previews/preview_running_right.png")

    # 4. Critical Stop state
    img_stop = render_vampior_mockup(state="RUNNING", threat="CRITICAL", angle_deg=0.0, dark_scene=True)
    img_stop.save("artifacts/previews/preview_stop.png")

    # 5. Paused state (CHẠY button ready)
    img_paused = render_vampior_mockup(state="PAUSED", threat="PAUSED", is_pressed=False, dark_scene=True)
    img_paused.save("artifacts/previews/preview_paused.png")

    # 6. Pressed button compression state
    img_pressed = render_vampior_mockup(state="RUNNING", threat="NORMAL", angle_deg=0.0, is_pressed=True, dark_scene=True)
    img_pressed.save("artifacts/previews/preview_button_pressed.png")

    print("All visual mockup previews generated successfully in artifacts/previews/")

if __name__ == "__main__":
    main()
