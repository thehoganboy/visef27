"""Reproducible real-frame/video replay with annotated MP4 export and telemetry logging."""
import argparse
import csv
import hashlib
import json
import math
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
from directional_advisory import estimate_directional_advisory, DirectionState

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', help='Path to input video file (e.g. data/tum_walking_static.mp4)')
    parser.add_argument('--frames', type=int, default=120, help='Maximum frames to process')
    parser.add_argument('--seconds', type=float, default=0, help='Maximum real seconds')
    parser.add_argument('--output', default='reports/demo_ready/replay', help='Output directory')
    parser.add_argument('--export-video', action='store_true', default=False, help='Export annotated MP4 video')
    args = parser.parse_args()

    dest = Path(args.output)
    dest.mkdir(parents=True, exist_ok=True)

    model = DepthEstimator()
    kin = KinematicsEngine()
    budget = AuditoryBudgetManager()
    view = DemoViewport()

    capture = cv2.VideoCapture(args.video) if args.video else None
    fixtures = sorted(Path('tests/fixtures/demo').glob('frame_*.png'))
    if capture is not None and not capture.isOpened():
        raise RuntimeError(f'Video unavailable: {args.video}')

    fps = capture.get(cv2.CAP_PROP_FPS) if capture else 10.0
    if not math.isfinite(fps) or fps <= 0:
        fps = 30.0

    video_writer = None
    if args.export_video:
        mp4_path = str(dest / 'annotated_replay.mp4')
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        # Viewport render is 480w x 800h portrait
        video_writer = cv2.VideoWriter(mp4_path, fourcc, min(fps, 30.0), (480, 800))

    rows = []
    start = time.monotonic()
    index = 0
    prev_angle = None

    try:
        while index < args.frames or (args.seconds and time.monotonic() - start < args.seconds):
            if capture:
                ok, frame = capture.read()
                if not ok:
                    if not args.seconds:
                        break
                    capture.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    kin = KinematicsEngine()
                    budget = AuditoryBudgetManager()
                    ok, frame = capture.read()
                    if not ok:
                        raise RuntimeError('Replay exhausted')
                pos_msec = capture.get(cv2.CAP_PROP_POS_MSEC)
                pts = (pos_msec / 1000.0) if (pos_msec is not None and pos_msec >= 0) else (index / max(fps, 1.0))
            else:
                frame = cv2.imread(str(fixtures[index % len(fixtures)]))
                # Independent static photos are not continuous successive frames
                kin = KinematicsEngine()
                budget = AuditoryBudgetManager()
                pts = index / max(fps, 1.0)

            t0 = time.perf_counter()
            norm, raw = model.infer_depth(frame)
            t1 = time.perf_counter()

            obs = model.detect_obstacle(norm, raw, frame_bgr=frame)
            t2 = time.perf_counter()

            k = kin.compute(obs, pts, frame_id=index + 1)
            t3 = time.perf_counter()

            d = budget.coordinate(obs, k)
            t4 = time.perf_counter()

            # Continuous directional advisory computed once per frame
            adv = estimate_directional_advisory(obs, threat=k.threat_level, now=pts, prev_angle=prev_angle)
            if adv.state == DirectionState.AVAILABLE:
                prev_angle = adv.angle_deg
            else:
                prev_angle = None

            canvas = view.render(frame, obs, k.threat_level, now=pts, advisory=adv)
            t5 = time.perf_counter()

            if video_writer is not None:
                video_writer.write(canvas)

            # Strict provenance: hazard_vz and hazard_ttc strictly from the exact same source (d)
            hazard_vz = d.velocity_z if d.is_active else 0.0
            hazard_ttc = d.ttc if d.is_active else float("inf")

            rows.append(dict(
                index=index,
                timestamp=pts,
                inference_ms=(t1 - t0) * 1000.0,
                objects_ms=(t2 - t1) * 1000.0,
                risk_ms=(t3 - t2) * 1000.0,
                budget_ms=(t4 - t3) * 1000.0,
                render_ms=(t5 - t4) * 1000.0,
                total_ms=(t5 - t0) * 1000.0,
                source_type=getattr(d, "source_type", "OBJECT" if d.is_active else "NONE"),
                source_id=getattr(d, "source_id", str(d.active_obstacle_id) if d.is_active else "0"),
                active_id=d.active_obstacle_id if d.is_active else 0,
                threat=k.threat_level,
                hazard_dist_cm=d.dist_cm if d.is_active else obs.dist_cm,
                hazard_vz=hazard_vz,
                hazard_ttc=hazard_ttc,
                primary_track_vz=k.primary_velocity_z,
                primary_track_ttc=k.primary_ttc,
                dist_cm=d.dist_cm if d.is_active else obs.dist_cm,
                vz=hazard_vz,
                ttc=hazard_ttc,
                direction_state=adv.state.value,
                direction_angle=adv.angle_deg if adv.angle_deg is not None else float("nan"),
                cue_mode=d.cue_mode,
                raw_min=float(raw.min()),
                raw_median=float(np.median(raw)),
                raw_max=float(raw.max())
            ))

            if index < 4:
                cv2.imwrite(str(dest / f'frame_{index}.png'), canvas)
            index += 1
    finally:
        if capture:
            capture.release()
        if video_writer:
            video_writer.release()

    if not rows:
        raise RuntimeError("No frames were processed in replay")

    with (dest / 'frames.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    summary = {
        'source_sha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True)),
        'platform': platform.platform(),
        'processor': platform.processor(),
        'frames': len(rows),
        'input': args.video or 'tests/fixtures/demo/manifest.json',
        'elapsed_sec': time.monotonic() - start,
        'camera_to_audio': 'NOT MEASURED: replay does not include camera or physical audio',
        'latency': {
            key: {
                'median': float(np.median([r[key] for r in rows])),
                'p95': float(np.percentile([r[key] for r in rows], 95)),
                'worst': float(max(r[key] for r in rows))
            } for key in rows[0] if key.endswith('_ms')
        },
        'processing_fps': 1000.0 / np.mean([r['total_ms'] for r in rows]),
        'annotated_video': str(dest / 'annotated_replay.mp4') if args.export_video else None
    }
    (dest / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))

if __name__ == '__main__':
    main()
