// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import '../ai/ai_access.dart';
import '../model/box_types.dart';
import '../storage/exclusive_publish.dart';
import '../storage/replace_if_unchanged.dart';
import 'binder.dart';

/// The result of reading a folder's binder file.
sealed class BinderRead {
  const BinderRead();
}

final class BinderFound extends BinderRead {
  const BinderFound(this.binder);

  final Binder binder;
}

/// The folder has no binder file.
final class BinderMissing extends BinderRead {
  const BinderMissing();
}

/// The binder file couldn't be read. It is never overwritten.
final class BinderUnreadable extends BinderRead {
  const BinderUnreadable(this.reason);

  final String reason;
}

/// Why [BinderStore.update] wrote nothing.
enum BinderRefusal {
  /// The binder file is not there.
  gone,

  /// The file is damaged, from a newer app, or has no binder id.
  unreadable,

  /// The file belongs to another binder (a different `binderId`).
  otherBinder,

  /// The temporary file couldn't be written.
  cantWrite,

  /// The binder file is read-only.
  readOnly,

  /// Every try found the file changed again.
  keepsChanging,

  /// The file, or a binder-file aside of a replace in progress, is there but
  /// can't be read or replaced now.
  inUse,
}

/// A temporary file [BinderStore.update] wrote beside the binder file. It is
/// removed only by [BinderStore.removeTemps], or by the user.
final class BinderTemp {
  const BinderTemp(this.path, this.bytes, this.binderId);

  final String path;

  /// What the file holds.
  final List<int> bytes;

  /// The id of the binder whose file the change was made on.
  final String binderId;
}

/// What kind of change a [BinderDelta] is.
enum BinderDeltaKind {
  /// Title, description, owner or color.
  cover,

  /// AI access, a box type or attachment storage.
  setting,
}

/// The AI field a setting delta changes, for the rule that a stricter value
/// found on disk is kept ([BinderStore.update], step U3).
sealed class BinderField {
  const BinderField();
}

/// The binder's AI access: [request] is what the delta sets; [base] is the
/// screen value it was changed from.
final class BinderAiField extends BinderField {
  const BinderAiField({required this.base, required this.request});

  final AiAccess? base;
  final AiAccess? request;
}

/// One box type of the binder: [request] is what the delta sets; [base] is the
/// screen value it was changed from.
final class BinderBoxTypeField extends BinderField {
  const BinderBoxTypeField(this.typeId, {required this.base, required this.request});

  final String typeId;
  final bool? base;
  final bool? request;
}

/// A change to a binder, kept until it lands (or is refused or dropped). It is
/// reapplied to the file as it is on disk, never to a copy.
final class BinderDelta {
  BinderDelta({
    required this.binderId,
    required this.apply,
    required this.kind,
    this.field,
    List<BinderTemp>? temps,
  }) : temps = temps ?? <BinderTemp>[];

  /// The id of the binder the change is for, or null while none is known (a
  /// delta recorded where no id was recorded). [BinderStore.update] needs one.
  String? binderId;

  /// Makes the change on a binder.
  final Binder Function(Binder onDisk) apply;
  final BinderDeltaKind kind;

  /// For an AI or box-type setting.
  final BinderField? field;

  /// The temporary files written for this delta so far.
  final List<BinderTemp> temps;
}

/// The result of [BinderStore.update].
sealed class BinderUpdate {
  const BinderUpdate(this.kept);

  /// Files an aside or conflict copy was kept at during this call.
  final List<String> kept;
}

/// The binder file holds [binder] now, as the text [written]. [wrote] is false
/// when the change made no difference and nothing was written.
final class BinderUpdated extends BinderUpdate {
  const BinderUpdated(this.binder, this.written, {required this.wrote, List<String> kept = const []})
    : super(kept);

  final Binder binder;
  final String written;
  final bool wrote;
}

/// Nothing was written. [reason] is a sentence for the user.
final class BinderRefused extends BinderUpdate {
  const BinderRefused(this.kind, this.reason, {List<String> kept = const []}) : super(kept);

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

/// A file beside the binder file whose name starts with `noted-binder`: a
/// temporary file, an aside, a conflict or sync-client copy.
final class BinderCopy {
  const BinderCopy(this.path, this.bytes, this.binder, this.modified);

