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
    reason_code: str = "UNSPECIFIED"

    def drawable_angle(self, now: float, max_age: float = 0.50) -> float | None:
        if self.state != DirectionState.AVAILABLE or self.angle_deg is None:
            return None
        # Max age for rendering directional guidance is strictly max_age (default 500ms)
        if not math.isfinite(self.angle_deg) or not 0 <= now - self.source_timestamp <= max_age:
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
    if threat == "CRITICAL":
        state = DirectionState.STOP
        code = "CRITICAL_OBSTACLE"
    elif threat in {"SAFE", "WARNING"}:
        state = DirectionState.UNAVAILABLE
        code = "LOCAL_DEPTH_MISSING"
    else:
        state = DirectionState.UNKNOWN
        code = "UNSPECIFIED"
    return DirectionalAdvisory(state=state, source_timestamp=timestamp, reason_code=code)


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
        return DirectionalAdvisory(state=DirectionState.UNKNOWN, source_timestamp=now, reason_code="UNSPECIFIED")
    if threat in {"SENSOR_FAULT", "INITIALIZING"} or observation is None:
        return DirectionalAdvisory(state=DirectionState.UNKNOWN, source_timestamp=now, reason_code="MODEL_OUTPUT_INVALID" if threat == "SENSOR_FAULT" else "UNSPECIFIED")
    if not getattr(observation, "is_valid", True) or getattr(observation, "is_zero_lux_blind", False):
        code = "SENSOR_BLIND" if getattr(observation, "is_zero_lux_blind", False) else "MODEL_OUTPUT_INVALID"
        return DirectionalAdvisory(state=DirectionState.UNKNOWN, source_timestamp=now, reason_code=code)

    # 1.1 Spatial observation freshness check (reject stale observations > 750ms)
    obs_ts = getattr(observation, "timestamp", None)
    adv_ts = now
    if obs_ts is not None and isinstance(obs_ts, (int, float)) and math.isfinite(obs_ts) and obs_ts > 0:
        adv_ts = obs_ts
        if now > 0 and (now - obs_ts > 0.75):
            return DirectionalAdvisory(state=DirectionState.UNAVAILABLE, source_timestamp=obs_ts, reason_code="SOURCE_FRAME_STALE")

    # 2. Camera geometry and observed FOV limits
    cam_w = float(getattr(observation, "cam_width", 640) or 640)
    cx = cam_w / 2.0
    half_fov = hfov_deg / 2.0  # e.g. 32.5 deg
    fx = cx / math.tan(math.radians(half_fov))
    obs_range = (-half_fov, half_fov)

    # 3. Explicit validity-aware sector extraction (no fabricated 250cm fallback)
    sector_dists = getattr(observation, "sector_dists", {}) or {}
    spatial_val = getattr(observation, "spatial_validity", {}) or {}
    spatial_bins = getattr(observation, "spatial_bins", None)

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
        # If spatial_bins are present, check whether central corridor bins are actually open
        # (doorway scenario: doorposts make sector averages close, but central gap is open)
        if spatial_bins and len(spatial_bins) > 0:
            c_bins = [b for b in spatial_bins if abs(getattr(b, "angle_center", 99.0)) <= 6.0 and getattr(b, "is_valid", False)]
            c_dists = [getattr(b, "dist_cm", float("nan")) for b in c_bins]
            finite_c_dists = [d for d in c_dists if math.isfinite(d) and d > 0]
            if len(finite_c_dists) == len(c_bins) and len(finite_c_dists) > 0 and all(d >= 75.0 for d in finite_c_dists):
                pass  # Central corridor is genuinely open with valid distance readings
            else:
                return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="CORRIDOR_OBSTRUCTED")
        else:
            return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="CORRIDOR_OBSTRUCTED")

    # Overhead hazard or drop-off hazard under CRITICAL threat forces immediate STOP
    is_overhead = bool(getattr(observation, "overhead_hazard", False) or
                       getattr(observation, "is_overhead_hazard", False) or
                       getattr(observation, "mode_text", "") == "OVERHEAD")
    is_drop_off = bool(getattr(observation, "drop_off_hazard", False) or
                       getattr(observation, "is_drop_off_hazard", False) or
                       getattr(observation, "mode_text", "") == "DROP_OFF")
    if threat == "CRITICAL" and (is_overhead or is_drop_off):
        code = "OVERHEAD_HAZARD" if is_overhead else "DROP_OFF_HAZARD"
        return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code=code)

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

    # Clear observation with no detected obstacles (P0-02 & P0-B)
    if not obstacle_profiles:
        center_supported = False
        center_coverage_ok = False
        cand_dist = z_center if (status_c == "VALID" and math.isfinite(z_center) and z_center > 0) else float("nan")
        if spatial_bins and len(spatial_bins) > 0:
            c_bins = [b for b in spatial_bins if abs(getattr(b, "angle_center", 99.0)) <= 5.0]
            valid_c = [b for b in c_bins if getattr(b, "is_valid", False)]
            if len(valid_c) >= max(1, int(len(c_bins) * 0.75)):
                center_coverage_ok = True
                dists = [getattr(b, "dist_cm", float("nan")) for b in valid_c if math.isfinite(getattr(b, "dist_cm", float("nan"))) and getattr(b, "dist_cm", float("nan")) > 0]
                if dists:
                    cand_dist = min(dists)
                    center_supported = True
        elif status_c == "VALID":
            center_coverage_ok = True
            if math.isfinite(z_center) and z_center > 0:
                center_supported = True

        if center_supported and math.isfinite(cand_dist) and cand_dist > 0 and cand_dist >= 75.0:
            angle_out = 0.0
            if prev_angle is not None and math.isfinite(prev_angle):
                angle_out = 0.3 * angle_out + 0.7 * prev_angle
            return DirectionalAdvisory(
                state=DirectionState.AVAILABLE,
                angle_deg=round(angle_out, 1),
                confidence=0.55,
                observed_angular_range=obs_range,
                source_timestamp=adv_ts,
                reason_code="AVAILABLE_FORWARD"
            )
        elif center_supported and math.isfinite(cand_dist) and cand_dist < 40.0:
            return DirectionalAdvisory(
                state=DirectionState.STOP,
                observed_angular_range=obs_range,
                source_timestamp=adv_ts,
                reason_code="CRITICAL_OBSTACLE"
            )
        else:
            if not center_coverage_ok:
                reason = "CENTER_COVERAGE_INSUFFICIENT"
            elif not center_supported or not math.isfinite(cand_dist) or cand_dist <= 0:
                reason = "LOCAL_DEPTH_MISSING"
            else:
                reason = "NO_SUPPORTED_CANDIDATE"
            return DirectionalAdvisory(
                state=DirectionState.UNAVAILABLE,
                observed_angular_range=obs_range,
                source_timestamp=adv_ts,
                reason_code=reason
            )

    # 5. Build candidate angles within observed FOV (step 2.5 degrees)
    # Step 5A: Generate candidate headings across observed FOV
    all_candidates = []
    ang = -half_fov + 2.5
    while ang <= half_fov - 2.5 + 1e-5:
        all_candidates.append(ang)
        ang += 2.5

    # Step 5B: Determine eligibility for each candidate heading
    # Evaluates candidate corridors against localized spatial bins or sectors
    eligible_candidates = []
    untrustworthy_sector_count = 0
    obstructed_count = 0

    for cand in all_candidates:
        # 1. Observation support and corridor distance extraction
        cand_supported = False
        cand_dist = float("nan")

        if spatial_bins and len(spatial_bins) > 0:
            c_min = cand - 5.0
            c_max = cand + 5.0
            k_min = cand - 2.5
            k_max = cand + 2.5
            w_corr = c_max - c_min  # 10.0 deg
            w_core = k_max - k_min  # 5.0 deg

            valid_corr_cov = 0.0
            valid_core_cov = 0.0
            valid_dists = []

            for b in spatial_bins:
                b_min = getattr(b, "angle_min", 99.0)
                b_max = getattr(b, "angle_max", -99.0)
                if b_max <= b_min:
                    continue
                # Overlap with corridor [c_min, c_max]
                ov_corr = max(0.0, min(b_max, c_max) - max(b_min, c_min))
                # Overlap with central load-bearing core [k_min, k_max]
                ov_core = max(0.0, min(b_max, k_max) - max(b_min, k_min))

                if getattr(b, "is_valid", False):
                    valid_corr_cov += ov_corr
                    valid_core_cov += ov_core
                    if ov_corr > 0.0:
                        d = getattr(b, "dist_cm", float("nan"))
                        if math.isfinite(d) and d > 0:
                            valid_dists.append(d)

            corr_ratio = valid_corr_cov / w_corr
            core_ratio = valid_core_cov / w_core

            # P0-02 / P0-03: Corridor must have >= 75% valid angular coverage
            # and central load-bearing core [theta - 2.5, theta + 2.5] must be valid (>= 90%)
            if corr_ratio >= 0.75 and core_ratio >= 0.90 and valid_dists:
                cand_supported = True
                cand_dist = min(valid_dists)
        else:
            # 3-sector fallback for legacy mocks or tests without spatial_bins
            if cand < -10.0:
                sec_status, z_sec = status_l, z_left
            elif cand > 10.0:
                sec_status, z_sec = status_r, z_right
            else:
                sec_status, z_sec = status_c, z_center
            if sec_status == "VALID":
                cand_supported = True
                cand_dist = z_sec

        if not cand_supported:
            untrustworthy_sector_count += 1
            continue

        # 2. Hard obstacle and proximity intersection checks
        is_blocked = False
        if cand_dist < 40.0:
            is_blocked = True

        if not is_blocked:
            for ang_c, radius, weight, z_obs, is_valid_dist in obstacle_profiles:
                d_ang = abs(cand - ang_c)
                if not is_valid_dist:
                    # Unknown-distance obstacle: hard rejection if heading falls within angular footprint
                    if d_ang < radius:
                        is_blocked = True
                        break
                else:
                    # Valid distance obstacle: hard rejection if hazardous proximity (z < 50cm) and heading intersects safety radius
                    if z_obs < 50.0 and d_ang < radius:
                        is_blocked = True
                        break
                    if z_obs < 35.0 and d_ang < (radius + 2.0):
                        is_blocked = True
                        break

        if is_blocked:
            obstructed_count += 1
            continue

        # 3. Candidate Risk Scoring
        risk = 0.0
        for ang_c, radius, weight, z_obs, is_valid_dist in obstacle_profiles:
            d_ang = abs(cand - ang_c)
            if d_ang < radius:
                penetration = 1.0 - (d_ang / radius)
                risk += weight * (penetration ** 2) * 15.0
            else:
                d_edge = d_ang - radius
                if d_edge < 15.0:
                    risk += weight * math.exp(-(d_edge ** 2) / 40.0) * 2.0

        if cand_dist < 80.0:
            risk += ((80.0 - cand_dist) / 10.0) * 4.0
        elif cand_dist < 150.0:
            risk += ((150.0 - cand_dist) / 70.0) * 1.5

        # Straightforward bias
        risk += 0.05 * abs(cand)

        # Hysteresis bonus for previous heading to prevent jitter
        if prev_angle is not None and math.isfinite(prev_angle):
            if abs(cand - prev_angle) <= 3.5:
                risk -= 1.0

        eligible_candidates.append((cand, cand_dist, risk))

    # Step 5C: Evaluate outcomes when no candidate is eligible
    if not eligible_candidates:
        if obstructed_count > 0 and (obstructed_count >= len(all_candidates) * 0.5 or (status_c == "VALID" and z_center < 50.0)):
            return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="CRITICAL_OBSTACLE")
        else:
            return DirectionalAdvisory(state=DirectionState.UNAVAILABLE, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="NO_SUPPORTED_CANDIDATE")

    # ── Step 6: Hierarchical Movement Policy (Directive Section 3) ──

    # Priority 1: HOLD FORWARD
    fwd_eligible = False
    fwd_dist = float("nan")
    fwd_risk = float("inf")
    for cand, dist, r in eligible_candidates:
        if abs(cand - 0.0) < 1.5:
            fwd_eligible = True
            fwd_dist = dist
            fwd_risk = r
            break

    fwd_encroached = any(
        (abs(ang_c) < radius)
        for ang_c, radius, weight, z_obs, is_valid_dist in obstacle_profiles
    )

    if fwd_eligible and not fwd_encroached and fwd_dist >= 75.0 and fwd_risk <= 4.0:
        angle_out = 0.0
        if prev_angle is not None and math.isfinite(prev_angle):
            angle_out = 0.35 * 0.0 + 0.65 * prev_angle
            if abs(angle_out) < 1.0:
                angle_out = 0.0
        return DirectionalAdvisory(
            state=DirectionState.AVAILABLE,
            angle_deg=round(angle_out, 1),
            confidence=0.55,
            observed_angular_range=obs_range,
            source_timestamp=adv_ts,
            reason_code="AVAILABLE_FORWARD"
        )

    # Priority 2: SMALL CORRECTION
    small_candidates = [(c, d, r) for c, d, r in eligible_candidates if abs(c) <= 12.5]
    if small_candidates:
        best_sc = min(small_candidates, key=lambda x: x[2] + 0.08 * abs(x[0]))
        if best_sc[2] < 20.0 and (not fwd_eligible or fwd_encroached or best_sc[2] < fwd_risk - 0.5):
            sc_angle = best_sc[0]
            if prev_angle is not None and math.isfinite(prev_angle):
                sc_angle = 0.45 * sc_angle + 0.55 * prev_angle
            sc_angle = max(-half_fov, min(half_fov, sc_angle))
            conf = max(0.35, min(0.55, 1.0 - (best_sc[2] / 35.0)))
            return DirectionalAdvisory(
                state=DirectionState.AVAILABLE,
                angle_deg=round(sc_angle, 1),
                confidence=round(conf, 2),
                observed_angular_range=obs_range,
                source_timestamp=adv_ts,
                reason_code="AVAILABLE_CORRECTION"
            )

    # Priority 3: ALTERNATIVE HEADING
    best_candidate = 0.0
    min_cost = float("inf")
    for cand, dist, r in eligible_candidates:
        total_cost = r + 0.08 * abs(cand)
        if prev_angle is not None and math.isfinite(prev_angle):
            total_cost += 0.05 * abs(cand - prev_angle)
        if total_cost < min_cost:
            min_cost = total_cost
            best_candidate = cand

    if min_cost > 30.0:
        return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="CRITICAL_OBSTACLE")

    if threat == "CRITICAL" and status_c == "VALID":
        if z_center < 25.0:
            return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="CRITICAL_OBSTACLE")
        if z_center < 40.0 and (min_cost > 15.0 or not any(d >= 60.0 for c, d, r in eligible_candidates if abs(c - best_candidate) < 1.5)):
            return DirectionalAdvisory(state=DirectionState.STOP, observed_angular_range=obs_range, source_timestamp=adv_ts, reason_code="CRITICAL_OBSTACLE")

    confidence = max(0.30, min(0.55, 1.0 - (min_cost / 35.0)))
    selected_angle = best_candidate
    if prev_angle is not None and math.isfinite(prev_angle):
        selected_angle = 0.45 * selected_angle + 0.55 * prev_angle
    selected_angle = max(-half_fov, min(half_fov, selected_angle))

    return DirectionalAdvisory(
        state=DirectionState.AVAILABLE,
        angle_deg=round(selected_angle, 1),
        confidence=round(confidence, 2),
        observed_angular_range=obs_range,
        source_timestamp=adv_ts,
        reason_code="AVAILABLE_ALTERNATIVE"
    )
