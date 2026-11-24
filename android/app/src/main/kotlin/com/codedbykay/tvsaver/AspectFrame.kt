package com.codedbykay.tvsaver

import android.content.Context
import android.widget.FrameLayout

/**
 * Holds the video SurfaceView and fits it, centred, into the space it has with
 * the clip's own shape. A SurfaceView stretches its picture to its whole box,
 * so this is what keeps a 4:3 or a portrait clip from being warped. The frame
 * itself always fills the screen and never changes size, which keeps the
 * Flutter platform view stable.
 */
class AspectFrame(context: Context) : FrameLayout(context) {
    /** Width over height of the picture; 0 (unknown) fills the box. */
    var aspect: Float = 0f
        set(value) {
            if (field != value) {
                field = value
                requestLayout()
            }
        }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val pw = right - left
        val ph = bottom - top
        var cw = pw
        var ch = ph
        if (aspect > 0f && pw > 0 && ph > 0) {
            if (pw.toFloat() / ph > aspect) {
                cw = (ph * aspect).toInt()
            } else {
                ch = (pw / aspect).toInt()
            }
        }
        val l = (pw - cw) / 2
        val t = (ph - ch) / 2
        for (i in 0 until childCount) {
            getChildAt(i).layout(l, t, l + cw, t + ch)
        }
    }
}
