// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    override fun onDestroy() {
        reader.shutdown()
        super.onDestroy()
    }

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
                    } catch (e: Throwable) {
                        // Includes OutOfMemoryError: a file too big for the heap is skipped.
                        Log.d("Noted", "Reading a pasted file failed: $e")
                        runOnUiThread { result.success(null) }
                    }
                }
            }
    }

    /** The display name and bytes of [uri], or null when over [MAX_BYTES]. */
    private fun readContent(uri: Uri): Map<String, Any?>? {
        var name: String? = null
        var size = -1L
        contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null
        )?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (n >= 0) name = c.getString(n)
                val z = c.getColumnIndex(OpenableColumns.SIZE)
                if (z >= 0 && !c.isNull(z)) size = c.getLong(z)
            }
        }
        if (size > MAX_BYTES) return tooBig()
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { s ->
            // A reported size only refuses early: some providers report 0 or a
            // stale size, so the bytes are read up to the limit whatever it says.
            val out = ByteArrayOutputStream(if (size in 1L..MAX_BYTES.toLong()) size.toInt() else 64 * 1024)
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = s.read(buf)
                if (n < 0) break
                if (out.size() + n > MAX_BYTES) return tooBig()
                out.write(buf, 0, n)
            }
            return mapOf("name" to name, "bytes" to out.toByteArray())
        }
    }

    private fun tooBig(): Map<String, Any?>? {
        Log.d("Noted", "Pasted file is over the size limit; skipped")
        return null
    }

    companion object {
        private const val MAX_BYTES = 50 * 1024 * 1024
    }
}
