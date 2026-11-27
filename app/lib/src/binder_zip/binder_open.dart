// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Opening a binder from a `.zip` (design t6 §4, build rules Z1, Z2): checked
// before anything is written, Guarded in the bytes, extracted into a fresh
// hidden staging folder, read back and verified, renamed into place without
// replacing anything, then added. Every file this open created is removed
// only through `deleteFileIfMatches(identity:)`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

import '../attachment_copy.dart' show removeFolderCoordinated;
import '../export/export_targets.dart';
import '../notebook.dart';
import 'binder_set.dart';
import 'zip_check.dart';
import 'zip_extract.dart';

/// "Couldn't make the binder's folder: [reason]."
BinderZipException folderNotMade(String reason) => BinderZipException("Couldn't make the binder's folder: $reason.");

/// Moves a folder without replacing; [moveExclusive] in production. A seam.
typedef BinderZipMover = Future<MoveOutcome> Function(String from, String to, {void Function()? beforeOsCall});

Future<MoveOutcome> _move(String from, String to, {void Function()? beforeOsCall}) =>
    moveExclusive(from, to, beforeOsCall: beforeOsCall);

class _ReadBackFailed implements Exception {
  const _ReadBackFailed();
}

/// How an open ended: the notice, and the binder's folder when it was added.
final class BinderZipOpened {
  const BinderZipOpened(this.message, {this.path});

  final String message;
  final String? path;
}

/// One open of a binder `.zip` into a parent folder the user chose.
class BinderZipOpen {
  BinderZipOpen(
    this.notebook, {
    required this.zipPath,
    required this.parent,
    required this.roots,
    this.mover = _move,
    this.busyFor = const Duration(seconds: 5),
    this.busyStep = const Duration(milliseconds: 250),
    this.afterExtract,
    this.beforeRollback,
    this.afterRename,
    this.beforeAdd,
  });

  final Notebook notebook;
  final String zipPath;
  final String parent;

  /// The folders an export never writes into (the export roots).
  final List<String> Function() roots;

  final BinderZipMover mover;

  /// How long a busy rename is tried again, and how often.
  final Duration busyFor;
  final Duration busyStep;

  /// Test seams: after every file was written, before the read-back (Z2);
  /// before a rollback removes anything (R-1); after the rename, before the
  /// add (BL2: a crash there); after the rename's add check and before the add
  /// itself (the backstop).
  final Future<void> Function(String staging)? afterExtract;
  final Future<void> Function(ZipExtraction created)? beforeRollback;
  final Future<void> Function(String folder)? afterRename;
  final Future<void> Function(String folder)? beforeAdd;

  final String _sep = Platform.pathSeparator;

  /// Checks the parent folder (A3) and returns why it is refused, or null.
  static String? parentRefusal(Notebook nb, String parent, List<String> Function() roots) {
    final p = Directory(parent).absolute.path;
    if (!nb.isDefaultBinderFolder(p) && ExportTargetCheck(roots: roots, sandboxed: Platform.isMacOS).refuses(p)) {
      return exportTargetRefusedMessage;
    }
    // Inside a folder a binder (listed or not) is in: refused too.
    var d = Directory(p);
    while (true) {
      if (File('${d.path}${Platform.pathSeparator}$binderFileName').existsSync()) return exportTargetRefusedMessage;
      final up = d.parent;
      if (up.path == d.path) break;
      d = up;
    }
    return nb.binderZipParentRefusal(p);
  }

  /// Refuses a `.zip` that is a placeholder or over the limit, before it is
  /// read (metadata only).
  static Future<void> checkZipFile(Notebook nb, String zip) async {
    if (notDownloaded(zip) || (Platform.isWindows && placeholderState(zip) != PlaceholderState.notPlaceholder)) {
      askSafely(zip, nb.askDownload);
      throw zipRefused("it isn't downloaded yet");
    }
    final int length;
    try {
      length = await File(zip).length();
    } on FileSystemException {
      throw zipRefused("it can't be read");
    }
    if (length > BinderZipLimits.archiveBytes) throw zipRefused('it is too large');
  }

