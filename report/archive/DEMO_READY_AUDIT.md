# DEMO-READY-01 independent audit

Audit date: 2026-11-13. Refreshed remote: main `6e103f9`, prior review
`7d54cc0`. Clean detached worktree moved to `feature/demo-ready-unified-ux`
from the prior review. Historical reports are preserved.

## Architecture and execution

Python: OpenCV capture thread → ONNX depth → centroid tracking/risk → budget →
PortAudio; the old main thread also performs inference and renders telemetry.
Android: CameraX analyzer executor → ONNX → Kotlin tracking/budget → AudioTrack;
MainActivity owns lifecycle. iOS: AVFoundation serial capture queue → Vision/Core
ML → Swift risk/budget → AVAudioEngine; SwiftUI owns presentation.

Dependencies: Python NumPy/OpenCV/SciPy/ONNX Runtime/sounddevice; Android JDK 17,
SDK 34, Gradle wrapper, CameraX 1.3.4, ONNX Runtime 1.17; iOS Xcode/XcodeGen,
Core ML export with PyTorch/coremltools. Windows has Python, JDK and Android SDK.
ADB initially reports no devices. macOS/Xcode execution requires CI.

## Initial risk register (source verified, before changes)

| ID | Severity | Root cause / evidence | Planned correction |
|---|---|---|---|
| BUG-01/02 | P0 | Android fallback says safe; Swift initial right/SAFE/ESCAPE_RIGHT | Unknown startup and explicit display contract |
| BUG-03/04 | P0 | Health checks depend on arriving frames; Python early continue; synchronous inference blocks UI | Independent UI timer, bounded worker, stale-result rejection |
| BUG-05 | P0 | Swift synthesizes disparity from brightness/edges on inference failure | Delete fabricated geometry; explicit model fault |
| BUG-06 | P0 | Swift primary and sector TTC assigned 0.5 for proximity | Motion-supported TTC only |
| BUG-07/08 | P0 | Swift ignores yaw in clearance; Kotlin suppression accepts empty obstacles regardless of coasting/fault; uncertainty defaults differ | Explicit fault/critical/unresolved precedence and guards |
| BUG-09 | P1 | Mobile cue renderers default unknown/reminder to normal ping | Exhaustive cue handling |
| BUG-10 | P1 | Reports differ from active calibration | Preserve arrays; record actual outputs as unverified estimates |
| BUG-11 | P0 | 471,800-byte desktop graph references 171 external tensors in absent .onnx.data (ignored by Git) | Use existing self-contained MiDaS asset; pin hash and tensor contract |
| BUG-12 | P1 | Single synthetic-frame benchmark cannot establish real-world behavior | Real-frame replay with provenance and honest device gaps |
| BUG-13/14 | P1 | Landscape telemetry UI; IPA packager overrides orientation | Portrait preview and brackets, unavailable/stop, bottom control |
| NEW-01 | P0 | Android inference exception only prints; old audio remains active | Publish fault, invalidate stale inference |
| NEW-02 | P1 | Kotlin Float absolute uptime timestamps lose subframe resolution | Relative monotonic epoch at analyzer boundary |
| NEW-03 | P1 | Python frame data and IDs updated in separate critical sections | Atomic frame snapshot |
| NEW-04 | P0 | Swift exporter may export untrained local model when weights absent; approximate channel normalization; tensor fallback incompatible with Vision image request | Require weights, exact wrapper normalization, image-only export |
| NEW-05 | P1 | Android exporter reports VERIFIED when image list is empty | Require comparison inputs |
| NEW-06 | P1 | Swift audio shared pointer has unsynchronized writer/renderer access | Synchronized state snapshots |

## Test reliability

Existing adversarial tests exercise synthetic Python state transitions, not mobile
apps. Source-string tests and old PASS prose are not evidence of runtime parity.
Golden JSON is a scenario description until executed by a harness. Model hashes
were all None: integrity verification was optional, not enforced. Android has a
self-contained 66,384,550-byte graph (input 1×3×256×192). Desktop model-small.onnx
is 66,764,249 bytes and has embedded Sub/Div preprocessing: it cannot be swapped
into the old preprocessing path without inspection. Weight lineage and physical
calibration still require evidence beyond file integrity.

## Direction and UI impact

No existing component establishes continuous traversable free space, camera
intrinsics, or a verified corridor. Implement the angle contract and renderer,
but emit UNAVAILABLE/UNKNOWN/STOP in the live pipeline. Three sectors cannot be
converted into a fabricated precise steering angle. Overlay coordinates must use
the same crop, rotation and aspect-fit transform as their preview.

Resolution status and evidence will be recorded in DEMO_READY_TEST_RESULTS.md and
DEMO_READY_CTO_REPORT.md after implementation. This initial audit is not acceptance.
