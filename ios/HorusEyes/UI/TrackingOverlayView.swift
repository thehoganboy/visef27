import SwiftUI

struct TrackingOverlayView: View {
    let result: ObstacleDetectionResult?
    let tracks: [MetricObstacleTracker.Track]
    let risk: PerceptionRisk
    let mode: DepthMode
    var isStop: Bool = false

    var body: some View {
        Canvas { context, size in
            guard let result = result, result.isValid else { return }
            guard result.camWidth > 0, result.camHeight > 0, size.width > 0, size.height > 0 else { return }
            let scale = min(size.width / CGFloat(result.camWidth), size.height / CGFloat(result.camHeight))
            guard scale.isFinite, scale > 0 else { return }
            let ox = (size.width - CGFloat(result.camWidth) * scale) / 2
            let oy = (size.height - CGFloat(result.camHeight) * scale) / 2
            guard ox.isFinite, oy.isFinite else { return }

            let visible = mode == .midas ? result.allObstacles.map {
                MetricObstacleTracker.Track(id: $0.id,
                    box: CGRect(x: $0.bbox.x, y: $0.bbox.y, width: $0.bbox.w, height: $0.bbox.h),
                    distanceCM: $0.distCM, confidence: 1 - $0.uncertaintyScore,
                    isWall: $0.isWall, isCritical: $0.distCM <= Config.distCriticalCM)
            } : tracks

            var labels: [CGRect] = []
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            for obstacle in visible.sorted(by: {
                if $0.isCritical != $1.isCritical { return $0.isCritical }
                if $0.isWall != $1.isWall { return !$0.isWall }
                return ($0.distanceCM.isFinite ? $0.distanceCM : .infinity) < ($1.distanceCM.isFinite ? $1.distanceCM : .infinity)
            }).prefix(4) {
                let box = obstacle.box
                let l = ox + box.minX * scale
                let t = oy + box.minY * scale
                let r = ox + box.maxX * scale
                let b = oy + box.maxY * scale
                guard l.isFinite, t.isFinite, r.isFinite, b.isFinite, r > l, b > t else { continue }
                let color: Color = obstacle.isCritical ? .red
                    : (isStop || risk == .warning ? .orange : .white)
                let leg = min(26, min(r - l, b - t) / 2.8)
                var path = Path()
                if obstacle.isWall {
                    path.move(to: CGPoint(x: l, y: t))
                    path.addLine(to: CGPoint(x: r, y: t))
                } else {
                    for (x, y, dx, dy) in [(l, t, CGFloat(1), CGFloat(1)), (r, t, -1, 1), (l, b, 1, -1), (r, b, -1, -1)] {
                        path.move(to: CGPoint(x: x + dx * leg, y: y))
                        path.addLine(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x, y: y + dy * leg))
                    }
                }

                context.stroke(path, with: .color(.black.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                context.stroke(path, with: .color(color.opacity(obstacle.isCritical ? 1 : 0.75 + Double(obstacle.confidence) * 0.25)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let label = (obstacle.isWall ? "Wall · " : "") + mode.distanceLabel(obstacle.distanceCM)
                let text = context.resolve(Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundColor(.white))
                let measured = text.measure(in: size)
                let w = measured.width + 12, h = measured.height + 6
                guard w <= bounds.width, h <= bounds.height else { continue }
                let positions = [
                    CGPoint(x: l, y: t - h - 4), CGPoint(x: l, y: b + 4),
                    CGPoint(x: r + 4, y: t), CGPoint(x: l + 4, y: t + 5)
                ]
                for position in positions {
                    let box = CGRect(x: min(max(position.x, bounds.minX), bounds.maxX - w),
                                     y: min(max(position.y, bounds.minY), bounds.maxY - h), width: w, height: h)
                    guard !labels.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(box) }) else { continue }
                    context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.black.opacity(0.82)))
                    context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
                    labels.append(box)
                    break
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
