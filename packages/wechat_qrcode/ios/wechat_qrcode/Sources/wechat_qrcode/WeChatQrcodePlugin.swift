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

/// iOS side of the `wechat_qrcode` plugin.
///
/// Owns the same three channels as the Android implementation
/// (`wechat_qrcode/methods`, `wechat_qrcode/events`, `wechat_qrcode/scanner`),
/// so the Dart API is identical on both platforms.
///
/// Camera permission is requested here — not from Dart — because only the
/// platform can tell "denied" apart from "denied and cannot be asked again",
/// and that distinction decides what the UI is allowed to offer.
public class WeChatQrcodePlugin: NSObject, FlutterPlugin {

    private static let methodsChannel = "wechat_qrcode/methods"
    private static let eventsChannel = "wechat_qrcode/events"
    private static let viewType = "wechat_qrcode/scanner"

    private let controller = ScannerController()
    private var eventSink: FlutterEventSink?
    private var pendingStartResult: FlutterResult?

    /// Detector calls and image decoding run here, never on the main thread.
    private let workQueue = DispatchQueue(
        label: "com.sundys.wechat_qrcode.work", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = WeChatQrcodePlugin()

        let methods = FlutterMethodChannel(
            name: methodsChannel, binaryMessenger: registrar.messenger())
        methods.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }

        let events = FlutterEventChannel(
            name: eventsChannel, binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)

        registrar.register(
            WeChatQrcodeViewFactory(controller: instance.controller),
            withId: viewType)
    }

    // MARK: - Method calls

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            initialize(result: result)
        case "decodeImageFile":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String, !path.isEmpty
            else {
                result(FlutterError(
                    code: "invalidImage", message: "No image path was supplied.", details: nil))
                return
            }
            decodeImageFile(path: path, result: result)
        case "startScanning":
            startScanning(result: result)
        case "stopScanning":
            controller.stopScanning()
            result(nil)
        case "pauseScanning":
            controller.pauseScanning()
            result(nil)
        case "resumeScanning":
            controller.resumeScanning()
            result(nil)
        case "setTorch":
            let args = call.arguments as? [String: Any]
            controller.setTorch(args?["enabled"] as? Bool ?? false)
            result(nil)
        case "hasCameraPermission":
            result(Self.cameraAuthorization() == .authorized)
        case "release":
            controller.stopScanning()
            WeChatQRCodeEngine.releaseEngine()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initialize(result: @escaping FlutterResult) {
        if WeChatQRCodeEngine.isInitialized() {
            result(nil)
            return
        }
        guard let directory = Self.modelsDirectory() else {
            result(FlutterError(
                code: "modelLoadFailed",
                message: "The QR detection models are not bundled with the application.",
                details: nil))
            return
        }

        workQueue.async {
            var error: NSError?
            let ok = WeChatQRCodeEngine.initialize(withModelDirectory: directory, error: &error)
            DispatchQueue.main.async {
                if ok {
                    result(nil)
                } else {
                    result(FlutterError(
                        code: "modelLoadFailed",
                        message: error?.localizedDescription ?? "The QR engine failed to start.",
                        details: nil))
                }
            }
        }
    }

    private func decodeImageFile(path: String, result: @escaping FlutterResult) {
        guard WeChatQRCodeEngine.isInitialized() else {
            result(FlutterError(
                code: "notInitialized",
                message: "initialize() has not completed.", details: nil))
            return
        }

        workQueue.async {
            var error: NSError?
            let texts = WeChatQRCodeEngine.detectAndDecodeImage(atPath: path, error: &error)
            DispatchQueue.main.async {
                if let error, texts.isEmpty {
                    result(FlutterError(
                        code: "invalidImage",
                        message: error.localizedDescription, details: nil))
                } else {
                    result(texts)
                }
            }
        }
    }

    private func startScanning(result: @escaping FlutterResult) {
        guard WeChatQRCodeEngine.isInitialized() else {
            result(FlutterError(
                code: "notInitialized",
                message: "initialize() has not completed.", details: nil))
            return
        }

        switch Self.cameraAuthorization() {
        case .authorized:
            controller.startScanning()
            result(nil)
        case .denied, .restricted:
            result(FlutterError(
                code: "cameraPermissionPermanentlyDenied",
                message:
                    "Camera access is disabled; it must be enabled in system settings.",
                details: nil))
        case .notDetermined:
            // The reply is deferred until the user answers the system prompt.
            pendingStartResult = result
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let pending = self.pendingStartResult
                    self.pendingStartResult = nil
                    if granted {
                        self.controller.startScanning()
                        pending?(nil)
                    } else {
                        pending?(FlutterError(
                            code: "cameraPermissionDenied",
                            message: "Camera access was denied.", details: nil))
                    }
                }
            }
        @unknown default:
            result(FlutterError(
                code: "cameraPermissionDenied",
                message: "Camera access is unavailable.", details: nil))
        }
    }

    private static func cameraAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Finds the bundled `models` directory.
    ///
    /// The assets live in whichever bundle the plugin was linked into — the pod
    /// resource bundle, an SPM resource bundle, or the app itself — so all three
    /// are checked rather than assuming one layout.
    private static func modelsDirectory() -> String? {
        var bundles: [Bundle] = []

        #if SWIFT_PACKAGE
        // Swift Package Manager build: resources land in the generated bundle.
        bundles.append(Bundle.module)
        #endif

        bundles.append(Bundle(for: WeChatQrcodePlugin.self))
        if let resourceBundle = Bundle(
            url: Bundle(for: WeChatQrcodePlugin.self).resourceURL?
                .appendingPathComponent("wechat_qrcode.bundle"))
        {
            bundles.append(resourceBundle)
        }
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(Bundle.main)

        for bundle in bundles {
            guard let url = bundle.url(forResource: "models", withExtension: nil) else {
                continue
            }
            let probe = url.appendingPathComponent("detect.prototxt").path
            if FileManager.default.fileExists(atPath: probe) {
                return url.path
            }
        }
        return nil
    }
}

// MARK: - Event channel

extension WeChatQrcodePlugin: FlutterStreamHandler {
    public func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        controller.onResults = { texts in
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(texts)
            }
        }
        controller.onError = { code, message in
            DispatchQueue.main.async { [weak self] in
                self?.eventSink?(FlutterError(code: code, message: message, details: nil))
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        controller.onResults = nil
        controller.onError = nil
        return nil
    }
}

// MARK: - Platform view

private final class WeChatQrcodeViewFactory: NSObject, FlutterPlatformViewFactory {
    private let controller: ScannerController

    init(controller: ScannerController) {
        self.controller = controller
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
        withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
    ) -> FlutterPlatformView {
        ScannerPlatformView(controller: controller)
    }
}
