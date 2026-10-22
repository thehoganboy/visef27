// HorusEyes 2.0 — HorusEyesApp.swift
// ════════════════════════════════════════════════════════════════════════════════
// Safety-Critical Real-Time iOS Entry Point (SwiftUI + Ultra-Low-Latency Audio Session)
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI
import AVFoundation

@main
struct HorusEyesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureLowLatencyAudioSession()
        UIApplication.shared.isIdleTimerDisabled = true // Keep screen awake during navigation
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Continue spatial audio in background if active
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        configureLowLatencyAudioSession()
    }

    private func configureLowLatencyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .measurement,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            // 5ms buffer duration = 220 samples @ 44.1kHz for sub-perception reaction time
            try session.setPreferredIOBufferDuration(0.005)
            try session.setPreferredSampleRate(Double(Config.audioSampleRate))
            try session.setActive(true)
        } catch {
            print("[HorusEyes] Warning: Low latency audio session setup failed: \(error.localizedDescription)")
        }
    }
}
