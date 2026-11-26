// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import '../import/convert.dart' show ImportRunner, runInIsolate;
import '../settings_panel.dart' show boxTypeSingularName;
import 'export_derive.dart';
import 'export_dialogs.dart';
import 'export_names.dart';
import 'export_render.dart';
import 'export_targets.dart';
import 'export_write.dart';

/// Why a box can't be exported, or what its export needs.
sealed class ExportCheck {
  const ExportCheck();
}

/// The box can't be exported now, for [reason] (shown as a notice).
final class ExportBlocked extends ExportCheck {
  const ExportBlocked(this.reason);

  final String reason;
}

/// The box can be exported in [formats] (the module's, with JPEG and PDF after
/// a PNG), from [data], the data the page's controller holds.
final class ExportReady extends ExportCheck {
  const ExportReady({
    required this.box,
    required this.module,
    required this.data,
    required this.formats,
    required this.label,
  });

  final BoxRecord box;
  final BoxModule<Object?> module;
  final Object? data;
  final List<ExportFormat> formats;

  /// The box type's name ("Note"), for the file name and the dialog.
  final String label;
}

/// Shown when the box is gone.
const String exportBoxRemoved = 'Box removed. Nothing was exported.';

/// Shown when the page changed while an export was under way.
const String exportPageChanged = 'Export stopped: the page changed.';

/// The formats the format dialog shows for a module's [listed] formats: the
/// module's own (a `jpeg` or `pdf` it lists is dropped), then JPEG and PDF
/// after a PNG.
List<ExportFormat> exportFormatsFor(List<ExportFormat> listed) {
  final own = [for (final f in listed) if (!ExportFormat.hostIds.contains(f.id)) f];
  return [
    for (final f in own) ...[
      f,
      if (f.id == ExportFormat.png.id) ...[ExportFormat.jpeg, ExportFormat.pdf],
    ],
  ];
}

/// Whether the box [boxId] of the captured page can be exported now: it
/// exists, isn't encrypted, its type is allowed on the page, its module is on
/// and lists a format, and, for a file, the file is ready. Nothing is decoded
/// for a box that fails an earlier check (the codec is never called for an
/// encrypted or disallowed box).
Future<ExportCheck> checkBoxForExport(ExportTarget target, String boxId) async {
  final c = target.controller;
  final node = c.page.node(boxId);
  if (node is! BoxRecord) return const ExportBlocked(exportBoxRemoved);
  if (isEncryptedBox(node)) return const ExportBlocked('Encrypted box');
  if (target.disallowed.contains(node.typeId)) return const ExportBlocked('Not allowed on this page');
  const off = ExportBlocked('This box type is off on this device.');
  if (c.modules.moduleFor(node.typeId) == null) return off;
  final r = c.modules.codecs.resolve(node);
  final BoxResolution resolved = r;
  switch (resolved) {
    case UnsupportedBox(:final reason):
      return reason == UnsupportedReason.unreadable
          ? const ExportBlocked("This box can't be read. Nothing was exported.")
          : off;
    case LiveBox(:final data):
      final module = c.modules.moduleFor(node.typeId)!;
      final formats = exportFormatsFor(module.hostExportFormats(data));
      if (formats.isEmpty) return const ExportBlocked("This box can't be exported.");
      final file = switch (data) {
        ImageData(:final ref) => ref,
        FileData(:final ref) => ref,
        _ => null,
      };
      if (file != null) {
        final problem = await _fileProblem(file, target.store);
        if (problem != null) return ExportBlocked(problem);
      }
      return ExportReady(
        box: node,
        module: module,
        data: data,
        formats: formats,
        label: boxTypeSingularName(node.typeId) ?? 'Box',
      );
  }
}

// The caller-side checks of a file, in order (design: reading originals).
Future<String?> _fileProblem(AttachmentRef ref, AttachmentStore? store) async {
  final name = ref.name;
  if (attachmentNameInvalid(ref)) return 'File not found: $name';
  if (downloadOf(ref, store) != AttachmentDownload.onDevice) {
    return '$name is downloading. Try again in a moment.';
  }
  return switch (await verifyAttachment(ref, store)) {
    AttachmentState.ok => null,
    AttachmentState.syncing => '$name is still syncing.',
    AttachmentState.damaged => '$name is damaged on this device. Nothing was exported.',
  };
}

/// The name of an original's own file, or null.
String? _originalName(Object? data) => switch (data) {
  ImageData(:final ref) => ref.name,
  FileData(:final ref) => ref.name,
  _ => null,
};

/// Asks for the file to write (the save dialog); null if cancelled. Tests
/// replace it.
@visibleForTesting
Future<String?> Function(String suggestedName, ExportFormat format) exportSavePicker = _saveDialog;

Future<String?> _saveDialog(String suggestedName, ExportFormat format) async {
  final ext = format.id == ExportFormat.original.id ? <String>[] : [format.extension];
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: ext.isEmpty ? const [] : [XTypeGroup(label: format.label, extensions: ext)],
    confirmButtonText: 'Export',
  );
  return location?.path;
}

/// Asks which format; tests replace it.
@visibleForTesting
Future<ExportFormat?> Function(BuildContext context, String boxLabel, List<ExportFormat> formats) exportFormatPicker =
    (context, label, formats) => showExportFormatDialog(context, boxLabel: label, formats: formats);

