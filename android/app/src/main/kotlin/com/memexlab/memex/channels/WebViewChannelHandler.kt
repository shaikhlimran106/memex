package com.memexlab.memex.channels

import android.app.Activity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                        else -> result.notImplemented()
                    }
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
