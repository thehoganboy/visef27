// HorusEyes 2.0 — TrackingOverlayView.swift
// ════════════════════════════════════════════════════════════════════════════════
// Real-Time High-Contrast AR Obstacle Bounding Box & Reticle Overlay (Landscape)
// Apple HIG & ViSEF Standards: Pixel-Accurate Aspect-Fill Matrix Projection
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct TrackingOverlayView: View {
    let result: ObstacleDetectionResult?
    let threatLevel: String
    let safeDirection: String
    let isPaused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if !isPaused, let res = result {
                    // 1. Draw all detected obstacles with 1:1 camera-to-screen matrix transform
                    ForEach(res.allObstacles, id: \.id) { obs in
                        obstacleBox(obs: obs, res: res, in: geo.size)
                    }

                    // 2. Center Corridor Guide Lines (3 Sectors)
                    corridorGuideLines(in: geo.size)
                } else if isPaused {
                    pausedBackdrop(in: geo.size)
                }
            }
        }
        .allowsHitTesting(false) // Let user touches pass through to controls
    }

    // ── Obstacle Bounding Box & Reticle ───────────────────────────────────────
    private func obstacleBox(obs: SingleObstacle, res: ObstacleDetectionResult, in size: CGSize) -> some View {
        let camW = CGFloat(res.camWidth > 0 ? res.camWidth : 1280)
        let camH = CGFloat(res.camHeight > 0 ? res.camHeight : 720)

        // Exact Uniform Aspect-Fill Transform matching AVCaptureVideoPreviewLayer
        let scale = max(size.width / camW, size.height / camH)
        let renderedW = camW * scale
        let renderedH = camH * scale
        let offsetX = (size.width - renderedW) / 2.0
        let offsetY = (size.height - renderedH) / 2.0

        let bx = CGFloat(obs.bbox.x) * scale + offsetX
        let by = CGFloat(obs.bbox.y) * scale + offsetY
        let bw = max(CGFloat(56), CGFloat(obs.bbox.w) * scale)
        let bh = max(CGFloat(56), CGFloat(obs.bbox.h) * scale)

        let color = colorForThreat(distCM: obs.distCM)

        return ZStack {
            // Semi-transparent colored tint
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.18))
                .frame(width: bw, height: bh)

            // Outer Box Border
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.7), lineWidth: 2)
                .frame(width: bw, height: bh)

            // Heavy Corner Brackets (Lock-on target aesthetic)
            CornerBracketsShape(bracketLength: min(CGFloat(24), bw * 0.25))
                .stroke(color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .frame(width: bw, height: bh)

            // Center Target Reticle
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }

            // Floating Header Badge (ID, Distance, Threat)
            VStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                    Text("#\(obs.id) • \(Int(obs.distCM))cm • \(threatText(distCM: obs.distCM))")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.85))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(color, lineWidth: 1.2))
                .offset(y: -bh / 2 - 16)

                Spacer()
            }
            .frame(width: bw, height: bh)
        }
        .position(x: bx + bw / 2, y: by + bh / 2)
        .shadow(color: color.opacity(0.4), radius: 8)
    }

    // ── Corridor Guide Lines ──────────────────────────────────────────────────
    private func corridorGuideLines(in size: CGSize) -> some View {
        Path { path in
            let leftX = size.width * 0.33
            let rightX = size.width * 0.66
            let topY = size.height * 0.18
            let botY = size.height * 0.82

            path.move(to: CGPoint(x: leftX, y: topY))
            path.addLine(to: CGPoint(x: leftX, y: botY))

            path.move(to: CGPoint(x: rightX, y: topY))
            path.addLine(to: CGPoint(x: rightX, y: botY))
        }
        .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
    }

    // ── Paused Screen Backdrop ────────────────────────────────────────────────
    private func pausedBackdrop(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.60)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.orange)
                Text("HỆ THỐNG ĐANG TẠM DỪNG")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text("Chạm vào nút bên phải hoặc chạm màn hình để tiếp tục")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .padding(20)
            .background(Color.black.opacity(0.85))
            .cornerRadius(18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.5), lineWidth: 1.5))
        }
    }

    // ── Threat Color & Labels ─────────────────────────────────────────────────
    private func colorForThreat(distCM: Float) -> Color {
        if distCM <= Config.distCriticalCM {
            return Color.red
        } else if distCM <= Config.distDangerCM {
            return Color.orange
        } else if distCM <= Config.distWarningCM {
            return Color.yellow
        } else if distCM <= Config.distAlertCM {
            return Color.cyan
        } else {
            return Color.green
        }
    }

    private func threatText(distCM: Float) -> String {
        if distCM <= Config.distCriticalCM {
            return "NGUY HIỂM"
        } else if distCM <= Config.distDangerCM {
            return "CHÚ Ý"
        } else if distCM <= Config.distWarningCM {
            return "CẢNH BÁO"
        } else {
            return "THOÁNG"
        }
    }
}

// ── Corner Brackets Shape ─────────────────────────────────────────────────────
struct CornerBracketsShape: Shape {
    let bracketLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let l = bracketLength

        // Top-Left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))

        // Top-Right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))

        // Bottom-Left
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.maxY))

        // Bottom-Right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - l))

        return path
    }
}
