// HorusEyes 2.0 — TrackingOverlayView.swift
// ════════════════════════════════════════════════════════════════════════════════
// Real-Time High-Contrast AR Obstacle Bounding Box & HUD Overlay (Landscape)
// Apple HIG & ViSEF Standards: Corner Brackets, Reticles, Threat Colors, Distance Badges
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct TrackingOverlayView: View {
    let result: ObstacleDetectionResult?
    let threatLevel: String
    let safeDirection: String
    let isPaused: Bool
    let camWidth: CGFloat = 640.0
    let camHeight: CGFloat = 480.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if !isPaused, let res = result {
                    // 1. Draw all detected obstacles
                    ForEach(res.allObstacles, id: \.id) { obs in
                        obstacleBox(obs: obs, in: geo.size)
                    }

                    // 2. Center Corridor Guide Lines (3 Sectors)
                    corridorGuideLines(in: geo.size)

                    // 3. Top Floating Escape Guidance Banner
                    topGuidanceBanner(res: res, in: geo.size)

                    // 4. Bottom 3-Sector Clearance Indicators
                    bottomSectorClearanceBar(sectorDists: res.sectorDists, in: geo.size)
                } else if isPaused {
                    pausedBackdrop(in: geo.size)
                }
            }
        }
        .allowsHitTesting(false) // Let user taps pass through to controls
    }

    // ── Obstacle Bounding Box & Reticle ───────────────────────────────────────
    private func obstacleBox(obs: SingleObstacle, in size: CGSize) -> some View {
        let scaleX = size.width / camWidth
        let scaleY = size.height / camHeight

        let bx = CGFloat(obs.bbox.x) * scaleX
        let by = CGFloat(obs.bbox.y) * scaleY
        let bw = max(60, CGFloat(obs.bbox.w) * scaleX)
        let bh = max(60, CGFloat(obs.bbox.h) * scaleY)

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
            CornerBracketsShape(bracketLength: min(24, bw * 0.25))
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
            let topY = size.height * 0.20
            let botY = size.height * 0.82

            path.move(to: CGPoint(x: leftX, y: topY))
            path.addLine(to: CGPoint(x: leftX, y: botY))

            path.move(to: CGPoint(x: rightX, y: topY))
            path.addLine(to: CGPoint(x: rightX, y: botY))
        }
        .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
    }

    // ── Top Floating Guidance Banner ──────────────────────────────────────────
    private func topGuidanceBanner(res: ObstacleDetectionResult, in size: CGSize) -> some View {
        let isSafe = res.distCM >= Config.distSafeCM || res.modeText.hasPrefix("SAFE")
        let bannerColor = isSafe ? Color.green : colorForThreat(distCM: res.distCM)

        return VStack {
            HStack(spacing: 10) {
                Image(systemName: isSafe ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(bannerColor)

                if isSafe {
                    Text("ĐƯỜNG THOÁNG AN TOÀN (>2.5m)")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                } else {
                    Text("CẢNH BÁO (\(Int(res.distCM))cm) — ")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    Text("NÉ SANG \(safeDirection == "LEFT" ? "TRÁI ◄" : "PHẢI ►")")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundColor(bannerColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.85))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(bannerColor.opacity(0.8), lineWidth: 1.5))
            .shadow(color: bannerColor.opacity(0.35), radius: 8)
            .padding(.top, 12)

            Spacer()
        }
    }

    // ── Bottom 3-Sector Clearance Meter ───────────────────────────────────────
    private func bottomSectorClearanceBar(sectorDists: [String: Float], in size: CGSize) -> some View {
        let distL = sectorDists["LEFT"] ?? 250.0
        let distC = sectorDists["CENTER"] ?? 250.0
        let distR = sectorDists["RIGHT"] ?? 250.0

        return VStack {
            Spacer()
            HStack(spacing: 12) {
                sectorPill(title: "TRÁI", distCM: distL)
                sectorPill(title: "GIỮA", distCM: distC)
                sectorPill(title: "PHẢI", distCM: distR)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.75))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .padding(.bottom, 14)
        }
    }

    private func sectorPill(title: String, distCM: Float) -> some View {
        let color = colorForThreat(distCM: distCM)
        return HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
            Text("\(Int(min(300, distCM)))cm")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }

    // ── Paused Backdrop ───────────────────────────────────────────────────────
    private func pausedBackdrop(in size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
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

    // ── Helpers ───────────────────────────────────────────────────────────────
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

