// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Sharing a binder as a `.zip` (design t6 §3): the binder set is listed by
// metadata, Noted's own files are copied each in a short gated job on the
// binder folder's lock, attachments are read outside it, and one metadata-only
// job checks that the listing and every stamp are what was captured, for up to
// three rounds. The zip is built in the app's temp folder; nothing is written
// to or removed from the binder folder.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:noted_core/noted_core.dart';

import '../attachment_copy.dart' show removeFolderCoordinated;
import '../notebook.dart';
import 'binder_set.dart';
import 'zip_check.dart' show BinderZipException;
import 'zip_writer.dart';

/// "Some of this binder's files are still downloading…" (Apple) or "Make
/// these files available on this device first." (elsewhere).
String get binderZipDownloadingMessage => appleMode()
    ? "Some of this binder's files are still downloading. Save it again once they're here."
    : 'Make these files available on this device first.';

/// A test seam: the placeholder state of a path, used on every platform when
/// set (production checks it on Windows only, with [placeholderState]).
@visibleForTesting
PlaceholderState Function(String path)? debugZipPlaceholderState;

const String binderZipTooLargeMessage = 'This binder is too large to save as a .zip.';
const String binderZipKeptChangingMessage = 'This binder kept changing. Try again.';

/// A zip a share made, in the app's temp folder, with the identity it was
/// written with.
final class BinderZipMade {
  const BinderZipMade(this.path, this.identity, this.workDir, {this.ownsDir = true});

  final String path;
  final ContentIdentity identity;
  final Directory workDir;

  /// Whether the share made [workDir] (and removes it once empty).
  final bool ownsDir;

  /// Removes the zip through `deleteFileIfMatches(identity:)`, then its
  /// folder if it is empty.
  Future<void> remove() async {
    try {
      await deleteFileIfMatches(path, identity: identity);
    } on StorageBusy {
      // Kept; the OS clears its temp folder.
    } on FileSystemException {
      // Kept; the OS clears its temp folder.
    }
    if (ownsDir) await _removeEmpty(workDir);
  }
}

Future<void> _removeEmpty(Directory d) async {
  try {
    if (d.existsSync() && d.listSync().isEmpty) await removeFolderCoordinated(d);
  } on StorageBusy {
    // Left for the OS.
  } on FileSystemException {
    // Left for the OS.
  }
}

// What the listing found: each file of the binder set by its path below the
// binder folder, with its stamp.
final class _Listing {
  _Listing(this.files, this.notDownloaded);

  final Map<String, ({List<String> rel, String path, FileStamp stamp})> files;
  final List<String> notDownloaded;
}

final class _Captured {
  _Captured(this.rel, this.stamp, this.record);

  final List<String> rel;
  final FileStamp stamp;
  final ZipRecord record;
}

// One copy of one of Noted's own files into the app's temp folder.
typedef _Copy = ({ZipAddState state, FileStamp? stamp, ContentIdentity? identity, String? error});

Future<_Copy> _copyOwn(String src, String dst, int fileLimit) async {
  final before = zipStampOf(src);
  if (before == null) return (state: ZipAddState.missing, stamp: null, identity: null, error: null);
  if (before.size > fileLimit) return (state: ZipAddState.tooLarge, stamp: null, identity: null, error: null);
  final Stream<List<int>> stream;
  switch (await openStoredRead(src)) {
    case StoredOpened(:final value):
      stream = value;
    case StoredRefused(result: StoredMissing()):
      return (state: ZipAddState.missing, stamp: null, identity: null, error: null);
    case StoredRefused(result: StoredNotDownloaded()):
      return (state: ZipAddState.notDownloaded, stamp: null, identity: null, error: null);
    case StoredRefused(result: StoredFailed(:final error)):
      return (state: ZipAddState.failed, stamp: null, identity: null, error: error.message);
    case StoredRefused():
      return (state: ZipAddState.failed, stamp: null, identity: null, error: null);
  }
  File(dst).createSync(exclusive: true);
  final raf = File(dst).openSync(mode: FileMode.append);
  final chunks = StreamController<List<int>>(sync: true);
  final hash = contentHashOfStream(chunks.stream);
  var length = 0;
  try {
    await for (final c in stream) {
      raf.writeFromSync(c);
      chunks.add(c);
      length += c.length;
    }
    raf.flushSync();
  } on FileSystemException catch (e) {
    // What reached the copy: each chunk is hashed only after its write, so
    // the identity is of the bytes written so far, and the copy is removed
    // against it.
    unawaited(chunks.close());
    raf.closeSync();
    final written = ContentIdentity(length, await hash);
    return (state: ZipAddState.failed, stamp: null, identity: written, error: e.message);
  }
  raf.closeSync();
  unawaited(chunks.close());
  final identity = ContentIdentity(length, await hash);
  final after = zipStampOf(src);
  return (state: after == before ? ZipAddState.added : ZipAddState.changed, stamp: before, identity: identity, error: null);
}

