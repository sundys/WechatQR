/*
 * Copyright (C) 2021 Jenly Yu (https://github.com/jenly1314)
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
 *
 * ---------------------------------------------------------------------------
 * Vendored from jenly1314/WeChatQRCode 2.6.0, module `wechat-qrcode`,
 * file `WeChatQRCodeDetector.kt`. See docs/decisions/0004-engine-integration.md.
 *
 * MODIFIED for this project (Apache-2.0 §4(b) notice of changed files):
 *
 *  1. `init` now reports failure instead of swallowing it. Upstream caught every
 *     exception and logged it, leaving a `lateinit` detector uninitialised so the
 *     next call crashed with `UninitializedPropertyAccessException`; callers had
 *     no way to show a retryable error (project spec §9.2).
 *  2. Models are extracted into the app's *internal* `filesDir` rather than
 *     `getExternalFilesDirs`. External storage can be absent or read-only, and
 *     the models are private to the app.
 *  3. `init` is `@Synchronized` and idempotent, so concurrent or repeated calls
 *     reuse one detector instead of racing to reload the models (§9.2).
 *  4. The OpenCV native library is loaded explicitly. Upstream never did this —
 *     it relied on the host app calling it first — so `init` is self-contained.
 *  5. Streams are closed with `use {}` so a failure part-way through model
 *     extraction cannot leak file handles.
 *
 * The detection API (`detectAndDecode`, `detectAndDecodeResult`, `scaleFactor`)
 * is unchanged from upstream.
 */
package com.king.wechat.qrcode

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.wechat_qrcode.WeChatQRCode
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * 微信二维码检测器 — WeChat QR code detector.
 *
 * Wraps OpenCV's `cv::wechat_qrcode::WeChatQRCode`, which combines a CNN
 * detector with a super-resolution model. The detector instance is created once
 * and reused for every frame (project spec §9.2).
 *
 * @author <a href="mailto:jenly1314@gmail.com">Jenly</a>
 * <p>
 * <a href="https://github.com/jenly1314">Follow me</a>
 */
object WeChatQRCodeDetector {

    private const val TAG = "WeChatQRCodeDetector"

    private const val MODEL_DIR = "models"
    private const val DETECT_PROTO_TXT = "detect.prototxt"
    private const val DETECT_CAFFE_MODEL = "detect.caffemodel"
    private const val SR_PROTO_TXT = "sr.prototxt"
    private const val SR_CAFFE_MODEL = "sr.caffemodel"

    private val MODEL_FILES = arrayOf(
        DETECT_PROTO_TXT,
        DETECT_CAFFE_MODEL,
        SR_PROTO_TXT,
        SR_CAFFE_MODEL,
    )

    /** The shared detector. `null` until [init] succeeds. */
    @Volatile
    private var weChatQRCode: WeChatQRCode? = null

    /** `true` once the models are loaded and the detector is usable. */
    @JvmStatic
    val isInitialized: Boolean
        get() = weChatQRCode != null

    /**
     * 初始化 Initialize the engine.
     *
     * Loads the OpenCV native library, extracts the four model files if needed
     * and builds the detector. Safe to call repeatedly; the detector is built
     * only once.
     *
     * @param context [Context]
     * @return the shared detector instance.
     * @throws QrEngineInitException when OpenCV, the model files, or the
     * detector could not be initialised. The failing step is described in the
     * exception message so the UI can offer a retry.
     */
    @JvmStatic
    @Synchronized
    @Throws(QrEngineInitException::class)
    fun init(context: Context): WeChatQRCode {
        weChatQRCode?.let { return it }

        if (!OpenCVLoader.initLocal()) {
            throw QrEngineInitException(
                "The OpenCV native library (libopencv_java4.so) could not be loaded " +
                    "for this device ABI.",
            )
        }

        val modelDir = File(context.applicationContext.filesDir, MODEL_DIR)
        try {
            ensureModelsExtracted(context, modelDir)
        } catch (e: IOException) {
            throw QrEngineInitException(
                "The QR detection models could not be extracted to ${modelDir.absolutePath}.",
                e,
            )
        }

        val detector = try {
            WeChatQRCode(
                File(modelDir, DETECT_PROTO_TXT).absolutePath,
                File(modelDir, DETECT_CAFFE_MODEL).absolutePath,
                File(modelDir, SR_PROTO_TXT).absolutePath,
                File(modelDir, SR_CAFFE_MODEL).absolutePath,
            )
        } catch (e: Throwable) {
            throw QrEngineInitException(
                "OpenCV rejected the QR detection models; they may be corrupt.",
                e,
            )
        }

        weChatQRCode = detector
        Log.d(TAG, "WeChatQRCode detector initialised")
        return detector
    }

    /**
     * 释放资源 Releases the native detector.
     *
     * The instance must be re-initialised before it can be used again.
     */
    @JvmStatic
    @Synchronized
    fun release() {
        weChatQRCode = null
    }