  final String path;

  /// What it holds, or null when it couldn't be read.
  final List<int>? bytes;

  /// It parsed as a binder of a format this build reads; null otherwise.
  final Binder? binder;

  final DateTime? modified;

  String get name => path.split(RegExp(r'[\\/]')).last;

  /// A temporary file written by a binder update (`<name>.<micros>-<n>.tmp`) or
  /// an older build's fixed `.tmp`.
  bool get isTemp => isBinderTempName(name);
}

/// What [BinderStore.sweepLeftovers] found.
final class BinderSweep {
  const BinderSweep({
    this.restored = const [],
    this.copies = const [],
    this.hasBinderAside = false,
  });

  /// Paths asides were restored to (see [sweepAsideFiles]).
  final List<String> restored;

  /// Every `noted-binder*` file except the binder file, never deleted.
  final List<BinderCopy> copies;

  /// A set-aside copy of the binder file (a replace in progress) is there.
  final bool hasBinderAside;
}

/// Whether [name] is the name of a binder temporary file: `noted-binder.json.`
/// then anything, ending in `.tmp` (the current names are
/// `noted-binder.json.<micros>-<n>.tmp`; older builds used the fixed
/// `noted-binder.json.tmp`).
bool isBinderTempName(String name) =>
    name.startsWith('$binderFileName.') && name.endsWith('.tmp');

final RegExp _binderAside = RegExp(
  '^${RegExp.escape(binderFileName)}\\.\\d+-[0-9a-f]+-[0-9a-f]+'
  '(${RegExp.escape(asideSuffix)}|${RegExp.escape(verifiedSuffix)})\$',
);

/// Whether [name] is exactly a set-aside copy of the binder file, as
/// [replaceIfUnchanged] names it: `noted-binder.json.<pid>-<hex>-<hex>` and
/// `.cas-old` or `.cas-verified`. Asides of a temporary file or of a conflict
/// copy are not.
bool isBinderFileAsideName(String name) => _binderAside.hasMatch(name);

/// The binder file of one folder.
///
/// Writes to an existing file are [update]s: the file is read, the change
/// reapplied to those bytes, and the file compared and replaced with
/// [replaceIfUnchanged]. Call them under the folder lock.
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

  /// Writes [bytes] to [temp], flushed. Public so tests can make the write
  /// fail, or stop part way.
  Future<void> writeTemp(File temp, List<int> bytes) => temp.writeAsBytes(bytes, flush: true);

  /// Reads the folder's binder file.
  Future<BinderRead> read() async {
    final f = file;
    try {
      if (!await f.exists()) return const BinderMissing();
      return BinderFound(Binder.parse(await f.readAsString()));
    } on BinderFormatException catch (e) {
      return BinderUnreadable(e.message);
    } on FileSystemException catch (e) {
      return BinderUnreadable(e.message);
    }
  }

