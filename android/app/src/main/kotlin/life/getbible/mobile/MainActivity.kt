package life.getbible.mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val channelName = "life.getbible.mobile/files"
    private val saveRequest = 501
    private val openRequest = 502
    private val maxFileBytes = 64 * 1024 * 1024
    private val maxShareBytes = 256 * 1024
    private var pendingResult: MethodChannel.Result? = null
    private var pendingText: String? = null
    private var pendingLimit = maxFileBytes

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method !in setOf("shareText", "saveText", "pickTextFile")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (!claim(result)) return@setMethodCallHandler
                try {
                    when (call.method) {
                        "shareText" -> {
                            val text = call.argument<String>("text") ?: ""
                            require(text.length <= maxShareBytes &&
                                text.toByteArray(Charsets.UTF_8).size <= maxShareBytes) {
                                "This text is too large for a share sheet. Save it as a file instead."
                            }
                            val subject = call.argument<String>("subject") ?: "getBible"
                            val intent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, text)
                                putExtra(Intent.EXTRA_SUBJECT, subject)
                            }
                            startActivity(Intent.createChooser(intent, subject))
                            // Android cannot report delivery to the recipient. Do not
                            // call this completed; only the chooser was presented.
                            finish(result) { it.success("presented") }
                        }
                        "saveText" -> {
                            val text = call.argument<String>("text") ?: ""
                            require(text.length <= maxFileBytes &&
                                text.toByteArray(Charsets.UTF_8).size <= maxFileBytes) {
                                "The text exceeds the size limit."
                            }
                            val filename = call.argument<String>("filename") ?: "getBible.txt"
                            require(validFilename(filename)) { "The export filename is invalid." }
                            pendingText = text
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = call.argument<String>("mimeType") ?: "text/plain"
                                putExtra(Intent.EXTRA_TITLE, filename)
                            }
                            startActivityForResult(intent, saveRequest)
                        }
                        "pickTextFile" -> {
                            pendingLimit = call.argument<Int>("maxBytes") ?: maxFileBytes
                            require(pendingLimit in 1..maxFileBytes) { "Invalid file size limit." }
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                                putExtra(Intent.EXTRA_MIME_TYPES,
                                    arrayOf("application/json", "text/plain"))
                            }
                            startActivityForResult(intent, openRequest)
                        }
                    }
                } catch (error: Exception) {
                    finish(result) {
                        it.error("file_failed", error.message ?: "The file operation could not be opened.", null)
                    }
                }
            }
    }

    private fun claim(result: MethodChannel.Result): Boolean {
        if (pendingResult != null) {
            result.error("busy", "Another file operation is already open.", null)
            return false
        }
        pendingResult = result
        return true
    }

    // Main-thread-only completion, guarded against a late I/O callback after
    // activity destruction. Keep the pending slot claimed until I/O completes.
    private fun finish(expected: MethodChannel.Result, complete: (MethodChannel.Result) -> Unit) {
        if (pendingResult !== expected) return
        pendingResult = null
        pendingText = null
        complete(expected)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveRequest && requestCode != openRequest) return
        val result = pendingResult ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finish(result) { it.success(if (requestCode == saveRequest) false else null) }
            return
        }
        val text = pendingText
        val limit = pendingLimit
        thread(name = "getbible-file-io") {
            try {
                val value: Any = if (requestCode == saveRequest) {
                    val output = contentResolver.openOutputStream(uri, "w")
                        ?: throw IllegalStateException("The selected destination could not be opened.")
                    output.bufferedWriter(Charsets.UTF_8).use { it.write(text ?: "") }
                    true
                } else {
                    readBoundedText(uri, limit)
                }
                runOnUiThread { finish(result) { it.success(value) } }
            } catch (error: Exception) {
                runOnUiThread {
                    finish(result) {
                        it.error(if (requestCode == saveRequest) "save_failed" else "open_failed",
                            error.message ?: "The file operation could not be completed.", null)
                    }
                }
            }
        }
    }

    private fun readBoundedText(uri: Uri, limit: Int): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (cursor.moveToFirst() && column >= 0 && !cursor.isNull(column)) {
                require(cursor.getLong(column) <= limit.toLong()) {
                    "The selected file exceeds the size limit."
                }
            }
        }
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("The selected file could not be opened.")
        val bytes = ByteArrayOutputStream()
        input.use { stream ->
            val chunk = ByteArray(8192)
            while (true) {
                val count = stream.read(chunk)
                if (count < 0) break
                require(count <= limit - bytes.size()) { "The selected file exceeds the size limit." }
                bytes.write(chunk, 0, count)
            }
        }
        return Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
    }

    private fun validFilename(name: String): Boolean =
        name.isNotEmpty() && name.length <= 200 && name != "." && name != ".." &&
            name.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 }

    override fun onDestroy() {
        pendingResult?.let { result ->
            finish(result) { it.error("interrupted", "The file operation was interrupted. Please retry.", null) }
        }
        super.onDestroy()
    }
}
