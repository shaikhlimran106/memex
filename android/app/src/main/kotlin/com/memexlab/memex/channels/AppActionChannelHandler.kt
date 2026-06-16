package com.memexlab.memex.channels

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Handles Memex app-action deep links such as memex://quick_note. */
object AppActionChannelHandler {
    private const val METHOD_CHANNEL = "com.memexlab.memex/app_actions"
    private const val EVENT_CHANNEL = "com.memexlab.memex/app_action_events"
    private const val MEMEX_SCHEME = "memex"

    @Volatile
    private var pendingLink: String? = null
    private var eventSink: EventChannel.EventSink? = null

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> result.success(pendingLink)
                    "clearInitialLink" -> {
                        pendingLink = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    pendingLink?.let {
                        eventSink?.success(it)
                        pendingLink = null
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    fun handleIntent(activity: Activity, intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (!isMemexActionLink(uri)) return

        val link = uri.toString()
        activity.runOnUiThread {
            val sink = eventSink
            if (sink == null) {
                pendingLink = link
            } else {
                sink.success(link)
                pendingLink = null
            }
        }
    }

    private fun isMemexActionLink(uri: Uri): Boolean {
        return uri.scheme.equals(MEMEX_SCHEME, ignoreCase = true)
    }
}
