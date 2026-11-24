// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'convert.dart';
import 'document_render.dart';
import 'import_dialog.dart';
import 'import_format.dart';
import 'import_limits.dart';
import 'import_source.dart';
import 'sheet_image.dart';

/// The most images of one sheet file.
const int maxSheetImages = 50;

/// The images of one source, in order, ready to store; [stopped] if the
/// target no longer held (the user has been told).
final class RenderedImages {
  const RenderedImages(this.files, {this.stopped = false});

  final List<IncomingFile> files;
  final bool stopped;
}

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Reads [s] unless it is over the size limit (checked first). Null, with a
/// notice, if it was refused or couldn't be read.
Future<Uint8List?> _readLimited(ImportSource s, ImportLimits limits, List<String> notices) async {
  try {
    if (await s.length() > limits.sourceBytes) {
      notices.add('"${s.name}" is too large to import.');
      return null;
    }
    return await s.read();
  } on FileSystemException catch (e) {
    debugPrint('Reading ${s.name} failed: $e');
    notices.add('"${s.name}" could not be read.');
    return null;
  }
}

String _pages(List<int> pages) => pages.length == 1 ? 'page ${pages.single}' : 'pages ${pages.join(', ')}';

/// Renders the pages of a PDF as PNGs through the platform renderer: the
/// document is opened once, a PDF of over [maxImportPages] pages asks for a
/// range, and every page is rendered before anything is stored. The document
/// is closed whatever happens. A page that fails is left out and named in the
/// notices.
Future<RenderedImages> renderPdfPages(
  BuildContext context,
  ImportTarget target,
  ImportSource s,
  ImportLimits limits,
  List<String> notices,
  String Function() stopText,
) async {
  const none = RenderedImages([]);
  final bytes = await _readLimited(s, limits, notices);
  if (bytes == null) return none;
  if (!target.holds) {
    target.store.notify(stopText());
    return const RenderedImages([], stopped: true);
  }
  final OpenedDocument doc;
  try {
    doc = await documentRenderer.open(bytes);
  } on DocumentPasswordException {
    notices.add('"${s.name}" is password-protected.');
    return none;
  } on DocumentRenderException catch (e) {
    debugPrint('Opening ${s.name} failed: $e');
    notices.add('"${s.name}" can’t be read.');
    return none;
  }
  try {
    if (doc.pageCount < 1) {
      notices.add('"${s.name}" has no pages to import.');
      return none;
    }
    var from = 1, to = doc.pageCount;
    if (doc.pageCount > maxImportPages) {
      if (!context.mounted) return none;
      final range = await showPageRangeDialog(context, fileName: s.name, pageCount: doc.pageCount);
      if (range == null) return none;
      if (!target.holds) {
        target.store.notify(stopText());
        return const RenderedImages([], stopped: true);
      }
      (from, to) = (range.from, range.to);
    }
    final stem = _stem(s.name);
    final files = <IncomingFile>[];
    final failed = <int>[];
    for (var page = from; page <= to; page++) {
      if (!target.holds) {
        target.store.notify(stopText());
        return const RenderedImages([], stopped: true);
      }
      try {
        final png = await documentRenderer.render(doc.handle, page - 1);
        if (png == null) continue; // under 1 px on a side: skipped
        final size = pngSize(png);
        if (size == null ||
            size.width < 1 ||
            size.height < 1 ||
            size.width > maxImageSide ||
            size.height > maxImageSide ||
            size.width * size.height > maxImagePixels) {
          failed.add(page);
          continue;
        }
        files.add(IncomingFile('$stem-$page.png', png));
      } on Exception catch (e) {
        debugPrint('Rendering page $page of ${s.name} failed: $e');
        failed.add(page);
      }
    }
    if (failed.isNotEmpty) notices.add('"${s.name}": ${_pages(failed)} could not be shown, so left out.');
    if (files.isEmpty && failed.isEmpty) notices.add('"${s.name}" has no pages to import.');
    return RenderedImages(files);
  } finally {
    await documentRenderer.close(doc.handle);
  }
}

/// Draws a sheet or csv as images: its tables read in an isolate, then drawn
/// in row chunks of at most 100 rows and 2,000 cells, one PNG each.
Future<RenderedImages> renderSheetImages(
  ImportTarget target,
  ImportSource s,
  ImportFormat format,
  ImportLimits limits,
  List<String> notices,
  String Function() stopText, {
  required ImportRunner run,
}) async {
  final bytes = await _readLimited(s, limits, notices);
  if (bytes == null) return const RenderedImages([]);
  if (!target.holds) {
    target.store.notify(stopText());
    return const RenderedImages([], stopped: true);
  }
  final read = await convertToSheets(format, s.name, bytes, limits, run: run);
  if (!target.holds) {
    target.store.notify(stopText());
    return const RenderedImages([], stopped: true);
  }
  if (read.error != null) {
    notices.add('"${s.name}" ${read.error}.');
    return const RenderedImages([]);
  }
  notices.addAll(read.notices);
  final stem = _stem(s.name);
  final files = <IncomingFile>[];
  var cut = false, cellsCut = false;
  for (final sheet in read.sheets) {
    final plan = await planSheet(sheet, holds: () => target.holds);
    if (plan == null) {
      target.store.notify(stopText());
      return const RenderedImages([], stopped: true);
    }
    cellsCut = cellsCut || plan.cut;
    for (final (from, to) in plan.chunks) {
      if (files.length >= maxSheetImages) {
        cut = true;
        break;
      }
      if (!target.holds) {
        target.store.notify(stopText());
        return const RenderedImages([], stopped: true);
      }
      try {
        files.add(IncomingFile('$stem-${files.length + 1}.png', await drawSheetChunk(sheet, plan, from, to)));
      } on Object catch (e) {
        debugPrint('Drawing a sheet image of ${s.name} failed: $e');
        notices.add('"${s.name}" could not be drawn.');
        return const RenderedImages([]);
      }
    }
  }
  if (cellsCut) notices.add('"${s.name}": some cells were too long to show in full.');
  if (cut) notices.add('"${s.name}" is too long; the first $maxSheetImages images were imported.');
  return RenderedImages(files);
}
