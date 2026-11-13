"""Landscape dual-panel desktop viewport (1280x720).
Left Panel: Live RGB camera stream with tracking brackets and 3D spatial arrow.
Right Panel: Genuine MiDaS relative depth heatmap (TURBO colormap, invalid data distinct).
Bottom: Substantially enlarged CHẠY / DỪNG button.
"""
import math
import cv2
import numpy as np
from directional_advisory import aspect_fit, advisory_for_risk, estimate_directional_advisory


class DemoViewport:
    width, height = 1280, 720
    panel_left = (24, 24, 624, 560)   # (l, t, r, b) width=600, height=536
    panel_right = (656, 24, 1256, 560) # (l, t, r, b) width=600, height=536
    button = (48, 584, 1232, 696)      # (l, t, r, b) width=1184, height=112

    def __init__(self):
        self._prev_angle = None

    def button_hit(self, x, y):
        l, t, r, b = self.button
        return l <= x <= r and t <= y <= b

    def render(self, frame, result=None, threat="PAUSED", mirror=False, now=0, advisory=None, depth_viz=None):
        canvas = np.full((self.height, self.width, 3), (16, 18, 22), np.uint8)

        # ── 1. LEFT PANEL: LIVE RGB CAMERA ──
        lx1, ly1, lx2, ly2 = self.panel_left
        lw, lh = lx2 - lx1, ly2 - ly1
        cv2.rectangle(canvas, (lx1, ly1), (lx2, ly2), (22, 25, 30), -1)
        cv2.rectangle(canvas, (lx1, ly1), (lx2, ly2), (40, 46, 56), 1)

        # Left panel header
        cv2.putText(canvas, "LIVE RGB CAMERA", (lx1 + 16, ly1 + 28),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (180, 185, 195), 1, cv2.LINE_AA)

        # Content area for left camera preview
        c_ly1 = ly1 + 36
        c_lh = lh - 40
        if frame is not None and frame.size > 0:
            h, w = frame.shape[:2]
            scale, ox, oy = aspect_fit(w, h, lw, c_lh)
            rw, rh, rox, roy = round(w * scale), round(h * scale), round(ox), round(oy)
            preview = cv2.resize(frame, (rw, rh))
            if mirror:
                preview = cv2.flip(preview, 1)
            target_y = c_ly1 + roy
            target_x = lx1 + rox
            canvas[target_y:target_y + rh, target_x:target_x + rw] = preview

            # Obstacle tracking brackets
            if result is not None and getattr(result, "is_valid", True):
                obs_color = (74, 68, 239) if threat == "CRITICAL" else (60, 180, 245) if threat == "WARNING" else (175, 180, 150)
                for o in getattr(result, "all_obstacles", []) or []:
                    bbox = getattr(o, "bbox", None)
                    if not bbox or len(bbox) < 4:
                        continue
                    bx, by, bw, bh = bbox[:4]
                    if mirror:
                        bx = w - bx - bw
                    bl = round(target_x + bx * scale)
                    bt = round(target_y + by * scale)
                    br = round(target_x + (bx + bw) * scale)
                    bb = round(target_y + (by + bh) * scale)
                    leg = min(18, max(4, (br - bl) // 3), max(4, (bb - bt) // 3))
                    for px, py, dx, dy in [(bl, bt, 1, 1), (br, bt, -1, 1), (bl, bb, 1, -1), (br, bb, -1, -1)]:
                        cv2.line(canvas, (px, py), (px + leg * dx, py), obs_color, 2)
                        cv2.line(canvas, (px, py), (px, py + leg * dy), obs_color, 2)

            # Spatial Direction Arrow / Status Indicator on Left Panel
            if advisory is None:
                if result is not None and threat != "PAUSED":
                    advisory = estimate_directional_advisory(result, threat=threat, now=now, prev_angle=self._prev_angle)
                else:
                    advisory = advisory_for_risk(threat, now)

            angle = advisory.drawable_angle(now)
            cx_arrow = lx1 + lw // 2
            cy_arrow = target_y + rh - 45

            if angle is not None and threat != "PAUSED":
                self._prev_angle = angle
                rad = math.radians(-angle if mirror else angle)
                points = np.array([[-13, 25], [13, 25], [13, -15], [28, -15], [0, -53], [-28, -15], [-13, -15]], np.float32)
                rot = np.array([[math.cos(rad), math.sin(rad)], [-math.sin(rad), math.cos(rad)]])
                points = points @ rot
                points[:, 1] *= 0.7  # 3D perspective tilt
                points += (cx_arrow, cy_arrow)
                # Drop shadow
                cv2.fillPoly(canvas, [points.astype(np.int32) + [3, 5]], (25, 30, 35))
                # Arrow polygon
                cv2.fillPoly(canvas, [points.astype(np.int32)], (225, 240, 235))
            else:
                self._prev_angle = None
                label = ("STOP" if threat == "CRITICAL" else
                         "PAUSED" if threat == "PAUSED" else
                         "UNAVAILABLE")
                color = (74, 68, 239) if threat == "CRITICAL" else (210, 210, 210)
                bw_b = 160
                bh_b = 36
                bx1 = cx_arrow - bw_b // 2
                by1 = cy_arrow - bh_b // 2
                cv2.rectangle(canvas, (bx1, by1), (bx1 + bw_b, by1 + bh_b), (20, 22, 26), -1)
                cv2.rectangle(canvas, (bx1, by1), (bx1 + bw_b, by1 + bh_b), (50, 56, 66), 1)
                t_size = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.65, 2)[0]
                tx = cx_arrow - t_size[0] // 2
                ty = cy_arrow + t_size[1] // 2
                cv2.putText(canvas, label, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 0.65, color, 2, cv2.LINE_AA)
        else:
            # Camera inactive or disconnected
            cv2.putText(canvas, "CAMERA UNAVAILABLE", (lx1 + lw // 2 - 110, ly1 + lh // 2),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.75, (100, 105, 115), 2, cv2.LINE_AA)

        # ── 2. RIGHT PANEL: ACTUAL MODEL DEPTH HEATMAP (TURBO) ──
        rx1, ry1, rx2, ry2 = self.panel_right
        rw_p, rh_p = rx2 - rx1, ry2 - ry1
        cv2.rectangle(canvas, (rx1, ry1), (rx2, ry2), (22, 25, 30), -1)
        cv2.rectangle(canvas, (rx1, ry1), (rx2, ry2), (40, 46, 56), 1)

        # Right panel header
        cv2.putText(canvas, "MIDAS RELATIVE DEPTH (TURBO HEATMAP)", (rx1 + 16, ry1 + 28),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (180, 185, 195), 1, cv2.LINE_AA)

        c_ry1 = ry1 + 36
        c_rh = rh_p - 40

        d_source = depth_viz if depth_viz is not None else getattr(result, "depth_viz", None)

        if threat == "PAUSED":
            cv2.putText(canvas, "PERCEPTION PAUSED", (rx1 + rw_p // 2 - 110, ry1 + rh_p // 2),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.75, (100, 105, 115), 2, cv2.LINE_AA)
        elif d_source is not None and isinstance(d_source, np.ndarray) and d_source.size > 0:
            dh, dw = d_source.shape[:2]
            scale_d, ox_d, oy_d = aspect_fit(dw, dh, rw_p, c_rh)
            drw, drh = round(dw * scale_d), round(dh * scale_d)
            d_resized = cv2.resize(d_source, (drw, drh), interpolation=cv2.INTER_NEAREST)

            # Apply COLORMAP_TURBO to genuine normalized depth
            heatmap = cv2.applyColorMap(d_resized, cv2.COLORMAP_TURBO)
            # Show invalid/zero data distinctly (dark charcoal background)
            invalid_mask = (d_resized == 0)
            heatmap[invalid_mask] = (18, 20, 24)

            if mirror:
                heatmap = cv2.flip(heatmap, 1)

            target_dy = c_ry1 + round(oy_d)
            target_dx = rx1 + round(ox_d)
            canvas[target_dy:target_dy + drh, target_dx:target_dx + drw] = heatmap
        else:
            status_text = "INITIALIZING..." if threat == "INITIALIZING" else "DEPTH UNAVAILABLE"
            cv2.putText(canvas, status_text, (rx1 + rw_p // 2 - 100, ry1 + rh_p // 2),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.75, (100, 105, 115), 2, cv2.LINE_AA)

        # ── 3. BOTTOM BUTTON: CHẠY / DỪNG ──
        bx1, by1, bx2, by2 = self.button
        btn_color = (235, 235, 235) if threat == "PAUSED" else (70, 70, 235)
        text_color = (20, 22, 26) if threat == "PAUSED" else (255, 255, 255)
        cv2.rectangle(canvas, (bx1, by1), (bx2, by2), btn_color, -1)
        cv2.rectangle(canvas, (bx1, by1), (bx2, by2), (60, 65, 75), 2)

        btn_text = "CHAY" if threat == "PAUSED" else "DUNG"
        btn_size = cv2.getTextSize(btn_text, cv2.FONT_HERSHEY_SIMPLEX, 1.1, 3)[0]
        tx_btn = bx1 + (bx2 - bx1 - btn_size[0]) // 2
        ty_btn = by1 + (by2 - by1 + btn_size[1]) // 2
        cv2.putText(canvas, btn_text, (tx_btn, ty_btn), cv2.FONT_HERSHEY_SIMPLEX, 1.1, text_color, 3, cv2.LINE_AA)

        return canvas
