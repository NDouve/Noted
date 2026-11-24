// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show FileSystemException;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:noted_canvas/noted_canvas.dart';

import '../device_storage.dart' show isMobilePlatform;
import 'convert.dart';
import 'import_dialog.dart';
import 'import_format.dart';
import 'import_limits.dart';

/// A file offered for import. Its bytes are read only when it is used, so
/// its size can be checked first.
final class ImportSource {
  const ImportSource(this.name, {required this.length, required this.read});

  /// A file from a drop or the open dialog.
  factory ImportSource.fromFile(XFile f) =>
      ImportSource(f.name.split(RegExp(r'[\\/]')).last, length: f.length, read: f.readAsBytes);

  /// The name the user sees, with its extension.
  final String name;
  final Future<int> Function() length;
  final Future<Uint8List> Function() read;
}

/// What this device can render as images; the PDF and sheet images are
/// turned on where a renderer exists. Tests change it.
ImportCapabilities importCapabilities = const ImportCapabilities();

/// The limits of this device; tests change it.
ImportLimits Function() importLimits = () => isMobilePlatform ? ImportLimits.mobile : ImportLimits.desktop;

/// How many imports are running now.
final ValueNotifier<int> importsRunning = ValueNotifier<int>(0);

/// Where conversions run; tests change it.
ImportRunner importRunner = runInIsolate;

/// Asks the user for files to import (the Import command); tests change it.
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

  // The choice for each file that asks; the others take the usual path.
  final formats = [for (final s in sources) ImportFormat.of(s.name)];
  final choice = <int, ImportChoice>{};
  final sticky = <ImportFormat, ImportChoice>{};
  for (var i = 0; i < sources.length; i++) {
    final f = formats[i];
    if (f == null || !importAsks(f, caps, off)) continue;
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
      options: importOptions(f, caps, disallowed: off),
      more: more,
    );
    if (!target.holds) {
      store.notify(importStoppedNotice);
      return;
    }
    if (d == null) return;
    choice[i] = d.choice;
    if (d.useForAll) sticky[f] = d.choice;
  }

  final notices = <String>[];
  for (var i = 0; i < sources.length; i++) {
    if (!target.holds) {
      store.notify(importStoppedNotice);
      return;
    }
    final s = sources[i];
    final c = choice[i];
    final result = c != null && c.makesNotes
        ? await _importNotes(canvas, target, s, formats[i]!, limits, notices)
        : await _importFile(canvas, target, s, c == ImportChoice.asFile ? ImportChoice.asFile.typeId : null, notices);
    if (result) return;
  }
  if (notices.isNotEmpty && target.holds) store.notify(notices.join(' '));
}

/// Adds one file as it is, with the module chosen by file (or [module]).
/// True if the import stopped.
Future<bool> _importFile(
  PageCanvasState canvas,
  ImportTarget target,
  ImportSource s,
  String? module,
  List<String> notices,
) async {
  final Uint8List bytes;
  try {
    bytes = await s.read();
  } on FileSystemException catch (e) {
    debugPrint('Reading ${s.name} failed: $e');
    notices.add('"${s.name}" could not be read.');
    return false;
  }
  final r = await canvas.insertImportInto(target, [IncomingFile(s.name, bytes)], module: module);
  if (r.stopped) return true;
  if (r.refused) notices.add('"${s.name}" can’t be added: not allowed on this page.');
  if (r.failed.isNotEmpty) notices.add('"${s.name}" could not be added.');
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
  final converted = await convertToNotes(format, s.name, bytes, limits, run: importRunner);
  if (!target.holds) {
    target.store.notify(importStoppedNotice);
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
  final r = await canvas.insertImportInto(target, files, module: ImportChoice.asText.typeId);
  if (r.stopped) return true;
  if (r.failed.isNotEmpty) notices.add('"${s.name}" could not be imported.');
  return false;
}
