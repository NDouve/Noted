// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package io.github.ndouve.noted

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

/**
 * PDF pages as PNG images, with [PdfRenderer] (no dependency).
 *
 * Channel `noted/document_render` (standard codec):
 *
 *  - `open({bytes})` -> `{handle, pageCount}`. The error code `password` for a
 *    PDF that needs a password, `invalid` for one that cannot be read.
 *  - `render({handle, index, maxW, maxH})` -> PNG bytes of page `index` (from 0)
 *    at 150 dpi, scaled down so that neither side is over `maxW` or `maxH` and
 *    the page is at most 16 megapixels; null if a side would be under 1 px; the
 *    error code `render` if the page cannot be drawn.
 *  - `close({handle})` -> null.
 *
 * All work runs on one background executor. The bytes are written to a private
 * temp file in [cacheDir] (a fresh name, outside every storage root), which is
 * deleted in `close` and in a `finally`. Replies go out on the main thread.
 * [detach] (the engine detaches) closes every open document.
 */
class DocumentRender(messenger: BinaryMessenger, private val cacheDir: File) {
    private class Doc(val renderer: PdfRenderer, val fd: ParcelFileDescriptor, val file: File) {
        fun close() {
            try {
                renderer.close()
            } catch (e: Throwable) {
                Log.d("Noted", "Closing a PDF failed: $e")
            }
            try {
                fd.close()
            } catch (e: IOException) {
                Log.d("Noted", "Closing a PDF file failed: $e")
            }
            file.delete()
        }
    }

    private class Failure(val code: String, message: String) : Exception(message)

    private val channel = MethodChannel(messenger, "noted/document_render")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val documents = HashMap<Int, Doc>()
    private var next = 1

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        // Leftovers of a killed run.
        cacheDir.listFiles { f -> f.name.startsWith(PREFIX) }?.forEach { it.delete() }
    }

    /** The engine detaches: close every open document. */
    fun detach() {
        channel.setMethodCallHandler(null)
        try {
            worker.execute {
                synchronized(documents) {
                    documents.values.forEach { it.close() }
                    documents.clear()
                }
            }
        } catch (e: RejectedExecutionException) {
            // Already shut down.
        }
        worker.shutdown()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("bad_args", "bytes is required", null)
                    return
                }
                run(result) { open(bytes) }
            }
            "render" -> {
                val handle = call.argument<Int>("handle")
                val index = call.argument<Int>("index")
                val maxW = call.argument<Int>("maxW")
                val maxH = call.argument<Int>("maxH")
                if (handle == null || index == null || maxW == null || maxH == null || index < 0 || maxW < 1 || maxH < 1) {
                    result.error("bad_args", "handle, index, maxW and maxH are required", null)
                    return
                }
                run(result) { render(handle, index, maxW, maxH) }
            }
            "close" -> {
                val handle = call.argument<Int>("handle")
                run(result) {
                    if (handle != null) {
                        synchronized(documents) { documents.remove(handle) }?.close()
                    }
                    null
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        try {
            worker.execute {
                try {
                    val value = work()
                    main.post { result.success(value) }
                } catch (e: Failure) {
                    main.post { result.error(e.code, e.message, null) }
                } catch (e: Throwable) {
                    // Includes OutOfMemoryError: the page is skipped.
                    Log.d("Noted", "A PDF call failed: $e")
                    main.post { result.error("render", e.message, null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("closed", "The renderer is closed", null)
        }
    }

    private fun open(bytes: ByteArray): Map<String, Any> {
        val file = File(cacheDir, PREFIX + UUID.randomUUID().toString() + ".pdf")
        var fd: ParcelFileDescriptor? = null
        var kept = false
        try {
            file.writeBytes(bytes)
            fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = try {
                PdfRenderer(fd)
            } catch (e: SecurityException) {
                // PdfRenderer reports a password-protected document this way.
                throw Failure("password", "The document needs a password")
            } catch (e: IOException) {
                throw Failure("invalid", "The document cannot be read")
            }
            val handle: Int
            synchronized(documents) {
                handle = next++
                documents[handle] = Doc(renderer, fd, file)
            }
            kept = true
            return mapOf("handle" to handle, "pageCount" to renderer.pageCount)
        } finally {
            if (!kept) {
                try {
                    fd?.close()
                } catch (e: IOException) {
                    Log.d("Noted", "Closing a PDF file failed: $e")
                }
                file.delete()
            }
        }
    }

    private fun render(handle: Int, index: Int, maxW: Int, maxH: Int): ByteArray? {
        val doc = synchronized(documents) { documents[handle] } ?: throw Failure("closed", "The document is not open")
        if (index >= doc.renderer.pageCount) throw Failure("render", "No such page")
        doc.renderer.openPage(index).use { page ->
            val size = fitPixels(page.width.toDouble(), page.height.toDouble(), maxW, maxH) ?: return null
            val bitmap = Bitmap.createBitmap(size.first, size.second, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = ByteArrayOutputStream()
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                    throw Failure("render", "The page could not be encoded")
                }
                return out.toByteArray()
            } finally {
                bitmap.recycle()
            }
        }
    }

    companion object {
        private const val PREFIX = "noted-render-"
        private const val DPI = 150.0
        private const val MAX_PIXELS = 16.0 * 1000 * 1000

        /** Page sizes are in points (1/72 inch). Null if a side would be under 1 px. */
        fun fitPixels(widthPt: Double, heightPt: Double, maxW: Int, maxH: Int): Pair<Int, Int>? {
            val w = widthPt * DPI / 72.0
            val h = heightPt * DPI / 72.0
            if (!(w > 0) || !(h > 0) || w.isInfinite() || h.isInfinite()) return null
            val s = min(1.0, min(min(maxW / w, maxH / h), sqrt(MAX_PIXELS / (w * h))))
            var pw = floor(w * s)
            var ph = floor(h * s)
            if (pw * ph > MAX_PIXELS) {
                val f = sqrt(MAX_PIXELS / (pw * ph))
                pw = floor(pw * f)
                ph = floor(ph * f)
            }
            if (pw < 1 || ph < 1) return null
            return Pair(pw.toInt(), ph.toInt())
        }
    }
}
