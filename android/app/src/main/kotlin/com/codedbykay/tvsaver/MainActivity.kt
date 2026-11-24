package com.codedbykay.tvsaver

import android.content.Context
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
        val spike = VideoSpike(this)
        videoSpike = spike
        flutterEngine.platformViewsController.registry
            .registerViewFactory("tvsaver/media3view", spike.factory())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvsaver/video")
            .setMethodCallHandler(spike::onMethodCall)

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
