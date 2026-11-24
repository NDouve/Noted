// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show FileSystemException, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart' show AttachmentStorage, embedLimitBytes;

import '../device_storage.dart' show isMobilePlatform;
import 'convert.dart';
import 'folder_store.dart';
import 'import_dialog.dart';
import 'import_format.dart';
import 'import_images.dart';
import 'import_limits.dart';
import 'import_source.dart';

export 'import_source.dart';

/// What this device can render as images: PDF pages where a platform
/// renderer exists (Windows, macOS, iOS, Android; not Linux), a sheet as an
/// image everywhere. Tests change it.
ImportCapabilities importCapabilities = ImportCapabilities(
  pdfPages: !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isIOS || Platform.isAndroid),
  sheetImages: true,
);

/// The limits of this device; tests change it.
@visibleForTesting
ImportLimits Function() importLimits = () => isMobilePlatform ? ImportLimits.mobile : ImportLimits.desktop;

/// How many imports are running now.
@visibleForTesting
final ValueNotifier<int> importsRunning = ValueNotifier<int>(0);

/// Where conversions run; tests change it.
@visibleForTesting
ImportRunner importRunner = runInIsolate;

/// Asks the user for files to import (the Import command); tests change it.
@visibleForTesting
Future<List<ImportSource>> Function() importPicker = pickImportSources;

/// The open dialog, with the formats an import takes.
Future<List<ImportSource>> pickImportSources() async {
  final files = await openFiles(
    acceptedTypeGroups: [
      XTypeGroup(
        label: 'Documents and images',
        extensions: importPickerExtensions,
        uniformTypeIdentifiers: const [
          'public.plain-text',
          'net.daringfireball.markdown',
          'public.comma-separated-values-text',
          'public.tab-separated-values-text',
          'com.adobe.pdf',
          'org.openxmlformats.wordprocessingml.document',
          'org.openxmlformats.spreadsheetml.sheet',
          'org.openxmlformats.presentationml.presentation',
          'public.image',
        ],
      ),
    ],
  );
  return [for (final f in files) ImportSource.fromFile(f)];
}

/// Imports [sources] into the page [target] was captured for: asks how for
/// each file that has a choice, converts, and adds the boxes through [canvas].
/// The target is checked after each dialog, after each conversion and before
/// each file and box; if it no longer holds, nothing more is stored or added
/// and the user is told once.
Future<void> runImport(
  BuildContext context,
  PageCanvasState canvas,
  ImportTarget target,
  List<ImportSource> sources,
) async {
  importsRunning.value++;
  try {
    await _runImport(context, canvas, target, sources);
  } finally {
    importsRunning.value--;
  }
}

Future<void> _runImport(
  BuildContext context,
  PageCanvasState canvas,
  ImportTarget target,
  List<ImportSource> sources,
) async {
  if (sources.isEmpty) return;
  final store = target.store;
  final caps = importCapabilities;
  final limits = importLimits();
  final off = target.disallowed;
  final switchedOff = {
    for (final t in [ImportChoice.asImage.typeId, ImportChoice.asFile.typeId, ImportChoice.asText.typeId])
      if (canvas.controller.modules.moduleFor(t) == null) t,
  };

  // The choice for each file that asks; the others take the usual path.
  final formats = [for (final s in sources) ImportFormat.of(s.name)];
  final choice = <int, ImportChoice>{};
  final sticky = <ImportFormat, ImportChoice>{};
  for (var i = 0; i < sources.length; i++) {
    final f = formats[i];
    if (f == null || !importAsks(f, caps, off, switchedOff)) continue;
    final decided = sticky[f];
    if (decided != null) {
      choice[i] = decided;
      continue;
    }
    if (!context.mounted) return;
    final more = [for (var j = i + 1; j < sources.length; j++) if (formats[j] == f) j].length;
    final d = await showImportDialog(
      context,
      fileName: sources[i].name,
      options: importOptions(f, caps, disallowed: off, switchedOff: switchedOff),
      more: more,
    );
    if (d == null) return;
    if (!target.holds) {
      store.notify(importStoppedNotice);
      return;
    }
    choice[i] = d.choice;
    if (d.useForAll) sticky[f] = d.choice;
  }

  final notices = <String>[];
  String stopText() => [...notices, importStoppedNotice].join(' ');
  for (var i = 0; i < sources.length; i++) {
    if (!target.holds) {
      store.notify(stopText());
      return;
    }
    if (!context.mounted) return;
    final s = sources[i];
    final bool stopped;
    switch (choice[i]) {
      case null:
        stopped = await _importFile(canvas, target, s, null, notices, stopText);
      case ImportChoice.asFile:
        stopped = await _importFile(canvas, target, s, ImportChoice.asFile.typeId, notices, stopText);
      case ImportChoice.asText || ImportChoice.asTable:
        stopped = await _importNotes(canvas, target, s, formats[i]!, limits, notices, stopText);
      case ImportChoice.pagesAsImages:
        stopped = await _importImages(context, canvas, target, s, formats[i]!, choice[i]!, limits, notices, stopText);
      case ImportChoice.asImage when formats[i] == ImportFormat.sheet || formats[i] == ImportFormat.csv:
        stopped = await _importImages(context, canvas, target, s, formats[i]!, choice[i]!, limits, notices, stopText);
      case ImportChoice.asImage || ImportChoice.slidesAsImages:
        // Word pages and slides as images stay off: no layout engine (design §4).
        throw StateError('${choice[i]} is not available for ${formats[i]}');
    }
    if (stopped) return;
  }
  if (notices.isNotEmpty && target.holds) store.notify(notices.join(' '));
}

