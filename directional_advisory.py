"""Camera-relative advisory contract. An empty image is not a verified route."""
from dataclasses import dataclass
from enum import Enum
import math

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
        if not math.isfinite(self.angle_deg) or not 0 <= now - self.source_timestamp <= 1:
            return None
        bounds = self.observed_angular_range
        if bounds is None or not all(math.isfinite(x) for x in bounds):
            return None
        if not -90 <= bounds[0] <= self.angle_deg <= bounds[1] <= 90:
            return None
        if self.confidence is None or not 0 < self.confidence <= 1:
            return None
        return self.angle_deg

def advisory_for_risk(threat: str, timestamp: float) -> DirectionalAdvisory:
    # No validated intrinsics or traversability: never invent route confidence.
    state = (DirectionState.STOP if threat == "CRITICAL" else
             DirectionState.UNAVAILABLE if threat in {"SAFE", "WARNING"} else DirectionState.UNKNOWN)
    return DirectionalAdvisory(state=state, source_timestamp=timestamp)

def image_x_to_angle(x: float, cx: float, fx: float) -> float:
    if not all(math.isfinite(v) for v in (x, cx, fx)) or fx <= 0:
        raise ValueError("Valid camera intrinsics required")
    return math.degrees(math.atan2(x - cx, fx))

def aspect_fit(source_w, source_h, target_w, target_h):
    scale = min(target_w / source_w, target_h / source_h)
    return scale, (target_w - source_w * scale) / 2, (target_h - source_h * scale) / 2
