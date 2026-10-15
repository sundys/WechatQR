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

import AudioToolbox
import Flutter
import Photos
import UIKit

/// iOS side of the `platform_services` plugin.
///
/// Only the capabilities iOS actually has are implemented. Installing a package
/// is Android-only, so `installApk` and the "install unknown apps" screen report
/// `unsupported` rather than pretending: on iOS the version row opens the
/// Releases page in the browser instead (project spec §3.2).
public class PlatformServicesPlugin: NSObject, FlutterPlugin {

    private static let channelName = "platform_services/methods"

    private let workQueue = DispatchQueue(
        label: "com.sundys.platform_services.work", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName, binaryMessenger: registrar.messenger())
        let instance = PlatformServicesPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "vibrate":
            vibrate()
            result(nil)
        case "canInstallPackages":
            // There is no in-app install path on iOS.
            result(false)
        case "saveImageToGallery":
            saveImageToGallery(call, result: result)
        case "openAppSettings":
            openAppSettings(result: result)
        case "openInstallPermissionSettings":
            result(unsupported("iOS has no install-permission screen."))
        case "installApk":
            result(unsupported("Installing packages is not supported on iOS."))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Vibration

    /// A short confirmation buzz.
    ///
    /// Uses the classic vibrate system sound, which is a no-op on devices without
    /// a vibrator and respects the system's haptics setting.
    private func vibrate() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    // MARK: - Photo library

    private func saveImageToGallery(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["bytes"] as? FlutterStandardTypedData,
              !data.data.isEmpty,
              let image = UIImage(data: data.data)
        else {
            result(FlutterError(
                code: "saveFailed", message: "No image data was supplied.", details: nil))
            return
        }

        // Add-only access is requested by the system the first time; the app never
        // reads the user's library.
        //
        // `for:` and the `.limited` status both arrived in iOS 14, and this plugin
        // declares iOS 13, so the older API is used below that. It has no add-only
        // variant, and asking for add-or-read access is the closest equivalent a
        // save can use.
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                self.writeToLibrary(
                    image,
                    granted: status == .authorized || status == .limited,
                    result: result)
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                self.writeToLibrary(
                    image, granted: status == .authorized, result: result)
            }
        }
    }

    /// Writes the image once access has been settled, whatever route granted it.
    private func writeToLibrary(
        _ image: UIImage, granted: Bool, result: @escaping FlutterResult
    ) {
        guard granted else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "permissionDenied",
                    message: "Photo library access was denied.", details: nil))
            }
            return
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    result(nil)
                } else {
                    result(FlutterError(
                        code: "saveFailed",
                        message: error?.localizedDescription
                            ?? "The image could not be saved.",
                        details: nil))
                }
            }
        }
    }

    // MARK: - Settings

    private func openAppSettings(result: @escaping FlutterResult) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            result(FlutterError(
                code: "unsupported", message: "The settings URL is unavailable.", details: nil))
            return
        }

        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened {
                    result(nil)
                } else {
                    result(FlutterError(
                        code: "unsupported",
                        message: "The settings app could not be opened.",
                        details: nil))
                }
            }
        }
    }

    private func unsupported(_ message: String) -> FlutterError {
        FlutterError(code: "unsupported", message: message, details: nil)
    }
}
