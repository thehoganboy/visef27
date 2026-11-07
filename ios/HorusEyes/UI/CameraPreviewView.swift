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
            updateOrientation()
        }

        func updateOrientation() {
            guard let conn = videoPreviewLayer.connection, conn.isVideoOrientationSupported else { return }
            let orientation = window?.windowScene?.interfaceOrientation ?? .landscapeRight
            switch orientation {
            case .landscapeLeft:
                conn.videoOrientation = .landscapeLeft
            case .landscapeRight:
                conn.videoOrientation = .landscapeRight
            default:
                conn.videoOrientation = .landscapeRight
            }
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.updateOrientation()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session != session {
            uiView.videoPreviewLayer.session = session
        }
        uiView.updateOrientation()
    }
}
