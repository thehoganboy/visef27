// HorusEyes 2.0 — CameraPreviewView.swift
// ════════════════════════════════════════════════════════════════════════════════
// Hardware-Accelerated Native Video Preview Layer (Full Screen Landscape)
// ════════════════════════════════════════════════════════════════════════════════

import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            videoPreviewLayer.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        if let conn = view.videoPreviewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        if let conn = uiView.videoPreviewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .landscapeRight
        }
    }
}
