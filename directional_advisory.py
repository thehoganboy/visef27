"""Camera-relative advisory contract and continuous 180° directional estimator.

An empty image is not a verified route. Directional advice represents a
lower-estimated-collision-risk heading within the observed camera field of view,
not a guarantee of a safe physical traversal path.
"""
from dataclasses import dataclass
from enum import Enum
import math
from typing import Optional, Tuple, List, Any


class DirectionState(str, Enum):
    AVAILABLE = "AVAILABLE"
    UNAVAILABLE = "UNAVAILABLE"
    STOP = "STOP"
    UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class DirectionalAdvisory:
    state: DirectionState = DirectionState.UNKNOWN
    angle_deg: float | None = None
    confidence: float | None = None
    observed_angular_range: tuple[float, float] | None = None
    source_timestamp: float = 0.0

    def drawable_angle(self, now: float) -> float | None:
        if self.state != DirectionState.AVAILABLE or self.angle_deg is None:
            return None
        if not math.isfinite(self.angle_deg) or not 0 <= now - self.source_timestamp <= 1.0:
            return None
        bounds = self.observed_angular_range
        if bounds is None or not all(math.isfinite(x) for x in bounds):
            return None
        if not -90.0 <= bounds[0] <= self.angle_deg <= bounds[1] <= 90.0:
            return None
        if self.confidence is None or not 0.0 < self.confidence <= 1.0:
            return None
        return self.angle_deg


def advisory_for_risk(threat: str, timestamp: float) -> DirectionalAdvisory:
    """Fallback advisory when no spatial obstacle perception data is available."""
    state = (DirectionState.STOP if threat == "CRITICAL" else
             DirectionState.UNAVAILABLE if threat in {"SAFE", "WARNING"} else DirectionState.UNKNOWN)
    return DirectionalAdvisory(state=state, source_timestamp=timestamp)


def image_x_to_angle(x: float, cx: float, fx: float) -> float:
    """Convert horizontal image coordinate x to horizontal angle in degrees."""
    if not all(math.isfinite(v) for v in (x, cx, fx)) or fx <= 0:
        raise ValueError("Valid camera intrinsics required")
    return math.degrees(math.atan2(x - cx, fx))


def aspect_fit(source_w: float, source_h: float, target_w: float, target_h: float):
    """Calculate aspect-fit scale and letterbox offsets."""
    scale = min(target_w / source_w, target_h / source_h)
    return scale, (target_w - source_w * scale) / 2.0, (target_h - source_h * scale) / 2.0


