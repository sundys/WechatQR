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

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.king.wechat.qrcode.QrEngineInitException
import com.king.wechat.qrcode.WeChatQRCodeDetector
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.util.concurrent.Executors

/**
 * Android side of the `wechat_qrcode` plugin.
 *
 * Owns three channels and one platform view:
 *  * `wechat_qrcode/methods` — engine lifecycle, image decoding, scan control.
 *  * `wechat_qrcode/events` — decoded payloads, one event per successful frame.
 *  * `wechat_qrcode/scanner` — the full-bleed camera preview.
 *
 * Camera permission is requested here rather than from Dart so the plugin can
 * distinguish "denied" from "permanently denied", which changes what the UI is
 * allowed to offer (project spec §5).
 */
class WeChatQrcodePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private val controller = ScannerController()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Detector calls and image decoding run here, never on the UI thread
     * (project spec §9.3).
     */
    private val workExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "wechat-qrcode-work")
    }

    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingStartResult: MethodChannel.Result? = null
    private var hasRequestedCameraPermission = false

    /**
     * Receives the answer to the camera prompt.
     *
     * `FlutterActivity` extends `android.app.Activity`, **not**
     * `androidx.activity.ComponentActivity`, so
     * `ComponentActivity.registerForActivityResult()` is not available to a
     * plugin. An earlier version of this class cast the activity to
     * `ComponentActivity`; the cast returned null, no launcher was created, and
     * the permission dialog was never requested — the user saw the button do
     * nothing. This listener is the supported path and works with a plain
     * Activity.
     */
    private val permissionListener =
        PluginRegistry.RequestPermissionsResultListener { requestCode, _, grantResults ->
            if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) {
                false
            } else {
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                onCameraPermissionResult(granted)
                true
            }
        }

    // ---------------------------------------------------------------- attaching

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHODS_CHANNEL)
        eventChannel = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, this)

        controller.onResults = { codes ->
            // Each code travels as a map so the Flutter layer knows both what was
            // decoded and where it was, which is what positions the indicators.
            val payload = codes.map { code ->
                mapOf<String, Any?>(
                    "text" to code.text,
                    "x" to code.x,
                    "y" to code.y,
                )
            }
            mainHandler.post { eventSink?.success(payload) }
        }
        controller.onError = { code, message ->
            mainHandler.post { eventSink?.error(code, message, null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        controller.onResults = null
        controller.onError = null
        eventSink = null
        workExecutor.shutdown()
    }

    // ------------------------------------------------------------- event channel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ------------------------------------------------------------ platform view

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return ScannerPlatformView(context, controller).also { controller.attach(it) }
    }

    // ---------------------------------------------------------------- activity

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onDetachedFromActivity() = detachActivity()

    private fun attachActivity(binding: ActivityPluginBinding) {
        detachActivity()
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionListener)
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionListener)
        activityBinding = null
        activity = null
        val pending = pendingStartResult
        pendingStartResult = null
        pending?.error(
            CAMERA_UNAVAILABLE,
            "The activity went away before the camera permission was answered.",
            null,
        )
    }

    // ------------------------------------------------------------ method calls

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(result)
            "decodeImageFile" -> decodeImageFile(call.argument<String>("path"), result)
            "startScanning" -> startScanning(result)
            "hasCameraPermission" -> {
                result.success(hasCameraPermission(context))
            }
            "stopScanning" -> {
                controller.stopScanning()
                result.success(null)
            }
            "pauseScanning" -> {
                controller.pauseScanning()
                result.success(null)
            }
            "resumeScanning" -> {
                controller.resumeScanning()
                result.success(null)
            }
            "capturePreview" -> capturePreview(result)
            "setTorch" -> {
                controller.setTorch(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            "release" -> {
                controller.stopScanning()
                WeChatQRCodeDetector.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Hands Dart a PNG of the frame the last result was decoded from.
     *
     * Always answered, with `null` when there is nothing to hand over: a missing
     * frame costs the caller a frozen picture, not the scan.
     */
    private fun capturePreview(result: MethodChannel.Result) {
        result.success(controller.lastFrame())
    }

    private fun initialize(result: MethodChannel.Result) {
        if (WeChatQRCodeDetector.isInitialized) {
            result.success(null)
            return
        }
        workExecutor.execute {
            try {
                WeChatQRCodeDetector.init(context)
                mainHandler.post { result.success(null) }
            } catch (e: QrEngineInitException) {
                mainHandler.post {
                    result.error(MODEL_LOAD_FAILED, e.message ?: "Engine init failed", null)
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error(
                        MODEL_LOAD_FAILED,
                        "The QR engine failed to start: ${e.message}",
                        null,
                    )
                }
            }
        }
    }

    private fun decodeImageFile(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error(INVALID_IMAGE, "No image path was supplied.", null)
            return
        }
        if (!WeChatQRCodeDetector.isInitialized) {
            result.error(NOT_INITIALIZED, "initialize() has not completed.", null)
            return
        }

        workExecutor.execute {
            var bitmap: Bitmap? = null
            try {
                bitmap = decodeBoundedBitmap(path)
                val texts = WeChatQRCodeDetector.detectAndDecode(bitmap)
                mainHandler.post { result.success(texts) }
            } catch (e: ImageDecodingException) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error(DECODE_FAILED, "Decoding failed: ${e.message}", null)
                }
            } finally {
                bitmap?.recycle()
            }
        }
    }

    private fun startScanning(result: MethodChannel.Result) {
        if (!WeChatQRCodeDetector.isInitialized) {
            result.error(NOT_INITIALIZED, "initialize() has not completed.", null)
            return
        }

        val activity = activity
        if (activity == null) {
            result.error(CAMERA_UNAVAILABLE, "No foreground activity is available.", null)
            return
        }

        if (hasCameraPermission(activity)) {
            controller.startScanning()
            result.success(null)
            return
        }

        if (pendingStartResult != null) {
            // A prompt is already on screen; do not stack a second one.
            result.error(
                CAMERA_PERMISSION_DENIED,
                "A camera permission request is already in progress.",
                null,
            )
            return
        }

        // The reply is deferred until the user answers the system dialog. The
        // request goes through the activity so the dialog is the real system
        // prompt — this is the only thing that can grant the permission.
        pendingStartResult = result
        hasRequestedCameraPermission = true
        try {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.CAMERA),
                CAMERA_PERMISSION_REQUEST_CODE,
            )
        } catch (e: Exception) {
            pendingStartResult = null
            result.error(
                CAMERA_UNAVAILABLE,
                "The camera permission could not be requested: ${e.message}",
                null,
            )
        }
    }

    private fun onCameraPermissionResult(granted: Boolean) {
        val result = pendingStartResult
        pendingStartResult = null

        if (granted) {
            controller.startScanning()
            result?.success(null)
            return
        }

        val activity = activity
        // Only the system can re-prompt once the user has denied and stopped
        // being asked; sending them to Settings is the only useful offer then.
        val permanentlyDenied = hasRequestedCameraPermission &&
            activity != null &&
            !ActivityCompat.shouldShowRequestPermissionRationale(
                activity,
                Manifest.permission.CAMERA,
            )

        result?.error(
            if (permanentlyDenied) CAMERA_PERMISSION_PERMANENTLY_DENIED
            else CAMERA_PERMISSION_DENIED,
            if (permanentlyDenied) {
                "Camera access was permanently denied; it must be enabled in system settings."
            } else {
                "Camera access was denied."
            },
            null,
        )
    }

    private fun hasCameraPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
    }

    /**
     * Decodes an image file, downsampling anything larger than
     * [MAX_IMAGE_DIMENSION] so a very large photo cannot exhaust memory (project
     * spec §6.5).
     *
     * EXIF orientation is intentionally not applied: the decoder tries all four
     * rotations of a QR symbol, so a rotated photo still decodes.
     */
    private fun decodeBoundedBitmap(path: String): Bitmap {
        val file = File(path)
        if (!file.exists() || !file.isFile || file.length() == 0L) {
            throw ImageDecodingException(INVALID_IMAGE, "The image file could not be read.")
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw ImageDecodingException(
                UNSUPPORTED_IMAGE_FORMAT,
                "The image format is not supported.",
            )
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }

        return BitmapFactory.decodeFile(path, options)
            ?: throw ImageDecodingException(
                UNSUPPORTED_IMAGE_FORMAT,
                "The image could not be decoded.",
            )
    }

    private fun sampleSizeFor(width: Int, height: Int): Int {
        var sample = 1
        var longest = maxOf(width, height)
        while (longest / 2 >= MAX_IMAGE_DIMENSION) {
            longest /= 2
            sample *= 2
        }
        return sample
    }

    private class ImageDecodingException(val code: String, message: String) :
        Exception(message)

    private companion object {
        const val METHODS_CHANNEL = "wechat_qrcode/methods"
        const val EVENTS_CHANNEL = "wechat_qrcode/events"
        const val VIEW_TYPE = "wechat_qrcode/scanner"

        /** Longest edge an image is decoded at before detection. */
        const val MAX_IMAGE_DIMENSION = 2400

        /** Arbitrary but unique within this plugin. */
        const val CAMERA_PERMISSION_REQUEST_CODE = 0x5751

        // Error codes; these string values are part of the Dart contract
        // (WeChatQrCodeError.name).
        const val NOT_INITIALIZED = "notInitialized"
        const val MODEL_LOAD_FAILED = "modelLoadFailed"
        const val CAMERA_PERMISSION_DENIED = "cameraPermissionDenied"
        const val CAMERA_PERMISSION_PERMANENTLY_DENIED =
            "cameraPermissionPermanentlyDenied"
        const val CAMERA_UNAVAILABLE = "cameraUnavailable"
        const val INVALID_IMAGE = "invalidImage"
        const val UNSUPPORTED_IMAGE_FORMAT = "unsupportedImageFormat"
        const val DECODE_FAILED = "decodeFailed"
    }
}
