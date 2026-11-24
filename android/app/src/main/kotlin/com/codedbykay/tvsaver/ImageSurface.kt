package com.codedbykay.tvsaver

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.SurfaceView
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max
import kotlin.math.min

/**
 * Story 5-3. Photos on a hardware surface at the panel's own size.
 *
 * Flutter draws the UI plane at 1080p on the X90K, which would halve the
 * resolution of every photo. A SurfaceView is a separate layer the compositor
 * scales to the screen, so a photo drawn onto it with the buffer fixed at
 * 3840x2160 reaches the panel pixel for pixel.
 *
 * This is a SurfaceView of its own (platform view `tvsaver/imageview`), never
 * the one the video decoder writes to: a Surface has one producer at a time,
 * and a canvas that has drawn on it keeps the decoder out. Dart puts the view
 * in the tree while a photo shows and takes it out for a clip.
 *
 * One photo is decoded at a time on its own thread (at most 3840x2160, never
 * enlarged, in the file's own colour space with its EXIF rotation applied by
 * [ImageDecoder]). The photo on screen stays until the next one is ready, then
 * they cross-fade; Ken Burns is a slow canvas scale, never a re-decode.
 * The newest request wins. Needs Android 9 (API 28); on anything older [show]
 * answers false and the Dart side uses its Flutter widget.
 */