def estimate_directional_advisory(
    observation: Any,
    threat: str = "UNKNOWN",
    now: float = 0.0,
    hfov_deg: float = 65.0,
    prev_angle: float | None = None
) -> DirectionalAdvisory:
    """
    Conservative camera-relative continuous direction estimator.

    Evaluates candidate headings theta in [-half_fov, +half_fov] across an angular
    risk representation derived from detected obstacles, their angular spans,
    distances, and sector clearances.

    Negative angle = left heading
    0 degrees      = straight ahead
    Positive angle = right heading
    """
    # 1. Immediate invalidity and safety halts
    if threat == "PAUSED":
        return DirectionalAdvisory(state=DirectionState.UNKNOWN, source_timestamp=now)
    if threat in {"SENSOR_FAULT", "INITIALIZING"} or observation is None:
        return DirectionalAdvisory(state=DirectionState.UNKNOWN, source_timestamp=now)
    if not getattr(observation, "is_valid", True) or getattr(observation, "is_zero_lux_blind", False):
        return DirectionalAdvisory(state=DirectionState.UNKNOWN, source_timestamp=now)

    # 1.1 Spatial observation freshness check (reject stale observations > 750ms)
    obs_ts = getattr(observation, "timestamp", None)
    adv_ts = now
    if obs_ts is not None and isinstance(obs_ts, (int, float)) and math.isfinite(obs_ts):
        adv_ts = obs_ts
        if now > 0 and obs_ts > 0 and (now - obs_ts > 0.75):
            return DirectionalAdvisory(state=DirectionState.UNAVAILABLE, source_timestamp=obs_ts)

    # 2. Camera geometry and observed FOV limits
    cam_w = float(getattr(observation, "cam_width", 640) or 640)
    cx = cam_w / 2.0
    half_fov = hfov_deg / 2.0  # e.g. 32.5 deg
    fx = cx / math.tan(math.radians(half_fov))
    obs_range = (-half_fov, half_fov)

    # 3. Explicit validity-aware sector extraction (no fabricated 250cm fallback)
    sector_dists = getattr(observation, "sector_dists", {}) or {}
    spatial_val = getattr(observation, "spatial_validity", {}) or {}

    def classify_sector(sec_name: str) -> tuple[str, float]:
        """Classify sector into VALID, UNKNOWN, INVALID, STALE."""
        if not isinstance(sector_dists, dict) or sec_name not in sector_dists:
            return "UNKNOWN", float("nan")
        val = sector_dists[sec_name]
        if val is None:
            return "UNKNOWN", float("nan")
        try:
            val_f = float(val)
        except (ValueError, TypeError):
            return "INVALID", float("nan")
        if not math.isfinite(val_f) or val_f <= 0:
            return "INVALID", float("nan")
        if spatial_val and sec_name in spatial_val:
            s_val = spatial_val[sec_name]
            if isinstance(s_val, (int, float)):
                if not math.isfinite(s_val) or s_val < 0.5:
                    return "INVALID", float("nan")
            elif s_val not in {None, "VALID"}:
                return "INVALID", float("nan")
        return "VALID", val_f

    status_l, z_left = classify_sector("LEFT")
    status_c, z_center = classify_sector("CENTER")
    status_r, z_right = classify_sector("RIGHT")

    # Completely obstructed check if all sectors are valid and close
    if (status_c == "VALID" and z_center < 50.0 and
            status_l == "VALID" and z_left < 60.0 and
            status_r == "VALID" and z_right < 60.0):
        return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts)

    # 4. Map obstacles to angular span and risk weights
    # Remove remaining fabricated 100cm fallback: preserve unknown-distance obstacles by their angular bbox
    all_obstacles = getattr(observation, "all_obstacles", []) or []
    obstacle_profiles = []
    for obs in all_obstacles:
        bbox = getattr(obs, "bbox", None)
        if not bbox or len(bbox) < 4:
            continue
        bx, by, bw, bh = bbox[:4]
        raw_dist = getattr(obs, "dist_cm", None)
        is_dist_valid = False
        z_obs = None
        if raw_dist is not None:
            try:
                z_f = float(raw_dist)
                if math.isfinite(z_f) and z_f > 0:
                    z_obs = z_f
                    is_dist_valid = True
            except (ValueError, TypeError):
                pass

        # Angular center and extent
        ang_left = image_x_to_angle(bx, cx, fx)
        ang_right = image_x_to_angle(bx + bw, cx, fx)
        ang_center = (ang_left + ang_right) / 2.0
        ang_half_w = max(2.0, (ang_right - ang_left) / 2.0)

        if is_dist_valid:
            # Body-clearance lateral margin (20cm shoulder margin at distance z)
            margin_deg = min(22.0, max(4.0, math.degrees(math.atan2(20.0, max(10.0, z_obs)))))
            total_radius = ang_half_w + margin_deg

            # Severity weight based on proximity
            if z_obs < 50.0:
                weight = 20.0
            elif z_obs < 80.0:
                weight = 10.0
            elif z_obs < 150.0:
                weight = 4.0
            else:
                weight = 1.0
            obstacle_profiles.append((ang_center, total_radius, weight, z_obs, True))
        else:
            # Unknown-distance obstacle: preserve image-space angular occupancy without fabricating 100cm
            margin_deg = 8.0
            total_radius = ang_half_w + margin_deg
            # Reject candidate headings intersecting it without turning entire scene CRITICAL
            weight = 12.0
            obstacle_profiles.append((ang_center, total_radius, weight, float("nan"), False))

    # Single obstacle fallback when all_obstacles is empty
    if not obstacle_profiles and status_c == "VALID" and z_center < 150.0:
        pan = float(getattr(observation, "pan", 0.0) or 0.0)
        ang_center = pan * half_fov
        weight = 15.0 if z_center < 80.0 else 5.0
        obstacle_profiles.append((ang_center, 12.0, weight, z_center, True))

    # Clear observation with no detected obstacles
    # ONLY allowed when ALL three sectors are confirmed VALID and clear
    if not obstacle_profiles:
        if status_c == "VALID" and status_l == "VALID" and status_r == "VALID":
            if z_center >= 150.0 and z_left >= 150.0 and z_right >= 150.0:
                angle_out = 0.0
                if prev_angle is not None and math.isfinite(prev_angle):
                    angle_out = 0.3 * angle_out + 0.7 * prev_angle
                # Documented: 0.55 is a heuristic support score for an unobstructed corridor,
                # NOT a calibrated probability of physical safety.
                return DirectionalAdvisory(
                    state=DirectionState.AVAILABLE,
                    angle_deg=round(angle_out, 1),
                    confidence=0.55,
                    observed_angular_range=obs_range,
                    source_timestamp=adv_ts
                )
        elif status_c != "VALID" and status_l != "VALID" and status_r != "VALID":
            # No valid sector data at all -> cannot recommend any direction
            return DirectionalAdvisory(
                state=DirectionState.UNAVAILABLE,
                observed_angular_range=obs_range,
                source_timestamp=adv_ts
            )

    # 5. Build candidate angles within observed FOV (step 2.5 degrees)
    # Heading eligibility depends on sector data validity
    candidates = []
    ang = -half_fov + 2.5
    while ang <= half_fov - 2.5 + 1e-5:
        # Sector support requirement
        if ang < -10.0:
            if status_l == "VALID":
                candidates.append((ang, z_left))
        elif ang > 10.0:
            if status_r == "VALID":
                candidates.append((ang, z_right))
        else:
            if status_c == "VALID":
                candidates.append((ang, z_center))
        ang += 2.5

    # If no candidate heading has valid sector support, directional guidance is unavailable
    if not candidates:
        return DirectionalAdvisory(
            state=DirectionState.UNAVAILABLE,
            observed_angular_range=obs_range,
            source_timestamp=adv_ts
        )

    best_candidate = 0.0
    min_risk = float("inf")

    for cand, z_sec in candidates:
        risk = 0.0

        # Obstacle risk penalty
        for ang_c, radius, weight, z_obs, is_valid in obstacle_profiles:
            d_ang = abs(cand - ang_c)
            if d_ang < radius:
                # Deep penetration into obstacle safety envelope
                penetration = 1.0 - (d_ang / radius)
                risk += weight * (penetration ** 2) * 15.0
            else:
                # Soft proximity tail
                d_edge = d_ang - radius
                if d_edge < 15.0:
                    risk += weight * math.exp(-(d_edge ** 2) / 40.0) * 2.0

        # Sector proximity penalty from verified sector distance
        if z_sec < 80.0:
            risk += ((80.0 - z_sec) / 10.0) * 5.0
        elif z_sec < 150.0:
            risk += ((150.0 - z_sec) / 70.0) * 2.0

        # Straightforward bias (small penalty for deviating from center)
        risk += 0.05 * abs(cand)

        # Hysteresis bonus: slightly favor candidate near previous heading to prevent jitter
        if prev_angle is not None and math.isfinite(prev_angle):
            if abs(cand - prev_angle) <= 3.5:
                risk -= 1.0

        if risk < min_risk:
            min_risk = risk
            best_candidate = cand

    # 6. Safety boundary checks
    # If all eligible candidates have extreme risk (> 30.0), path is blocked -> STOP
    if min_risk > 30.0 or (threat == "CRITICAL" and status_c == "VALID" and z_center < 40.0):
        return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts)

    # 7. Confidence & Temporal Smoothing
    # Heuristic support score bounded in [0.30, 0.85]
    confidence = max(0.30, min(0.85, 1.0 - (min_risk / 35.0)))
    selected_angle = best_candidate
    if prev_angle is not None and math.isfinite(prev_angle):
        selected_angle = 0.45 * selected_angle + 0.55 * prev_angle

    # Clamp strictly to observed angular range
    selected_angle = max(-half_fov, min(half_fov, selected_angle))

    return DirectionalAdvisory(
        state=DirectionState.AVAILABLE,
        angle_deg=round(selected_angle, 1),
        confidence=round(confidence, 2),
        observed_angular_range=obs_range,
        source_timestamp=adv_ts
    )
