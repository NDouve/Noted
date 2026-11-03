package io.github.ndouve.noted

import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val reader = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noted/content")
            .setMethodCallHandler { call, result ->
                if (call.method != "read") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.error("bad_args", "uri is required", null)
                    return@setMethodCallHandler
                }
                // Reading can be slow (cloud-backed providers): off the main thread.
                reader.execute {
                    try {
                        val read = readContent(Uri.parse(uri))
                        runOnUiThread { result.success(read) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("read_failed", e.message, null) }
                    }
                }
            }
    }

    /** The display name and bytes of [uri], or null when over [MAX_BYTES]. */
    private fun readContent(uri: Uri): Map<String, Any?>? {
        var name: String? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0) name = c.getString(i)
            }
        }
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { s ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = s.read(buf)
                if (n < 0) break
                if (out.size() + n > MAX_BYTES) {
                    Log.d("Noted", "Pasted file is over the size limit; skipped")
                    return null
                }
                out.write(buf, 0, n)
            }
            return mapOf("name" to name, "bytes" to out.toByteArray())
        }
    }

    companion object {
        private const val MAX_BYTES = 100 * 1024 * 1024
    }
}
