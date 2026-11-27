"""Summarize an iOS Research diagnostics CSV and compare independently measured trials."""

import argparse
import csv
import json
import math
from pathlib import Path
from statistics import mean


def number(row, name):
    try:
        value = float(row.get(name, ""))
    except (ValueError, TypeError):
        return None
    return value if math.isfinite(value) else None


def numeric(rows, name):
    return [value for row in rows if (value := number(row, name)) is not None]


def quantile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def latency(values):
    return {"p50": quantile(values, .5), "p95": quantile(values, .95)}


def distance(rows, reference, minimum_roi):
    values = []
    for row in rows:
        cm = number(row, "target_roi_cm")
        coverage = number(row, "target_roi_valid_fraction")
        if (cm is not None and cm > 0 and coverage is not None and coverage >= minimum_roi
                and row.get("decision_reason") != "SOURCE_FRAME_STALE"):
            values.append(cm)
    result = {
        "valid": len(values),
        "unavailable": len(rows) - len(values),
        "valid_fraction": len(values) / len(rows) if rows else None,
        "mean_spatial_coverage": mean(numeric(rows, "valid_fraction")) if numeric(rows, "valid_fraction") else None,
    }
    errors = [value - reference for value in values] if reference is not None else []
    if errors:
        absolute = list(map(abs, errors))
        result.update(mae_cm=mean(absolute), rmse_cm=math.sqrt(mean(value**2 for value in errors)),
                      bias_cm=mean(errors), p95_absolute_error_cm=quantile(absolute, .95))
    return result


def expected_match(row, expected):
    state = row.get("state")
    risk = row.get("risk")
    angle = number(row, "advisory_angle_deg")
    if expected == "LEFT":
        return state == "AVAILABLE" and angle is not None and angle < -2
    if expected == "RIGHT":
        return state == "AVAILABLE" and angle is not None and angle > 2
    if expected in {"WARNING", "CRITICAL"}:
        return risk == expected or (expected == "CRITICAL" and state == "STOP"
                                    and row.get("decision_reason") == "CRITICAL_OBSTACLE")
    return state == expected


def decisions(rows, expected, onset):
    guidance = ("AVAILABLE", "LEFT", "RIGHT")
    frame_times = numeric(rows, "capture_s")
    matches = [row for row in rows if expected_match(row, expected)] if expected else []
    match_times = numeric(matches, "capture_s")
    first = min(match_times, default=None)
    start = onset if onset is not None else min(frame_times, default=None)
    return {
        "frames": len(rows),
        "available": sum(row.get("state") == "AVAILABLE" for row in rows),
        "stop": sum(row.get("state") == "STOP" for row in rows),
        "false_available": sum(row.get("state") == "AVAILABLE" for row in rows) if expected == "UNAVAILABLE" else None,
        "missed_critical": len(rows) - len(matches) if expected == "CRITICAL" else None,
        "unnecessary_stop": sum(row.get("state") == "STOP" for row in rows) if expected in guidance else None,
        "expected_fraction": len(matches) / len(rows) if rows and expected else None,
        "response_ms": (first - start) * 1000 if first is not None and start is not None else None,
    }


def single_object(rows, field):
    """Compare one centered target before and after display tracking on the same frames."""
    detections = []
    for row in rows:
        candidates = row.get(field, "").split("|")
        box = candidates[0].split(":") if len(candidates) == 1 else []
        try:
            detection = (int(box[0]), *(float(value) for value in box[1:6])) if len(box) >= 6 else None
        except ValueError:
            detection = None
        detections.append(detection if detection and all(math.isfinite(v) for v in detection) else None)
    transitions = [(a, b) for a, b in zip(detections, detections[1:]) if a and b]
    center_jitter = [math.hypot((a[1] + a[3] / 2) - (b[1] + b[3] / 2),
                               (a[2] + a[4] / 2) - (b[2] + b[4] / 2)) for a, b in transitions]
    distance_jitter = [abs(a[5] - b[5]) for a, b in transitions]
    segments = sum(current is not None and previous is None for previous, current in zip([None] + detections, detections))
    return {
        "single_detection_frames": sum(value is not None for value in detections),
        "fragments_after_first_segment": max(0, segments - 1),
        "adjacent_id_switches": sum(a[0] != b[0] for a, b in transitions),
        "mean_center_step_px": mean(center_jitter) if center_jitter else None,
        "mean_distance_step_cm": mean(distance_jitter) if distance_jitter else None,
    }


def summarize(path, source=None, start=None, end=None, truth=None, expected=None, min_roi=.2, track=False):
    with path.open(newline="", encoding="utf-8-sig") as stream:
        data = list(csv.DictReader(stream))
    groups = {}
    for row in data:
        mode = row.get("source")
        source_matches = not source or mode == source or (source == "Stereo" and mode and mode.startswith("Stereo"))
        if row.get("event") != "frame" or not mode or not source_matches:
            continue
        stamp = number(row, "capture_s")
        if stamp is None or (start is not None and stamp < start) or (end is not None and stamp > end):
            continue
        groups.setdefault(mode, []).append(row)
    summary = {}
    for mode, rows in groups.items():
        rows.sort(key=lambda row: float(row["capture_s"]))
        duration = float(rows[-1]["capture_s"]) - float(rows[0]["capture_s"])
        capture = numeric(rows, "source_capture_fps")
        if mode.startswith("Stereo"):
            capture = numeric([row for row in data if row.get("event") == "stereo_capture"
                               and row.get("capture_stage") == "health"], "pair_fps")
        summary[mode] = {
            "depth": distance(rows, truth, min_roi),
            "guidance": decisions(rows, expected, start),
            "performance": {
                "processing_fps": (len(rows) - 1) / duration if duration > 0 else None,
                "capture_fps_median": quantile(capture, .5),
                "processing_ms": latency(numeric(rows, "processing_ms")),
                "end_to_end_ms": latency(numeric(rows, "end_to_end_ms")),
            },
        }
        if track:
            summary[mode]["stationary_single_target"] = {
                "raw_components": single_object(rows, "components_id_xywh_cm"),
                "display_tracks": single_object(rows, "tracks_id_xywh_cm_confidence"),
            }
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("telemetry", type=Path)
    parser.add_argument("--source", help="Filter to MiDaS, LiDAR or Stereo")
    parser.add_argument("--start", type=float, help="Trial onset in capture_s, inclusive")
    parser.add_argument("--end", type=float, help="Trial end in capture_s, inclusive")
    parser.add_argument("--truth-cm", type=float, help="Independently measured optical-axis distance")
    parser.add_argument("--minimum-roi", type=float, default=.2, help="Minimum measured fraction of central ROI")
    parser.add_argument("--expected", choices=("AVAILABLE", "LEFT", "RIGHT", "STOP", "CRITICAL", "WARNING", "UNAVAILABLE"))
    parser.add_argument("--single-stationary-object", action="store_true", help="Compare raw and displayed tracks")
    args = parser.parse_args()
    if not 0 <= args.minimum_roi <= 1 or (args.truth_cm is not None and not 0 < args.truth_cm < math.inf):
        parser.error("ROI fraction must be in [0, 1] and reference distance must be positive and finite")
    summary = summarize(args.telemetry, args.source, args.start, args.end, args.truth_cm, args.expected,
                        args.minimum_roi, args.single_stationary_object)
    if not summary:
        parser.error("No matching frame rows")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
