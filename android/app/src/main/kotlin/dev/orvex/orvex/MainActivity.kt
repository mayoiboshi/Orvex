package dev.orvex.orvex

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract as Docs
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val scopes = mutableMapOf<String, Uri>()
    private var picker: MethodChannel.Result? = null
    private val pickRequest = 4719

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.orvex/folders").setMethodCallHandler { call, result ->
            if (call.method == "pick") {
                if (picker != null) { result.error("busy", "目录选择器已打开", null) }
                else {
                    picker = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        }, pickRequest)
                    } catch (e: Exception) { picker = null; result.error("folder_access", e.localizedMessage, null) }
                }
            } else {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                worker.execute {
                    try {
                        val output: Any? = when (call.method) {
                            "acquire" -> {
                                val tree = Uri.parse(args["grant"] as String)
                                require(contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }) { "目录权限已失效，请重新授权" }
                                val doc = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
                                contentResolver.query(doc, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { require(it.moveToFirst()) { "目录不存在" } } ?: error("无法访问目录")
                                val handle = UUID.randomUUID().toString()
                                scopes[handle] = tree
                                mapOf("handle" to handle, "location" to tree.toString(), "identity" to identity(tree, Docs.getTreeDocumentId(tree)))
                            }
                            "release" -> { scopes.remove(args["handle"] as String); null }
                            "list" -> {
                                val (tree, doc) = locate(args)
                                val child = Docs.buildChildDocumentsUriUsingTree(tree, Docs.getDocumentId(doc))
                                val output = mutableListOf<Map<String, Any?>>()
                                contentResolver.query(child, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { cursor ->
                                    while (cursor.moveToNext()) {
                                        output.add(mapOf("identity" to identity(tree, cursor.getString(0)), "name" to cursor.getString(1), "directory" to (cursor.getString(2) == Docs.Document.MIME_TYPE_DIR), "size" to cursor.getLong(3), "modified" to cursor.getLong(4)))
                                    }
                                } ?: error("无法读取目录")
                                output
                            }
                            "resolve" -> {
                                val (tree, doc) = locate(args)
                                val expected = args["identity"] as? String
                                require(expected == null || identity(tree, Docs.getDocumentId(doc)) == expected) { "文件身份已变化，请重新扫描" }
                                doc.toString()
                            }
                            "thumbnail", "thumbnailImported" -> {
                                val uri = if (call.method == "thumbnailImported") {
                                    val path = args["path"] as String
                                    val parts = path.split('/')
                                    require(parts.size >= 2 && parts.first() == "Imports" && parts.all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') }) { "导入文件位置无效" }
                                    val documents = getDir("flutter", 0)
                                    val file = File(documents, path).canonicalFile
                                    require(file.path.startsWith(File(documents, "Imports").canonicalPath + File.separator)) { "文件超出导入目录" }
                                    Uri.fromFile(file)
                                } else locate(args).second
                                val retriever = MediaMetadataRetriever()
                                try {
                                    retriever.setDataSource(this, uri)
                                    val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
                                    require(duration > 0) { "当前格式无法提取预览" }
                                    val frame = retriever.getFrameAtTime((duration * 0.15).toLong().coerceIn(1000L, 90000L) * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: error("无可用画面")
                                    val ratio = minOf(480.0 / frame.width, 270.0 / frame.height, 1.0)
                                    val scaled = Bitmap.createScaledBitmap(frame, (frame.width * ratio).toInt().coerceAtLeast(1), (frame.height * ratio).toInt().coerceAtLeast(1), true)
                                    val bytes = ByteArrayOutputStream()
                                    scaled.compress(Bitmap.CompressFormat.JPEG, 78, bytes)
                                    if (scaled !== frame) scaled.recycle()
                                    frame.recycle()
                                    mapOf("bytes" to bytes.toByteArray(), "duration" to duration)
                                } finally { retriever.release() }
                            }
                            else -> { runOnUiThread { result.notImplemented() }; return@execute }
                        }
                        runOnUiThread { result.success(output) }
                    } catch (e: Exception) { runOnUiThread { result.error("folder_access", e.localizedMessage, null) } }
                }
            }
        }
    }

    private fun identity(tree: Uri, id: String) = "${tree.authority}:$id"
    private fun locate(args: Map<*, *>): Pair<Uri, Uri> {
        val tree = scopes[args["handle"] as String] ?: error("目录权限已失效")
        val path = args["path"] as? String ?: ""
        require(path.isEmpty() || path.split('/').all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') }) { "无效相对路径" }
        var id = Docs.getTreeDocumentId(tree)
        for (name in if (path.isEmpty()) emptyList() else path.split('/')) {
            val child = Docs.buildChildDocumentsUriUsingTree(tree, id)
            var found: String? = null
            contentResolver.query(child, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
                while (c.moveToNext()) { if (c.getString(1) == name) { require(found == null) { "重名文件无法确定" }; found = c.getString(0) } }
            }
            id = found ?: error("文件不存在，请重新扫描")
        }
        return tree to Docs.buildDocumentUriUsingTree(tree, id)
    }

    @Deprecated("Uses Activity result for the existing Flutter activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickRequest) { super.onActivityResult(requestCode, resultCode, data); return }
        val callback = picker
        picker = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) { callback?.success(null); return }
        try {
            contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val doc = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
            var name = "媒体文件夹"
            contentResolver.query(doc, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) name = it.getString(0) }
            callback?.success(mapOf("name" to name, "grant" to tree.toString(), "location" to tree.toString(), "identity" to identity(tree, Docs.getTreeDocumentId(tree))))
        } catch (e: Exception) { callback?.error("folder_access", e.localizedMessage, null) }
    }
}
