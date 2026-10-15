/*
 * Copyright (C) 2025 WeChatQR project contributors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.sundys.wechat_qrcode

/**
 * One decoded payload, with where it was found.
 *
 * [x] and [y] are the centre of the code normalised to `0.0..1.0` of the preview
 * view, so the Flutter layer can place an indicator without knowing anything
 * about preview scaling. They are `null` when the engine reported no vertices
 * for that code, in which case no indicator is drawn for it.
 */
internal data class DecodedCode(val text: String, val x: Double?, val y: Double?)

/**
 * Shared camera state between the plugin (which answers Dart's method calls) and
 * the [ScannerPlatformView] (which owns the CameraX session).
 *
 * Dart may call `startScanning()` before the platform view exists, or leave the
 * scan page while it does — so the requested state is remembered here and
 * applied whenever a view attaches. That ordering independence is what stops the
 * scan tab from silently doing nothing on a cold start.
 */
internal class ScannerController {

    @Volatile
    private var view: ScannerPlatformView? = null

    /** The user's intent, independent of whether a view is attached yet. */
    @Volatile
    var isScanningRequested: Boolean = false
        private set

    /** Set while a result is on screen and frame analysis must stay suspended. */
    @Volatile
    var isPaused: Boolean = false
        private set

    /** Invoked on the analysis thread; the plugin marshals it to the UI thread. */
    var onResults: ((List<DecodedCode>) -> Unit)? = null

    /** Invoked on the analysis thread; the plugin marshals it to the UI thread. */
    var onError: ((code: String, message: String) -> Unit)? = null

    fun attach(view: ScannerPlatformView) {
        this.view = view
        if (isScanningRequested) {
            view.start()
            view.setAnalyzing(!isPaused)
        }
    }

    fun detach(view: ScannerPlatformView) {
        if (this.view === view) {
            this.view = null
        }
    }

    fun startScanning() {
        isScanningRequested = true
        isPaused = false
        view?.apply {
            start()
            setAnalyzing(true)
        }
    }

    fun stopScanning() {
        isScanningRequested = false
        view?.stop()
    }

    fun pauseScanning() {
        isPaused = true
        view?.setAnalyzing(false)
    }

    fun resumeScanning() {
        isPaused = false
        if (isScanningRequested) {
            view?.setAnalyzing(true)
        }
    }

    fun setTorch(enabled: Boolean) {
        view?.setTorch(enabled)
    }

    /** The frame the last result came from, or null when there is no view. */
    fun lastFrame(): ByteArray? = view?.lastFrame()

    fun onDecoded(codes: List<DecodedCode>) {
        onResults?.invoke(codes)
    }

    fun onCameraError(code: String, message: String) {
        onError?.invoke(code, message)
    }
}