/// The Import command: the target is taken first, then the open dialog.
Future<void> runImportCommand(BuildContext context, PageCanvasState canvas) async {
  if (!canvas.mounted) return;
  final target = canvas.captureImportTarget(null);
  if (target == null) return;
  final sources = await importPicker();
  if (sources.isEmpty || !context.mounted) return;
  if (!target.holds) {
    target.store.notify(importStoppedNotice);
    return;
  }
  await runImport(context, canvas, target, sources);
}

/// Adds one file as it is, with the module chosen by file (or [module]).
/// True if the import stopped.
Future<bool> _importFile(
  PageCanvasState canvas,
  ImportTarget target,
  ImportSource s,
  String? module,
  List<String> notices,
  String Function() stopText,
) async {
  final Uint8List bytes;
  try {
    bytes = await s.read();
  } on FileSystemException catch (e) {
    debugPrint('Reading ${s.name} failed: $e');
    notices.add('"${s.name}" could not be read.');
    return false;
  }
  final r = await canvas.insertImportInto(target, [IncomingFile(s.name, bytes)], module: module, stopNotice: stopText());
  if (r.stopped) return true;
  _noteFailures(r, s.name, notices);
  return false;
}

void _noteFailures(ImportInsert r, String name, List<String> notices) {
  if (r.refused) notices.add('"$name" can’t be added: not allowed on this page.');
  for (final n in r.unwritable) {
    notices.add('"$n" could not be added: the page\'s folder could not be written.');
  }
  if (r.failed.isNotEmpty) notices.add('"$name" could not be added.');
}

/// Renders a PDF's pages or draws a sheet as images, all of them first, then
/// adds one image box each, stacked down from the point. If together they are
/// over the embed limit and the page embeds, they go to the folder (0098's
/// notice). True if the import stopped.
Future<bool> _importImages(
  BuildContext context,
  PageCanvasState canvas,
  ImportTarget target,
  ImportSource s,
  ImportFormat format,
  ImportChoice choice,
  ImportLimits limits,
  List<String> notices,
  String Function() stopText,
) async {
  final rendered = choice == ImportChoice.pagesAsImages
      ? await renderPdfPages(context, target, s, limits, notices, stopText)
      : await renderSheetImages(target, s, format, limits, notices, stopText, run: importRunner);
  if (rendered.stopped) return true;
  if (rendered.files.isEmpty) return false;
  final total = rendered.files.fold<int>(0, (n, f) => n + f.bytes.length);
  final store = target.store;
  final forced = store.storage == AttachmentStorage.embedded && total > embedLimitBytes;
  final r = await canvas.insertImportInto(
    target,
    rendered.files,
    module: ImportChoice.asImage.typeId,
    stopNotice: stopText(),
    storeVia: forced ? forceFolderStorage(store) : null,
  );
  if (r.stopped) return true;
  _noteFailures(r, s.name, notices);
  return false;
}

/// Converts one file to note boxes and adds them. True if the import stopped.
Future<bool> _importNotes(
  PageCanvasState canvas,
  ImportTarget target,
  ImportSource s,
  ImportFormat format,
  ImportLimits limits,
  List<String> notices,
  String Function() stopText,
) async {
  final Uint8List bytes;
  try {
    // The size is checked before the file is read.
    if (await s.length() > limits.sourceBytes) {
      notices.add('"${s.name}" is too large to import.');
      return false;
    }
    bytes = await s.read();
  } on FileSystemException catch (e) {
    debugPrint('Reading ${s.name} failed: $e');
    notices.add('"${s.name}" could not be read.');
    return false;
  }
  if (!target.holds) {
    target.store.notify(stopText());
    return true;
  }
  final converted = await convertToNotes(format, s.name, bytes, limits, run: importRunner);
  if (!target.holds) {
    target.store.notify(stopText());
    return true;
  }
  if (converted.error != null) {
    notices.add('"${s.name}" ${converted.error}.');
    return false;
  }
  notices.addAll(converted.notices);
  final files = [
    for (var i = 0; i < converted.boxes.length; i++) noteImportFile(s.name, converted.boxes[i], i, converted.boxes.length),
  ];
  final r = await canvas.insertImportInto(target, files, module: ImportChoice.asText.typeId, stopNotice: stopText());
  if (r.stopped) return true;
  if (r.failed.isNotEmpty || r.unwritable.isNotEmpty) {
    notices.add('"${s.name}" could not be imported.');
  }
  return false;
}