/// One share of the binder at [binderPath] into a zip in the app's temp
/// folder, with its files under the top folder [topName].
class BinderZipShare {
  BinderZipShare(
    this.notebook,
    this.binderPath, {
    required this.topName,
    String? zipName,
    this.rounds = 3,
    this.workDir,
    this.beforeOwnRead,
    this.afterCapture,
    this.readPause,
  }) : zipName = zipName ?? '$topName.zip';

  final Notebook notebook;
  final String binderPath;
  final String topName;

  /// The name the notice of a failed share gives (the target's name).
  final String zipName;
  final int rounds;

  /// Where the zip is built; null makes a fresh folder in the app's temp
  /// folder.
  final Directory? workDir;

  /// Test seams: inside the read job of each of Noted's own files, before it
  /// is copied; after each round's capture, before its check; a pause while
  /// an attachment is held open.
  final Future<void> Function(List<String> rel)? beforeOwnRead;
  final Future<void> Function(int round)? afterCapture;
  final ZipReadPause? readPause;

  final String _sep = Platform.pathSeparator;
  final Map<String, _Captured> _captured = {};
  final List<CreatedLocal> _locals = [];
  late Directory _work;
  late String _zip;

  // The identity of [_zip] as this share last wrote it, recorded in the
  // isolate that wrote it; null until this share has created it. Every removal
  // of the zip checks against this, never against what is there then.
  ContentIdentity? _zipIdentity;
  int _end = 0;
  bool _dead = false;
  int _copies = 0;

  /// The rounds the last [run] took (for tests).
  int roundsTaken = 0;

  /// Builds the zip. Throws a [BinderZipException] with the notice when it
  /// can't; nothing it made is left then.
  Future<BinderZipMade> run() async {
    assert(Notebook.binderZipJobKind == null, 'a share started inside a binder .zip job');
    try {
      return await _run();
    } on BinderZipException {
      rethrow;
    } on FileSystemException catch (e) {
      // StorageBusy too: a failed share always says so.
      debugPrint('Saving $zipName failed: $e');
      throw BinderZipException("Couldn't save $zipName. Nothing was saved.");
    }
  }

  Future<BinderZipMade> _run() async {
    _work = workDir ?? await Directory.systemTemp.createTemp('noted-binder-zip-');
    _zip = '${_work.path}${_sep}binder.zip';
    try {
      File(_zip).createSync(exclusive: true);
      _zipIdentity = ContentIdentity.ofBytes(const []);
      var listing = _listOrRefuse(_list());
      var toRead = listing.files.keys.toList();
      for (var round = 1; ; round++) {
        roundsTaken = round;
        await _capture(listing, toRead);
        await afterCapture?.call(round);
        final _Listing now;
        try {
          now = await notebook.binderZipJob(binderPath, () async => _list(), metadataOnly: true);
        } on NotebookException catch (e) {
          throw BinderZipException(e.message);
        }
        _listOrRefuse(now);
        final changed = <String>[];
        for (final e in now.files.entries) {
          final c = _captured[e.key];
          if (c == null || c.stamp != e.value.stamp) changed.add(e.key);
        }
        final removed = [for (final k in _captured.keys) if (!now.files.containsKey(k)) k];
        if (changed.isEmpty && removed.isEmpty) break;
        if (round >= rounds) throw const BinderZipException(binderZipKeptChangingMessage);
        for (final k in [...removed, ...changed]) {
          if (_captured.remove(k) != null) _dead = true;
        }
        listing = now;
        toRead = changed;
      }
      return await _assemble();
    } on Object {
      await _discard();
      rethrow;
    }
  }

