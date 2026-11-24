package com.codedbykay.tvsaver

import android.content.Context
import android.view.SurfaceView
import android.view.TextureView
import android.widget.FrameLayout

/**
 * Holds the two places a clip can be drawn and lays them out.
 *
 * The SurfaceView (hardware video plane, 4K and HDR) always fills the screen:
 * on this TV the plane mis-scales as soon as that view is resized or reshaped
 * (a clip in a corner, garbage). It stretches a clip to its box, which is
 * right for a 16:9 clip only.
 *
 * Any other shape plays on the TextureView instead, which is composited by
 * the GPU like any other view and can be fitted into the screen with bars on
 * its sides. [fit] is that clip's width over height.
 */
class AspectFrame(context: Context) : FrameLayout(context) {
    /** Width over height of the clip on the TextureView; 0 fills the box. */
    var fit: Float = 0f
        set(value) {
            if (field != value) {
                field = value
                requestLayout()
            }
        }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val pw = right - left
        val ph = bottom - top
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child is TextureView && fit > 0f && pw > 0 && ph > 0) {
                var cw = pw
                var ch = ph
                if (pw.toFloat() / ph > fit) {
                    cw = (ph * fit).toInt()
                } else {
                    ch = (pw / fit).toInt()
                }
                val l = (pw - cw) / 2
                val t = (ph - ch) / 2
                child.layout(l, t, l + cw, t + ch)
            } else if (child is SurfaceView || child is TextureView) {
                child.layout(0, 0, pw, ph)
            }
        }
    }
}
