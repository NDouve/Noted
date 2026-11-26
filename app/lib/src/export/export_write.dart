// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:noted_core/noted_core.dart';

import 'exclusive_create.dart';

/// How an export write ended.
enum ExportWriteKind {
  /// The file was written (new, or replacing the user's choice).
  exported,

  /// The user declined to replace or to put back, or the bytes were not made;
  /// nothing was written.
  stopped,

  /// Nothing was written, for the reason in [ExportWriteResult.message].
  failed,
}

/// The end of one export write, with the message the user is shown (null for
/// a plain stop).
class ExportWriteResult {
  const ExportWriteResult(this.kind, [this.message]);

  final ExportWriteKind kind;
  final String? message;

  bool get exported => kind == ExportWriteKind.exported;

  @override
  String toString() => 'ExportWriteResult($kind, $message)';
}

/// Asks "Replace NAME?" (true to replace).
typedef AskReplace = Future<bool> Function(String name);

/// Asks "Put back NAME? It is kept as ASIDE." (true to put it back).
typedef AskPutBack = Future<bool> Function(String name, String aside);

/// What [ExportWriter] replaces a taken name with; the default is
/// [replaceIfUnchanged]. A test seam.
typedef ExportReplace = Future<ReplaceResult> Function(File tmp, String target, ContentIdentity identity);

/// The file name of [path].
String exportBaseName(String path) => path.split(RegExp(r'[\\/]')).last;

String _folderOf(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? '.' : path.substring(0, i);
}

final Random _random = Random.secure();

String _hex() =>
    _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0') + _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');

/// The staging temp of [name] a write makes beside the target.
String exportTempName(String name) => '.$name.noted-export-${_hex()}.tmp';

final RegExp _asideTail = RegExp(r'\.\d+-[0-9a-f]+-[0-9a-f]+\.cas-(old|verified)$');

/// Writes one export file into a user-chosen folder (design: box export, the
/// write on every platform). The file is staged in a temporary beside the
/// target and published with [publishExclusive], which never replaces; a
/// taken name is replaced only after Noted's own "Replace NAME?" prompt, and
/// only through [replaceIfUnchanged] against the identity read before the
/// prompt, so a file that changed or was swapped meanwhile is never
/// overwritten. Where hard links don't work it creates the new file
/// exclusively and never replaces. Nothing in the notebook, the page files,
/// undo, autosave or recovery is touched.
class ExportWriter {
  ExportWriter({
    required this.askReplace,
    required this.askPutBack,
    this.sandboxed = false,
    this.publish = publishExclusive,
    this.replace,
    this.hardLinks,
    this.open,
    this.posix,
    this.afterStaleIdentity,
    DateTime Function()? now,
    this.staleAfter = const Duration(days: 1),
  }) : _now = now ?? DateTime.now;

  final AskReplace askReplace;
  final AskPutBack askPutBack;

  /// The macOS sandbox, where only the chosen file is granted.
  final bool sandboxed;

  /// The exclusive publish, a seam: a probe that can't link is simulated by a
  /// publisher that throws.
  final Future<bool> Function(File tmp, String target) publish;

  /// Replaces a taken name; null is [replaceIfUnchanged].
  final ExportReplace? replace;

  /// Whether hard links work in a folder: null probes it (on POSIX; Windows
  /// has no need of links). A seam.
  final Future<bool> Function(String folder)? hardLinks;

  /// The exclusive create's opener, a seam.
  final ExclusiveOpener? open;

  /// Whether the hard-link probe is needed: null is every platform but Windows,
  /// whose publish is a move and needs no links. A seam.
  final bool? posix;

  /// Runs between the identity of a stale temp being read and its delete. A
  /// seam: a temp that changes there survives.
  final Future<void> Function(String path)? afterStaleIdentity;

  final DateTime Function() _now;

  /// A staging temp or an aside older than this is removed by the next export
  /// into its folder.
  final Duration staleAfter;

  // Targets this process is replacing, and the temps it holds, so the cleanup
  // and Put back leave their files alone.
  final Set<String> _replacing = {};
  final Set<String> _temps = {};

  /// Whether this process holds [path] (a staging temp, or an aside of a
  /// replace in flight).
  bool inFlight(String path) {
    if (_temps.contains(path)) return true;
    for (final t in _replacing) {
      if (path.startsWith('$t.') && _asideTail.hasMatch(path)) return true;
    }
    for (final t in _temps) {
      if (path.startsWith('$t.') && _asideTail.hasMatch(path)) return true;
    }
    return false;
  }

