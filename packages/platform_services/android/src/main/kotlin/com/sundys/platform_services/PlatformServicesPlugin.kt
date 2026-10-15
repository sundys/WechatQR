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
package com.sundys.platform_services

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Android implementations of the platform capabilities the shared Flutter layer
 * needs.
 *
 * Everything runs against the application context and starts system screens with
 * `FLAG_ACTIVITY_NEW_TASK`, so no Activity plumbing is required. Nothing here
 * installs or grants anything silently: the installer and the settings screens
 * are always the OS's own.
 */
class PlatformServicesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var context: Context
    private lateinit var channel: MethodChannel

    /** File writes and gallery inserts stay off the UI thread (project spec §4.5). */
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "platform-services")
    }

    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "vibrate" -> {
                vibrate()
                result.success(null)
            }
            "canInstallPackages" -> result.success(canInstallPackages())
            "saveImageToGallery" -> saveImageToGallery(call, result)
            "openInstallPermissionSettings" -> runOrReport(result) {
                openInstallPermissionSettings()
            }
            "openAppSettings" -> runOrReport(result) { openAppSettings() }
            "installApk" -> runOrReport(result) {
                installApk(call.argument<String>("path"))
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- vibration

    /**
     * A short confirmation buzz.
     *
     * Devices without a vibrator, or with vibration disabled system-wide, do
     * nothing at all — the caller treats silence as success (project spec §6.2).
     */
    private fun vibrate() {
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }

        if (vibrator == null || !vibrator.hasVibrator()) {
            return
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createOneShot(
                        VIBRATION_MILLIS,
                        VibrationEffect.DEFAULT_AMPLITUDE,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(VIBRATION_MILLIS)
            }
        } catch (e: Exception) {
            // Some OEM builds throw when vibration is disabled in settings.
        }
    }

    // ------------------------------------------------------------- gallery

    private fun saveImageToGallery(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = call.argument<String>("fileName")
        if (bytes == null || bytes.isEmpty() || fileName.isNullOrEmpty()) {
            result.error(SAVE_FAILED, "No image data was supplied.", null)
            return
        }

        executor.execute {
            try {
                writeToGallery(bytes, sanitize(fileName))
                mainHandler.post { result.success(null) }
            } catch (e: PlatformServiceException) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(SAVE_FAILED, "The image could not be saved: ${e.message}", null)
                }
            }
        }
    }

    private fun writeToGallery(bytes: ByteArray, fileName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            writeViaMediaStore(bytes, fileName)
            return
        }
        writeViaPublicDirectory(bytes, fileName)
    }

    /**
     * Android 10+: insert through MediaStore, which needs no storage permission
     * and keeps the image owned by the gallery rather than the app.
     */
    private fun writeViaMediaStore(bytes: ByteArray, fileName: String) {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, MIME_PNG)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}/$ALBUM_NAME",
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }

        val uri: Uri = resolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            values,
        ) ?: throw PlatformServiceException(SAVE_FAILED, "MediaStore rejected the image.")

        try {
            resolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw PlatformServiceException(SAVE_FAILED, "The image stream could not be opened.")

            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            // Never leave a half-written, pending entry behind.
            resolver.delete(uri, null, null)
            throw e
        }
    }

    /**
     * Android 9 and below: write into the public Pictures directory.
     *
     * This path needs WRITE_EXTERNAL_STORAGE, which is declared with
     * `maxSdkVersion="28"`. If the user has not granted it, the caller is told
     * the save failed for a permission reason rather than being silently
     * ignored.
     */
    private fun writeViaPublicDirectory(bytes: ByteArray, fileName: String) {
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED

        if (!granted) {
            throw PlatformServiceException(
                PERMISSION_DENIED,
                "Storage permission is required to save on this Android version.",
            )
        }

        @Suppress("DEPRECATION")
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            ALBUM_NAME,
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw PlatformServiceException(SAVE_FAILED, "The Pictures directory is unavailable.")
        }

        val file = File(directory, fileName)
        FileOutputStream(file).use { output ->
            output.write(bytes)
            output.flush()
        }

        // Make the new file visible to gallery apps immediately.
        MediaScannerConnection.scanFile(
            context,
            arrayOf(file.absolutePath),
            arrayOf(MIME_PNG),
            null,
        )
    }

    // ------------------------------------------------------------- installer

    /**
     * Whether the OS will let this app launch the package installer.
     *
     * Android 8 introduced the per-app "install unknown apps" grant; before that
     * there was no such gate. Nothing is granted here — the user does that in
     * system settings (project spec §3.1).
     */
    private fun canInstallPackages(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openInstallPermissionSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            )
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        startSystemScreen(intent)
    }

    private fun openAppSettings() {
        startSystemScreen(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            ),
        )
    }

    /**
     * Hands a downloaded APK to the system installer.
     *
     * The file must live inside the app's private `updates` directory, which is
     * the only path the FileProvider exposes — that check is what stops an
     * arbitrary path from being handed to the installer.
     */
    private fun installApk(path: String?) {
        if (path.isNullOrEmpty()) {
            throw PlatformServiceException(FILE_NOT_FOUND, "No package path was supplied.")
        }

        val file = File(path)
        if (!file.exists() || !file.isFile) {
            throw PlatformServiceException(FILE_NOT_FOUND, "The update package is missing.")
        }

        val updatesRoot = File(context.filesDir, UPDATES_DIRECTORY).canonicalFile
        val canonical = file.canonicalFile
        if (!canonical.path.startsWith(updatesRoot.path + File.separator)) {
            throw PlatformServiceException(
                INSTALL_FAILED,
                "Only packages in the app's update directory can be installed.",
            )
        }

        val uri = try {
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", canonical)
        } catch (e: IllegalArgumentException) {
            throw PlatformServiceException(INSTALL_FAILED, "The package could not be shared.")
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startSystemScreen(intent)
    }

    // ------------------------------------------------------------- helpers

    private fun startSystemScreen(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw PlatformServiceException(INSTALL_FAILED, "No system screen handled the request.")
        }
    }

    private fun runOrReport(result: MethodChannel.Result, action: () -> Unit) {
        try {
            action()
            result.success(null)
        } catch (e: PlatformServiceException) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            result.error(INSTALL_FAILED, e.message ?: "The request failed.", null)
        }
    }

    private fun sanitize(fileName: String): String {
        val base = fileName.substringAfterLast('/').substringAfterLast('\\').trim()
        return base.ifEmpty { "qrcode.png" }
    }

    private class PlatformServiceException(val code: String, message: String) :
        Exception(message)

    private companion object {
        const val CHANNEL = "platform_services/methods"

        /** Must match [JsonFileHistoryStore]'s counterpart on the Dart side. */
        const val UPDATES_DIRECTORY = "updates"

        const val ALBUM_NAME = "WeChatQR"
        const val MIME_PNG = "image/png"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"

        const val VIBRATION_MILLIS = 40L

        // Error codes; these string values are part of the Dart contract
        // (PlatformServiceError.name).
        const val PERMISSION_DENIED = "permissionDenied"
        const val SAVE_FAILED = "saveFailed"
        const val FILE_NOT_FOUND = "fileNotFound"
        const val INSTALL_FAILED = "installFailed"
    }
}
