// Copyright (C) 2025 WeChatQR project contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AVFoundation
import Flutter
import UIKit

/// Full-bleed camera preview that runs WeChatQRCode frame analysis.
///
/// This is the iOS counterpart of the Android `ScannerPlatformView` and keeps
/// the same shape: one capture session owned by the view, analysis on a serial
/// queue that drops frames it cannot keep up with, and results handed back to
/// Flutter on the main thread.
///
/// Frames are requested in BGRA rather than the device-native YUV format: the
/// engine wants BGR, and letting CoreVideo hand us an already-converted buffer
/// avoids hand-written NV21 maths on this side.
final class ScannerPlatformView: NSObject, FlutterPlatformView {

    private let container = ScannerPreviewView()
    private let controller: ScannerController

    private let session = AVCaptureSession()

    /// The view's own backing layer, so it tracks the view's bounds.
    private var previewLayer: AVCaptureVideoPreviewLayer { container.previewLayer }
    private let sessionQueue = DispatchQueue(label: "com.sundys.wechat_qrcode.session")
    private let analysisQueue = DispatchQueue(label: "com.sundys.wechat_qrcode.analysis")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var isConfigured = false
    private var isRunning = false

    /// Set while a result is on screen; frames are ignored rather than analysed.
    /// The camera stays open so the preview does not flicker.
    private var isAnalyzing = false

    private let lock = NSLock()

    init(controller: ScannerController) {
        self.controller = controller

        super.init()

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        controller.attach(self)
    }

    deinit {
        controller.detach(self)
    }

    func view() -> UIView { container }

    // MARK: - Session control

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard self.configureSession() else { return }
            }
            guard !self.isRunning else { return }
            self.session.startRunning()
            self.isRunning = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
    }

    func release() {
        lock.lock()
        isAnalyzing = false
        lock.unlock()
        stop()
    }

    /// Enables or disables frame analysis without closing the camera.
    func setAnalyzing(_ enabled: Bool) {
        lock.lock()
        isAnalyzing = enabled
        lock.unlock()
    }

    /// Turns the torch on or off. Silently ignored where unsupported.
    func setTorch(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.currentDevice(), device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
            } catch {
                // A torch that cannot be configured is not worth surfacing.
            }
        }
    }

    // MARK: - Configuration

    private func configureSession() -> Bool {
        guard let device = preferredDevice() else {
            controller.onCameraError(
                code: "cameraUnavailable",
                message: "No usable back camera is available.")
            return false
        }

        session.beginConfiguration()
        // A balanced preset: detailed enough for dense codes at arm's length
        // without the cost of the highest resolutions.
        session.sessionPreset = .hd1280x720

        defer { session.commitConfiguration() }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                controller.onCameraError(
                    code: "cameraUnavailable",
                    message: "The camera input could not be added.")
                return false
            }
            session.addInput(input)
        } catch {
            controller.onCameraError(
                code: "cameraUnavailable",
                message: "The camera could not be opened: \(error.localizedDescription)")
            return false
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: analysisQueue)

        guard session.canAddOutput(output) else {
            controller.onCameraError(
                code: "cameraUnavailable",
                message: "The video output could not be added.")
            return false
        }
        session.addOutput(output)
        videoOutput = output

        // Keep the connection upright so the preview matches the device.
        if let connection = output.connection(with: .video) {
            applyPortraitOrientation(to: connection)
        }

        isConfigured = true
        return true
    }

    private func preferredDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func currentDevice() -> AVCaptureDevice? {
        session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first?
            .device
    }

    private func applyPortraitOrientation(to connection: AVCaptureConnection) {
        // `videoRotationAngle` replaced `videoOrientation` in iOS 17.
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }

    private func rotationDegrees(for connection: AVCaptureConnection?) -> Int {
        guard let connection else { return 0 }
        if #available(iOS 17.0, *) {
            return Int(connection.videoRotationAngle.rounded())
        }
        switch connection.videoOrientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        @unknown default: return 0
        }
    }
}

extension ScannerPlatformView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let analysing = isAnalyzing
        lock.unlock()

        // Frames arriving while a result is on screen are dropped here, which is
        // what keeps the recognition loop suspended without stopping the camera.
        guard analysing else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Objective-C declares this as
        // `detectAndDecodePixelBuffer:rotationDegrees:`, but Swift drops
        // "PixelBuffer" — it repeats the first parameter's type — leaving
        // `detectAndDecode(_:rotationDegrees:)`, with the first argument
        // unlabelled.
        let decoded = WeChatQRCodeEngine.detectAndDecode(
            pixelBuffer,
            rotationDegrees: Int32(rotationDegrees(for: connection)))

        guard !decoded.isEmpty else { return }
        controller.onDecoded(decoded)
    }
}

/// A view whose backing layer *is* the capture preview layer.
///
/// Hosting the layer this way, instead of adding an `AVCaptureVideoPreviewLayer`
/// to a plain view's layer tree, is what lets it follow the view's bounds with no
/// layout code at all: `CALayer.autoresizingMask` is not available on iOS, so a
/// manually added layer would have to be resized by hand on every layout pass.
private final class ScannerPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Guaranteed by `layerClass` above.
        layer as! AVCaptureVideoPreviewLayer
    }
}
