package com.memexlab.memex.channels

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.min

/**
 * Handles `com.memexlab.memex/webview` MethodChannel.
 */
class WebViewChannelHandler(private val activity: Activity) {

    companion object {
        private const val CHANNEL = "com.memexlab.memex/webview"

        fun register(flutterEngine: FlutterEngine, activity: Activity) {
            val handler = WebViewChannelHandler(activity)
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "disableScrolling" -> {
                            handler.disableWebViewScrolling()
                            result.success(null)
                        }
                        "renderHtmlToImage" -> {
                            val html = call.argument<String>("html")
                            if (html == null) {
                                result.error(
                                    "INVALID_ARGS",
                                    "renderHtmlToImage requires a 'html' string argument.",
                                    null
                                )
                            } else {
                                val width = call.argument<Double>("width") ?: 390.0
                                val maxHeight = call.argument<Double>("maxHeight") ?: 3000.0
                                handler.renderHtmlToImage(html, width, maxHeight, result)
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
        }
    }

    /**
     * Renders a self-contained HTML document into a PNG (base64) using an
     * off-screen [WebView]. Rendering happens inside the native WebView, so
     * `webView.draw(canvas)` captures real content (unlike Flutter-layer
     * screenshots of platform views, which can be blank under hybrid
     * composition). The WebView is created/owned here and never attached to the
     * visible view tree, so it is fully isolated from timeline card WebViews.
     */
    fun renderHtmlToImage(
        html: String,
        width: Double,
        maxHeight: Double,
        result: MethodChannel.Result,
    ) {
        val mainHandler = Handler(Looper.getMainLooper())
        mainHandler.post {
            val density = activity.resources.displayMetrics.density
            val widthPx = (width * density).toInt().coerceAtLeast(1)
            val maxHeightPx = (maxHeight * density).toInt().coerceAtLeast(1)

            val webView = WebView(activity)
            // Single-shot guard so we resolve the Flutter result exactly once.
            var settled = false
            fun finish(base64: String?, errorMessage: String?) {
                if (settled) return
                settled = true
                try {
                    webView.destroy()
                } catch (_: Throwable) {
                }
                if (base64 != null) {
                    result.success(base64)
                } else {
                    result.error(
                        "RENDER_FAILED",
                        errorMessage ?: "Failed to render HTML snapshot.",
                        null
                    )
                }
            }

            try {
                webView.settings.javaScriptEnabled = true
                webView.settings.loadWithOverviewMode = false
                webView.settings.useWideViewPort = false
                webView.setBackgroundColor(Color.TRANSPARENT)

                webView.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String) {
                        // Measure real content height, then layout + capture.
                        view.evaluateJavascript("document.body.scrollHeight") { value ->
                            val cssHeight = value?.toFloatOrNull() ?: maxHeight.toFloat()
                            val heightPx = min((cssHeight * density).toInt(), maxHeightPx)
                                .coerceAtLeast(1)

                            view.measure(
                                View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
                                View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY),
                            )
                            view.layout(0, 0, widthPx, heightPx)

                            // Let layout/images settle before drawing.
                            mainHandler.postDelayed({
                                try {
                                    val bitmap = Bitmap.createBitmap(
                                        widthPx,
                                        heightPx,
                                        Bitmap.Config.ARGB_8888,
                                    )
                                    val canvas = Canvas(bitmap)
                                    view.draw(canvas)
                                    val stream = ByteArrayOutputStream()
                                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                                    bitmap.recycle()
                                    val base64 = Base64.encodeToString(
                                        stream.toByteArray(),
                                        Base64.NO_WRAP,
                                    )
                                    finish(base64, null)
                                } catch (e: Throwable) {
                                    finish(null, e.message)
                                }
                            }, 150)
                        }
                    }
                }

                webView.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)

                // Safety timeout in case onPageFinished never fires.
                mainHandler.postDelayed({
                    finish(null, "Render timed out.")
                }, 8000)
            } catch (e: Throwable) {
                finish(null, e.message)
            }
        }
    }

    private fun disableWebViewScrolling() {
        val rootView = activity.window.decorView.rootView
        disableScrollingInView(rootView)
    }

    private fun disableScrollingInView(view: View) {
        if (view is WebView) {
            view.isVerticalScrollBarEnabled = false
            view.isHorizontalScrollBarEnabled = false
            view.overScrollMode = View.OVER_SCROLL_NEVER
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                disableScrollingInView(view.getChildAt(i))
            }
        }
    }
}
