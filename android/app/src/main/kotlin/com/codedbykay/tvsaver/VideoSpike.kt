package com.codedbykay.tvsaver

import android.app.Activity
import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.view.Display
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Story 1-2 spike (video path). Channel `tvsaver/video`:
 *
 *  - `decoders`: MediaCodecList lines (HEVC profiles, AC-3 / E-AC-3).
 *  - `displayInfo`: active display mode, refresh rate, supported modes, HDR types.
 *  - `probe {path}`: container facts read with MediaExtractor (HDR type, fps,
 *    the decoder Android would pick) for clips played through `video_player`.
 *  - `m3Open {path, loop}`, `m3Stats`, `m3Control {action}`: a Media3 ExoPlayer
 *    drawing on a SurfaceView platform view (`tvsaver/media3view`). `video_player`
 *    cannot do a two-item playlist loop or report decoder / dropped frames, so
 *    the loop strategies and the stats come from here. Read-only: nothing here
 *    changes a TV setting.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class VideoSpike(private val activity: Activity) {
    private var surfaceView: SurfaceView? = null
    private var player: ExoPlayer? = null
    private var decoderName: String? = null
    private var droppedFrames = 0
    private var inputFormat: Format? = null
    private var loopMode = "repeatOne"

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            this@VideoSpike.decoderName = decoderName
        }

        override fun onDroppedVideoFrames(
            eventTime: AnalyticsListener.EventTime,
            droppedFrames: Int,
            elapsedMs: Long,
        ) {
            this@VideoSpike.droppedFrames += droppedFrames
        }

        override fun onVideoInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            inputFormat = format
        }
    }

    fun factory(): PlatformViewFactory = object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val view = SurfaceView(context)
            attach(view)
            return object : PlatformView {
                override fun getView(): View = view
                override fun dispose() = detach(view)
            }
        }
    }

    private fun attach(view: SurfaceView) {
        surfaceView = view
        player?.setVideoSurfaceView(view)
    }

    private fun detach(view: SurfaceView) {
        if (surfaceView === view) {
            player?.clearVideoSurfaceView(view)
            surfaceView = null
        }
    }

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "spikeDir" -> result.success(activity.getExternalFilesDir(null)?.absolutePath?.let { "$it/spike" })
                "decoders" -> result.success(decoderLines())
                "displayInfo" -> result.success(displayInfo())
                "probe" -> result.success(probe(call.argument<String>("path")!!))
                "m3Open" -> {
                    m3Open(call.argument<String>("path")!!, call.argument<String>("loop") ?: "repeatOne")
                    result.success(null)
                }
                "m3Stats" -> result.success(m3Stats())
                "m3Control" -> {
                    when (call.argument<String>("action")) {
                        "play" -> player?.play()
                        "pause" -> player?.pause()
                        "release" -> m3Release()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("video_spike", e.message ?: e.javaClass.simpleName, null)
        }
    }

    fun dispose() = m3Release()

    // --- Media3 player on the SurfaceView ---------------------------------

    private fun m3Open(path: String, loop: String) {
        m3Release()
        decoderName = null
        droppedFrames = 0
        inputFormat = null
        loopMode = loop
        val exo = ExoPlayer.Builder(activity).build()
        exo.addAnalyticsListener(analytics)
        val item = MediaItem.fromUri(Uri.fromFile(java.io.File(path)))
        if (loop == "playlist") {
            // Two items of the same clip: the next one is prepared before the
            // current one ends. REPEAT_MODE_ALL keeps the pair going.
            exo.setMediaItems(listOf(item, item))
            exo.repeatMode = Player.REPEAT_MODE_ALL
        } else {
            exo.setMediaItem(item)
            exo.repeatMode = Player.REPEAT_MODE_ONE
        }
        surfaceView?.let { exo.setVideoSurfaceView(it) }
        exo.prepare()
        exo.playWhenReady = true
        player = exo
    }

    private fun m3Release() {
        player?.let {
            it.removeAnalyticsListener(analytics)
            it.release()
        }
        player = null
    }

    private fun m3Stats(): Map<String, Any?> {
        val p = player
        val fmt = p?.videoFormat ?: inputFormat
        return mapOf(
            "playing" to (p?.isPlaying ?: false),
            "state" to p?.playbackState,
            "positionMs" to p?.currentPosition,
            "item" to p?.currentMediaItemIndex,
            "loop" to loopMode,
            "decoder" to decoderName,
            "droppedFrames" to droppedFrames,
            "width" to fmt?.width,
            "height" to fmt?.height,
            "frameRate" to fmt?.frameRate?.takeIf { it > 0f },
            "hdr" to hdrName(fmt),
            "error" to p?.playerError?.let { "${it.errorCodeName}: ${it.message}" },
        )
    }

    // --- Reads ------------------------------------------------------------

    private fun hdrName(fmt: Format?): String {
        if (fmt == null) return "unknown"
        val transfer = fmt.colorInfo?.colorTransfer
        return when {
            fmt.sampleMimeType == "video/dolby-vision" -> "DolbyVision"
            transfer == C.COLOR_TRANSFER_ST2084 -> "HDR10"
            transfer == C.COLOR_TRANSFER_HLG -> "HLG"
            fmt.colorInfo != null -> "SDR"
            else -> "unknown"
        }
    }

    private fun decoderLines(): List<String> {
        val lines = mutableListOf<String>()
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        for (info in infos) {
            if (info.isEncoder) continue
            for (type in info.supportedTypes) {
                val t = type.lowercase()
                if (t != "video/hevc" && t != "audio/ac3" && t != "audio/eac3" && t != "audio/eac3-joc") continue
                val caps = info.getCapabilitiesForType(type)
                val hw = if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated else null
                val detail = if (t == "video/hevc") {
                    val profiles = caps.profileLevels.map { it.profile }.distinct().sorted()
                        .joinToString(",") { hevcProfileName(it) }
                    val vc = caps.videoCapabilities
                    val max = vc?.let { "${it.supportedWidths.upper}x${it.supportedHeights.upper}" }
                    "profiles=[$profiles] max=$max"
                } else {
                    "channels<=${caps.audioCapabilities?.maxInputChannelCount}"
                }
                lines.add("${info.name} $type hw=$hw $detail")
            }
        }
        return lines
    }

    private fun hevcProfileName(p: Int): String = when (p) {
        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain -> "Main"
        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 -> "Main10"
        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10 -> "Main10HDR10"
        MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus -> "Main10HDR10Plus"
        MediaCodecInfo.CodecProfileLevel.HEVCProfileMainStill -> "MainStill"
        else -> "p$p"
    }

    private fun currentDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay
        }

    private fun displayInfo(): Map<String, Any?> {
        val d = currentDisplay() ?: return mapOf("error" to "no display")
        val mode = d.mode
        @Suppress("DEPRECATION")
        val hdr = d.hdrCapabilities?.supportedHdrTypes?.toList() ?: emptyList()
        return mapOf(
            "modeId" to mode.modeId,
            "width" to mode.physicalWidth,
            "height" to mode.physicalHeight,
            "refreshRate" to mode.refreshRate.toDouble(),
            "supportedModes" to d.supportedModes.map {
                "${it.modeId}:${it.physicalWidth}x${it.physicalHeight}@${"%.3f".format(java.util.Locale.ROOT, it.refreshRate)}"
            },
            "hdrTypes" to hdr, // 1 DolbyVision, 2 HDR10, 3 HLG, 4 HDR10+
        )
    }

    private fun probe(path: String): Map<String, Any?> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            var video: MediaFormat? = null
            var audio: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && video == null) video = f
                if (mime.startsWith("audio/") && audio == null) audio = f
            }
            if (video == null) return mapOf("error" to "no video track")
            val mime = video.getString(MediaFormat.KEY_MIME)!!
            val transfer = if (video.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                video.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
            } else {
                null
            }
            val hdr = when {
                mime == "video/dolby-vision" -> "DolbyVision"
                transfer == MediaFormat.COLOR_TRANSFER_ST2084 -> "HDR10"
                transfer == MediaFormat.COLOR_TRANSFER_HLG -> "HLG"
                else -> "SDR"
            }
            val decoder = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(video)
            return mapOf(
                "mime" to mime,
                "width" to video.getInteger(MediaFormat.KEY_WIDTH),
                "height" to video.getInteger(MediaFormat.KEY_HEIGHT),
                "frameRate" to if (video.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                    try {
                        video.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble()
                    } catch (e: ClassCastException) {
                        video.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
                    }
                } else {
                    null
                },
                "hdr" to hdr,
                "decoder" to decoder,
                "audio" to audio?.getString(MediaFormat.KEY_MIME),
            )
        } finally {
            ex.release()
        }
    }
}
