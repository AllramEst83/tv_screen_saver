package com.codedbykay.tvsaver

import android.os.Build
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

    private fun currentDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        }
}
