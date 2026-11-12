"""Minimal portrait renderer. The old TelemetryHUD remains engineering-only."""
import math
import cv2
import numpy as np
from directional_advisory import aspect_fit, advisory_for_risk

class DemoViewport:
    width, height, preview_height = 480, 800, 680
    button = (24, 704, 456, 776)

    def button_hit(self, x, y):
        l, t, r, b = self.button
        return l <= x <= r and t <= y <= b

    def render(self, frame, result=None, threat="PAUSED", mirror=False, now=0, advisory=None):
        canvas = np.full((self.height, self.width, 3), (18, 20, 24), np.uint8)
        if frame is not None:
            h, w = frame.shape[:2]
            scale, ox, oy = aspect_fit(w, h, self.width, self.preview_height)
            rw, rh, ox, oy = round(w*scale), round(h*scale), round(ox), round(oy)
            preview = cv2.resize(frame, (rw, rh))
            if mirror:
                preview = cv2.flip(preview, 1)
            canvas[oy:oy+rh, ox:ox+rw] = preview
            if result is not None:
                color = (74, 68, 239) if threat == "CRITICAL" else (60, 180, 245) if threat == "WARNING" else (175, 180, 150)
                for o in result.all_obstacles or []:
                    x, y, bw, bh = o.bbox
                    if mirror:
                        x = w-x-bw
                    l,t,r,b = [round(v) for v in (ox+x*scale,oy+y*scale,ox+(x+bw)*scale,oy+(y+bh)*scale)]
                    leg = min(18,max(4,(r-l)//3),max(4,(b-t)//3))
                    for px,py,dx,dy in [(l,t,1,1),(r,t,-1,1),(l,b,1,-1),(r,b,-1,-1)]:
                        cv2.line(canvas,(px,py),(px+leg*dx,py),color,3)
                        cv2.line(canvas,(px,py),(px,py+leg*dy),color,3)
        advisory = advisory or advisory_for_risk(threat, now)
        angle = advisory.drawable_angle(now)
        if angle is not None and threat != "PAUSED":
            angle = math.radians(-angle if mirror else angle)
            points = np.array([[-13,25],[13,25],[13,-15],[28,-15],[0,-53],[-28,-15],[-13,-15]],np.float32)
            points = points @ np.array([[math.cos(angle),math.sin(angle)],[-math.sin(angle),math.cos(angle)]])
            points[:,1] *= .7
            points += (240,605)
            cv2.fillPoly(canvas,[points.astype(np.int32)+[4,7]],(65,80,85))
            cv2.fillPoly(canvas,[points.astype(np.int32)],(210,225,220))
        else:
            label = "STOP" if threat == "CRITICAL" else "UNAVAILABLE" if threat in {"SENSOR_FAULT","UNKNOWN","UNRESOLVED_HAZARD"} else "PAUSED" if threat == "PAUSED" else "NO DIRECTION"
            color = (74,68,239) if threat == "CRITICAL" else (210,210,210)
            cv2.rectangle(canvas,(95,570),(385,630),(22,24,28),-1)
            cv2.putText(canvas,label,(112,609),cv2.FONT_HERSHEY_SIMPLEX,.75,color,2,cv2.LINE_AA)
        l,t,r,b=self.button
        cv2.rectangle(canvas,(l,t),(r,b),(225,225,225),-1)
        cv2.putText(canvas,"START" if threat == "PAUSED" else "STOP",(180,752),cv2.FONT_HERSHEY_SIMPLEX,1,(25,25,25),2,cv2.LINE_AA)
        return canvas