  /// Applies [d] to the binder file as it is on disk now, never to a copy the
  /// caller holds, and replaces the file only if it is unchanged since it was
  /// read. Up to [tries] tries; call it under the folder lock.
  ///
  /// Each try:
  /// - U2 reads the file strictly. A missing file is [BinderRefusal.inUse]
  ///   when a binder-file aside stands (a replace is in progress), else
  ///   [BinderRefusal.gone]; a damaged, newer or id-less one is
  ///   [BinderRefusal.unreadable]; another binder's is
  ///   [BinderRefusal.otherBinder]. Nothing is written then. An I/O error is
  ///   tried again after [retryDelay].
  /// - U3 reapplies the change to what was read. For an AI or box-type field,
  ///   a value on disk that is stricter than the delta's base is kept.
  ///   An equal result writes nothing.
  /// - U4 refuses a read-only file ([BinderRefusal.readOnly]), then writes a
  ///   temporary file (reusing one of [BinderDelta.temps] with the same bytes)
  ///   and adds it to [BinderDelta.temps].
  /// - U5 replaces the file with [replaceIfUnchanged]. A changed file is read
  ///   again; a replacement that appeared while the file was set aside is left
  ///   as it is and the set-aside copy kept (listed in `kept`).
  ///
  /// Temporary files are never deleted here; see [removeTemps].
  ///
  /// [beforeMoveAside], [afterRead], [beforePublish] and [beforeRestore] are
  /// the seams of [replaceIfUnchanged], run on every try.
  Future<BinderUpdate> update(
    BinderDelta d, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) async {
    final id = d.binderId;
    if (id == null) throw ArgumentError('the delta has no binder id');
    final kept = <String>[];
    BinderRefused last = BinderRefused(
      BinderRefusal.keepsChanging,
      'The binder file keeps changing',
      kept: kept,
    );
    BinderRefused inUse(FileSystemException e) => BinderRefused(
      BinderRefusal.inUse,
      'The binder file is in use by another program${_reasonOf(e)}',
      kept: kept,
    );
    for (var attempt = 1; attempt <= tries; attempt++) {
      // U2. Read.
      final f = file;
      final List<int> bytes;
      try {
        bytes = await f.readAsBytes();
      } on FileSystemException catch (e) {
        if (_notFound(f.path)) {
          if (hasBinderAsideSync()) {
            return BinderRefused(
              BinderRefusal.inUse,
              'The binder file is being replaced',
              kept: kept,
            );
          }
          return BinderRefused(BinderRefusal.gone, 'The binder file is missing', kept: kept);
        }
        last = inUse(e);
        if (attempt < tries) await Future<void>.delayed(retryDelay);
        continue;
      }
      final Binder parsed;
      final String text;
      try {
        text = utf8.decode(bytes);
        parsed = Binder.parse(text);
      } on BinderFormatException catch (e) {
        return BinderRefused(
          BinderRefusal.unreadable,
          "The binder file can't be read (${e.message})",
          kept: kept,
        );
      } on FormatException {
        return BinderRefused(
          BinderRefusal.unreadable,
          "The binder file can't be read (not valid UTF-8 text)",
          kept: kept,
        );
      }
      if (parsed.id != id) {
        return BinderRefused(
          BinderRefusal.otherBinder,
          'The binder file in this folder belongs to another binder',
          kept: kept,
        );
      }
      // U3. Reapply.
      final next = _reapply(d, parsed);
      final written = next.write();
      if (written == text) {
        return BinderUpdated(next, text, wrote: false, kept: kept);
      }
      // U4. Temporary file.
      if (!_isWritable(f.path)) {
        return BinderRefused(BinderRefusal.readOnly, 'The binder file is read-only', kept: kept);
      }
      final out = utf8.encode(written);
      File? tmp;
      for (final t in d.temps) {
        if (_same(t.bytes, out) && _holds(t.path, out)) {
          tmp = File(t.path);
          break;
        }
      }
      if (tmp == null) {
        final fresh = newTempFile();
        try {
          await writeTemp(fresh, out);
        } on FileSystemException catch (e) {
          await _afterFailedWrite(fresh, out, d, parsed.id, kept);
          return BinderRefused(
            BinderRefusal.cantWrite,
            "The binder file couldn't be written${_reasonOf(e)}",
            kept: kept,
          );
        }
        d.temps.add(BinderTemp(fresh.path, out, parsed.id));
        tmp = fresh;
      }
      // U5. Replace.
      final ReplaceResult r;
      try {
        r = await replaceIfUnchanged(
          tmp,
          f.path,
          bytes,
          beforeMoveAside: beforeMoveAside,
          afterRead: afterRead,
          beforePublish: beforePublish,
          beforeRestore: beforeRestore,
        );
      } on FileSystemException catch (e) {
        if (!_isWritable(f.path)) {
          return BinderRefused(BinderRefusal.readOnly, 'The binder file is read-only', kept: kept);
        }
        last = inUse(e);
        if (attempt < tries) await Future<void>.delayed(retryDelay);
        continue;
      }
      switch (r.outcome) {
        case ReplaceOutcome.replaced:
          final path = tmp.path;
          d.temps.removeWhere((t) => t.path == path);
          if (r.keptPath != null) kept.add(r.keptPath!);
          return BinderUpdated(next, written, wrote: true, kept: kept);
        case ReplaceOutcome.changed:
          if (attempt >= tries && _notFound(f.path)) {
            return BinderRefused(BinderRefusal.gone, 'The binder file is missing', kept: kept);
          }
          last = BinderRefused(
            BinderRefusal.keepsChanging,
            'The binder file keeps changing',
            kept: kept,
          );
        case ReplaceOutcome.changedKept || ReplaceOutcome.supersededKept:
          if (r.keptPath != null) kept.add(r.keptPath!);
          last = BinderRefused(
            BinderRefusal.keepsChanging,
            'The binder file keeps changing',
            kept: kept,
          );
      }
    }
    return last;
  }

