"""Fit a VAMPIOR iPhone Stereo profile from a physical checkerboard JSONL export."""
import argparse
import base64
import json
import math
from pathlib import Path

import cv2 as cv
import numpy as np


def require(condition, message):
    if not condition:
        raise ValueError(message)


def matrix(values):
    fx, fy, cx, cy = values
    return np.array([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=np.float64)


def intrinsic_values(k):
    return [float(k[0, 0]), float(k[1, 1]), float(k[0, 2]), float(k[1, 2])]


def rectification(rotation, translation):
    baseline_vector = -(rotation.T @ translation.reshape(3))
    baseline = np.linalg.norm(baseline_vector)
    require(1 <= baseline <= 150, "Baseline must be in millimeters, in [1, 150]")
    across = baseline_vector / baseline
    require(abs(across[2]) < 0.1, "Unsupported axial baseline component")
    down = np.cross([0, 0, 1], across)
    down /= np.linalg.norm(down)
    forward = np.cross(across, down)
    return np.column_stack([across, down, forward]), baseline


def checkerboard(lens, shape):
    data = np.frombuffer(base64.b64decode(lens["pgmBase64"], validate=True), dtype=np.uint8)
    image = cv.imdecode(data, cv.IMREAD_GRAYSCALE)
    size = (lens["width"], lens["height"])
    require(image is not None and image.shape[::-1] == size, "Invalid original-resolution PGM")
    ok, corners = cv.findChessboardCornersSB(image, shape, cv.CALIB_CB_EXHAUSTIVE | cv.CALIB_CB_ACCURACY)
    require(ok, "Full checkerboard not detected")
    x, y, w, h = cv.boundingRect(corners)
    require(w * h / image.size >= .008 and min(w, h) >= 20, "Board span too small")
    require(x >= 3 and y >= 3 and x + w < size[0] - 3 and y + h < size[1] - 3, "Board clipped")
    sharpness = cv.Laplacian(image[y:y+h, x:x+w], cv.CV_64F).var()
    require(sharpness >= 35, f"Blur score too low ({sharpness:.1f})")
    return corners


def projected(corners, k, d, rotation):
    return cv.undistortPoints(corners, k, d, R=rotation).reshape(-1, 2)


def read_dataset(path):
    with path.open(encoding="utf-8") as stream:
        header = json.loads(next(stream))
        rows = [json.loads(line) for line in stream if line.strip()]
    shape = (int(header["columns"]), int(header["rows"]))
    square = float(header["squareMM"])
    require(header["schema"] == 1 and all(4 <= n <= 20 for n in shape) and shape[0] != shape[1],
            "Expected asymmetric checkerboard inner corners and schema 1")
    require(1 <= square <= 200, "Square size must be measured in millimeters")
    return shape, square, rows


def select_observations(rows, shape):
    rejected, fitting, held_out = [], [], []
    metadata = None
    last_times = set()
    for index, record in enumerate(rows, start=1):
        try:
            pair = record["capture"]
            lenses = [pair[k] for k in ("left", "right")]
            measured = record.get("measuredCM")
            require(measured is None or (math.isfinite(measured) and 40 <= measured <= 330), "Invalid physical reference")
            require(len(set(pair["pair"])) == 2 and len(pair["captureSignature"]) == 2, "Invalid camera identity")
            stamp = tuple(lens["hostSeconds"] for lens in lenses)
            require(abs(stamp[1] - stamp[0]) <= .008 and abs(pair["skewMS"]) <= 8,
                    "Capture skew exceeds 8 ms")
            require(stamp not in last_times, "Duplicate acquisition timestamp")
            last_times.add(stamp)
            for lens in lenses:
                require(math.isfinite(lens["position"]) and 0 <= lens["position"] <= 1
                        and np.isfinite(lens["intrinsics"]).all(), "Missing or invalid focus/intrinsics")
            ext = np.asarray(pair["factoryExtrinsicsColumnsMM"], dtype=float).T
            require(ext.shape == (3, 4) and np.isfinite(ext).all(), "Missing factory relative pose")
            r0, t0 = ext[:, :3], ext[:, 3]
            require(np.linalg.norm(r0.T @ r0 - np.eye(3)) < .02 and np.linalg.det(r0) > 0.99, "Invalid factory rotation")
            basis, _ = rectification(r0, t0)
            if metadata:
                require(pair["pair"] == metadata["pair"] and pair["captureSignature"] == metadata["captureSignature"],
                        "Camera IDs or format changed")
                require(np.max(np.abs(ext - np.asarray(metadata["factoryExtrinsicsColumnsMM"]).T)) < .05,
                        "Factory pose changed")
                for key, lens in zip(("left", "right"), lenses):
                    original = metadata[key]
                    require((lens["width"], lens["height"]) == (original["width"], original["height"]),
                            "Capture dimensions changed")
                    require(abs(lens["position"] - original["position"]) <= .015, "Focus changed")
                    earlier, current = np.array(original["intrinsics"]), np.array(lens["intrinsics"])
                    require(np.all(np.abs(earlier - current) <= np.maximum(1, np.abs(earlier)*0.005)), "Stream intrinsics changed")
            points = [checkerboard(lens, shape) for lens in lenses]
            # Compare both row-major directions using the physical pose prior.
            # Reprojection and held-out epipolar checks still gate the final fit.
            ya = projected(points[0], matrix(lenses[0]["intrinsics"]), None, basis.T)[:, 1]
            yb = projected(points[1], matrix(lenses[1]["intrinsics"]), None, basis.T @ r0.T)[:, 1]
            if np.median(np.abs(ya - yb[::-1])) < np.median(np.abs(ya - yb)):
                points[1] = points[1][::-1].copy()
            if measured is None:
                fitting.append(points)
            else:
                held_out.append((points, float(measured)))
            if metadata is None:
                metadata = pair
        except (ValueError, KeyError, TypeError, cv.error) as exc:
            rejected.append(f"row {index}: {exc}")
    return metadata, fitting, held_out, rejected


def pose_diversity(fitting, objects, k, d, size):
    centers = np.array([points[0].reshape(-1, 2).mean(axis=0) for points in fitting]) / size
    normals = []
    for points in fitting:
        ok, vec, _ = cv.solvePnP(objects, points[0], k, d)
        require(ok, "Could not estimate checkerboard pose")
        normals.append(cv.Rodrigues(vec)[0][:, 2])
    span = np.ptp(centers, axis=0)
    normals = np.array(normals)
    require(np.min(span) >= .12 and np.min(normals @ normals.T) < math.cos(math.radians(18)),
            "Insufficient pose diversity. Move the board across the overlap and tilt by at least 20 degrees.")


def reference_trial(points, truth, objects, k1, d1, k2, d2, basis, rotation, baseline, focal):
    a = projected(points[0], k1, d1, basis.T)
    b = projected(points[1], k2, d2, basis.T @ rotation.T)
    disparity = a[:, 0] - b[:, 0]
    require(np.all(disparity > 0), "Held-out pair has nonpositive disparity")
    rect_z = baseline / disparity
    xyz = (np.column_stack([a, np.ones(len(a))]) * rect_z[:, None]) @ basis.T
    center = np.median(xyz, axis=0)
    # Use the monocular board pose only for its unit normal. Scale and axis
    # intercept still come from the binocular corner disparities.
    ok, rvec, _ = cv.solvePnP(objects, points[0], k1, d1)
    require(ok, "Could not estimate reference board orientation")
    normal = cv.Rodrigues(rvec)[0][:, 2]
    require(abs(normal[2]) >= math.cos(math.radians(25)), "Reference board is not near fronto-parallel")
    require(abs(center[0] / center[2]) < .16 and abs(center[1] / center[2]) < .16, "Reference board is off the camera axis")
    measured = float(np.median(xyz @ normal) / normal[2] / 10)
    require(abs(measured - truth) <= max(4, truth * .10), f"Reference {truth:.1f} cm reconstructed {measured:.2f} cm")
    return {"measuredCM": truth, "stereoCM": measured}, (a[:, 1] - b[:, 1]) * focal


def fit(path):
    shape, square, rows = read_dataset(path)
    meta, fitting, held_out, rejected = select_observations(rows, shape)
    for reason in rejected:
        print(f"Rejected {reason}")
    require(len(fitting) >= 15, f"Only {len(fitting)} usable fitting pairs; need 15")
    for cm in (50, 100, 200, 300):
        require(any(abs(measured-cm) <= cm*.1 for _, measured in held_out), f"Missing independent reference near {cm} cm")

    objects = np.zeros((shape[0] * shape[1], 3), np.float32)
    objects[:, :2] = np.mgrid[0:shape[0], 0:shape[1]].T.reshape(-1, 2) * square
    object_sets = [objects] * len(fitting)
    left, right = [list(side) for side in zip(*fitting)]
    la, lb = meta["left"], meta["right"]
    size_a, size_b = (la["width"], la["height"]), (lb["width"], lb["height"])
    fit_a, ka, da, _, _ = cv.calibrateCamera(object_sets, left, size_a, matrix(la["intrinsics"]), None,
                                             flags=cv.CALIB_USE_INTRINSIC_GUESS)
    fit_b, kb, db, _, _ = cv.calibrateCamera(object_sets, right, size_b, matrix(lb["intrinsics"]), None,
                                             flags=cv.CALIB_USE_INTRINSIC_GUESS)
    pose_diversity(fitting, objects, ka, da, size_a)
    rms, _, _, _, _, rotation, translation, _, _ = cv.stereoCalibrate(
        object_sets, left, right, ka, da, kb, db, size_a, flags=cv.CALIB_FIX_INTRINSIC)
    require(max(fit_a, fit_b, rms) <= 1, f"Reprojection RMS too high: {fit_a:.3f}/{fit_b:.3f}/{rms:.3f} px")
    basis, baseline = rectification(rotation, translation)
    factory = np.asarray(meta["factoryExtrinsicsColumnsMM"], dtype=float).T
    factory_basis, factory_baseline = rectification(factory[:, :3], factory[:, 3])
    require(abs(baseline-factory_baseline) <= .05 * factory_baseline, "Physical scale differs from factory baseline by >5%")
    require(np.dot(basis[:, 0], factory_basis[:, 0]) > .995 and np.min(np.diag(rotation.T @ factory[:, :3])) > .999,
            "Fitted relative pose disagrees with factory geometry")
    focal_native = max(ka[0, 0] / size_a[0], kb[0, 0] / size_b[0]) * size_a[0]
    trial = [reference_trial(points, truth, objects, ka, da, kb, db, basis, rotation, baseline, focal_native)
             for points, truth in held_out]
    epipolar = math.sqrt(float(np.mean(np.concatenate([residual for _, residual in trial]) ** 2)))
    require(epipolar <= 1, f"Held-out vertical epipolar RMS too high: {epipolar:.3f} px")

    w, h = 320, 240
    f = focal_native / size_a[0] * w
    virtual_k = matrix([f, f, (w - 1)/2, (h - 1)/2])
    ax, ay = cv.initUndistortRectifyMap(ka, da, basis.T, virtual_k, (w, h), cv.CV_32FC1)
    bx, by = cv.initUndistortRectifyMap(kb, db, basis.T @ rotation.T, virtual_k, (w, h), cv.CV_32FC1)
    overlap = (ax >= 0) & (ay >= 0) & (ax < size_a[0]-1) & (ay < size_a[1]-1)
    overlap &= (bx >= 0) & (by >= 0) & (bx < size_b[0]-1) & (by < size_b[1]-1)
    coverage = float(overlap.mean())
    require(coverage >= .25, f"Rectified overlap only {coverage:.1%}")
    roi = cv.boundingRect(overlap.astype(np.uint8))

    def lens_data(original, k, d):
        coeff = d.ravel()[:5]
        require(np.isfinite(coeff).all() and np.all(np.abs(coeff) <= 4), "Unstable lens distortion")
        return {key: original[key] for key in ("width", "height", "position", "intrinsics")} | {
            "fittedIntrinsics": intrinsic_values(k), "distortion": coeff.tolist()}

    profile = {
        "pair": meta["pair"], "captureSignature": meta["captureSignature"],
        "factoryExtrinsicsColumnsMM": meta["factoryExtrinsicsColumnsMM"],
        "fittedExtrinsicsColumnsMM": np.column_stack((rotation, translation.reshape(3))).T.tolist(),
        "left": lens_data(la, ka, da), "right": lens_data(lb, kb, db),
        "baselineMM": float(baseline), "trainingPairs": len(fitting),
        "reprojectionRMSPx": max(fit_a, fit_b, rms), "epipolarRMSPx": epipolar,
        "overlapFraction": coverage, "overlapROI320x240": roi,
        "references": [entry for entry, _ in trial],
    }
    return profile, {"ax": ax, "ay": ay, "bx": bx, "by": by, "overlap": overlap}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--out", type=Path, default=Path("StereoCalibration.json"))
    parser.add_argument("--maps", type=Path, help="Optional OpenCV rectification maps .npz")
    args = parser.parse_args()
    try:
        profile, maps = fit(args.dataset)
        args.out.write_text(json.dumps(profile, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        if args.maps is not None:
            np.savez_compressed(args.maps, **maps)
    except (OSError, ValueError, KeyError, TypeError, StopIteration, cv.error) as exc:
        parser.exit(2, f"Calibration refused: {exc}\n")
    print(f"Wrote {args.out}: {profile['trainingPairs']} usable fitting pairs, "
          f"{profile['reprojectionRMSPx']:.3f} px reprojection, {profile['epipolarRMSPx']:.3f} px held-out epipolar RMS")
    errors = np.array([ref["stereoCM"] - ref["measuredCM"] for ref in profile["references"]])
    print(f"Held-out checkerboard geometry: MAE {np.abs(errors).mean():.2f} cm, "
          f"RMSE {np.sqrt(np.mean(errors**2)):.2f} cm, bias {errors.mean():.2f} cm, "
          f"P95 absolute error {np.quantile(np.abs(errors), .95):.2f} cm")


if __name__ == "__main__":
    main()
