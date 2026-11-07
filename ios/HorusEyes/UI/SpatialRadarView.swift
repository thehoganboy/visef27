// HorusEyes 2.0 — SpatialRadarView.swift
// ════════════════════════════════════════════════════════════════════════════════
// Ultra-Minimalist Qualitative Spatial Radar HUD (Zero Numbers, Pure Human UX)
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct SpatialRadarView: View {
    let sectorDists: [String: Float]
    let nearestDistCM: Float
    let threatLevel: String
    let isPaused: Bool

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.5

    private var leftDist: Float { sectorDists["LEFT"] ?? 250.0 }
    private var centerDist: Float { sectorDists["CENTER"] ?? 250.0 }
    private var rightDist: Float { sectorDists["RIGHT"] ?? 250.0 }

    var body: some View {
        VStack(spacing: 16) {
            // ── Primary Safety Orb & Status Indicator ──────────────────────────────
            VStack(spacing: 8) {
                ZStack {
                    // Ambient Ripple Rings (Breathing Animation)
                    if !isPaused {
                        Circle()
                            .stroke(primaryColor.opacity(pulseOpacity * 0.4), lineWidth: 2)
                            .frame(width: 82, height: 82)
                            .scaleEffect(pulseScale)

                        Circle()
                            .stroke(primaryColor.opacity(pulseOpacity * 0.2), lineWidth: 1.5)
                            .frame(width: 104, height: 104)
                            .scaleEffect(pulseScale * 1.1)
                    }

                    // Main Spatial Core
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [primaryColor.opacity(0.35), primaryColor.opacity(0.08)],
                                center: .center,
                                startRadius: 5,
                                endRadius: 36
                            )
                        )
                        .frame(width: 68, height: 68)
                        .overlay(
                            Circle()
                                .stroke(primaryColor.opacity(0.6), lineWidth: 2)
                        )
                        .shadow(color: isPaused ? Color.clear : primaryColor.opacity(0.4), radius: 10)

                    // Hero Icon
                    Image(systemName: heroIconName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(primaryColor)
                        .scaleEffect(isPaused ? 0.9 : 1.0)
                }
                .frame(height: 90)

                // Qualitative Safety Label (No Numbers)
                Text(safetyStatusText)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(primaryColor)
                    .tracking(0.5)
                    .animation(.easeInOut(duration: 0.25), value: threatLevel)
            }
            .padding(.top, 2)

            // ── 3-Sector Qualitative Clearance HUD ────────────────────────────────
            HStack(spacing: 10) {
                SectorStatusCard(
                    title: "TRÁI",
                    distanceCM: leftDist,
                    isPaused: isPaused
                )

                SectorStatusCard(
                    title: "HÀNH LANG GIỮA",
                    distanceCM: centerDist,
                    isPaused: isPaused,
                    isCenterHero: true
                )

                SectorStatusCard(
                    title: "PHẢI",
                    distanceCM: rightDist,
                    isPaused: isPaused
                )
            }
            .padding(.horizontal, 16)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulseScale = 1.15
                pulseOpacity = 0.15
            }
        }
    }

    // ── Qualitative Status Texts & Colors ──────────────────────────────────────
    private var primaryColor: Color {
        guard !isPaused else { return Color.gray }
        if nearestDistCM <= Config.distCriticalCM {
            return Color(red: 1.0, green: 0.25, blue: 0.25) // Đỏ
        } else if nearestDistCM <= Config.distDangerCM {
            return Color(red: 1.0, green: 0.55, blue: 0.15) // Cam
        } else if nearestDistCM <= Config.distWarningCM {
            return Color(red: 1.0, green: 0.82, blue: 0.10) // Vàng
        } else {
            return Color(red: 0.20, green: 0.85, blue: 0.55) // Xanh ngọc
        }
    }

    private var heroIconName: String {
        guard !isPaused else { return "pause.circle.fill" }
        if nearestDistCM <= Config.distCriticalCM {
            return "hand.raised.fill"
        } else if nearestDistCM <= Config.distDangerCM {
            return "exclamationmark.triangle.fill"
        } else if nearestDistCM <= Config.distWarningCM {
            return "eye.trianglebadge.exclamationmark"
        } else {
            return "shield.checkered"
        }
    }

    private var safetyStatusText: String {
        guard !isPaused else { return "HỆ THỐNG ĐANG TẠM DỪNG" }
        if nearestDistCM <= Config.distCriticalCM {
            return "NGUY HIỂM: VẬT CẢN QUÁ GẦN"
        } else if nearestDistCM <= Config.distDangerCM {
            return "CẢNH BÁO VẬT CẢN PHÍA TRƯỚC"
        } else if nearestDistCM <= Config.distWarningCM {
            return "LƯU Ý: ĐANG TIẾP CẬN VẬT CẢN"
        } else {
            return "HÀNH LANG HOÀN TOÀN AN TOÀN"
        }
    }
}

// ── Sector Status Card (Zero Numbers, Pure Visual Signal Bars) ────────────────
struct SectorStatusCard: View {
    let title: String
    let distanceCM: Float
    let isPaused: Bool
    var isCenterHero: Bool = false

    private var level: Int {
        guard !isPaused else { return 0 }
        if distanceCM <= Config.distCriticalCM {
            return 1 // Rất nguy hiểm
        } else if distanceCM <= Config.distDangerCM {
            return 2 // Nguy hiểm
        } else if distanceCM <= Config.distWarningCM {
            return 3 // Cảnh giác
        } else {
            return 4 // Hoàn toàn thông thoáng
        }
    }

    private var statusColor: Color {
        guard !isPaused else { return Color.gray.opacity(0.4) }
        switch level {
        case 1: return Color(red: 1.0, green: 0.25, blue: 0.25)
        case 2: return Color(red: 1.0, green: 0.55, blue: 0.15)
        case 3: return Color(red: 1.0, green: 0.82, blue: 0.10)
        default: return Color(red: 0.20, green: 0.85, blue: 0.55)
        }
    }

    private var statusLabel: String {
        guard !isPaused else { return "Tạm dừng" }
        switch level {
        case 1: return "Bị chặn"
        case 2: return "Vật cản"
        case 3: return "Lưu ý"
        default: return "Thông thoáng"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            // Sector Title
            Text(title)
                .font(.system(size: isCenterHero ? 11 : 10, weight: .black, design: .rounded))
                .foregroundColor(isCenterHero ? .white : Color.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            // Clearance Signal Indicator (4-Segment Wave Bars)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(1...4, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barIndex <= level ? statusColor : Color.white.opacity(0.12))
                        .frame(width: isCenterHero ? 7 : 6, height: CGFloat(barIndex * 4 + 4))
                }
            }
            .frame(height: 22)

            // Human Friendly Status Label (No Numbers)
            Text(statusLabel)
                .font(.system(size: isCenterHero ? 12 : 11, weight: .bold, design: .rounded))
                .foregroundColor(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.11).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isCenterHero ? statusColor.opacity(0.4) : Color.white.opacity(0.08),
                            lineWidth: isCenterHero ? 1.5 : 1.0
                        )
                )
        )
        .shadow(color: isCenterHero ? statusColor.opacity(0.15) : Color.clear, radius: 8, y: 3)
    }
}