  /// Removes the temporary files of [d] one by one, each only while the same
  /// binder's file is present and readable at the moment it is deleted
  /// (see [deleteFileIfMatches]'s `stillRedundant`). The id is [d]'s
  /// `binderId`, else what [currentId] says now, else the temp's own.
  /// Returns the temps that stayed; removed ones leave [BinderDelta.temps].
  Future<List<BinderTemp>> removeTemps(BinderDelta d, {String? Function()? currentId}) async {
    final stayed = <BinderTemp>[];
    for (final t in List<BinderTemp>.of(d.temps)) {
      try {
        final r = await deleteFileIfMatches(
          t.path,
          bytes: t.bytes,
          stillRedundant: () => fileHoldsBinderSync(d.binderId ?? currentId?.call() ?? t.binderId),
        );
        if (r.outcome == DeleteOutcome.deleted || r.outcome == DeleteOutcome.absent) {
          d.temps.remove(t);
        } else {
          stayed.add(t);
        }
      } on FileSystemException {
        stayed.add(t);
      }
    }
    return stayed;
  }

  /// Whether the binder file is present, readable and has id [binderId],
  /// read synchronously.
  bool fileHoldsBinderSync(String binderId) {
    try {
      return Binder.parse(utf8.decode(file.readAsBytesSync())).id == binderId;
    } on Object {
      return false;
    }
  }

  /// Whether a set-aside copy of the binder file stands in the folder.
  bool hasBinderAsideSync() {
    try {
      for (final e in directory.listSync(followLinks: false)) {
        if (e is File && isBinderFileAsideName(_name(e.path))) return true;
      }
    } on FileSystemException {
      // Treated as none.
    }
    return false;
  }

