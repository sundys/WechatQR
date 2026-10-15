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

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Point
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.king.camera.scan.AnalyzeResult
import com.king.camera.scan.analyze.Analyzer
import com.king.view.viewfinderview.ViewfinderView
import com.king.wechat.qrcode.DecodeResult
import com.king.wechat.qrcode.scanning.analyze.WeChatScanningAnalyzer
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Full-bleed camera preview that runs the WeChatQRCode frame analysis.
 *
 * The preview is covered by the reference project's own `ViewfinderView`,
 * which draws the scanning frame and the animated laser line. Result
 * indicators are drawn by the Flutter layer instead of
 * `ViewfinderView.showResultPoints`: the 3-second "tap a code to pick it"
 * interaction lives in Dart, and keeping the indicators in the same layer as
 * the tap handling avoids splitting one gesture path across two frameworks.
 *
 * The analysis itself is still performed by [WeChatScanningAnalyzer] — the
 * `wechat-qrcode-scanning` module's NV21 conversion, rotation handling and
 * detector call — not a reimplementation.
 */
internal class ScannerPlatformView(
    private val context: Context,
    private val controller: ScannerController,
) : PlatformView {

    private val container = FrameLayout(context)

    private val previewView = PreviewView(context).apply {
        // Fill the viewport without letterboxing; the spec wants the preview to
        // cover the page (project spec §6.1).
        scaleType = PreviewView.ScaleType.FILL_CENTER
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    }

    private val viewfinderView = ViewfinderView(context).apply {
        layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER,
        )
        // Drawn over the preview as pure decoration. It must not take touches
        // away from the Flutter layer that sits above it.
        isClickable = false
        isFocusable = false
    }

    init {
        container.addView(
            previewView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        container.addView(viewfinderView)
    }

    private val lifecycleOwner = ScannerLifecycleOwner()
    private val lifecycleRegistry: LifecycleRegistry get() = lifecycleOwner.registry

    private val analysisExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "wechat-qrcode-analysis")
        }

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Vertex output is enabled so each decoded code can be located on screen and
     * given an indicator.
     */
    private val analyzer: WeChatScanningAnalyzer = WeChatScanningAnalyzer(true)

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var isBound = false
    private var isAnalyzing = false
    private var disposed = false

    /**
     * Re-triggers autofocus on a timer.
     *
     * CameraX starts with continuous AF, but on several Android builds (and on
     * some Chinese vendor ROMs in particular) that mode can settle at
     * infinity and stay there, leaving the preview permanently soft. Asking for
     * AF periodically is what actually keeps a code in focus.
     */
    private val autoFocusRunnable = object : Runnable {
        override fun run() {
            requestAutoFocus()
            if (!disposed) {
                mainHandler.postDelayed(this, AUTO_FOCUS_INTERVAL_MS)
            }
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        disposed = true
        mainHandler.removeCallbacks(autoFocusRunnable)
        controller.detach(this)
        unbindCamera()
        analysisExecutor.shutdown()
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
    }

    /** Binds the camera and starts delivering preview frames. */
    @SuppressLint("MissingPermission") // The plugin requests and verifies CAMERA first.
    fun start() {
        if (disposed || isBound) {
            return
        }
        isBound = true

        val future = ProcessCameraProvider.getInstance(context)
        future.addListener(
            {
                if (disposed) {
                    return@addListener
                }
                try {
                    val provider = future.get()
                    cameraProvider = provider

                    val preview = Preview.Builder()
                        .build()
                        .also { it.surfaceProvider = previewView.surfaceProvider }

                    val analysis = ImageAnalysis.Builder()
                        // Decoding is heavier than preview, so let CameraX drop
                        // frames instead of queueing them — this is what keeps
                        // memory flat and the UI responsive (project spec §9.2).
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        .setResolutionSelector(
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        Size(ANALYSIS_WIDTH, ANALYSIS_HEIGHT),
                                        ResolutionStrategy
                                            .FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                    ),
                                )
                                .build(),
                        )
                        .build()

                    imageAnalysis = analysis

                    provider.unbindAll()
                    camera = provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analysis,
                    )

                    setAnalyzing(!controller.isPaused)
                    mainHandler.postDelayed(autoFocusRunnable, AUTO_FOCUS_INTERVAL_MS)
                } catch (e: Exception) {
                    isBound = false
                    controller.onCameraError(
                        "cameraUnavailable",
                        "The camera could not be started: ${e.message}",
                    )
                }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    /** Releases the camera. */
    fun stop() {
        if (!isBound) {
            return
        }
        setAnalyzing(false)
        mainHandler.removeCallbacks(autoFocusRunnable)
        unbindCamera()
    }

    /**
     * Attaches or clears the CameraX analyzer.
     *
     * Clearing the analyzer is how the analysis loop is paused while a result is
     * on screen: the preview keeps running and the camera stays open, but no
     * frames reach the decoder (project spec §6.1). Calling this before the
     * camera is bound is harmless.
     */
    fun setAnalyzing(enabled: Boolean) {
        val analysis = imageAnalysis ?: return
        if (enabled == isAnalyzing) {
            return
        }
        isAnalyzing = enabled

        if (!enabled) {
            analysis.clearAnalyzer()
            return
        }

        analysis.setAnalyzer(analysisExecutor) { imageProxy ->
            try {
                analyzer.analyze(imageProxy, analyzeListener)
            } catch (e: Exception) {
                // A malformed frame must never kill the analysis thread.
                controller.onCameraError(
                    "decodeFailed",
                    "Frame analysis failed: ${e.message}",
                )
            } finally {
                // CameraX requires every image to be closed or the pipeline
                // stalls after a handful of frames.
                imageProxy.close()
            }
        }
    }

    private val analyzeListener = object : Analyzer.OnAnalyzeListener<DecodeResult> {
        override fun onSuccess(result: AnalyzeResult<DecodeResult>) {
            val texts = result.result.texts
            if (texts.isEmpty()) {
                return
            }

            // Vertices arrive as four consecutive points per code, in image
            // coordinates. The engine does not guarantee one quad per decoded
            // text, so a code without a quad simply gets no indicator rather
            // than a misplaced one.
            val quads = result.result.getVertexPoints().chunked(4)
            val viewWidth = previewView.width
            val viewHeight = previewView.height

            val codes = texts.mapIndexed { index, text ->
                val quad = quads.getOrNull(index)?.takeIf { it.size == 4 }
                if (quad == null || viewWidth <= 0 || viewHeight <= 0) {
                    DecodedCode(text, null, null)
                } else {
                    val centreX = quad.sumOf { it.x } / 4.0
                    val centreY = quad.sumOf { it.y } / 4.0
                    val normalised = normaliseToView(
                        centreX,
                        centreY,
                        result.imageWidth,
                        result.imageHeight,
                        viewWidth,
                        viewHeight,
                    )
                    DecodedCode(text, normalised.first, normalised.second)
                }
            }

            controller.onDecoded(codes)
        }

        override fun onFailure(e: Exception?) {
            // "No QR code in this frame" is the common case and is reported as a
            // failure by the analyzer; it is not an error worth surfacing.
        }
    }

    /**
     * Maps a point in the (already rotated) analysis image to normalised
     * coordinates within the preview view.
     *
     * The preview uses `FILL_CENTER`, so the image is scaled to cover the view
     * and then centre-cropped; the crop offsets have to be removed or every
     * indicator is displaced. The result is expressed as a fraction of the view
     * so the Flutter layer can position indicators without duplicating any of
     * this.
     */
    private fun normaliseToView(
        pointX: Double,
        pointY: Double,
        imageWidth: Int,
        imageHeight: Int,
        viewWidth: Int,
        viewHeight: Int,
    ): Pair<Double, Double> {
        if (imageWidth <= 0 || imageHeight <= 0) {
            return Pair(0.5, 0.5)
        }
        val scale = maxOf(
            viewWidth.toDouble() / imageWidth,
            viewHeight.toDouble() / imageHeight,
        )
        val offsetX = (imageWidth * scale - viewWidth) / 2.0
        val offsetY = (imageHeight * scale - viewHeight) / 2.0

        val x = (pointX * scale - offsetX) / viewWidth
        val y = (pointY * scale - offsetY) / viewHeight
        return Pair(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0))
    }

    /** Asks the camera to re-focus on the centre of the preview. */
    private fun requestAutoFocus() {
        val control = camera?.cameraControl ?: return
        if (previewView.width <= 0 || previewView.height <= 0) {
            return
        }
        try {
            val point = previewView.meteringPointFactory.createPoint(
                previewView.width / 2f,
                previewView.height / 2f,
            )
            val action = FocusMeteringAction
                .Builder(point, FocusMeteringAction.FLAG_AF)
                .setAutoCancelDuration(2, TimeUnit.SECONDS)
                .build()
            control.startFocusAndMetering(action)
        } catch (e: Exception) {
            // A camera that refuses metering is not worth surfacing; the
            // preview still works with whatever focus mode the device chose.
        }
    }

    /** Enables or disables the torch. No-op on devices without one. */
    fun setTorch(enabled: Boolean) {
        val control = camera?.cameraControl ?: return
        try {
            control.enableTorch(enabled)
        } catch (e: Exception) {
            // Some devices expose a torch that cannot be toggled while previewing.
        }
    }

    private fun unbindCamera() {
        isBound = false
        isAnalyzing = false
        camera = null
        imageAnalysis = null
        try {
            cameraProvider?.unbindAll()
        } catch (e: Exception) {
            // Provider already shut down.
        }
    }

    /**
     * Minimal [LifecycleOwner] so CameraX can bind without the host Activity's
     * lifecycle. The registry is held RESUMED for the view's lifetime and the
     * camera is attached/detached explicitly by [start]/[stop], which gives the
     * app precise control over when the camera is open (project spec §4.6).
     */
    private class ScannerLifecycleOwner : LifecycleOwner {
        val registry = LifecycleRegistry(this)

        override val lifecycle: Lifecycle get() = registry

        init {
            registry.currentState = Lifecycle.State.RESUMED
        }
    }

    private companion object {
        /**
         * Analysis resolution. High enough to resolve dense QR codes at arm's
         * length, low enough to keep per-frame decoding fast.
         */
        const val ANALYSIS_WIDTH = 1280
        const val ANALYSIS_HEIGHT = 720

        /** How often autofocus is re-triggered while scanning. */
        const val AUTO_FOCUS_INTERVAL_MS = 2500L
    }
}
