"""Minimal portrait renderer. The old TelemetryHUD remains engineering-only."""
import math
import cv2
import numpy as np
from directional_advisory import aspect_fit, advisory_for_risk, estimate_directional_advisory


class DemoViewport:
    width, height, preview_height = 480, 800, 680
    button = (24, 700, 456, 780)

    def __init__(self):
        self._prev_angle = None

    def button_hit(self, x, y):
        l, t, r, b = self.button
        return l <= x <= r and t <= y <= b

    def render(self, frame, result=None, threat="PAUSED", mirror=False, now=0, advisory=None):
        canvas = np.full((self.height, self.width, 3), (18, 20, 24), np.uint8)
        if frame is not None:
            h, w = frame.shape[:2]
            scale, ox, oy = aspect_fit(w, h, self.width, self.preview_height)
            rw, rh, ox, oy = round(w * scale), round(h * scale), round(ox), round(oy)
            preview = cv2.resize(frame, (rw, rh))
            if mirror:
                preview = cv2.flip(preview, 1)
            canvas[oy:oy + rh, ox:ox + rw] = preview
            if result is not None and getattr(result, "is_valid", True):
                color = (74, 68, 239) if threat == "CRITICAL" else (60, 180, 245) if threat == "WARNING" else (175, 180, 150)
                for o in getattr(result, "all_obstacles", []) or []:
                    bbox = getattr(o, "bbox", None)
                    if not bbox or len(bbox) < 4:
                        continue
                    x, y, bw, bh = bbox[:4]
                    if mirror:
                        x = w - x - bw
                    l, t, r, b = [round(v) for v in (ox + x * scale, oy + y * scale, ox + (x + bw) * scale, oy + (y + bh) * scale)]
                    leg = min(18, max(4, (r - l) // 3), max(4, (b - t) // 3))
                    for px, py, dx, dy in [(l, t, 1, 1), (r, t, -1, 1), (l, b, 1, -1), (r, b, -1, -1)]:
                        cv2.line(canvas, (px, py), (px + leg * dx, py), color, 3)
                        cv2.line(canvas, (px, py), (px, py + leg * dy), color, 3)

        # Directional Advisory calculation
        if advisory is None:
            if result is not None and threat != "PAUSED":
                advisory = estimate_directional_advisory(result, threat=threat, now=now, prev_angle=self._prev_angle)
            else:
                advisory = advisory_for_risk(threat, now)

        angle = advisory.drawable_angle(now)
        if angle is not None and threat != "PAUSED":
            self._prev_angle = angle
            rad = math.radians(-angle if mirror else angle)
            # Perspective 3D-styled arrow
            points = np.array([[-13, 25], [13, 25], [13, -15], [28, -15], [0, -53], [-28, -15], [-13, -15]], np.float32)
            rot = np.array([[math.cos(rad), math.sin(rad)], [-math.sin(rad), math.cos(rad)]])
            points = points @ rot
            points[:, 1] *= 0.7  # 3D perspective tilt
            points += (240, 605)
            # Drop shadow
            cv2.fillPoly(canvas, [points.astype(np.int32) + [4, 7]], (45, 50, 55))
            # Foreground gradient / highlight
            cv2.fillPoly(canvas, [points.astype(np.int32)], (220, 235, 230))
        else:
            self._prev_angle = None
            label = "STOP" if threat == "CRITICAL" else "UNAVAILABLE" if threat in {"SENSOR_FAULT", "UNKNOWN", "UNRESOLVED_HAZARD", "INITIALIZING"} else "PAUSED" if threat == "PAUSED" else "UNAVAILABLE"
            color = (74, 68, 239) if threat == "CRITICAL" else (210, 210, 210)
            cv2.rectangle(canvas, (95, 570), (385, 630), (22, 24, 28), -1)
            cv2.rectangle(canvas, (95, 570), (385, 630), (50, 55, 60), 1)
            text_size = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.75, 2)[0]
            tx = (self.width - text_size[0]) // 2
            cv2.putText(canvas, label, (tx, 608), cv2.FONT_HERSHEY_SIMPLEX, 0.75, color, 2, cv2.LINE_AA)

        # Large bottom button (START / STOP)
        l, t, r, b = self.button
        btn_color = (225, 225, 225) if threat == "PAUSED" else (235, 80, 80)
        text_color = (25, 25, 25) if threat == "PAUSED" else (255, 255, 255)
        cv2.rectangle(canvas, (l, t), (r, b), btn_color, -1)
        btn_text = "START" if threat == "PAUSED" else "STOP"
        btn_size = cv2.getTextSize(btn_text, cv2.FONT_HERSHEY_SIMPLEX, 0.9, 2)[0]
        bx = (self.width - btn_size[0]) // 2
        by = t + (b - t + btn_size[1]) // 2
        cv2.putText(canvas, btn_text, (bx, by), cv2.FONT_HERSHEY_SIMPLEX, 0.9, text_color, 2, cv2.LINE_AA)

        return canvas
