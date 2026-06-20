package com.memexlab.memex.channels

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
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
        private const val TAG = "ClipboardPreview"

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
            Log.i(TAG, "getClipboardSummary: empty clipboard")
            return null
        }

        val description = clip.description
        val sourcePrefix = "android:${clipboardTimestamp(description)}"
        val allowCoercedText = hasTextMimeType(description)
        Log.i(
            TAG,
            "getClipboardSummary: items=${clip.itemCount}, " +
                "mimes=${mimeTypes(description)}, allowCoercedText=$allowCoercedText",
        )

        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val uri = item.uri
            val imageMimeType = resolveImageMimeType(uri, description.mimeTypeCount) {
                description.getMimeType(it)
            }
            Log.i(
                TAG,
                "item[$index] image scan: uri=${shortValue(uri?.toString())}, " +
                    "resolvedImageMime=$imageMimeType",
            )

            if (imageMimeType != null && uri != null) {
                Log.i(TAG, "item[$index] selected as image: mime=$imageMimeType")
                return mapOf(
                    "type" to "image",
                    "uri" to uri.toString(),
                    "mimeType" to imageMimeType,
                    "fileName" to displayName(uri),
                    "sourceId" to "$sourcePrefix:$index:$uri:$imageMimeType",
                )
            }
        }

        for (index in 0 until clip.itemCount) {
            val trimmedText = textFromItem(
                clip.getItemAt(index),
                allowCoercedText,
                index,
            ) ?: continue

            val textImageUri = parseImageUri(trimmedText)
            if (textImageUri != null) {
                val textImageMimeType = imageMimeTypeForUri(textImageUri) ?: "image/*"
                Log.i(
                    TAG,
                    "item[$index] selected as image from text uri: mime=$textImageMimeType",
                )
                return mapOf(
                    "type" to "image",
                    "uri" to textImageUri.toString(),
                    "mimeType" to textImageMimeType,
                    "fileName" to displayName(textImageUri),
                    "sourceId" to "$sourcePrefix:$index:$textImageUri:$textImageMimeType",
                )
            }

            Log.i(
                TAG,
                "item[$index] selected as text: len=${trimmedText.length}, " +
                    "preview=${shortValue(trimmedText)}",
            )
            return mapOf(
                "type" to "text",
                "text" to trimmedText,
            )
        }

        Log.i(TAG, "getClipboardSummary: no supported image/text candidate")
        return null
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
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            item.uri?.let { uri ->
                if (imageMimeTypeForUri(uri)?.startsWith("image/") == true) {
                    return uri
                }
            }
            parseImageUri(item.text?.toString()?.trim())?.let { return it }
        }
        return null
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

    private fun hasTextMimeType(description: ClipDescription): Boolean {
        for (index in 0 until description.mimeTypeCount) {
            if (description.getMimeType(index).startsWith("text/")) return true
        }
        return false
    }

    private fun textFromItem(
        item: ClipData.Item,
        allowCoercedText: Boolean,
        index: Int,
    ): String? {
        val coercedText = if (allowCoercedText) {
            item.coerceToText(activity)?.toString()
        } else {
            null
        }
        Log.i(
            TAG,
            "item[$index] text scan: textLen=${item.text?.length ?: 0}, " +
                "htmlLen=${item.htmlText?.length ?: 0}, " +
                "coercedLen=${coercedText?.length ?: 0}",
        )
        val text = item.text?.toString()
            ?: coercedText
            ?: item.htmlText
        val trimmedText = text?.trim()
        if (trimmedText.isNullOrBlank()) {
            Log.i(TAG, "item[$index] ignored: blank text")
            return null
        }
        if (looksLikeBinaryClipboardText(trimmedText)) {
            Log.i(
                TAG,
                "item[$index] ignored: binary-looking text len=${trimmedText.length}",
            )
            return null
        }
        return trimmedText
    }

    private fun mimeTypes(description: ClipDescription): String {
        val values = mutableListOf<String>()
        for (index in 0 until description.mimeTypeCount) {
            values.add(description.getMimeType(index))
        }
        return values.joinToString(prefix = "[", postfix = "]")
    }

    private fun shortValue(value: String?): String {
        if (value.isNullOrBlank()) return "<none>"
        val normalized = value.replace(Regex("\\s+"), " ").trim()
        return if (normalized.length <= 96) {
            normalized
        } else {
            "${normalized.take(96)}..."
        }
    }

    private fun looksLikeBinaryClipboardText(text: String): Boolean {
        if (text.contains('\u0000')) return true
        if (text.startsWith("\u0089PNG") || text.contains("PNG\r\n\u001A\n")) return true
        if (text.contains("JFIF\u0000") || text.contains("Exif\u0000")) return true

        var controlCount = 0
        var replacementCount = 0
        var total = 0

        for (char in text) {
            total += 1
            val code = char.code
            val isAllowedWhitespace = code == 0x09 || code == 0x0A || code == 0x0D
            val isControl = !isAllowedWhitespace &&
                ((code in 0x00..0x1F) || (code in 0x7F..0x9F))
            if (isControl) controlCount += 1
            if (code == 0xFFFD) replacementCount += 1
        }

        if (total == 0) return false
        if (controlCount >= 3 || controlCount.toDouble() / total > 0.02) return true
        if (replacementCount >= 8 || replacementCount.toDouble() / total > 0.08) return true
        return false
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
