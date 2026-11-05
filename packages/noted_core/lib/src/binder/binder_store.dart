// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import '../storage/exclusive_publish.dart';
import '../storage/replace_by_rename.dart';
import 'binder.dart';
import 'binder_temps.dart';

/// The result of reading a folder's binder file.
sealed class BinderRead {
  const BinderRead();
}

final class BinderFound extends BinderRead {
  const BinderFound(this.binder, this.text);

  final Binder binder;

  /// The decoded text [binder] was parsed from: the only source of the text
  /// the caller remembers as "what the file held".
  final String text;
}

/// The folder has no binder file.
final class BinderMissing extends BinderRead {
  const BinderMissing();
}

/// The binder file isn't a readable Noted binder (invalid text, JSON or
/// format, or a newer format). It is never overwritten.
final class BinderUnreadable extends BinderRead {
  const BinderUnreadable(this.reason);

  final String reason;
}

/// The binder file couldn't be read right now (an I/O error), which says
/// nothing about its content. It is not "missing" and not "damaged".
final class BinderReadFailed extends BinderRead {
  const BinderReadFailed(this.reason);

  final String reason;
}

/// Why [BinderStore.update] wrote nothing.
enum BinderRefusal {
  /// The binder file is not there.
  gone,

  /// The file is damaged or from a newer app.
  unreadable,

  /// The file belongs to another binder (a different `binderId`).
  otherBinder,

  /// The temporary file couldn't be written.
  cantWrite,

  /// The binder file is read-only.
  readOnly,

  /// Every try found the file changed again.
  keepsChanging,

  /// The file is open in another program, or can't be read or replaced.
  inUse,
}

/// The result of [BinderStore.update].
sealed class BinderUpdate {
  const BinderUpdate();
}

/// The binder file holds [binder] now, as the text [written] (which is the
/// text that was read, when the change made no difference and nothing was
/// written: [wrote] is false).
final class BinderUpdated extends BinderUpdate {
  const BinderUpdated(this.binder, this.written, {required this.wrote});

  final Binder binder;
  final String written;
  final bool wrote;
}

/// Nothing was written. [reason] is a sentence for the user.
final class BinderRefused extends BinderUpdate {
  const BinderRefused(this.kind, this.reason);

  final BinderRefusal kind;
  final String reason;
}

/// The result of [BinderStore.create].
enum BinderCreated {
  /// The new binder file was published.
  created,

  /// The folder has a binder file; it was not touched.
  exists,
}

/// The binder file of one folder.
///
/// Writes to an existing file are [update]s: the file is reread, the change
/// reapplied to those bytes, and the file compared and replaced by a replacing
/// rename (the 0131 exception for binder files). Call them under the folder
/// lock.
class BinderStore {
  BinderStore(
    this.directory, {
    this.retryDelay = const Duration(milliseconds: 100),
    this.tries = 5,
  });

  final Directory directory;

  /// The wait between two tries of [update] after an I/O error.
  final Duration retryDelay;

  /// How many times [update] reads the file and tries to replace it.
  final int tries;

  static int _tmpCounter = 0;

  File get file => File('${directory.path}${Platform.pathSeparator}$binderFileName');

  /// A new unique temporary file name beside the binder file, never reused.
  /// Public so tests can make the temporary write fail.
  File newTempFile() =>
      File('${file.path}.${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');

  /// Reads the folder's binder file: the bytes, strictly decoded as UTF-8.
  /// Only a file that is not found is [BinderMissing].
  Future<BinderRead> read() async {
    final f = file;
    final List<int> bytes;
    try {
      bytes = await f.readAsBytes();
    } on FileSystemException catch (e) {
      if (_notFound(f.path)) return const BinderMissing();
      return BinderReadFailed(_describe(e));
    }
    return _parse(bytes);
  }

