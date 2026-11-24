package com.codedbykay.tvsaver

import android.content.Context
import androidx.core.content.FileProvider
import java.io.File
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var videoSpike: VideoSpike? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Story 1-2 video-path spike: MediaCodecList / display reads and a
        // Media3 SurfaceView player (see VideoSpike.kt).
        val videoChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvsaver/video")
        // Story 3-4: the item the TV was playing for the Pi reached its end.
        val spike = VideoSpike(this) { videoChannel.invokeMethod("m3Ended", null) }
        videoSpike = spike
        flutterEngine.platformViewsController.registry
            .registerViewFactory("tvsaver/media3view", spike.factory())
        flutterEngine.platformViewsController.registry
            .registerViewFactory("tvsaver/imageview", spike.imageFactory())
        videoChannel.setMethodCallHandler(spike::onMethodCall)

        // Phone app: reference-counted Wi-Fi multicast lock for mDNS, and a
        // shortcut to this app's settings page (camera permission).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvsaver/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            multicastLock().acquire()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("multicast", e.message, null)
                        }
                    }
                    "release" -> {
                        try {
                            val lock = multicastLock()
                            if (lock.isHeld) lock.release()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("multicast", e.message, null)
                        }
                    }
                    "openSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                    .setData(Uri.fromParts("package", packageName, null))
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("settings", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Story 6-1: the TV app installs its own update from the app cache.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvsaver/installer")
            .setMethodCallHandler { call, result ->
                if (call.method != "install") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = call.argument<String>("path")
                    val file = path?.let { File(it) }
                    if (file == null ||
                        !file.canonicalPath.startsWith(cacheDir.canonicalPath + File.separator) ||
                        !file.exists()
                    ) {
                        result.error("bad_path", "The update file is not in the app's cache", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                        // The system screen where the person allows this app to
                        // install apps; nothing is changed from here.
                        try {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        } catch (_: Exception) {
                            // No such screen on this TV: Dart still shows the help text.
                        }
                        result.success("needs_permission")
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                    startActivity(
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success("started")
                } catch (e: Exception) {
                    result.error("install_failed", e.message ?: "Could not start the installer", null)
                }
            }

        // Free space of the volume a path is on, so the TV cache leaves the
        // TV its own room.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvsaver/storage")
            .setMethodCallHandler { call, result ->
                if (call.method != "freeBytes") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = call.argument<String>("path")
                    result.success(if (path == null) null else android.os.StatFs(path).availableBytes)
                } catch (e: Exception) {
                    result.success(null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvsaver/display")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // The panel's true size. `Display.getMode()` reports the
                    // native display mode, which a `wm size` override does not
                    // change (unlike the display's logical size).
                    "panelSize" -> {
                        val mode = currentDisplay()?.mode
                        if (mode == null) {
                            result.error("no_display", "No display available", null)
                        } else {
                            result.success(
                                mapOf(
                                    "width" to mode.physicalWidth,
                                    "height" to mode.physicalHeight,
                                )
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private var multicast: WifiManager.MulticastLock? = null

    private fun multicastLock(): WifiManager.MulticastLock {
        multicast?.let { return it }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        return wifi.createMulticastLock("tvsaver-mdns").also {
            it.setReferenceCounted(true)
            multicast = it
        }
    }

    override fun onDestroy() {
        multicast?.let { while (it.isHeld) it.release() }
        videoSpike?.dispose()
        super.onDestroy()
    }

    private fun currentDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        }
}