  /// Writes the file at [target]. [makeBytes] runs after the housekeeping of
  /// the folder (Put back, old staging temps) and before anything is written;
  /// it answers null to stop (it has said why itself).
  Future<ExportWriteResult> write(String target, Future<Uint8List?> Function() makeBytes) async {
    final name = exportBaseName(target);
    final folder = _folderOf(target);
    try {
      await housekeeping(target);
      final bytes = await makeBytes();
      if (bytes == null) return const ExportWriteResult(ExportWriteKind.stopped);
      return await _write(target, name, folder, bytes);
    } on StorageBusy catch (e) {
      return ExportWriteResult(ExportWriteKind.failed, _busyMessage(name, e));
    } on ExclusiveWriteFailed catch (e) {
      return ExportWriteResult(
        ExportWriteKind.failed,
        e.left ? '${e.message} Nothing else was changed.' : 'Could not write $name. Nothing was exported.',
      );
    } on FileSystemException catch (e) {
      return ExportWriteResult(ExportWriteKind.failed, _failureMessage(name, e));
    } on Object {
      return ExportWriteResult(ExportWriteKind.failed, 'Could not write $name. Nothing was exported.');
    }
  }

  Future<ExportWriteResult> _write(String target, String name, String folder, Uint8List bytes) async {
    final links = await (hardLinks ?? (f) => _probe(f, name))(folder);
    if (!links) {
      // No hard links: a taken name is refused before any prompt, and a new
      // file is created exclusively.
      const noReplace = ExportWriteResult(
        ExportWriteKind.failed,
        "Choose a new name; Noted can't safely replace a file here.",
      );
      if (_taken(target)) return noReplace;
      final r = await createExclusive(target, bytes, open: open, sandboxed: sandboxed);
      return r == ExclusiveOutcome.taken ? noReplace : _exported(name);
    }
    final tmp = File('$folder${Platform.pathSeparator}${exportTempName(name)}');
    _temps.add(tmp.path);
    var published = false;
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      published = await publish(tmp, target);
      if (published) return _exported(name);
      return await _replaceTaken(tmp, target, name, bytes, onPublished: () => published = true);
    } finally {
      // Whenever the temp wasn't published it is removed, against the bytes
      // written, so a file that took its name meanwhile survives.
      _temps.remove(tmp.path);
      if (!published) await _removeTemp(tmp.path, bytes);
    }
  }

  ExportWriteResult _exported(String name) =>
      ExportWriteResult(ExportWriteKind.exported, 'Exported $name.');

  bool _taken(String target) =>
      FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound;

  Future<ExportWriteResult> _replaceTaken(
    File tmp,
    String target,
    String name,
    Uint8List bytes, {
    required void Function() onPublished,
  }) async {
    // The identity first, then the prompt (Noted's own, not the save dialog's).
    final identity = await ContentIdentity.ofFile(target);
    if (!await askReplace(name)) return const ExportWriteResult(ExportWriteKind.stopped);
    _replacing.add(target);
    final ReplaceResult r;
    try {
      r = await (replace ?? _replaceChecked)(tmp, target, identity);
    } on Object {
      // The target may be moved aside: put it back at once.
      _replacing.remove(target);
      await putBack(target);
      rethrow;
    }
    _replacing.remove(target);
    final kept = r.keptPath;
    final also = [for (final p in r.alsoKept) ' Also kept as $p.'].join();
    switch (r.outcome) {
      case ReplaceOutcome.replaced:
        onPublished();
        return ExportWriteResult(
          ExportWriteKind.exported,
          'Exported $name.${kept == null ? '' : ' Your previous $name is kept as $kept.'}$also',
        );
      case ReplaceOutcome.changed:
        return ExportWriteResult(ExportWriteKind.failed, '$name changed since you chose it. Nothing was written.$also');
      case ReplaceOutcome.changedKept:
        return ExportWriteResult(
          ExportWriteKind.failed,
          '$name changed since you chose it. Nothing was written.${kept == null ? '' : ' Your previous $name is kept as $kept.'}$also',
        );
      case ReplaceOutcome.supersededKept:
        return ExportWriteResult(
          ExportWriteKind.failed,
          '$name was replaced by another app meanwhile. Nothing was exported.${kept == null ? '' : ' Your previous $name is kept as $kept.'}$also',
        );
    }
  }

  static Future<ReplaceResult> _replaceChecked(File tmp, String target, ContentIdentity identity) =>
      replaceIfUnchanged(tmp, target, null, identity: identity);

  Future<void> _removeTemp(String path, Uint8List bytes) async {
    try {
      await deleteFileIfMatches(path, bytes: bytes);
    } on Object {
      // The temp stays; a later export into this folder removes it.
    }
  }

  // The probe: once per export, before the first publish. Hard links work when
  // the temp can be linked to a second name. Both names match the staging
  // pattern, so a crash leaves nothing the cleanup misses.
  Future<bool> _probe(String folder, String name) async {
    if (!(posix ?? !Platform.isWindows)) return true;
    final sep = Platform.pathSeparator;
    final base = '.$name.noted-export-${_hex()}';
    final a = File('$folder$sep$base.tmp');
    final linkPath = '$folder$sep$base.link.tmp';
    final probe = Uint8List.fromList(const [0x6e, 0x6f, 0x74, 0x65, 0x64]);
    _temps
      ..add(a.path)
      ..add(linkPath);
    try {
      await a.writeAsBytes(probe, flush: true);
      var linked = false;
      try {
        // The publish links the temp to the second name and removes the first.
        linked = await publish(a, linkPath);
      } on FileSystemException {
        linked = false;
      }
      if (linked) await _removeTemp(linkPath, probe);
      return linked;
    } finally {
      _temps
        ..remove(a.path)
        ..remove(linkPath);
      await _removeTemp(a.path, probe);
    }
  }

  // Housekeeping for a folder an export goes to: Put back (its own asides of
  // the chosen name), then the old staging temps of that name.
  Future<void> housekeeping(String target) async {
    try {
      await putBack(target);
      await removeStaleTemps(target);
    } on StorageBusy {
      // The folder is busy; the real write says so.
    } on FileSystemException {
      // The folder can't be listed; the real write says so.
    }
  }

  /// Offers to put back Noted's own aside of [target] (named `NAME.PID-RANDOM.cas-old`
  /// or `.cas-verified`, left by a replace that didn't finish) when
  /// [target] is absent, skipping those of replaces in flight. The target is
  /// checked again after the prompt; the aside is then published to the name
  /// with [publishExclusive]. Otherwise the aside stays.
  Future<void> putBack(String target) async {
    if (_taken(target)) return;
    final name = exportBaseName(target);
    final dir = Directory(_folderOf(target));
    if (!dir.existsSync()) return;
    final own = RegExp('^${RegExp.escape(name)}\\.\\d+-[0-9a-f]+-[0-9a-f]+\\.cas-(old|verified)\$');
    final asides = <String>[];
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! File || !own.hasMatch(exportBaseName(e.path)) || inFlight(e.path)) continue;
      asides.add(e.path);
    }
    asides.sort();
    for (final aside in asides) {
      if (_taken(target)) return;
      if (!await askPutBack(name, aside)) return;
      // Absent after the prompt too, or nothing is published.
      if (_taken(target)) return;
      await publish(File(aside), target);
      return;
    }
  }

  /// Removes Noted's own staging temps of [target]'s name (and the asides of
  /// them) older than [staleAfter] that no export of this process holds,
  /// through [deleteFileIfMatches] against the identity read, so a temp that
  /// changed meanwhile survives.
  Future<void> removeStaleTemps(String target) async {
    final name = exportBaseName(target);
    final dir = Directory(_folderOf(target));
    if (!dir.existsSync()) return;
    final prefix = '.$name.noted-export-';
    final pattern = RegExp(
      '^${RegExp.escape(prefix)}[0-9a-f]+(\\.link)?\\.tmp(\\.\\d+-[0-9a-f]+-[0-9a-f]+\\.cas-(old|verified))?\$',
    );
    final cutoff = _now().subtract(staleAfter);
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      if (!pattern.hasMatch(exportBaseName(e.path))) continue;
      if (inFlight(e.path)) continue;
      try {
        if (!e.lastModifiedSync().isBefore(cutoff)) continue;
        final id = await ContentIdentity.ofFile(e.path);
        await afterStaleIdentity?.call(e.path);
        await deleteFileIfMatches(e.path, identity: id);
      } on StorageBusy {
        continue;
      } on FileSystemException {
        continue;
      }
    }
  }

  String _busyMessage(String name, StorageBusy e) =>
      e.reason == StorageBusyReason.dataless ? "$name isn't downloaded yet." : 'The folder is busy. Try again.';

  String _failureMessage(String name, FileSystemException e) {
    final code = e.osError?.errorCode;
    if (Platform.isWindows && (code == 32 || code == 33)) {
      return '$name is open in another app. Close it and try again.';
    }
    return 'Could not write $name. Nothing was exported.';
  }
}
