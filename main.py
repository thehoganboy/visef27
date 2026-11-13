"""Minimal demo. Space/S toggles perception; Q/Escape closes. Offline prototype."""
import argparse
import logging
import time
import cv2
from video_capture import ThreadedCamera
from demo_runtime import DemoRuntime
from demo_ui import DemoViewport


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', '-s', default=None)
    p.add_argument('--no-audio', action='store_true')
    p.add_argument('--mirror-display', action='store_true')
    p.add_argument('--smoke-seconds', type=float, default=0)
    return p.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(level=logging.INFO)
    cam = audio = None
    runtime, view = DemoRuntime(), DemoViewport()
    title = 'HorusEyes 2.0'
    active = toggle_requested = False

    def click(event, x, y, flags, param):
        nonlocal toggle_requested
        if event == cv2.EVENT_LBUTTONUP and view.button_hit(x, y):
            toggle_requested = True

    try:
        cv2.namedWindow(title, cv2.WINDOW_AUTOSIZE)
        cv2.setMouseCallback(title, click)
        cv2.imshow(title, view.render(None))
        cv2.waitKey(1)
        try:
            cam = ThreadedCamera(source=args.source).start()
        except (RuntimeError, ValueError):
            logging.exception('Camera unavailable')
        if not args.no_audio:
            from audio_synth import SpatialAudioEngine
            audio = SpatialAudioEngine()
            audio.start()
        start = time.monotonic()
        while True:
            now = time.monotonic()
            frame, frame_id, timestamp, lighting = cam.read() if cam else (None, 0, 0, {})
            healthy = frame is not None and now - timestamp <= 1
            if active and healthy:
                runtime.submit(frame, frame_id, timestamp, lighting)
            threat, result, decision = runtime.snapshot(healthy)
            if audio:
                audio.update_decision(decision)
                audio.check_stream_health()
            # Centralized Freshness Policy (Directive P0-02):
            # 1. Preview: freshest camera frame displayed directly at native capture rate
            display = frame if healthy else None
            obs_to_render = None
            adv_to_render = None

            if result and healthy:
                result_age = max(0.0, now - result.timestamp)
                # 2. Tracking overlay window: <= 250ms (never misalign onto moved camera view)
                if result_age <= 0.250:
                    obs_to_render = result.observation
                # 3. Directional advisory window: <= 500ms
                if result_age <= 0.500:
                    adv_to_render = getattr(result, "advisory", None)

            if not active or threat == "PAUSED":
                adv_to_render = advisory_for_risk("PAUSED", now)
            elif threat in {"SENSOR_FAULT", "UNKNOWN", "INITIALIZING"}:
                adv_to_render = advisory_for_risk(threat, now)
            elif adv_to_render is None:
                # Stale observation (> 500ms): withdraw directional arrow immediately
                adv_to_render = DirectionalAdvisory(state=DirectionState.UNAVAILABLE, source_timestamp=now)

            canvas = view.render(display, obs_to_render,
                                 threat, args.mirror_display, now, advisory=adv_to_render)
            cv2.imshow(title, canvas)
            key = cv2.waitKey(20) & 255
            if key in (27, ord('q')) or cv2.getWindowProperty(title, cv2.WND_PROP_VISIBLE) < 1:
                break
            if toggle_requested or key in (32, ord('s')):
                active = not active
                runtime.set_active(active)
                toggle_requested = False
            if args.smoke_seconds and now - start >= args.smoke_seconds:
                break
    finally:
        runtime.close()
        if audio:
            audio.stop()
        if cam:
            cam.release()
        cv2.destroyAllWindows()


if __name__ == '__main__':
    main()
