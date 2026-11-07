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
        // Maintain background safety state if necessary
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        configureLowLatencyAudioSession()
    }

    private func configureLowLatencyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use .default mode for maximum hardware compatibility across iPhone 14 Pro speakers/AirPods
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            // iPhone 14 Pro hardware native sample rate is 48kHz
            try session.setPreferredSampleRate(48000.0)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[HorusEyes] Warning: Low latency audio session setup fallback: \(error.localizedDescription)")
        }
    }
}