    /**
     * Copies the bundled models into [targetDir] when any of them is missing.
     *
     * A partially present directory is treated as incomplete and refilled, so a
     * previous interrupted extraction cannot leave the detector with bad models.
     */
    private fun ensureModelsExtracted(context: Context, targetDir: File) {
        val complete = targetDir.isDirectory &&
            MODEL_FILES.all { File(targetDir, it).length() > 0L }
        if (complete) {
            return
        }

        if (!targetDir.exists() && !targetDir.mkdirs()) {
            throw IOException("Could not create ${targetDir.absolutePath}")
        }

        for (model in MODEL_FILES) {
            val target = File(targetDir, model)
            context.assets.open("$MODEL_DIR/$model").use { input ->
                FileOutputStream(target).use { output ->
                    input.copyTo(output, DEFAULT_BUFFER_SIZE)
                    output.flush()
                }
            }
        }
        Log.d(TAG, "Models extracted to ${targetDir.absolutePath}")
    }

    /**
     * set scale factor
     * QR code detector use neural network to detect QR.
     * Before running the neural network, the input image is pre-processed by scaling.
     * By default, the input image is scaled to an image with an area of 160000 pixels.
     * The scale factor allows to use custom scale the input image:
     * width = scaleFactor*width
     * height = scaleFactor*width
     * <p>
     * scaleFactor values must be &gt; 0 and &lt;= 1, otherwise the scaleFactor value
     * is set to -1 and use default scaled to an image with an area of 160000 pixels.
     *
     * @param scalingFactor automatically generated
     */
    @JvmStatic
    fun setScaleFactor(scalingFactor: Float) {
        requireDetector().scaleFactor = scalingFactor
    }

    /**
     * get scale factor
     */
    @JvmStatic
    fun getScaleFactor(): Float {
        return requireDetector().scaleFactor
    }

    /**
     * Both detects and decodes QR code.
     *
     * @param bitmap [Bitmap]
     * @return list of decoded string.
     */
    @JvmStatic
    fun detectAndDecode(bitmap: Bitmap): List<String> {
        return detectAndDecodeResult(bitmap).texts
    }

    /**
     * Both detects and decodes QR code.
     *
     * @param bitmap [Bitmap]
     * @param points optional output array of vertices of the found QR code quadrangle.
     *               Will be empty if not found.
     * @return list of decoded string.
     */
    @JvmStatic
    fun detectAndDecode(bitmap: Bitmap, points: MutableList<Mat>): List<String> {
        return detectAndDecodeResult(bitmap, true, points).texts
    }

    /**
     * Both detects and decodes QR code, and returns [DecodeResult] directly.
     *
     * @param bitmap [Bitmap]
     * @param isOutputVertices whether to output QR code vertices
     * @return [DecodeResult]
     */
    @JvmOverloads
    @JvmStatic
    fun detectAndDecodeResult(
        bitmap: Bitmap,
        isOutputVertices: Boolean = false,
        points: MutableList<Mat>? = null,
    ): DecodeResult {
        val mat = Mat()
        try {
            Utils.bitmapToMat(bitmap, mat)
            return detectAndDecodeResult(mat, isOutputVertices, points)
        } finally {
            mat.release()
        }
    }

    /**
     * Both detects and decodes QR code.
     *
     * @param img supports grayscale or color (BGR) image.
     * @return list of decoded string. Empty if not found.
     */
    @JvmStatic
    fun detectAndDecode(img: Mat): List<String> {
        return detectAndDecodeResult(img).texts
    }

    /**
     * Both detects and decodes QR code.
     *
     * @param img    supports grayscale or color (BGR) image.
     * @param points optional output array of vertices of the found QR code quadrangle.
     * @return list of decoded string.
     */
    @JvmStatic
    fun detectAndDecode(img: Mat, points: MutableList<Mat>): List<String> {
        return detectAndDecodeResult(img, true, points).texts
    }

    /**
     * Both detects and decodes QR code, and returns [DecodeResult] directly.
     *
     * @param img supports grayscale or color (BGR) image.
     * @param isOutputVertices whether to output QR code vertices
     * @return [DecodeResult]
     */
    @JvmOverloads
    @JvmStatic
    fun detectAndDecodeResult(
        img: Mat,
        isOutputVertices: Boolean = false,
        points: MutableList<Mat>? = null,
    ): DecodeResult {
        val detector = requireDetector()
        return if (isOutputVertices) {
            val vertexPoints = points ?: ArrayList()
            DecodeResult(detector.detectAndDecode(img, vertexPoints), vertexPoints)
        } else {
            DecodeResult(detector.detectAndDecode(img), null)
        }
    }

    private fun requireDetector(): WeChatQRCode {
        return weChatQRCode ?: throw QrEngineInitException(
            "WeChatQRCodeDetector.init() must complete before the detector can be used.",
        )
    }
}

/**
 * Raised when the QR engine cannot be initialised.
 *
 * Distinct from a decode failure: the caller can offer a retry, and maps this to
 * the plugin's `modelLoadFailed` error code.
 */
class QrEngineInitException(message: String, cause: Throwable? = null) :
    Exception(message, cause)