  _Listing _listOrRefuse(_Listing l) {
    if (l.notDownloaded.isNotEmpty) {
      for (final p in l.notDownloaded) {
        askSafely(p, notebook.askDownload);
      }
      throw BinderZipException(binderZipDownloadingMessage);
    }
    if (l.files.length > BinderZipLimits.entries) throw const BinderZipException(binderZipTooLargeMessage);
    var total = 0;
    for (final f in l.files.values) {
      if (f.stamp.size > BinderZipLimits.fileBytes) throw const BinderZipException(binderZipTooLargeMessage);
      total += f.stamp.size;
    }
    if (total > BinderZipLimits.totalBytes) throw const BinderZipException(binderZipTooLargeMessage);
    return l;
  }

  // The binder set by name and metadata only (A1, A2): `folderWalk` over the
  // binder folder, whose failed listings count as not downloaded; on Windows
  // each file and folder's placeholder state too. What is outside the set is
  // left alone.
  _Listing _list() {
    final root = binderPath;
    final walk = folderWalk(root);
    final missing = <String>[];
    List<String> relOf(String path) {
      final rest = path.length > root.length ? path.substring(root.length + 1) : '';
      return rest.isEmpty ? const [] : rest.split(RegExp(r'[\\/]'));
    }

    for (final p in walk.notDownloaded) {
      final rel = relOf(p);
      if (rel.isEmpty || folderInBinderSet(rel) || inBinderSet(rel) || inBinderSet([...rel.take(rel.length - 1), stubTargetName(rel.last) ?? rel.last])) {
        missing.add(p);
      }
    }
    final files = <String, ({List<String> rel, String path, FileStamp stamp})>{};
    final folders = <String>{root};
    for (final p in walk.files) {
      final rel = relOf(p);
      if (!inBinderSet(rel)) continue;
      final stamp = zipStampOf(p);
      if (stamp == null) continue; // gone since the walk: the check sees it
      files[rel.join('/')] = (rel: rel, path: p, stamp: stamp);
      for (var i = 1; i < rel.length; i++) {
        folders.add('$root$_sep${rel.take(i).join(_sep)}');
      }
    }
    final state = debugZipPlaceholderState ?? (Platform.isWindows ? placeholderState : null);
    if (state != null) {
      for (final p in [...folders, for (final f in files.values) f.path]) {
        if (state(p) != PlaceholderState.notPlaceholder) missing.add(p);
      }
    }
    return _Listing(files, missing);
  }

  // One round's capture of [keys] (in [listing]): Noted's own files each in a
  // read job, copied locally, then zipped; attachments zipped from where they
  // are, outside the lock.
  Future<void> _capture(_Listing listing, List<String> keys) async {
    final own = <String>[];
    final attachments = <ZipSource>[];
    for (final k in keys) {
      final f = listing.files[k]!;
      if (isNotedOwnFile(f.rel)) {
        own.add(k);
      } else {
        attachments.add(ZipSource('$topName/$k', f.path, deflate: _deflates(k)));
      }
    }
    final copied = <ZipSource>[];
    final stamps = <String, FileStamp>{};
    for (final k in own) {
      final f = listing.files[k]!;
      final c = await _copyOwnLocked(f.rel, f.path);
      switch (c.state) {
        case ZipAddState.added:
          stamps[k] = c.stamp!;
          copied.add(ZipSource('$topName/$k', c.local!, deflate: _deflates(k)));
        case ZipAddState.missing || ZipAddState.changed:
          break; // the check sees it and the next round reads it again
        case ZipAddState.notDownloaded:
          askSafely(f.path, notebook.askDownload);
          throw BinderZipException(binderZipDownloadingMessage);
        case ZipAddState.tooLarge:
          throw const BinderZipException(binderZipTooLargeMessage);
        case ZipAddState.failed:
          throw BinderZipException("Couldn't read $k. Nothing was saved.");
      }
    }
    await _append(copied, stamps);
    await _removeLocals();
    await _append(attachments, null);
  }

  static bool _deflates(String k) => k.endsWith(PageStore.extension) || k.endsWith('.json');

