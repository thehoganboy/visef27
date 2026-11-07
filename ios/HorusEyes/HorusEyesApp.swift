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
        // Configure audio session safely without blocking options
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
            // Note: In Apple AVFoundation, notifyOthersOnDeactivation can only be used when active is FALSE.
            // When active is true, call setActive(true) with no options.
            try session.setActive(true)
        } catch {
            print("[HorusEyes] AudioSession startup notice: \(error.localizedDescription)")
        }
    }
}