  /// Publishes a new binder file for [binder], never replacing: a folder that
  /// has one gives [BinderCreated.exists], and that file is left as it is.
  /// Throws [FileSystemException] if the folder or the drive can't take it (a
  /// volume without hard links can't publish safely). The temporary file this
  /// call wrote and didn't publish is deleted by its bytes.
  ///
  /// [beforePublish] is a test seam, run after the temporary file is written.
  Future<BinderCreated> create(Binder binder, {void Function()? beforePublish}) async {
    if (await file.exists()) return BinderCreated.exists;
    await directory.create(recursive: true);
    final tmp = newTempFile();
    final bytes = utf8.encode(binder.write());
    try {
      await writeTemp(tmp, bytes);
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
        // Our own temp, never published, and the binder's content is still in
        // memory: deleted by its bytes, without asking what the file holds.
        await _deleteQuiet(tmp, bytes);
        return BinderCreated.exists;
      }
      return BinderCreated.created;
    } on FileSystemException {
      await _deleteQuiet(tmp, bytes);
      rethrow;
    }
  }

  /// Under the folder lock: with [restore], puts back every set-aside file
  /// whose target name starts with `noted-binder` (see [sweepAsideFiles]; one
  /// whose name is taken becomes a `-recovered-` or `-conflict-` copy). Then
  /// lists every `noted-binder*` file except the binder file. It never
  /// deletes anything.
  Future<BinderSweep> sweepLeftovers({required bool restore}) async {
    if (!await directory.exists()) return const BinderSweep();
    var restored = const <String>[];
    if (restore) {
      try {
        restored = await sweepAsideFiles(
          directory,
          extension: '',
          only: (name) => name.startsWith('noted-binder'),
        );
      } on FileSystemException {
        // Left for the next call.
      }
    }
    final copies = <BinderCopy>[];
    var aside = false;
    try {
      await for (final e in directory.list(followLinks: false)) {
        if (e is! File) continue;
        final name = _name(e.path);
        if (!name.startsWith('noted-binder') || name == binderFileName) continue;
        if (isBinderFileAsideName(name)) aside = true;
        List<int>? bytes;
        Binder? binder;
        DateTime? modified;
        try {
          modified = e.lastModifiedSync();
          bytes = await e.readAsBytes();
          binder = Binder.parse(utf8.decode(bytes));
        } on Object {
          // Unreadable or not a binder.
        }
        copies.add(BinderCopy(e.path, bytes, binder, modified));
      }
    } on FileSystemException {
      // A folder that can't be listed has nothing to show.
    }
    copies.sort((a, b) => a.path.compareTo(b.path));
    return BinderSweep(restored: restored, copies: copies, hasBinderAside: aside);
  }

  Binder _reapply(BinderDelta d, Binder parsed) {
    switch (d.field) {
      case BinderAiField(:final base, :final request):
        final read = parsed.aiAccess;
        if (_aiRank(read) > _aiRank(base)) {
          return parsed.withAiAccess(_aiRank(read) >= _aiRank(request) ? read : request);
        }
      case BinderBoxTypeField(:final typeId, :final base, :final request):
        final read = parsed.boxTypeChoice(typeId);
        if (_boxRank(read) > _boxRank(base)) {
          return parsed.withBoxType(typeId, _boxRank(read) >= _boxRank(request) ? read : request);
        }
      case null:
        break;
    }
    return d.apply(parsed);
  }

  // Open < Privileged < Guarded, with null as Guarded.
  static int _aiRank(AiAccess? v) => (v ?? AiAccess.guarded).strictness;

  // `false` is stricter than `null` or `true`.
  static int _boxRank(bool? v) => v == false ? 1 : 0;

  // A write that threw: read the temp back. A complete one is a temp of the
  // delta; a part-written one is deleted by its own bytes (the binder file is
  // known to be this binder's); an unreadable one is kept and listed.
  Future<void> _afterFailedWrite(
    File temp,
    List<int> wanted,
    BinderDelta d,
    String binderId,
    List<String> kept,
  ) async {
    final List<int> back;
    try {
      if (!await temp.exists()) return;
      back = await temp.readAsBytes();
    } on FileSystemException {
      kept.add(temp.path);
      return;
    }
    if (_same(back, wanted)) {
      d.temps.add(BinderTemp(temp.path, wanted, binderId));
      return;
    }
    // Only our own part-written file is deleted: bytes that are a prefix of what
    // this write sent, or nothing. Anything else was put there by someone else
    // and is kept, listed with the other copies.
    if (back.length > wanted.length || !_same(back, wanted.sublist(0, back.length))) {
      kept.add(temp.path);
      return;
    }
    try {
      final r = await deleteFileIfMatches(
        temp.path,
        bytes: back,
        stillRedundant: () => fileHoldsBinderSync(binderId),
      );
      if (r.outcome != DeleteOutcome.deleted && r.outcome != DeleteOutcome.absent) {
        kept.add(temp.path);
      }
    } on FileSystemException {
      kept.add(temp.path);
    }
  }

  static Future<void> _deleteQuiet(File f, List<int> bytes) async {
    try {
      await deleteFileIfMatches(f.path, bytes: bytes);
    } on FileSystemException {
      // Listed by the sweep.
    }
  }

  static bool _holds(String path, List<int> bytes) {
    try {
      return _same(File(path).readAsBytesSync(), bytes);
    } on FileSystemException {
      return false;
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _name(String path) => path.split(RegExp(r'[\\/]')).last;

  static bool _notFound(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;

  /// Whether the file has the owner write permission (on Windows, doesn't have
  /// the read-only attribute). A file that can't be examined counts as
  /// writable: the next step reports the real error.
  static bool _isWritable(String path) {
    try {
      final stat = FileStat.statSync(path);
      if (stat.type == FileSystemEntityType.notFound) return true;
      return stat.mode & 0x80 != 0;
    } on FileSystemException {
      return true;
    }
  }

  static String _reasonOf(FileSystemException e) {
    final m = e.osError?.message.trim() ?? '';
    return m.isEmpty ? '' : ' ($m)';
  }
}