/// Asks "Replace NAME?"; tests replace it.
@visibleForTesting
Future<bool> Function(BuildContext context, String name) exportReplaceAsk = showReplaceDialog;

/// Asks "Put back NAME?"; tests replace it.
@visibleForTesting
Future<bool> Function(BuildContext context, String name, String aside) exportPutBackAsk = showPutBackDialog;

/// Where the JPEG and PDF conversion runs; tests replace it.
@visibleForTesting
ImportRunner exportRunner = runInIsolate;

/// The writer of the export files. One for the app run, so the staging temps
/// and asides of an export in flight are known to the cleanup.
@visibleForTesting
ExportWriter? exportWriterOverride;

ExportWriter? _writer;

// The context the prompts of the export under way are shown in. The writer
// outlives one export (it knows the staging temps in flight), so it asks for the
// context each time.
BuildContext? _promptContext;

ExportWriter _writerFor(BuildContext context) {
  _promptContext = context;
  return exportWriterOverride ??
      (_writer ??= ExportWriter(
        askReplace: (name) async {
          final c = _promptContext;
          return c != null && c.mounted && await exportReplaceAsk(c, name);
        },
        askPutBack: (name, aside) async {
          final c = _promptContext;
          return c != null && c.mounted && await exportPutBackAsk(c, name, aside);
        },
        sandboxed: Platform.isMacOS,
      ));
}

void Function(String) _noticeTo(BuildContext context, ExportTarget target) => (message) {
  final store = target.store;
  if (store != null) {
    store.notify(message);
    return;
  }
  if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
};

/// The Export… command (File menu, desktop): exports the selected box of the
/// open page in a format its module lists, to a file the user picks. [roots]
/// are the folders an export never writes into.
///
/// The page is captured first and again after the save dialog, and before any
/// bytes are made the box is checked again (it exists, is allowed, its module
/// is on, it isn't encrypted). The bytes are made in memory from the record the
/// page's controller holds.
Future<void> runExportCommand(
  BuildContext context,
  PageCanvasState canvas, {
  required List<String> Function() roots,
}) async {
  if (!canvas.mounted) return;
  final target = canvas.captureExportTarget();
  final say = _noticeTo(context, target);
  final boxId = target.controller.selectedId;
  if (boxId == null) return;
  final first = await checkBoxForExport(target, boxId);
  if (first is ExportBlocked) {
    say(first.reason);
    return;
  }
  first as ExportReady;
  if (!context.mounted || !target.holds) {
    say(exportPageChanged);
    return;
  }
  final ExportFormat? format;
  if (first.formats.length == 1) {
    format = first.formats.single;
  } else {
    format = await exportFormatPicker(context, first.label, first.formats);
  }
  if (format == null) return;
  if (!context.mounted || !target.holds) {
    say(exportPageChanged);
    return;
  }

  final suggested = suggestedExportName(
    pageTitle: target.controller.page.meta.title,
    boxLabel: first.label,
    extension: format.extension,
    original: format.id == ExportFormat.original.id ? _originalName(first.data) : null,
  );
  final path = await exportSavePicker(suggested, format);
  if (path == null) return;

  // The page again, after the dialog.
  if (!context.mounted || !canvas.mounted || !target.holds) {
    say(exportPageChanged);
    return;
  }
  if (ExportTargetCheck(roots: roots, sandboxed: Platform.isMacOS).refuses(path)) {
    say(exportTargetRefusedMessage);
    return;
  }

  final result = await _writerFor(context).write(path, () async {
    // The box is checked again before any bytes are made.
    if (!canvas.mounted || !target.holds) {
      say(exportPageChanged);
      return null;
    }
    final again = canvas.captureExportTarget();
    final check = await checkBoxForExport(again, boxId);
    if (check is ExportBlocked) {
      say(check.reason);
      return null;
    }
    check as ExportReady;
    if (!check.formats.contains(format)) {
      say("This box can't be exported.");
      return null;
    }
    if (!context.mounted) return null;
    try {
      final bytes = await _makeBytes(context, again, check, format!);
      if (bytes == null) say('Nothing was exported.');
      return bytes;
    } on FormatException catch (e) {
      // A module's own refusal (an image too large to convert).
      say(e.message);
      return null;
    }
  });
  final message = result.message;
  if (message != null && context.mounted) say(message);
}

Future<Uint8List?> _makeBytes(
  BuildContext context,
  ExportTarget target,
  ExportReady box,
  ExportFormat format,
) async {
  final b = box.box.bounds;
  final size = Size(b.width, b.height);
  final raw = format.id == ExportFormat.jpeg.id || format.id == ExportFormat.pdf.id;
  final ctx = ExportContext(
    attachments: target.store,
    size: size,
    viewRenderer: () => renderBoxPng(
      context: context,
      module: box.module,
      data: box.data,
      boxId: box.box.id,
      size: size,
      attachments: target.store,
    ),
  );
  final file = await box.module.hostExport(box.data, raw ? ExportFormat.png : format, ctx);
  if (file == null) return null;
  if (!raw) return file.bytes;
  return derivePngExport(
    png: file.bytes,
    name: _originalName(box.data) ?? box.label,
    pdf: format.id == ExportFormat.pdf.id,
    boxSize: size,
    run: exportRunner,
  );
}
