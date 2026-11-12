"""Reproducible real-frame/video replay; no physical accuracy or mobile FPS claim."""
import argparse
import csv
import hashlib
import json
import platform
import subprocess
import time
from pathlib import Path
import cv2
import numpy as np
from depth_engine import DepthEstimator
from motion_ttc import KinematicsEngine
from auditory_budget import AuditoryBudgetManager
from demo_ui import DemoViewport

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video')
    parser.add_argument('--frames',type=int,default=120)
    parser.add_argument('--seconds',type=float,default=0)
    parser.add_argument('--output',default='reports/demo_ready/replay')
    args=parser.parse_args()
    dest=Path(args.output);dest.mkdir(parents=True,exist_ok=True)
    model=DepthEstimator();kin=KinematicsEngine();budget=AuditoryBudgetManager();view=DemoViewport()
    capture=cv2.VideoCapture(args.video) if args.video else None
    fixtures=sorted(Path('tests/fixtures/demo').glob('frame_*.png'))
    if capture is not None and not capture.isOpened(): raise RuntimeError('Video unavailable')
    fps=capture.get(cv2.CAP_PROP_FPS) if capture else 10
    rows=[];start=time.monotonic();index=0
    try:
        while index<args.frames or (args.seconds and time.monotonic()-start<args.seconds):
            if capture:
                ok,frame=capture.read()
                if not ok:
                    if not args.seconds: break
                    capture.set(cv2.CAP_PROP_POS_FRAMES,0);kin=KinematicsEngine();budget=AuditoryBudgetManager()
                    ok,frame=capture.read()
                    if not ok: raise RuntimeError('Replay exhausted')
            else:
                frame=cv2.imread(str(fixtures[index%len(fixtures)]))
                # Independent photos are not successive motion observations.
                kin=KinematicsEngine();budget=AuditoryBudgetManager()
            t0=time.perf_counter();norm,raw=model.infer_depth(frame);t1=time.perf_counter()
            obs=model.detect_obstacle(norm,raw,frame_bgr=frame);t2=time.perf_counter()
            k=kin.compute(obs,10+index/max(fps,1),frame_id=index+1);t3=time.perf_counter()
            d=budget.coordinate(obs,k);t4=time.perf_counter()
            canvas=view.render(frame,obs,k.threat_level,now=10+index/max(fps,1));t5=time.perf_counter()
            rows.append(dict(index=index,inference_ms=(t1-t0)*1000,objects_ms=(t2-t1)*1000,
                risk_ms=(t3-t2)*1000,budget_ms=(t4-t3)*1000,render_ms=(t5-t4)*1000,total_ms=(t5-t0)*1000,
                threat=k.threat_level,ttc=k.primary_ttc,dist_cm=obs.dist_cm,raw_min=float(raw.min()),raw_median=float(np.median(raw)),raw_max=float(raw.max())))
            if index<4: cv2.imwrite(str(dest/f'frame_{index}.png'),canvas)
            index+=1
    finally:
        if capture: capture.release()
    with (dest/'frames.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=rows[0]);writer.writeheader();writer.writerows(rows)
    summary={'source_sha':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        'dirty':bool(subprocess.check_output(['git','status','--porcelain'],text=True)),
        'platform':platform.platform(),'processor':platform.processor(),'frames':len(rows),
        'input':args.video or 'tests/fixtures/demo/manifest.json','elapsed_sec':time.monotonic()-start,
        'camera_to_audio':'NOT MEASURED: replay does not include camera or physical audio',
        'latency':{key:{'median':float(np.median([r[key] for r in rows])),
            'p95':float(np.percentile([r[key] for r in rows],95)),
            'worst':float(max(r[key] for r in rows))} for key in rows[0] if key.endswith('_ms')},
        'processing_fps':1000/np.mean([r['total_ms'] for r in rows])}
    (dest/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