  Future<({ZipAddState state, FileStamp? stamp, String? local})> _copyOwnLocked(List<String> rel, String src) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final dst = '${_work.path}$_sep${_copies++}.copy';
      final _Copy c;
      try {
        c = await notebook.binderZipJob(binderPath, () async {
          await beforeOwnRead?.call(rel);
          // Nothing not downloaded is read, and nothing is asked for in here.
          if (notDownloaded(src)) {
            return (state: ZipAddState.notDownloaded, stamp: null, identity: null, error: null);
          }
          return _copyOwnInIsolate(src, dst);
        }, metadataOnly: false);
      } on NotebookException catch (e) {
        throw BinderZipException(e.message);
      }
      final id = c.identity;
      if (id != null) _locals.add(CreatedLocal(dst, id));
      if (c.state == ZipAddState.changed) continue;
      return (state: c.state, stamp: c.stamp, local: c.state == ZipAddState.added ? dst : null);
    }
    return (state: ZipAddState.changed, stamp: null, local: null);
  }

  Future<void> _append(List<ZipSource> sources, Map<String, FileStamp>? stamps) async {
    if (sources.isEmpty) return;
    final zip = _zip;
    final at = _end;
    final pause = readPause;
    final top = topName;
    final r = await appendZipEntriesInIsolate(
      zip,
      at,
      sources,
      fileLimit: BinderZipLimits.fileBytes,
      archiveLimit: BinderZipLimits.archiveBytes,
      pause: pause,
    );
    _end = r.end;
    _zipIdentity = r.identity;
    if (r.overArchive) throw const BinderZipException(binderZipTooLargeMessage);
    for (final a in r.added) {
      final k = a.source.name.substring(top.length + 1);
      switch (a.state) {
        case ZipAddState.added:
          // An own file's stamp is its source's, taken in its read job.
          _captured[k] = _Captured(k.split('/'), stamps?[k] ?? a.stamp!, a.record!);
        case ZipAddState.missing || ZipAddState.changed:
          break;
        case ZipAddState.notDownloaded:
          throw BinderZipException(binderZipDownloadingMessage);
        case ZipAddState.tooLarge:
          throw const BinderZipException(binderZipTooLargeMessage);
        case ZipAddState.failed:
          throw BinderZipException("Couldn't read $k. Nothing was saved.");
      }
    }
  }

  Future<void> _removeLocals() async {
    for (final l in _locals) {
      try {
        await deleteFileIfMatches(l.path, identity: l.identity);
      } on StorageBusy {
        // Kept in the temp folder.
      } on FileSystemException {
        // Kept in the temp folder.
      }
    }
    _locals.clear();
  }

  // The zip's central directory; dead entries (read again, or gone) are
  // compacted away first.
  Future<BinderZipMade> _assemble() async {
    var zip = _zip;
    var records = [for (final c in _captured.values) c.record]..sort((a, b) => a.offset.compareTo(b.offset));
    var end = _end;
    if (_dead) {
      final from = zip;
      final to = '${_work.path}${_sep}binder-1.zip';
      final live = records;
      final old = _zipIdentity!;
      final c = await compactZipInIsolate(from, to, live);
      records = c.records;
      zip = _zip = to;
      _zipIdentity = c.identity;
      await _removeOwn(from, old);
      end = records.isEmpty ? 0 : records.last.end;
    }
    final at = end;
    final list = records;
    final path = zip;
    final identity = _zipIdentity = await finishZipInIsolate(path, at, list);
    return BinderZipMade(zip, identity, _work, ownsDir: workDir == null);
  }

  // Removes a zip this share built and no longer needs, against the identity
  // recorded when it was last written.
  static Future<void> _removeOwn(String path, ContentIdentity identity) async {
    try {
      await deleteFileIfMatches(path, identity: identity);
    } on StorageBusy {
      // Kept in the temp folder.
    } on FileSystemException {
      // Kept in the temp folder.
    }
  }

  Future<void> _discard() async {
    await _removeLocals();
    final id = _zipIdentity;
    if (id != null) await _removeOwn(_zip, id);
    if (workDir == null) await _removeEmpty(_work);
  }
}

/// A file a share made in the app's temp folder, with the identity it was
/// written with.
final class CreatedLocal {
  const CreatedLocal(this.path, this.identity);

  final String path;
  final ContentIdentity identity;
}

Future<_Copy> _copyOwnInIsolate(String src, String dst) =>
    Isolate.run(() => _copyOwn(src, dst, BinderZipLimits.fileBytes));