  BinderRead _parse(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      return BinderFound(Binder.parse(text), text);
    } on BinderFormatException catch (e) {
      return BinderUnreadable(e.message);
    } on FormatException {
      return const BinderUnreadable('not valid UTF-8 text');
    }
  }

  /// Applies [change] to the binder file as it is on disk now, never to a
  /// copy the caller holds, and writes the result. [binderId] is the id of the
  /// binder the change was made for; another binder's file is not touched.
  ///
  /// Each of up to [tries] tries:
  /// 1. reads the file's bytes (nothing is written if it is missing, damaged,
  ///    from a newer app or another binder's);
  /// 2. reapplies [change]; a change that alters nothing writes nothing;
  /// 3. writes the result to a temporary file;
  /// 4. compares the file with the bytes of step 1 and replaces it
  ///    ([replaceByRenameIfUnchanged]). A file that changed since is read
  ///    again and the change reapplied on top of it.
  ///
  /// [beforeCompare] and [beforeRename] are test seams, see
  /// [replaceByRenameIfUnchanged]; they run on every try.
  Future<BinderUpdate> update(
    Binder Function(Binder onDisk) change, {
    required String binderId,
    void Function()? beforeCompare,
    void Function()? beforeRename,
  }) async {
    try {
      await sweepBinderTemps(directory);
    } on Object {
      // Tidying is best effort.
    }
    BinderRefused last = const BinderRefused(
      BinderRefusal.keepsChanging,
      'The binder file keeps changing',
    );
    for (var attempt = 1; attempt <= tries; attempt++) {
      final f = file;
      // 1. Read.
      final List<int> bytes;
      try {
        bytes = await f.readAsBytes();
      } on FileSystemException catch (e) {
        if (_notFound(f.path)) {
          return const BinderRefused(BinderRefusal.gone, 'The binder file is missing');
        }
        last = _inUse(e);
        if (attempt < tries) await Future<void>.delayed(retryDelay);
        continue;
      }
      final Binder parsed;
      final String text;
      switch (_parse(bytes)) {
        case BinderFound(binder: final b, text: final t):
          parsed = b;
          text = t;
        case BinderUnreadable(:final reason):
          return BinderRefused(
            BinderRefusal.unreadable,
            "The binder file can't be read ($reason)",
          );
        case _:
          return const BinderRefused(
            BinderRefusal.unreadable,
            "The binder file can't be read",
          );
      }
      if (parsed.id != binderId) {
        return const BinderRefused(
          BinderRefusal.otherBinder,
          'The binder file in this folder belongs to another binder',
        );
      }
      // 2. Reapply.
      final next = change(parsed);
      final written = next.write();
      if (written == text) return BinderUpdated(next, text, wrote: false);
      // 3. Write the temporary file.
      final tmp = newTempFile();
      try {
        await tmp.writeAsString(written, flush: true);
      } on FileSystemException catch (e) {
        _deleteQuiet(tmp);
        return BinderRefused(
          BinderRefusal.cantWrite,
          "The binder file couldn't be written${_reasonOf(e)}",
        );
      }
      // 4. Compare and rename.
      final RenameOutcome outcome;
      try {
        outcome = replaceByRenameIfUnchanged(
          tmp,
          f.path,
          bytes,
          beforeCompare: beforeCompare,
          beforeRename: beforeRename,
        );
      } on FileSystemException catch (e) {
        _deleteQuiet(tmp);
        if (!isWritableFile(f.path)) {
          return const BinderRefused(BinderRefusal.readOnly, 'The binder file is read-only');
        }
        last = _inUse(e);
        if (attempt < tries) await Future<void>.delayed(retryDelay);
        continue;
      }
      switch (outcome) {
        case RenameOutcome.replaced:
          return BinderUpdated(next, written, wrote: true);
        case RenameOutcome.missing:
          _deleteQuiet(tmp);
          return const BinderRefused(BinderRefusal.gone, 'The binder file is missing');
        case RenameOutcome.changed:
          _deleteQuiet(tmp);
          last = const BinderRefused(
            BinderRefusal.keepsChanging,
            'The binder file keeps changing',
          );
      }
    }
    return last;
  }

  /// Publishes a new binder file for [binder], never replacing: a folder that
  /// has one gives [BinderCreated.exists], and that file is left as it is.
  /// Throws [FileSystemException] if the folder or the drive can't take it (a
  /// volume without hard links can't publish safely).
  ///
  /// [beforePublish] is a test seam, run after the temporary file is written.
  Future<BinderCreated> create(Binder binder, {void Function()? beforePublish}) async {
    if (await file.exists()) return BinderCreated.exists;
    await directory.create(recursive: true);
    final tmp = newTempFile();
    try {
      await tmp.writeAsString(binder.write(), flush: true);
      beforePublish?.call();
      final bool published;
      try {
        published = await publishExclusive(tmp, file.path);
      } on FileSystemException catch (e) {
        throw FileSystemException(
          "This folder's drive can't create a binder safely",
          file.path,
          e.osError,
        );
      }
      if (!published) {
        _deleteQuiet(tmp);
        return BinderCreated.exists;
      }
      return BinderCreated.created;
    } on FileSystemException {
      _deleteQuiet(tmp);
      rethrow;
    }
  }

  static bool _notFound(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;

  static void _deleteQuiet(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // A leftover temp is handled by the sweep.
    }
  }

  static String _describe(FileSystemException e) {
    final m = e.osError?.message.trim() ?? '';
    return m.isNotEmpty ? m : e.message;
  }

  static String _reasonOf(FileSystemException e) {
    final m = e.osError?.message.trim() ?? '';
    return m.isEmpty ? '' : ' ($m)';
  }

  static BinderRefused _inUse(FileSystemException e) => BinderRefused(
    BinderRefusal.inUse,
    'The binder file is in use by another program${_reasonOf(e)}',
  );
}
