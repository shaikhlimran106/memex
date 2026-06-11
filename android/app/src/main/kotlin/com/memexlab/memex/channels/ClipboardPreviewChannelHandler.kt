package com.memexlab.memex.channels

import android.app.Activity
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Handles `com.memexlab.memex/clipboard_preview` MethodChannel.
 */
class ClipboardPreviewChannelHandler(private val activity: Activity) {

    companion object {
        private const val CHANNEL = "com.memexlab.memex/clipboard_preview"

        fun register(flutterEngine: FlutterEngine, activity: Activity) {
            val handler = ClipboardPreviewChannelHandler(activity)
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getClipboardSummary" -> handler.getClipboardSummary(result)
                        "copyImageToCache" -> {
                            val uri = call.argument<String>("uri")
                            val fileName = call.argument<String>("fileName")
                            val mimeType = call.argument<String>("mimeType")
                            handler.copyImageToCache(uri, fileName, mimeType, result)
                        }
                        else -> result.notImplemented()
                    }
                }
        }
    }

    private fun getClipboardSummary(result: MethodChannel.Result) {
        Thread {
            try {
                val summary = buildClipboardSummary()
                activity.runOnUiThread { result.success(summary) }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("CLIPBOARD_READ_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun buildClipboardSummary(): Map<String, Any?>? {
        val clip = clipboardManager().primaryClip
        if (clip == null || clip.itemCount == 0) {
            return null
        }

        val description = clip.description
        val item = clip.getItemAt(0)
        val uri = item.uri
        val sourcePrefix = "android:${clipboardTimestamp(description)}"
        val imageMimeType = resolveImageMimeType(uri, description.mimeTypeCount) {
            description.getMimeType(it)
        }

        if (imageMimeType != null && uri != null) {
            return mapOf(
                "type" to "image",
                "uri" to uri.toString(),
                "mimeType" to imageMimeType,
                "fileName" to displayName(uri),
                "sourceId" to "$sourcePrefix:$uri:$imageMimeType",
            )
        }

        val text = item.text?.toString()
            ?: item.htmlText
            ?: item.coerceToText(activity)?.toString()
        if (text.isNullOrBlank()) {
            return null
        }

        val textImageUri = parseImageUri(text.trim())
        if (textImageUri != null) {
            val textImageMimeType = imageMimeTypeForUri(textImageUri) ?: "image/*"
            return mapOf(
                "type" to "image",
                "uri" to textImageUri.toString(),
                "mimeType" to textImageMimeType,
                "fileName" to displayName(textImageUri),
                "sourceId" to "$sourcePrefix:$textImageUri:$textImageMimeType",
            )
        }

        return mapOf(
            "type" to "text",
            "text" to text.trim(),
        )
    }

    private fun copyImageToCache(
        uriString: String?,
        fileName: String?,
        mimeType: String?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val uri = uriString?.let(Uri::parse) ?: currentClipboardImageUri()
                    ?: throw IllegalStateException("No clipboard image URI")
                val resolvedMimeType = imageMimeTypeForUri(uri) ?: mimeType ?: "image/png"
                val extension = extensionForMimeType(resolvedMimeType)
                    ?: MimeTypeMap.getFileExtensionFromUrl(uri.toString())
                    ?: "png"
                val safeName = safeFileName(
                    fileName?.takeIf { it.isNotBlank() }
                        ?: "clipboard_image_${System.currentTimeMillis()}.$extension"
                )
                val targetDir = File(activity.cacheDir, "clipboard_images").apply {
                    mkdirs()
                }
                val targetFile = File(targetDir, ensureExtension(safeName, extension))

                activity.contentResolver.openInputStream(uri).use { input ->
                    if (input == null) throw IllegalStateException("Unable to open clipboard image")
                    targetFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }

                activity.runOnUiThread { result.success(targetFile.absolutePath) }
            } catch (e: SecurityException) {
                activity.runOnUiThread { result.error("PERMISSION_DENIED", e.message, null) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("COPY_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun clipboardTimestamp(description: ClipDescription): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            description.timestamp
        } else {
            0L
        }
    }

    private fun clipboardManager(): ClipboardManager {
        return activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    }

    private fun currentClipboardImageUri(): Uri? {
        val clip = clipboardManager().primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).uri ?: parseImageUri(
            clip.getItemAt(0).text?.toString()?.trim()
        )
    }

    private fun resolveImageMimeType(
        uri: Uri?,
        mimeTypeCount: Int,
        mimeTypeAt: (Int) -> String,
    ): String? {
        for (index in 0 until mimeTypeCount) {
            val mimeType = mimeTypeAt(index)
            if (mimeType.startsWith("image/")) return mimeType
        }
        return uri?.let(::imageMimeTypeForUri)
    }

    private fun parseImageUri(text: String?): Uri? {
        if (text.isNullOrBlank()) return null
        val uri = runCatching { Uri.parse(text) }.getOrNull() ?: return null
        val scheme = uri.scheme ?: return null
        if (scheme != "content" && scheme != "file") return null
        return if (imageMimeTypeForUri(uri)?.startsWith("image/") == true) uri else null
    }

    private fun imageMimeTypeForUri(uri: Uri): String? {
        val resolverType = runCatching { activity.contentResolver.getType(uri) }.getOrNull()
        if (resolverType?.startsWith("image/") == true) return resolverType

        val extension = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
        if (extension.isNullOrBlank()) return null
        val mimeType = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extension.lowercase())
        return mimeType?.takeIf { it.startsWith("image/") }
    }

    private fun displayName(uri: Uri): String? {
        val cursor = runCatching {
            activity.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )
        }.getOrNull()
        cursor?.use {
            if (it.moveToFirst()) {
                val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return it.getString(index)
            }
        }
        return uri.lastPathSegment
    }

    private fun extensionForMimeType(mimeType: String): String? {
        return when (mimeType) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/gif" -> "gif"
            "image/webp" -> "webp"
            "image/heic" -> "heic"
            "image/heif" -> "heif"
            "image/bmp" -> "bmp"
            else -> null
        }
    }

    private fun safeFileName(fileName: String): String {
        return fileName.replace(Regex("""[^\w.\-]+"""), "_")
    }

    private fun ensureExtension(fileName: String, extension: String): String {
        return if (fileName.contains(".")) fileName else "$fileName.$extension"
    }
}
