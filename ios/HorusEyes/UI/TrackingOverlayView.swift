import SwiftUI

struct TrackingOverlayView: View {
    let result: ObstacleDetectionResult?
    let threatLevel: String
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

            let isEffectiveStop = isStop
            let primaryColor: Color = isEffectiveStop ? Color(red: 1.0, green: 0.23, blue: 0.19) :
                                      threatLevel == "WARNING" ? Color(red: 1.0, green: 0.58, blue: 0.0) :
                                      Color(red: 0.95, green: 0.95, blue: 0.97)

            var labels: [CGRect] = []
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            for obstacle in result.allObstacles.prefix(12) {
                let box = obstacle.bbox
                let l = ox + CGFloat(box.x) * scale
                let t = oy + CGFloat(box.y) * scale
                let r = l + CGFloat(box.w) * scale
                let b = t + CGFloat(box.h) * scale
                guard l.isFinite, t.isFinite, r.isFinite, b.isFinite, r > l, b > t else { continue }
                let leg = min(26, min(r - l, b - t) / 2.8)
                var path = Path()
                for (x, y, dx, dy) in [(l, t, CGFloat(1), CGFloat(1)), (r, t, -1, 1), (l, b, 1, -1), (r, b, -1, -1)] {
                    path.move(to: CGPoint(x: x + dx * leg, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + dy * leg))
                }

                // Pass 1: Outer dark outline for maximum contrast against bright scenes
                context.stroke(path, with: .color(Color.black.opacity(0.85)), style: StrokeStyle(lineWidth: 7.0, lineCap: .round, lineJoin: .round))

                // Pass 2: Vivid inner colored stroke
                context.stroke(path, with: .color(primaryColor), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                let text = context.resolve(Text(mode.distanceLabel(obstacle.distCM))
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
