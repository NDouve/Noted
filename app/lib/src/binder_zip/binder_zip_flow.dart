// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The binder `.zip` commands (design t6, desktop only): File › Save binder as
// .zip…, a binder row's Save as .zip…, and File › Open binder from .zip….

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../export/export_flow.dart' show exportWriterFor;
import '../export/export_roots.dart';
import '../export/export_targets.dart';
import '../export/export_write.dart';
import '../notebook.dart';
import 'binder_open.dart';
import 'binder_share.dart';
import 'zip_check.dart';
import 'zip_extract.dart' show binderZipFolderName;

/// Whether this device offers the binder `.zip` commands: desktop only (§7).
bool get binderZipSupported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

const XTypeGroup _zipType = XTypeGroup(label: 'Zip', extensions: ['zip']);

/// Asks where to save a binder `.zip` (the save dialog); null if cancelled.
/// Tests replace it.
@visibleForTesting
Future<String?> Function(String suggestedName) binderZipSavePicker = (suggested) async =>
    (await getSaveLocation(suggestedName: suggested, acceptedTypeGroups: const [_zipType], confirmButtonText: 'Save'))
        ?.path;

/// Asks for a `.zip` to open; null if cancelled. Tests replace it.
@visibleForTesting
Future<String?> Function() binderZipOpenPicker = () async =>
    (await openFile(acceptedTypeGroups: const [_zipType], confirmButtonText: 'Open'))?.path;

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

/// Saves binder [b] as a `.zip` the user picks (§3). Returns the notice, or
/// null when the user cancelled. Throws a [NotebookException] while the
/// binder list can't be trusted, before any picker.
Future<String?> saveBinderZip(
  Notebook nb,
  BinderSection b, {
  required List<String> Function() roots,
  required ExportWriter writer,
}) async {
  assert(Notebook.binderZipJobKind == null, 'a share started inside a binder .zip job');
  nb.binderZipRefuseWhileHeld();
  await nb.flush();
  final title = b.title;
  final path = await binderZipSavePicker('${binderFolderName(title)}.zip');
  if (path == null) return null;
  if (ExportTargetCheck(roots: roots, sandboxed: Platform.isMacOS).refuses(path)) return exportTargetRefusedMessage;
  final name = _baseName(path);
  final stem = name.toLowerCase().endsWith('.zip') ? name.substring(0, name.length - 4) : name;
  final share = BinderZipShare(nb, b.path, topName: binderZipFolderName([stem, binderFolderName(title)]));
  final BinderZipMade made;
  try {
    made = await share.run();
  } on BinderZipException catch (e) {
    return e.message;
  }
  try {
    final r = await writer.writeFile(path, made.path, made.identity);
    if (!r.exported) return r.message;
    final m = r.message ?? '';
    final exported = 'Exported $name.';
    return m.startsWith(exported) ? 'Saved $name.${m.substring(exported.length)}' : 'Saved $name.';
  } finally {
    await made.remove();
  }
}

/// Opens a binder from a `.zip` the user picks, into a parent folder the user
/// picks (§4). Returns the notice, or null when the user cancelled. Throws a
/// [NotebookException] while the binder list can't be trusted, before any
/// picker.
Future<String?> openBinderZip(Notebook nb, {required List<String> Function() roots}) async {
  nb.binderZipRefuseWhileHeld();
  final zip = await binderZipOpenPicker();
  if (zip == null) return null;
  // A placeholder or a file over the limit is refused before the next picker.
  try {
    await BinderZipOpen.checkZipFile(nb, zip);
  } on BinderZipException catch (e) {
    return e.message;
  }
  final pick = nb.pickFolder;
  if (pick == null) return null;
  final parent = await pick();
  if (parent == null) return null;
  try {
    return (await BinderZipOpen(nb, zipPath: zip, parent: parent, roots: roots).run()).message;
  } on BinderZipException catch (e) {
    return e.message;
  } on NotebookException catch (e) {
    return e.message;
  }
}

void _show(BuildContext context, String? message) {
  if (message == null || !context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message), showCloseIcon: true));
}

/// The Save as .zip… commands, with their notice shown in [context].
Future<void> runSaveBinderZip(BuildContext context, Notebook nb, BinderSection b) async {
  String? message;
  try {
    message = await saveBinderZip(
      nb,
      b,
      roots: () => exportRefusedRoots(nb, settings: nb.settings),
      writer: exportWriterFor(context),
    );
  } on NotebookException catch (e) {
    message = e.message;
  }
  if (context.mounted) _show(context, message);
}

/// The Open binder from .zip… command, with its notice shown in [context].
Future<void> runOpenBinderZip(BuildContext context, Notebook nb) async {
  String? message;
  try {
    message = await openBinderZip(nb, roots: () => exportRefusedRoots(nb, settings: nb.settings));
  } on NotebookException catch (e) {
    message = e.message;
  }
  if (context.mounted) _show(context, message);
}
