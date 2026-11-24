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
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.IOException

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
 *
 * Story 3-4 (the TV as the paired display) adds one-item playback:
 *
 *  - `m3OpenItem {url, headers, startMs, muted, playing}`: one HTTP item with
 *    `Authorization` headers, no repeat; `onItemEnded` fires when it ends.
 *  - `m3Control {action}` gains `resume`, `seek {positionMs}` and
 *    `mute {muted}` (player volume only, never the TV's volume).
 */
@androidx.annotation.OptIn(UnstableApi::class)
class VideoSpike(
    private val activity: Activity,
    /** Called on the main thread when the current `m3OpenItem` item played to its end. */
    private val onItemEnded: () -> Unit = {},
) {
    private var surfaceView: SurfaceView? = null
    private var player: ExoPlayer? = null
    private var decoderName: String? = null
    private var droppedFrames = 0
    private var inputFormat: Format? = null
    private var loopMode = "repeatOne"
    private var lastHttpStatus: Int? = null

    private val endListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) onItemEnded()
        }
    }

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

        override fun onLoadCompleted(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
        ) {
            lastHttpStatus = null
        }

        override fun onLoadError(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
            error: IOException,
            wasCanceled: Boolean,
        ) {
            extractHttpStatus(error)?.let { lastHttpStatus = it }
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
                "filesDir" -> result.success(activity.getExternalFilesDir(null)?.absolutePath)
                "decoders" -> result.success(decoderLines())
                "displayInfo" -> result.success(displayInfo())
                "probe" -> result.success(probe(call.argument<String>("path")!!))
                "m3Open" -> {
                    m3Open(call.argument<String>("path")!!, call.argument<String>("loop") ?: "repeatOne")
                    result.success(null)
                }
                "m3OpenHttp" -> {
                    val urls = call.argument<List<String>>("urls") ?: emptyList()
                    if (urls.isEmpty()) {
                        result.error("invalid_args", "urls must not be empty", null)
                        return
                    }
                    @Suppress("UNCHECKED_CAST")
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    m3OpenHttp(urls, headers)
                    result.success(null)
                }
                "m3OpenItem" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("invalid_args", "url must not be empty", null)
                        return
                    }
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    m3OpenItem(
                        url,
                        headers,
                        (call.argument<Number>("startMs") ?: 0).toLong(),
                        call.argument<Boolean>("muted") ?: false,
                        call.argument<Boolean>("playing") ?: true,
                    )
                    result.success(null)
                }
                "m3Stats" -> result.success(m3Stats())
                "m3Control" -> {
                    when (call.argument<String>("action")) {
                        "play", "resume" -> player?.play()
                        "pause" -> player?.pause()
                        "seek" -> {
                            val pos = call.argument<Number>("positionMs")
                            if (pos == null) {
                                result.error("invalid_args", "positionMs is required", null)
                                return
                            }
                            player?.seekTo(pos.toLong())
                        }
                        "mute" -> {
                            val muted = call.argument<Boolean>("muted")
                            if (muted == null) {
                                result.error("invalid_args", "muted is required", null)
                                return
                            }
                            player?.volume = if (muted) 0f else 1f
                        }
                        "next" -> player?.seekToNextMediaItem()
                        "prev" -> player?.seekToPreviousMediaItem()
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
        lastHttpStatus = null
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

    private fun m3OpenHttp(urls: List<String>, headers: Map<String, String>) {
        m3Release()
        decoderName = null
        droppedFrames = 0
        inputFormat = null
        lastHttpStatus = null
        loopMode = if (urls.size == 1) "repeatOne" else "playlist"
        val httpFactory = DefaultHttpDataSource.Factory()
        if (headers.isNotEmpty()) {
            httpFactory.setDefaultRequestProperties(headers)
        }
        val mediaSourceFactory = DefaultMediaSourceFactory(activity)
            .setDataSourceFactory(httpFactory)
        val exo = ExoPlayer.Builder(activity)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
        exo.addAnalyticsListener(analytics)
        val items = urls.map { MediaItem.fromUri(it) }
        exo.setMediaItems(items)
        exo.repeatMode = if (items.size == 1) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_ALL
        surfaceView?.let { exo.setVideoSurfaceView(it) }
        exo.prepare()
        exo.playWhenReady = true
        player = exo
    }

    /** One item over HTTP, started at [startMs], played once (the Dart side decides what comes next). */
    private fun m3OpenItem(
        url: String,
        headers: Map<String, String>,
        startMs: Long,
        muted: Boolean,
        playing: Boolean,
    ) {
        m3Release()
        decoderName = null
        droppedFrames = 0
        inputFormat = null
        lastHttpStatus = null
        loopMode = "item"
        // A Pi that stops answering fails the item after 8 s instead of hanging.
        val httpFactory = DefaultHttpDataSource.Factory()
            .setConnectTimeoutMs(8000)
            .setReadTimeoutMs(8000)
        if (headers.isNotEmpty()) {
            httpFactory.setDefaultRequestProperties(headers)
        }
        val exo = ExoPlayer.Builder(activity)
            .setMediaSourceFactory(DefaultMediaSourceFactory(activity).setDataSourceFactory(httpFactory))
            .build()
        exo.addAnalyticsListener(analytics)
        exo.addListener(endListener)
        exo.setMediaItem(MediaItem.fromUri(url))
        exo.repeatMode = Player.REPEAT_MODE_OFF
        exo.volume = if (muted) 0f else 1f
        if (startMs > 0) exo.seekTo(startMs)
        surfaceView?.let { exo.setVideoSurfaceView(it) }
        exo.prepare()
        exo.playWhenReady = playing
        player = exo
    }

    private fun m3Release() {
        player?.let {
            it.removeListener(endListener)
            it.removeAnalyticsListener(analytics)
            it.release()
        }
        player = null
        lastHttpStatus = null
    }

    private fun extractHttpStatus(t: Throwable?): Int? {
        var cur = t
        while (cur != null) {
            if (cur is HttpDataSource.InvalidResponseCodeException) {
                return cur.responseCode
            }
            cur = cur.cause
        }
        return null
    }

    private fun m3Stats(): Map<String, Any?> {
        val p = player
        val fmt = p?.videoFormat ?: inputFormat
        val durMs = p?.duration?.takeIf { it != C.TIME_UNSET && it >= 0L }
        val err = p?.playerError
        return mapOf(
            "playing" to (p?.isPlaying ?: false),
            "state" to p?.playbackState,
            "positionMs" to p?.currentPosition,
            "durationMs" to durMs,
            "item" to p?.currentMediaItemIndex,
            "loop" to loopMode,
            "decoder" to decoderName,
            "droppedFrames" to droppedFrames,
            "width" to fmt?.width,
            "height" to fmt?.height,
            "frameRate" to fmt?.frameRate?.takeIf { it > 0f },
            "hdr" to hdrName(fmt),
            "httpStatus" to (extractHttpStatus(err) ?: lastHttpStatus),
            "error" to err?.let { "${it.errorCodeName}: ${it.message}" },
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
