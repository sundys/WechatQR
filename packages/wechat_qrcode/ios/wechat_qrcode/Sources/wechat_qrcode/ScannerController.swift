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

import Foundation

/// Shared camera state between the plugin (which answers Dart's method calls)
/// and `ScannerPlatformView` (which owns the capture session).
///
/// Mirrors the Android `ScannerController`: Dart may call `startScanning()`
/// before the platform view exists, so the requested state is remembered and
/// applied when a view attaches.
final class ScannerController {

    private let lock = NSLock()

    private weak var view: ScannerPlatformView?

    /// The caller's intent, independent of whether a view is attached yet.
    private(set) var isScanningRequested = false

    /// Set while a result is on screen.
    private(set) var isPaused = false

    /// Invoked on the analysis queue; the plugin marshals it to the main thread.
    var onResults: (([String]) -> Void)?

    /// Invoked on the analysis queue; the plugin marshals it to the main thread.
    var onError: ((String, String) -> Void)?

    func attach(_ view: ScannerPlatformView) {
        lock.lock()
        self.view = view
        let shouldStart = isScanningRequested
        let paused = isPaused
        lock.unlock()

        guard shouldStart else { return }
        view.start()
        view.setAnalyzing(!paused)
    }

    func detach(_ view: ScannerPlatformView) {
        lock.lock()
        if self.view === view {
            self.view = nil
        }
        lock.unlock()
    }

    func startScanning() {
        lock.lock()
        isScanningRequested = true
        isPaused = false
        let view = self.view
        lock.unlock()

        view?.start()
        view?.setAnalyzing(true)
    }

    func stopScanning() {
        lock.lock()
        isScanningRequested = false
        let view = self.view
        lock.unlock()

        view?.stop()
    }

    func pauseScanning() {
        lock.lock()
        isPaused = true
        let view = self.view
        lock.unlock()

        view?.setAnalyzing(false)
    }

    func resumeScanning() {
        lock.lock()
        isPaused = false
        let shouldResume = isScanningRequested
        let view = self.view
        lock.unlock()

        guard shouldResume else { return }
        view?.setAnalyzing(true)
    }

    func setTorch(_ enabled: Bool) {
        lock.lock()
        let view = self.view
        lock.unlock()

        view?.setTorch(enabled)
    }

    func releaseView() {
        lock.lock()
        let view = self.view
        lock.unlock()

        view?.release()
    }

    func onDecoded(_ texts: [String]) {
        onResults?(texts)
    }

    func onCameraError(code: String, message: String) {
        onError?(code, message)
    }
}
