package com.memexlab.memex.channels

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Handles `com.memexlab.memex/backup_storage` MethodChannel.
 *
 * Android backup folder selection uses the Storage Access Framework. This gives
 * Memex persistent access to the chosen folder without requesting
 * MANAGE_EXTERNAL_STORAGE or broad shared-storage permissions.
 */
class BackupStorageChannelHandler(private val activity: Activity) {

    companion object {
        private const val CHANNEL = "com.memexlab.memex/backup_storage"
        private const val REQUEST_PICK_BACKUP_DIRECTORY = 7301
        private const val BACKUP_MIME_TYPE = "application/octet-stream"

        private var activeHandler: BackupStorageChannelHandler? = null

        fun register(flutterEngine: FlutterEngine, activity: Activity) {
            val handler = BackupStorageChannelHandler(activity)
            activeHandler = handler
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "pickBackupDirectory" -> handler.pickBackupDirectory(result)
                        "writeFileToTree" -> {
                            val treeUri = call.argument<String>("treeUri")
                            val sourcePath = call.argument<String>("sourcePath")
                            val fileName = call.argument<String>("fileName")
                            handler.writeFileToTree(treeUri, sourcePath, fileName, result)
                        }
                        "listBackupFiles" -> {
                            val treeUri = call.argument<String>("treeUri")
                            handler.listBackupFiles(treeUri, result)
                        }
                        "copyDocumentToCache" -> {
                            val documentUri = call.argument<String>("documentUri")
                            val fileName = call.argument<String>("fileName")
                            handler.copyDocumentToCache(documentUri, fileName, result)
                        }
                        "deleteDocument" -> {
                            val documentUri = call.argument<String>("documentUri")
                            handler.deleteDocument(documentUri, result)
                        }
                        else -> result.notImplemented()
                    }
                }
        }

        fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
            return activeHandler?.onActivityResult(requestCode, resultCode, data) ?: false
        }
    }

    private var pendingPickResult: MethodChannel.Result? = null

    private fun pickBackupDirectory(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("PICK_IN_PROGRESS", "A backup directory picker is already open", null)
            return
        }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }

        pendingPickResult = result
        try {
            activity.startActivityForResult(intent, REQUEST_PICK_BACKUP_DIRECTORY)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("PICK_FAILED", e.message, null)
        }
    }

    private fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_BACKUP_DIRECTORY) return false

        val result = pendingPickResult ?: return true
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }

        val uri = data.data!!
        val persistFlags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        try {
            if (persistFlags != 0) {
                activity.contentResolver.takePersistableUriPermission(uri, persistFlags)
            }
            result.success(
                mapOf(
                    "treeUri" to uri.toString(),
                    "displayName" to displayNameForTree(uri),
                )
            )
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("PICK_FAILED", e.message, null)
        }
        return true
    }

    private fun writeFileToTree(
        treeUriString: String?,
        sourcePath: String?,
        fileName: String?,
        result: MethodChannel.Result,
    ) {
        if (treeUriString.isNullOrBlank() || sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("INVALID_ARGUMENTS", "Missing treeUri, sourcePath, or fileName", null)
            return
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.error("SOURCE_MISSING", "Backup source file does not exist", null)
            return
        }

        Thread {
            try {
                val treeUri = Uri.parse(treeUriString)
                val parentUri = documentUriForTree(treeUri)
                deleteChildIfExists(treeUri, fileName)

                val tempName = ".$fileName.tmp"
                deleteChildIfExists(treeUri, tempName)

                val tempDocumentUri = DocumentsContract.createDocument(
                    activity.contentResolver,
                    parentUri,
                    BACKUP_MIME_TYPE,
                    tempName,
                ) ?: throw IllegalStateException("Unable to create backup document")

                try {
                    copyFileToDocument(sourceFile, tempDocumentUri)
                    val finalDocumentUri = DocumentsContract.renameDocument(
                        activity.contentResolver,
                        tempDocumentUri,
                        fileName,
                    ) ?: throw IllegalStateException("Unable to finalize backup document")

                    val info = documentInfo(finalDocumentUri, fileName, sourceFile.length())
                    activity.runOnUiThread { result.success(info) }
                } catch (e: Exception) {
                    try {
                        DocumentsContract.deleteDocument(activity.contentResolver, tempDocumentUri)
                    } catch (_: Exception) {
                    }
                    throw e
                }
            } catch (e: SecurityException) {
                activity.runOnUiThread { result.error("PERMISSION_DENIED", e.message, null) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("WRITE_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun listBackupFiles(treeUriString: String?, result: MethodChannel.Result) {
        if (treeUriString.isNullOrBlank()) {
            result.error("INVALID_ARGUMENTS", "Missing treeUri", null)
            return
        }

        try {
            val treeUri = Uri.parse(treeUriString)
            val treeDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                treeDocumentId,
            )
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val items = mutableListOf<Map<String, Any?>>()
            activity.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val modifiedIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameIndex) ?: continue
                    if (!name.endsWith(".memex", ignoreCase = true)) continue
                    val documentId = cursor.getString(idIndex) ?: continue
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                    items.add(
                        mapOf(
                            "documentUri" to documentUri.toString(),
                            "name" to name,
                            "size" to cursor.getLongOrZero(sizeIndex),
                            "lastModified" to cursor.getLongOrZero(modifiedIndex),
                        )
                    )
                }
            }
            result.success(items)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("LIST_FAILED", e.message, null)
        }
    }

    private fun copyDocumentToCache(
        documentUriString: String?,
        fileName: String?,
        result: MethodChannel.Result,
    ) {
        if (documentUriString.isNullOrBlank()) {
            result.error("INVALID_ARGUMENTS", "Missing documentUri", null)
            return
        }

        Thread {
            try {
                val documentUri = Uri.parse(documentUriString)
                val safeName = (fileName ?: "backup.memex").replace(Regex("""[^\w.\-]+"""), "_")
                val restoreDir = File(activity.cacheDir, "backup_restore").apply {
                    mkdirs()
                }
                val targetFile = File(restoreDir, safeName)
                activity.contentResolver.openInputStream(documentUri).use { input ->
                    if (input == null) throw IllegalStateException("Unable to open backup document")
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

    private fun deleteDocument(documentUriString: String?, result: MethodChannel.Result) {
        if (documentUriString.isNullOrBlank()) {
            result.error("INVALID_ARGUMENTS", "Missing documentUri", null)
            return
        }

        try {
            val deleted = DocumentsContract.deleteDocument(
                activity.contentResolver,
                Uri.parse(documentUriString),
            )
            result.success(deleted)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("DELETE_FAILED", e.message, null)
        }
    }

    private fun documentUriForTree(treeUri: Uri): Uri {
        return DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
    }

    private fun copyFileToDocument(sourceFile: File, documentUri: Uri) {
        sourceFile.inputStream().use { input ->
            activity.contentResolver.openOutputStream(documentUri, "wt").use { output ->
                if (output == null) throw IllegalStateException("Unable to open output stream")
                input.copyTo(output)
            }
        }
    }

    private fun deleteChildIfExists(treeUri: Uri, displayName: String) {
        val childUri = findChildDocumentUri(treeUri, displayName) ?: return
        DocumentsContract.deleteDocument(activity.contentResolver, childUri)
    }

    private fun findChildDocumentUri(treeUri: Uri, displayName: String): Uri? {
        val treeDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            treeDocumentId,
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        activity.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameIndex) ?: continue
                if (name != displayName) continue
                val documentId = cursor.getString(idIndex) ?: return null
                return DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
            }
        }
        return null
    }

    private fun documentInfo(documentUri: Uri, fileName: String, fallbackSize: Long): Map<String, Any?> {
        return mapOf(
            "documentUri" to documentUri.toString(),
            "name" to fileName,
            "size" to fallbackSize,
            "lastModified" to System.currentTimeMillis(),
        )
    }

    private fun displayNameForTree(treeUri: Uri): String {
        val documentUri = documentUriForTree(treeUri)
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        activity.contentResolver.query(documentUri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index) ?: treeUri.lastPathSegment ?: "Selected folder"
                }
            }
        }
        return treeUri.lastPathSegment ?: "Selected folder"
    }

    private fun Cursor.getLongOrZero(index: Int): Long {
        if (index < 0 || isNull(index)) return 0L
        return getLong(index)
    }
}
