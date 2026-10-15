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
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
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
import com.king.wechat.qrcode.DecodeResult
import com.king.wechat.qrcode.scanning.analyze.WeChatScanningAnalyzer
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Full-bleed camera preview that runs the WeChatQRCode frame analysis.
 *
 * Deliberately mirrors the reference project's own frame path: the analysis is
 * performed by [WeChatScanningAnalyzer] — the `wechat-qrcode-scanning` module's
 * NV21 conversion, rotation handling and detector call — rather than a
 * reimplementation. Only the plumbing around it (CameraX binding, pausing,
 * torch, lifecycle) is written here, because the reference scanning UI is
 * Activity-based and cannot host a Flutter platform view.
 *
 * Threading: CameraX delivers frames on a single-threaded executor.
 * [WeChatScanningAnalyzer] analyses synchronously and drops frames it cannot
 * keep up with, so at most one decode is ever in flight and results arrive in
 * order. Results are posted to the main thread, where the event channel lives.
 */
internal class ScannerPlatformView(
    private val context: Context,
    private val controller: ScannerController,
) : PlatformView {

    private val previewView = PreviewView(context).apply {
        // Fill the viewport without letterboxing; the spec wants the preview to
        // cover the page (project spec §6.1).
        scaleType = PreviewView.ScaleType.FILL_CENTER
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    }

    private val lifecycleOwner = ScannerLifecycleOwner()
    private val lifecycleRegistry: LifecycleRegistry get() = lifecycleOwner.registry

    private val analysisExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "wechat-qrcode-analysis")
        }

    private val analyzer: WeChatScanningAnalyzer = WeChatScanningAnalyzer()

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var isBound = false
    private var isAnalyzing = false
    private var disposed = false

    override fun getView(): View = previewView

    override fun dispose() {
        disposed = true
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
            if (texts.isNotEmpty()) {
                controller.onDecoded(texts)
            }
        }

        override fun onFailure(e: Exception?) {
            // "No QR code in this frame" is the common case and is reported as a
            // failure by the analyzer; it is not an error worth surfacing.
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
    }
}