  /// Runs the open. Throws a [BinderZipException] with the notice when
  /// nothing was added.
  Future<BinderZipOpened> run() async {
    final zip = zipPath;
    await checkZipFile(notebook, zip);
    final refused = parentRefusal(notebook, parent, roots);
    if (refused != null) throw BinderZipException(refused);

    // Check before writing, in the isolate, which reads the zip itself.
    final BinderZipPlan plan;
    try {
      plan = await checkBinderZipInIsolate(zip);
    } on FileSystemException {
      throw zipRefused("it can't be read");
    }
    final listed = notebook.listedBinderTitle(plan.binderId);
    if (listed != null) throw BinderZipException('You have this binder already: "$listed".');

    // Guarded in the bytes (BL2): what will be published.
    var bytes = plan.binderBytes;
    final patched = !plan.guarded;
    if (patched) {
      final g = guardedBinderBytes(bytes);
      if (g == null) throw zipRefused("its binder file can't be read");
      bytes = g;
    }

    final zipStem = _stem(zip);
    final name = binderZipFolderName([?plan.top, zipStem, binderFolderName(plan.title)]);
    final parentPath = Directory(parent).absolute.path;
    final stagingPrefix = '.$name.noted-open-';
    final estimate = '$parentPath$_sep$stagingPrefix${'x' * createTempSuffixLength}';
    if (longestOpenPath(plan, stagingPath: estimate, parent: parentPath, name: name) > maxOpenPath) {
      throw zipRefused('a path in it is too long');
    }

    // Stage: a fresh random hidden folder, made exclusively.
    final Directory staging;
    try {
      staging = await Directory(parentPath).createTemp(stagingPrefix);
    } on FileSystemException catch (e) {
      throw folderNotMade(e.osError?.message ?? e.message);
    }
    final made = ZipExtraction()..folders.add(staging.path);
    String? why;
    final String folder;
    try {
      if (longestOpenPath(plan, stagingPath: staging.path, parent: parentPath, name: name) > maxOpenPath) {
        why = 'a path in it is too long';
      } else {
        final stagingPath = staging.path;
        final x = await extractBinderZipInIsolate(zip, stagingPath, plan, bytes);
        made
          ..files.addAll(x.files)
          ..folders.addAll(x.folders)
          ..binderIdentity = x.binderIdentity;
        why = x.failure;
      }
      if (why != null) throw zipRefused(why);
      await afterExtract?.call(staging.path);
      // Z1: the binder file read back from the staging folder.
      if (!await _readBack(staging.path, made.binderIdentity!, plan.binderId)) {
        throw zipRefused('its binder file changed while it was opened');
      }
      folder = await _rename(staging.path, parentPath, name, made.binderIdentity!, plan.binderId);
    } on BinderZipException {
      // Step 8: nothing was renamed, so everything this open made is still
      // below the staging folder.
      if (await _rollback(made)) throw BinderZipException('Not opened. Part of it is left in ${staging.path}.');
      rethrow;
    }
    return _add(folder, plan, patched);
  }

  static String _stem(String path) {
    final n = path.split(RegExp(r'[\\/]')).last;
    return n.toLowerCase().endsWith('.zip') ? n.substring(0, n.length - 4) : n;
  }

  // Z1: the bytes at the binder file are the ones written, they parse as the
  // checked binder, and they say Guarded.
  Future<bool> _readBack(String staging, ContentIdentity written, String id) async {
    final r = await readStored('$staging$_sep$binderFileName');
    return r is StoredBytes && _verified(r.bytes, written, id);
  }

  bool _readBackSync(String staging, ContentIdentity written, String id) {
    final r = readStoredSync('$staging$_sep$binderFileName');
    return r is StoredBytes && _verified(r.bytes, written, id);
  }

  static bool _verified(Uint8List bytes, ContentIdentity written, String id) {
    if (ContentIdentity.ofBytes(bytes) != written) return false;
    try {
      final b = Binder.parse(utf8.decode(bytes));
      return b.id == id && (b.aiAccess ?? defaultAiAccess) == AiAccess.guarded;
    } on FormatException {
      return false;
    } on BinderFormatException {
      return false;
    }
  }

