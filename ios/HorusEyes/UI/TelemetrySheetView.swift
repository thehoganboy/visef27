// HorusEyes 2.0 — TelemetrySheetView.swift
// ════════════════════════════════════════════════════════════════════════════════
// High-Precision Technical Diagnostic Sheet for ViSEF Evaluation & Research Demo
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct TelemetrySheetView: View {
    @Environment(\.dismiss) private var dismiss

    let fps: Float
    let latencyMs: Float
    let meanLuma: Float
    let distCM: Float
    let velocityZ: Float
    let ttc: Float
    let uncertainty: Float
    let cueMode: String
    let threatLevel: String
    let safeDirection: String
    let isZeroLuxBlind: Bool
    let isTorchActive: Bool
    let sectorDists: [String: Float]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Subtitle
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BẢNG CHẨN ĐOÁN KỸ THUẬT VISEF")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Text("Real-Time Kinematics & Auditory Budget Metrics")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Circle()
                            .fill(isZeroLuxBlind ? Color.red : Color.green)
                            .frame(width: 10, height: 10)
                            .shadow(color: isZeroLuxBlind ? Color.red : Color.green, radius: 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // ── Card 1: Edge Computing & CoreML ANE Performance ───────────
                    TelemetryCard(title: "HIỆU NĂNG PHẦN CỨNG BIÊN (EDGE ANE)", icon: "cpu.fill") {
                        VStack(spacing: 12) {
                            HStack {
                                TechMetricRow(label: "Tốc độ khung hình (Camera FPS)", value: String(format: "%.1f FPS", fps), isHighlight: true)
                                Divider().background(Color.white.opacity(0.1))
                                TechMetricRow(label: "Độ trễ suy luận ANE", value: String(format: "%.1f ms", latencyMs), isHighlight: latencyMs < 35.0)
                            }
                            Divider().background(Color.white.opacity(0.1))
                            HStack {
                                TechMetricRow(label: "Độ rọi quang học (Luma Y)", value: String(format: "%.0f Lux", meanLuma))
                                Divider().background(Color.white.opacity(0.1))
                                TechMetricRow(label: "0-Lux Defense", value: isTorchActive ? "TORCH ACTIVE" : "AUTO MONITOR", isHighlight: isTorchActive)
                            }
                        }
                    }

                    // ── Card 2: Kinematics & Time-To-Collision ────────────────────
                    TelemetryCard(title: "ĐỘNG HỌC & DỰ BÁO VA CHẠM (KINEMATICS)", icon: "speedometer") {
                        VStack(spacing: 12) {
                            HStack {
                                TechMetricRow(label: "Khoảng cách trục Z", value: String(format: "%.0f cm", distCM))
                                Divider().background(Color.white.opacity(0.1))
                                TechMetricRow(label: "Vận tốc tương đối V_z", value: String(format: "%.0f cm/s", velocityZ), isHighlight: velocityZ > 20.0)
                            }
                            Divider().background(Color.white.opacity(0.1))
                            HStack {
                                TechMetricRow(
                                    label: "Thời gian va chạm (TTC)",
                                    value: ttc.isFinite ? String(format: "%.2f s", ttc) : "SAFE (∞)",
                                    isHighlight: ttc < 2.5 && ttc.isFinite
                                )
                                Divider().background(Color.white.opacity(0.1))
                                TechMetricRow(label: "Mức độ đe dọa", value: threatLevel, isHighlight: threatLevel != "SAFE")
                            }
                        }
                    }

                    // ── Card 3: Uncertainty-Aware Auditory Budget ─────────────────
                    TelemetryCard(title: "ĐIỀU PHỐI NGÂN SÁCH THÍNH GIÁC (BUDGET ≤ 1)", icon: "waveform") {
                        VStack(spacing: 12) {
                            HStack {
                                TechMetricRow(label: "Độ bất định AI (u-score)", value: String(format: "%.2f", uncertainty), isHighlight: uncertainty > 0.48)
                                Divider().background(Color.white.opacity(0.1))
                                TechMetricRow(label: "Chế độ âm cảnh báo", value: cueMode, isHighlight: cueMode == "ACOUSTIC_BLUR")
                            }
                            Divider().background(Color.white.opacity(0.1))
                            HStack {
                                TechMetricRow(label: "Số luồng âm hoạt động", value: "1 / 1 Stream (Strict)", isHighlight: true)
                                Divider().background(Color.white.opacity(0.1))
                                TechMetricRow(label: "Hướng thoát hiểm tối ưu", value: safeDirection, isHighlight: true)
                            }
                        }
                    }

                    // ── Card 4: Corridor Clearance Breakdown ───────────────────────
                    TelemetryCard(title: "KHOẢNG CÁCH 3 SECTOR HÀNH LANG", icon: "arrow.triangle.swap") {
                        HStack(spacing: 12) {
                            SectorMiniPill(name: "TRÁI (35°)", dist: sectorDists["LEFT"] ?? 250.0)
                            SectorMiniPill(name: "GIỮA (40°)", dist: sectorDists["CENTER"] ?? 250.0)
                            SectorMiniPill(name: "PHẢI (35°)", dist: sectorDists["RIGHT"] ?? 250.0)
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Thông Số Kỹ Thuật")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
}

// ── Supporting Telemetry Subviews ──────────────────────────────────────────────
struct TelemetryCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.75))
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

struct TechMetricRow: View {
    let label: String
    let value: String
    var isHighlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gray)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundColor(isHighlight ? .cyan : .white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectorMiniPill: View {
    let name: String
    let dist: Float

    var color: Color {
        if dist <= Config.distCriticalCM {
            return .red
        } else if dist <= Config.distDangerCM {
            return .orange
        } else if dist <= Config.distWarningCM {
            return .yellow
        } else {
            return .green
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
            Text(String(format: "%.0f cm", dist))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundColor(color)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

