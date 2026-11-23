package com.codedbykay.tvsaver

import android.os.Build
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

    override fun onDestroy() {
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
