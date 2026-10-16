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
import CoreImage
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
    private var runtimeErrorObserver: NSObjectProtocol?

    /// PNG of the most recent frame that produced a result.
    ///
    /// Written on the analysis queue and read from the method channel, so both
    /// accessors take the lock; Swift has no equivalent of Kotlin's `@Volatile`.
    private var lastFramePng: Data?

    /// Reused: constructing a `CIContext` is expensive, and this one is used on
    /// every frame that decodes something.
    private lazy var ciContext = CIContext()

    /// Set while a result is on screen; frames are ignored rather than analysed.
    /// The camera stays open so the preview does not flicker.
    private var isAnalyzing = false

    private let lock = NSLock()

    /// How many times a start is attempted before the failure is reported.
    private static let startAttempts = 3

    init(controller: ScannerController) {
        self.controller = controller

        super.init()

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        observeRuntimeErrors()

        controller.attach(self)
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        controller.detach(self)
    }

    func view() -> UIView { container }

    /// The frame the last result came from, or `nil`.
    func lastFrame() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastFramePng
    }

    // MARK: - Session control

    /// Starts, or restarts, the capture session.
    ///
    /// Deliberately restartable and verified. The first launch after the
    /// permission prompt showed a black preview that only relaunching the app
    /// cleared; a start that quietly does nothing cannot be recovered from, so
    /// this always attempts the start, checks that the session really came up,
    /// retries, and reports the failure to Dart if it still has not. A black
    /// screen with no explanation is the one outcome that must not happen.
    ///
    /// No disposal flag is needed the way the Android view has one: this is a
    /// `FlutterPlatformView` with no `dispose` callback, and every hop onto the
    /// session queue captures `self` weakly and re-checks it.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard self.configureSession() else { return }
            }
            self.beginRunning(attempt: 1)
        }
    }

    private func beginRunning(attempt: Int) {
        alignOrientations()

        if !session.isRunning {
            session.startRunning()
        }

        if session.isRunning {
            isRunning = true
            return
        }

        guard attempt < Self.startAttempts else {
            isRunning = false
            controller.onCameraError(
                code: "cameraUnavailable",
                message: "The camera did not start. Try again, or reopen the app.")
            return
        }

        // `startRunning` can return without the session having started — for
        // instance when it is called while the app is still becoming active,
        // which is exactly when the permission prompt has just been dismissed.
        sessionQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.beginRunning(attempt: attempt + 1)
        }
    }

    /// Restarts the session after the system reports a runtime error.
    ///
    /// Without this the preview simply freezes, which looks identical to the
    /// black-screen report and is just as unrecoverable.
    private func observeRuntimeErrors() {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.beginRunning(attempt: 1)
            }
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
        alignOrientations()

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

    /// Puts the preview layer and the analysed buffers in the same orientation.
    ///
    /// They are two independent connections, and nothing keeps them in step: the
    /// preview layer has its own `videoOrientation` and the data output has
    /// another. Only the output's was ever set, which left the preview free to
    /// sit at its own default. Markers computed from the analysis frame then
    /// land rotated on the preview — which is what was reported on iPhone SE and
    /// 6s, the devices old enough to take the `videoOrientation` path rather than
    /// `videoRotationAngle`.
    ///
    /// Called while configuring and again on every start, because the preview
    /// layer only produces a connection once the session has an input.
    private func alignOrientations() {
        let connections = [previewLayer.connection, videoOutput?.connection(with: .video)]
        for connection in connections.compactMap({ $0 }) {
            applyPortraitOrientation(to: connection)
        }
    }

    /// The rotation the preview is being displayed at.
    ///
    /// The analysis is turned by this rather than by the data output's own
    /// orientation, so the two agree by construction: whatever the preview does,
    /// the frame the markers are computed from has been rotated to match it.
    private func displayRotationDegrees() -> Int {
        guard let connection = previewLayer.connection else {
            return 0
        }
        return rotationDegrees(for: connection)
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

        // Taken from the preview rather than from this frame's connection: the
        // markers have to match what is on screen, not what the output happens to
        // report.
        let displayDegrees = displayRotationDegrees()

        // ...but only rotate if the buffer is not upright already.
        //
        // The connection reports the orientation the preview is displayed at,
        // while whether the buffers arrive already turned for it depends on the
        // platform: on iOS 14 and 15 they do. The engine was rotating them a
        // second time, so the analysed image sat a quarter turn from the picture,
        // and every marker came out rotated with it — reported on an iPhone SE
        // (1st gen) and a 6s, where the codes formed a triangle pointing down and
        // the markers formed the same triangle pointing left.
        //
        // Rather than pick a side, the buffer's own shape settles it: an upright
        // buffer for an upright display needs no further rotation, and a sideways
        // one does.
        let wantsPortrait = displayDegrees == 90 || displayDegrees == 270
        let bufferIsSideways =
            CVPixelBufferGetWidth(pixelBuffer) > CVPixelBufferGetHeight(pixelBuffer)
        let rotation = (wantsPortrait && bufferIsSideways) ? displayDegrees : 0

        // Objective-C declares this as
        // `detectAndDecodePixelBuffer:rotationDegrees:`, but Swift drops
        // "PixelBuffer" — it repeats the first parameter's type — leaving
        // `detectAndDecode(_:rotationDegrees:)`, with the first argument
        // unlabelled.
        let matches = WeChatQRCodeEngine.detectAndDecode(
            pixelBuffer,
            rotationDegrees: Int32(rotation))

        guard !matches.isEmpty else { return }

        // The engine reports centres in the coordinates of the image it analysed.
        // Passing the rotation actually applied — not the display's — keeps the
        // size used here and the image the centres were measured in the same one.
        let imageSize = rotatedImageSize(of: pixelBuffer, degrees: rotation)

        let payload: [[String: Any?]] = matches.map { match in
            var x: Double?
            var y: Double?
            if let centre = match.centreInImage?.cgPointValue,
               let normalised = normalise(centre, imageSize: imageSize) {
                x = Double(normalised.x)
                y = Double(normalised.y)
            }
            // Annotated rather than inferred: the values are a mix of String and
            // Double?, which would otherwise land on [String: Any].
            let entry: [String: Any?] = ["text": match.text, "x": x, "y": y]
            return entry
        }

        storeLastFrame(pixelBuffer)
        controller.onDecoded(payload)
    }

    /// The analysed image's size, accounting for the rotation the engine applied.
    private func rotatedImageSize(
        of pixelBuffer: CVPixelBuffer, degrees: Int
    ) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return (degrees == 90 || degrees == 270)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Maps a centre given in image coordinates onto the preview layer.
    ///
    /// The layer uses `.resizeAspectFill`, so the image is scaled to cover the
    /// view and centre-cropped; those offsets have to come back out or every
    /// marker sits displaced towards the centre. The result is a fraction of the
    /// view, which is what the Flutter layer positions markers with — the same
    /// arithmetic the Android view does.
    private func normalise(_ centre: CGPoint, imageSize: CGSize) -> CGPoint? {
        let viewSize = previewLayer.bounds.size
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else {
            return nil
        }

        let scale = max(viewSize.width / imageSize.width,
                        viewSize.height / imageSize.height)
        let offsetX = (imageSize.width * scale - viewSize.width) / 2
        let offsetY = (imageSize.height * scale - viewSize.height) / 2

        let x = (centre.x * imageSize.width * scale - offsetX) / viewSize.width
        let y = (centre.y * imageSize.height * scale - offsetY) / viewSize.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Keeps a PNG of the frame a result came from, for the caller to freeze.
    ///
    /// Encoding once per detection, not per frame. A layer snapshot is not an
    /// option here: `AVCaptureVideoPreviewLayer` does not draw its video frames
    /// into its backing store, so rendering it yields a blank image.
    private func storeLastFrame(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return
        }
        let png = UIImage(cgImage: cgImage).pngData()
        lock.lock()
        lastFramePng = png
        lock.unlock()
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