  // Step 6: renamed to `<parent>/<name>`, or the first of " (2)" … " (99)"
  // free; a busy rename is tried again for [busyFor]. Just before the OS call
  // the binder file is read back once more (Z1; on Apple after the move's walk).
  Future<String> _rename(String staging, String parent, String name, ContentIdentity written, String id) async {
    void check() {
      if (!_readBackSync(staging, written, id)) throw const _ReadBackFailed();
    }

    for (var n = 1; n <= 99; n++) {
      final to = '$parent$_sep${n == 1 ? name : '$name ($n)'}';
      final clock = Stopwatch()..start();
      while (true) {
        final MoveOutcome r;
        try {
          r = await mover(staging, to, beforeOsCall: check);
        } on _ReadBackFailed {
          throw zipRefused('its binder file changed while it was opened');
        } on FileSystemException catch (e) {
          throw folderNotMade(e.osError?.message ?? e.message);
        }
        switch (r) {
          case MoveOutcome.moved:
            return to;
          case MoveOutcome.targetExists:
            break;
          case MoveOutcome.busy:
            if (clock.elapsed < busyFor) {
              await Future<void>.delayed(busyStep);
              continue;
            }
            throw folderNotMade('the folder is busy');
          case MoveOutcome.cannotRename:
            throw folderNotMade("the folder can't be renamed there");
        }
        break;
      }
    }
    throw folderNotMade('every name for it is taken');
  }

  // Step 7: the add, with the Guarded backstop.
  Future<BinderZipOpened> _add(String folder, BinderZipPlan plan, bool patched) async {
    await afterRename?.call(folder);
    await notebook.binderZipFolderMade(folder);
    await beforeAdd?.call(folder);
    final BinderSection section;
    final bool added;
    try {
      final r = await notebook.addBinderChecked(folder);
      section = r.section;
      added = r.added;
    } on NotebookException catch (e) {
      throw BinderZipException("The binder is in $folder, but Noted couldn't open it: ${_plain(e.message)}.");
    }
    if (!section.available) {
      throw BinderZipException(
        "The binder is in $folder, but Noted couldn't open it: ${_plain(section.reason ?? "it can't be read")}.",
      );
    }
    // Backstop: another writer changed the file after the rename.
    if ((section.binder?.aiAccess ?? defaultAiAccess) != AiAccess.guarded) {
      await notebook.setBinderAiAccess(section.path, AiAccess.guarded);
      await notebook.flush();
      final now = notebook.binders.where((b) => b.path == section.path).firstOrNull;
      final ok = now != null && now.pending.isEmpty && (now.saved?.aiAccess ?? defaultAiAccess) == AiAccess.guarded;
      if (!ok) {
        if (added) {
          try {
            await notebook.removeBinder(section.path);
          } on NotebookException catch (e) {
            debugPrint('Taking the opened binder out again failed: $e');
          }
        }
        throw BinderZipException(
          "Noted couldn't set AI access to Guarded, so the binder wasn't opened. It is in $folder.",
        );
      }
    }
    final title = section.title;
    final skipped = plan.skipped;
    final parts = [
      'Opened "$title".',
      if (patched) 'AI access was set to Guarded.',
      if (skipped == 1) "1 other file wasn't opened.",
      if (skipped > 1) "$skipped other files weren't opened.",
    ];
    if (added) notebook.showCover(section.path);
    return BinderZipOpened(parts.join(' '), path: section.path);
  }

  static String _plain(String message) => message.endsWith('.') ? message.substring(0, message.length - 1) : message;

  // Step 8: every created file through deleteFileIfMatches(identity:), then
  // the folders, deepest first, only while empty. True when anything stays.
  Future<bool> _rollback(ZipExtraction made) async {
    await beforeRollback?.call(made);
    var kept = false;
    for (final f in made.files.reversed) {
      try {
        final r = await deleteFileIfMatches(f.path, identity: f.identity);
        if (!r.deleted && r.outcome != DeleteOutcome.absent) kept = true;
        if (r.keptPath != null) kept = true;
      } on StorageBusy {
        kept = true;
      } on FileSystemException {
        kept = true;
      }
    }
    final folders = [...made.folders]..sort((a, b) => b.length.compareTo(a.length));
    for (final d in folders) {
      final dir = Directory(d);
      try {
        if (!dir.existsSync()) continue;
        if (dir.listSync().isNotEmpty) {
          kept = true;
          continue;
        }
        await removeFolderCoordinated(dir);
      } on StorageBusy {
        kept = true;
      } on FileSystemException {
        kept = true;
      }
    }
    return kept;
  }
}
