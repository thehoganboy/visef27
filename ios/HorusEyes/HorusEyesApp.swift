// HorusEyes 2.0 — HorusEyesApp.swift
// ════════════════════════════════════════════════════════════════════════════════
// Crash-Proof iOS App Lifecycle Entry Point (Pure SwiftUI + Safe Audio Session)
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
        // Configure audio session category safely without activating hardware prematurely
        configureAudioSession()
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        configureAudioSession()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            // Note: Do NOT call session.setActive(true) during app launch.
            // Activating hardware audio before the UI is ready or when another app owns audio
            // can cause immediate SIGABRT / termination on physical devices.
            // Audio session is activated lazily when the user starts navigation in SpatialAudioEngine.
        } catch {
            print("[HorusEyes] AudioSession category setup notice: \(error.localizedDescription)")
        }
    }
}
