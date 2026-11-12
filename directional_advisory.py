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

    # 2. Camera geometry and observed FOV limits
    cam_w = float(getattr(observation, "cam_width", 640) or 640)
    cx = cam_w / 2.0
    half_fov = hfov_deg / 2.0  # e.g. 32.5 deg
    fx = cx / math.tan(math.radians(half_fov))
    obs_range = (-half_fov, half_fov)

    # 3. Extract sector distances
    sector_dists = getattr(observation, "sector_dists", {}) or {}
    z_left = float(sector_dists.get("LEFT", 250.0))
    z_center = float(sector_dists.get("CENTER", getattr(observation, "dist_cm", 250.0)))
    z_right = float(sector_dists.get("RIGHT", 250.0))

    # Completely obstructed environment check
    if z_center < 50.0 and z_left < 60.0 and z_right < 60.0:
        return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=now)

    # 4. Map obstacles to angular span and risk weights
    all_obstacles = getattr(observation, "all_obstacles", []) or []
    obstacle_profiles = []
    for obs in all_obstacles:
        bbox = getattr(obs, "bbox", None)
        if not bbox or len(bbox) < 4:
            continue
        bx, by, bw, bh = bbox[:4]
        z_obs = float(getattr(obs, "dist_cm", z_center))
        if not math.isfinite(z_obs) or z_obs <= 0:
            z_obs = 100.0

        # Angular center and extent
        ang_left = image_x_to_angle(bx, cx, fx)
        ang_right = image_x_to_angle(bx + bw, cx, fx)
        ang_center = (ang_left + ang_right) / 2.0
        ang_half_w = max(2.0, (ang_right - ang_left) / 2.0)

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

        obstacle_profiles.append((ang_center, total_radius, weight, z_obs))

    # If single obstacle attribute exists but all_obstacles is empty
    if not obstacle_profiles:
        primary_dist = float(getattr(observation, "dist_cm", 250.0))
        if math.isfinite(primary_dist) and primary_dist < 150.0:
            pan = float(getattr(observation, "pan", 0.0) or 0.0)
            ang_center = pan * half_fov
            weight = 15.0 if primary_dist < 80.0 else 5.0
            obstacle_profiles.append((ang_center, 12.0, weight, primary_dist))

    # If no obstacle profiles and all sectors clear (> 180cm), clear straight path
    if not obstacle_profiles and z_center >= 180.0 and z_left >= 150.0 and z_right >= 150.0:
        angle_out = 0.0
        if prev_angle is not None and math.isfinite(prev_angle):
            angle_out = 0.3 * angle_out + 0.7 * prev_angle
        return DirectionalAdvisory(
            state=DirectionState.AVAILABLE,
            angle_deg=round(angle_out, 1),
            confidence=0.92,
            observed_angular_range=obs_range,
            source_timestamp=now
        )

    # 5. Evaluate candidate angles across observed FOV (step 2.5 degrees)
    # Exclude outer edge margin (2.5 deg from bounds) to ensure valid heading
    candidates = []
    ang = -half_fov + 2.5
    while ang <= half_fov - 2.5 + 1e-5:
        candidates.append(ang)
        ang += 2.5

    best_candidate = 0.0
    min_risk = float("inf")

    for cand in candidates:
        risk = 0.0

        # Obstacle risk penalty
        for ang_c, radius, weight, z_obs in obstacle_profiles:
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

        # Sector risk penalty
        if cand < -10.0:
            z_sec = z_left
        elif cand > 10.0:
            z_sec = z_right
        else:
            z_sec = z_center

        if z_sec < 80.0:
            risk += ((80.0 - z_sec) / 10.0) * 5.0
        elif z_sec < 150.0:
            risk += ((150.0 - z_sec) / 70.0) * 2.0

        # Straightforward bias (small penalty for deviating from center)
        risk += 0.05 * abs(cand)

        if risk < min_risk:
            min_risk = risk
            best_candidate = cand

    # 6. Safety boundary checks
    # If all candidates have extreme risk (> 30.0), no safe heading exists -> STOP
    if min_risk > 30.0 or (threat == "CRITICAL" and z_center < 40.0 and z_left < 50.0 and z_right < 50.0):
        return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=now)

    # 7. Confidence & Temporal Smoothing
    confidence = max(0.30, min(0.95, 1.0 - (min_risk / 35.0)))
    selected_angle = best_candidate
    if prev_angle is not None and math.isfinite(prev_angle):
        selected_angle = 0.45 * selected_angle + 0.55 * prev_angle

    # Clamp to observed angular range
    selected_angle = max(-half_fov, min(half_fov, selected_angle))

    return DirectionalAdvisory(
        state=DirectionState.AVAILABLE,
        angle_deg=round(selected_angle, 1),
        confidence=round(confidence, 2),
        observed_angular_range=obs_range,
        source_timestamp=now
    )