class ImageSurface(private val activity: Activity) {
    private val thread = HandlerThread("tvsaver-image").apply { start() }
    private val handler = Handler(thread.looper)
    private val seq = AtomicInteger()
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)

    /** The photo fully on screen; touched on [thread] only. */
    private var shown: Bitmap? = null

    /** The view the photos go on; null while Dart has it out of the tree. */
    @Volatile
    private var view: SurfaceView? = null

    /** The photo that belongs on a (re)created view: the last one shown. */
    @Volatile
    private var currentPath: String? = null

    private class Request(
        val path: String,
        val crossfadeMs: Int,
        val kenBurns: Boolean,
        val durationMs: Int,
        val done: (Boolean) -> Unit,
    )

    /** A request that came before the view existed; the newest one only. */
    private var waiting: Request? = null

    fun attach(v: SurfaceView) {
        v.holder.setFixedSize(TARGET_W, TARGET_H)
        view = v
        val request = synchronized(this) { waiting.also { waiting = null } }
        if (request != null) {
            start(request)
        } else {
            // The view came back (after the menu): draw the photo again.
            currentPath?.let { path ->
                start(Request(path, 0, false, 0) {})
            }
        }
    }

    fun detach(v: SurfaceView) {
        if (view === v) {
            view = null
            seq.incrementAndGet()
        }
    }

    /**
     * Draws [path]. [done] is called on the main thread with true once the
     * first frame is on screen, or false when the photo cannot be shown here.
     */
    fun show(
        path: String,
        crossfadeMs: Int,
        kenBurns: Boolean,
        durationMs: Int,
        done: (Boolean) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            done(false)
            return
        }
        val request = Request(path, crossfadeMs, kenBurns, durationMs, done)
        currentPath = path
        if (view == null) {
            // Dart has just put the view in the tree: it is created in a moment.
            val old = synchronized(this) { waiting.also { waiting = request } }
            old?.let { finish(it.done, true) } // superseded
            activity.window.decorView.postDelayed({
                val still = synchronized(this) {
                    if (waiting === request) {
                        waiting = null
                        true
                    } else {
                        false
                    }
                }
                if (still) finish(done, false) // no view came: the Flutter widget shows it
            }, VIEW_WAIT_MS)
            return
        }
        start(request)
    }

    /** Forget the photo and free its memory (a clip is next, or nothing). */
    fun clear() {
        seq.incrementAndGet()
        currentPath = null
        val old = synchronized(this) { waiting.also { waiting = null } }
        old?.let { finish(it.done, true) }
        handler.post {
            shown?.recycle()
            shown = null
        }
    }

    fun dispose() {
        clear()
        thread.quitSafely()
    }

    private fun start(r: Request) {
        val mine = seq.incrementAndGet()
        handler.post {
            val v = view
            val bitmap = try {
                decode(r.path)
            } catch (t: Throwable) {
                null
            }
            if (bitmap == null || v == null) {
                bitmap?.recycle()
                finish(r.done, false)
                return@post
            }
            if (mine != seq.get()) {
                bitmap.recycle()
                finish(r.done, true) // a newer photo took over
                return@post
            }
            animate(v, mine, bitmap, r.crossfadeMs, r.kenBurns, r.durationMs, r.done)
        }
    }

    private fun finish(done: (Boolean) -> Unit, ok: Boolean) {
        activity.runOnUiThread { done(ok) }
    }

    private fun decode(path: String): Bitmap? {
        val source = ImageDecoder.createSource(File(path))
        return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val scale = min(1.0, min(TARGET_W.toDouble() / w, TARGET_H.toDouble() / h))
            if (scale < 1.0) {
                decoder.setTargetSize(
                    max(1, (w * scale).toInt()),
                    max(1, (h * scale).toInt()),
                )
            }
        }
    }

    private fun animate(
        view: SurfaceView,
        mine: Int,
        next: Bitmap,
        crossfadeMs: Int,
        kenBurns: Boolean,
        durationMs: Int,
        done: (Boolean) -> Unit,
    ) {
        val previous = shown
        val start = SystemClock.uptimeMillis()
        var reported = false
        lateinit var frame: Runnable
        frame = Runnable {
            if (mine != seq.get()) {
                // Superseded: keep what is on screen, drop this photo.
                if (next !== shown) next.recycle()
                if (!reported) finish(done, true)
                return@Runnable
            }
            val t = (SystemClock.uptimeMillis() - start).toInt()
            val fading = previous != null && crossfadeMs > 0 && t < crossfadeMs
            val alpha = if (fading) t.toFloat() / crossfadeMs else 1f
            val zoom = if (kenBurns && durationMs > 0) {
                1f + 0.08f * min(1f, t.toFloat() / durationMs)
            } else {
                1f
            }
            val drawn = drawFrame(view, if (fading) previous else null, next, alpha, zoom)
            if (!reported) {
                reported = true
                if (!drawn) {
                    // No surface to draw on: let the Flutter widget do it.
                    next.recycle()
                    finish(done, false)
                    return@Runnable
                }
                finish(done, true)
            }
            val more = fading || (kenBurns && durationMs > 0 && t < durationMs)
            if (more) {
                handler.postDelayed(frame, FRAME_MS)
            } else {
                shown = next
                if (previous != null && previous !== next) previous.recycle()
            }
        }
        handler.post(frame)
    }

    /** One frame: black, then [from] under [to] at [alpha]. False without a surface. */
    private fun drawFrame(
        view: SurfaceView,
        from: Bitmap?,
        to: Bitmap?,
        alpha: Float,
        zoom: Float,
    ): Boolean {
        val holder = view.holder
        if (!holder.surface.isValid) return false
        val canvas: Canvas = try {
            holder.lockHardwareCanvas()
        } catch (t: Throwable) {
            return false
        } ?: return false
        try {
            canvas.drawColor(Color.BLACK)
            from?.let { drawFitted(canvas, it, 255, 1f) }
            to?.let { drawFitted(canvas, it, (alpha * 255).toInt().coerceIn(0, 255), zoom) }
        } finally {
            holder.unlockCanvasAndPost(canvas)
        }
        return true
    }

    private fun drawFitted(canvas: Canvas, bitmap: Bitmap, alpha: Int, zoom: Float) {
        val cw = canvas.width.toFloat()
        val ch = canvas.height.toFloat()
        val scale = min(cw / bitmap.width, ch / bitmap.height)
        val w = bitmap.width * scale
        val h = bitmap.height * scale
        paint.alpha = alpha
        canvas.save()
        canvas.scale(zoom, zoom, cw / 2f, ch / 2f)
        canvas.drawBitmap(
            bitmap,
            null,
            android.graphics.RectF((cw - w) / 2f, (ch - h) / 2f, (cw + w) / 2f, (ch + h) / 2f),
            paint,
        )
        canvas.restore()
    }

    companion object {
        const val TARGET_W = 3840
        const val TARGET_H = 2160
        private const val FRAME_MS = 16L

        /** How long a photo waits for its view to be created. */
        private const val VIEW_WAIT_MS = 3000L
    }
}
