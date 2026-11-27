"""Synthetic image fixture for the workstation calibration utility. Writes no profile."""
import base64
import json
import sys
import tempfile
from pathlib import Path

import cv2 as cv
import numpy as np

from ios.scripts.fit_stereo_calibration import fit, matrix


def main():
    cols, rows = 8, 5
    square, baseline = 60.0, 20.0
    width, height = 640, 480
    intrinsics = [480., 480., 319.5, 239.5]
    k = matrix(intrinsics)
    cell = 100
    grid = (np.indices((rows + 1, cols + 1)).sum(axis=0) % 2) * 230 + 12
    board = np.repeat(np.repeat(grid.astype(np.uint8), cell, axis=0), cell, axis=1)
    pixel_corners = np.float32([[0, 0], [board.shape[1], 0],
                                [board.shape[1], board.shape[0]], [0, board.shape[0]]]) - .5
    physical = (np.float32([[-1, -1, 0], [cols, -1, 0], [cols, rows, 0], [-1, rows, 0]])
                - np.float32([(cols - 1) / 2, (rows - 1) / 2, 0])) * square

    def image(rotation, translation, stamp):
        target, _ = cv.projectPoints(physical, rotation, np.array(translation, dtype=float), k, None)
        transform = cv.getPerspectiveTransform(pixel_corners, target.reshape(4, 2))
        im = cv.warpPerspective(board, transform, (width, height), borderValue=175)
        im = cv.GaussianBlur(im, (3, 3), .55)
        ok, encoded = cv.imencode(".pgm", im)
        assert ok
        return {"width": width, "height": height, "pgmBase64": base64.b64encode(encoded).decode(),
                "intrinsics": intrinsics, "position": .45, "hostSeconds": stamp}

    def observation(rotation, xyz, sequence, truth=None):
        stamp = 1000 + sequence
        return {"capture": {
            "pair": ["synthetic-A", "synthetic-B"], "captureSignature": ["synthetic-A", "synthetic-B"],
            "factoryExtrinsicsColumnsMM": [[1, 0, 0], [0, 1, 0], [0, 0, 1], [-baseline, 0, 0]],
            "skewMS": 5.4, "left": image(rotation, xyz, stamp),
            "right": image(rotation, (xyz[0] - baseline, xyz[1], xyz[2]), stamp + .0054)},
            **({"measuredCM": truth} if truth is not None else {})}

    rng = np.random.default_rng(57)
    trials = []
    for i in range(22):
        pose = rng.uniform(-.36, .36, 3)
        pose[2] *= 0.35
        xyz = (rng.uniform(-170, 170), rng.uniform(-115, 115), rng.uniform(700, 1120))
        trials.append(observation(pose, xyz, i))
    for i, cm in enumerate((50, 100, 200, 300), start=25):
        trials.append(observation(np.zeros(3), (0, 0, cm * 10), i, cm))

    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "synthetic.jsonl"
        with path.open("w", encoding="utf-8") as stream:
            stream.write(json.dumps({"schema": 1, "columns": cols, "rows": rows, "squareMM": square}) + "\n")
            for record in trials:
                stream.write(json.dumps(record) + "\n")
        profile, maps = fit(path)
        assert abs(profile["baselineMM"] - baseline) < 1
        errors = np.array([ref["stereoCM"] - ref["measuredCM"] for ref in profile["references"]])
        print("SYNTHETIC checkerboard held-out errors (cm):", np.round(errors, 3).tolist())
        assert np.abs(errors).mean() < 8
        assert maps["overlap"].mean() > 0.9
        print(f"SYNTHETIC checkerboard fitting: {profile['trainingPairs']} poses, "
              f"baseline {profile['baselineMM']:.3f} mm, reprojection {profile['reprojectionRMSPx']:.3f} px, "
              f"held-out epipolar {profile['epipolarRMSPx']:.3f} px")


if __name__ == "__main__":
    main()
