// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:noted_core/noted_core.dart';

import 'device_storage.dart';

/// The folder for recovery entries: `recovery` next to `binders.json`, the
/// app settings folder.
///
/// On a device the default `binders.json` is in the documents folder, but
/// recovery goes to the app's support folder (0129).
Directory defaultRecoveryDirectory(File bindersFile) {
  final sep = Platform.pathSeparator;
  final support = deviceSupportDirectory();
  final docs = devicePagesDirectory()?.parent;
  if (support != null && docs != null && recoveryLocationKey(bindersFile.parent.path) == recoveryLocationKey(docs.path)) {
    return Directory('${support.path}${sep}recovery');
  }
  return Directory('${bindersFile.absolute.parent.path}${sep}recovery');
}

/// A comparable form of a storage location: absolute, with forward slashes
/// and, on Windows only, lower case. This mirrors `Notebook._key` in
/// notebook.dart; keep the two in step. [windows] is for tests; it defaults
/// to the platform the app runs on.
String recoveryLocationKey(String path, {bool? windows}) {
  final p = File(path).absolute.path.replaceAll(r'\', '/');
  return (windows ?? Platform.isWindows) ? p.toLowerCase() : p;
}

/// An edit that couldn't be saved because its folder was unavailable.
///
/// On disk an entry is one file in the recovery folder, so it is always one
/// complete generation. It is named `<page id>-<hash of location and id>.entry`
/// (see [recoveryLocationKey]) and holds, for example (all strings, `base`
/// may be null):
///
///     {"format":2,"folder":"D:\Notes","pageId":"p1",
///      "time":"2026-10-25T10:00:00.000Z","base":"...page file text...",
///      "page":"...page file text..."}
///
/// - `page`: exactly the text a normal save of the page writes (`writePage`).
///   Nothing else is derived from the page's content, so an entry never holds
///   anything a page file wouldn't (invariant 3).
/// - `base`: the page file as last read or written by the app, the base of the
///   three-way merge. It is itself a former page file.
///
/// The file is written to a unique `<name>.entry.<n>.tmp` file and then
/// renamed over the entry, so a crash leaves the previous generation intact.
/// If the rename fails or the process stops, a complete `.tmp` stays;
/// [RecoveryStore.list] promotes it when it is newer than the published
/// entry (or none exists), deletes it when the entry has the same page and
/// base or a strictly later time, and otherwise keeps it and reports it. A newer edit of
/// the same page and location replaces its entry; an existing entry of
/// another location or page under the same name is never replaced (the new
/// one gets `<name>_dup<n>`). Files added while the folder was away are kept
/// apart, in `<page id>.assets` folders (0098).
///
/// Entries written before this layout were two files, `<old name>.canvas` (the
/// page) and `<old name>.json` (the rest, as `format` 1). They are read and
/// converted to the layout above by [RecoveryStore.list].
class RecoveryEntry {
  RecoveryEntry._(
    this.storedFolder,
    this.folder,
    this.pageId,
    this.time,
    this.baseText,
    this.pageText,
    this.page,
    this._stem,
    this._dir,
  );

  /// The folder as written in the entry's file: on mobile `@documents/...`, or
  /// an absolute path of an older app container (see [resolveStoredPath]).
  /// Every generation hash is over this string.
  final String storedFolder;

  /// The folder the page belongs in, as a path of this container.
  final String folder;
  final String pageId;
  final DateTime time;

  /// The page file as last read or written before the edit; null if unknown.
  final String? baseText;

  /// What a normal save of the page would have written.
  final String pageText;
  final NotedPage page;
  final String _stem;
  final Directory _dir;

  /// The entry's file.
  File get file => File('${_dir.path}${Platform.pathSeparator}$_stem.entry');

  /// Names this generation: a hash of its time, base and page text. Two
  /// entries with the same [gen] hold the same edits.
  late final String gen = RecoveryStore._generationOf(storedFolder, time, baseText, pageText);
}

/// An entry was not replaced because the slot holds something that isn't one
/// of the generations the writer may replace (R-1 v5, build note 1).
class RecoveryRefused implements Exception {
  const RecoveryRefused(this.why);
  final String why;
  @override
  String toString() => why;
}

/// A recovery transaction did not finish within its limit.
class RecoveryTimeout implements Exception {
  const RecoveryTimeout();
  @override
  String toString() => "the recovery folder isn't responding";
}

/// What a scan of the recovery folder found: [entries] that can be used and
/// [problems] (descriptions of files that can't be read; they are kept).
class RecoveryListing {
  const RecoveryListing(this.entries, this.problems, [this.damaged = const []]);
  final List<RecoveryEntry> entries;
  final List<String> problems;

  /// The same damaged entries as [problems], one for each, with the entry's
  /// path (without extension) and a short reason, for the sidebar.
  final List<UnreadablePage> damaged;
}

// A parsed entry file.
class _Env {
  _Env(this.folder, this.id, this.time, this.timeOk, this.base, this.text, this.key, this.rawKey);
  final String folder;
  final String id;
  final DateTime time;

  /// False if the time couldn't be read ([time] is then the epoch).
  final bool timeOk;
  final String? base;
  final String text;

  /// The location key ([RecoveryStore._locKey]): equal for every form of one
  /// folder.
  final String key;

  /// The key of the folder string as written ([RecoveryStore._key]): two files
  /// whose raw keys differ are of different forms.
  final String rawKey;
}

/// The recovery folder: one entry per page and location, never deleted except
/// by [delete] (and the superseded leftovers described at [RecoveryEntry]).
///
/// Every write, migration, promotion and deletion runs one after another, per
/// folder and across instances, so [list] never sees a write half done. A
/// `hook` runs inside that sequence, so it must not call back into the store.
class RecoveryStore {
  /// [windows] says whether locations compare without regard to case (see
  /// [recoveryLocationKey]); [hook] is called at named points of a write
  /// (write: before anything is written; delete: before an entry is removed) or a
  /// migration, so tests can inject a failure there (`tmp-written`: a new
  /// generation is complete but not yet published; `envelope-published`: an
  /// old entry is converted but its old files are still there;
  /// `legacy-first-deleted`: the first of the old files is removed).
  RecoveryStore(this.directory, {this.windows, this.hook});

  final Directory directory;
  final bool? windows;
  Future<void> Function(String point)? hook;

  static int _tmpCounter = 0;
  static final Map<String, Future<void>> _chains = {};

  /// How long one transaction may take before its caller gets a
  /// [RecoveryTimeout] and the next transaction runs (the abandoned one may
  /// still finish). Recovery is on the local disk, so this is generous.
  Duration transactionLimit = const Duration(seconds: 10);

  /// Runs [job] after every earlier transaction on this folder (also from
  /// other instances) and before any later one (L2). Inside, [RecoveryTx]
  /// lists, writes and deletes without waiting for the chain again; a job
  /// must not await the notebook's save chain, a dialog or a page folder.
  ///
  /// A transaction that times out is fenced: its caller gets the error and
  /// the next transaction runs, but while the abandoned job is still running
  /// every later transaction fails at once with the same [RecoveryTimeout]
  /// (nothing else may change the folder under it), and the abandoned job's
  /// own writes and deletes stop at their last check (it must not rename or
  /// delete over a slot that changed since it chose it).
  Future<T> transaction<T>(Future<T> Function(RecoveryTx tx) job, {Duration? limit}) {
    final k = recoveryLocationKey(directory.path, windows: windows);
    final prev = _chains[k] ?? Future<void>.value();
    final c = Completer<T>();
    _chains[k] = prev.then((_) async {
      if ((_outstanding[k] ?? 0) > 0) {
        c.completeError(const RecoveryTimeout());
        return;
      }
      final tx = RecoveryTx._(this, limit ?? transactionLimit);
      final over = Completer<void>();
      final timer = Timer(limit ?? transactionLimit, () {
        if (!c.isCompleted) {
          tx.abandoned = true;
          _outstanding[k] = (_outstanding[k] ?? 0) + 1;
          c.completeError(const RecoveryTimeout());
        }
        if (!over.isCompleted) over.complete();
      });
      unawaited(() async {
        try {
          final v = await job(tx);
          if (!c.isCompleted) c.complete(v);
        } on Object catch (e, s) {
          if (!c.isCompleted) c.completeError(e, s);
        } finally {
          timer.cancel();
          if (tx.abandoned) {
            final n = (_outstanding[k] ?? 1) - 1;
            if (n <= 0) {
              _outstanding.remove(k);
            } else {
              _outstanding[k] = n;
            }
          }
          if (!over.isCompleted) over.complete();
        }
      }());
      await over.future;
    });
    return c.future;
  }

  // Abandoned (timed out, still running) transactions, by folder.
  static final Map<String, int> _outstanding = {};

  /// Whether a transaction that timed out is still running on this folder.
  bool get hasAbandonedJob =>
      (_outstanding[recoveryLocationKey(directory.path, windows: windows)] ?? 0) > 0;

  Future<T> _serial<T>(Future<T> Function(RecoveryTx tx) f) => transaction(f);

  // The generation hash of an entry with these parts, over the folder as
  // stored in its file.
  static String _generationOf(String storedFolder, DateTime time, String? base, String pageText) =>
      contentHash(utf8.encode(jsonEncode([storedFolder, time.toUtc().toIso8601String(), base, pageText])));

  /// The generation hash of an entry for [resolvedFolder] (a path of this
  /// container) with these parts: the hash of the entry [write] would make.
  /// The only way for a caller to compute one.
  String generationFor(String resolvedFolder, DateTime time, String? base, String pageText) =>
      _generationOf(storedPath(resolvedFolder, windows: windows), time, base, pageText);

  // The entries this process knows of: built by every listing and kept
  // current by every write and delete. This process is the only writer, so
  // open, preview, the quit notice and the delete question read it without
  // touching the disk.
  final List<RecoveryEntry> _index = [];
  bool _indexed = false;

  // Generations whose page landed but whose entry could not be deleted yet.
  final Set<String> _landed = {};

  // An old-form file whose re-keyed twin exists but which could not be deleted:
  // the twin's generation -> the old file's. When the twin lands, so did the
  // old file's generation (build note 3): it is not re-keyed again, and its
  // entry is offered as landed.
  final Map<String, String> _twinOf = {};
  final Set<String> _landedOld = {};

  /// Whether a listing has filled the index.
  bool get indexed => _indexed;

  /// Every entry the index holds.
  List<RecoveryEntry> get indexEntries => List.unmodifiable(_index);

  /// The entries of [pageId] in [folder], from the index.
  List<RecoveryEntry> entriesFor(String folder, String pageId) {
    final k = _locKey(folder);
    return [
      for (final e in _index)
        if (e.pageId == pageId && _locKey(e.storedFolder) == k) e,
    ];
  }

  /// The entries of [pageId] in any folder, from the index.
  List<RecoveryEntry> entriesOfPage(String pageId) => [
    for (final e in _index)
      if (e.pageId == pageId) e,
  ];

  /// Whether generation [gen] landed in its page but is still on disk.
  bool isLanded(String gen) => _landed.contains(gen);

  /// Marks [gen] as landed: open and replay delete it and merge nothing.
  void markLanded(String gen) {
    _landed.add(gen);
    final old = _twinOf[gen];
    if (old != null) _landedOld.add(old);
  }

  /// The landed generations that are still in the index.
  List<RecoveryEntry> get landedEntries => [
    for (final e in _index)
      if (_landed.contains(e.gen)) e,
  ];

  void _indexPut(RecoveryEntry e) {
    _index.removeWhere((x) => x.file.path == e.file.path);
    _index.add(e);
  }

  // A retired generation with an old-form twin that could not be deleted: the
  // twin is retired with it, so no later listing offers it again.
  void _retireTwin(String gen) {
    final twin = _twinOf[gen];
    if (twin != null) _landedOld.add(twin);
  }

  void _indexRemove(RecoveryEntry e) {
    _index.removeWhere((x) => x.file.path == e.file.path && x.gen == e.gen);
    if (!_index.any((x) => x.gen == e.gen)) _landed.remove(e.gen);
  }

  static int _fnv(String s) {
    var h = 0xcbf29ce484222325;
    for (final u in utf8.encode(s)) {
      h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h;
  }

  static String _safe(String pageId) {
    final safe = pageId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.length > 40 ? safe.substring(0, 40) : safe;
  }

  // The key of a folder string as written. An `@documents/` string is its own
  // key (never resolved against the working directory); case is folded on
  // Windows only.
  String _key(String folder) {
    if (isDocumentsForm(folder)) return (windows ?? Platform.isWindows) ? folder.toLowerCase() : folder;
    return recoveryLocationKey(folder, windows: windows);
  }

  // The folder in the form a new file is written in.
  String _canon(String folder) => storedPath(resolveStoredPath(folder, windows: windows), windows: windows);

  // The location key: the same for a folder in any form (stored, old absolute
  // or resolved). Used for every comparison of locations.
  String _locKey(String folder) => _key(_canon(folder));

  // Whether [folder] is an old form of a location: absolute where this build
  // writes `@documents/` (a path of an older app container). Never on desktop.
  bool _isOldForm(String folder) => !isDocumentsForm(folder) && _canon(folder) != folder;

  // The name of the entry of [pageId] in [folder] as written: the name its file
  // was given, which [_checkIdentity] checks.
  String _rawName(String folder, String pageId) =>
      '${_safe(pageId)}-${_fnv('${_key(folder)}|$pageId').toRadixString(16)}';

  // The name a new entry of [pageId] in [folder] gets.
  String _name(String folder, String pageId) => _rawName(_canon(folder), pageId);

  // The name entries had before the layout changed: it folded case on every
  // platform.
  static String _legacyName(String folder, String pageId) =>
      '${_safe(pageId)}-${_fnv('${folder.replaceAll(r'\', '/').toLowerCase()}|$pageId').toRadixString(16)}';

  String _path(String stem, String ext) => '${directory.path}${Platform.pathSeparator}$stem.$ext';

  // The k-th file an entry of [folder] and [id] may have: the name, then
  // `<name>_dup2`, `_dup3`, ...
  // With [raw], by the name of [folder] as written, not its canonical form.
  File _slot(String folder, String id, int k, {bool raw = false}) {
    final n = raw ? _rawName(folder, id) : _name(folder, id);
    return File(_path(k == 1 ? n : '${n}_dup$k', 'entry'));
  }

  // [selectedGen]: the generation the slot held when the writer chose it (null:
  // it was free). Just before the rename the slot is looked at again, and a
  // writer whose transaction was abandoned stops: it must not publish over a
  // slot that changed since (build: R-1 v5 pre-merge, timed-out transactions).
  Future<void> _atomic(File f, String text, {bool checkSlot = false, String? selectedGen, RecoveryTx? tx}) async {
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsString(text, flush: true);
    } on Object {
      await _tryDelete(tmp);
      rethrow;
    }
    // A failure injected here stands for a crash: the file stays.
    await hook?.call('tmp-written');
    if (checkSlot) {
      final now = await _peek(f);
      final nowGen = now == null ? (await f.exists() ? '?' : null) : _generationOf(now.folder, now.time, now.base, now.text);
      if ((tx?.abandoned ?? false) || nowGen != selectedGen) {
        await _tryDelete(tmp);
        if (tx?.abandoned ?? false) throw const RecoveryTimeout();
        throw const RecoveryRefused('the entry changed while it was being written');
      }
    }
    // If the rename fails, the complete tmp stays: it may be the only copy of
    // the newest edit, and the next listing promotes it.
    await tmp.rename(f.path);
  }

  // Writes [text] to a unique tmp and publishes it at the free slot [f] without
  // replacing anything. False if a file is at [f] now (the tmp is removed).
  Future<bool> _atomicNew(File f, String text) async {
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsString(text, flush: true);
    } on Object {
      await _tryDelete(tmp);
      rethrow;
    }
    // A failure injected here stands for a crash: the complete tmp stays.
    await hook?.call('tmp-written');
    var published = false;
    try {
      published = await _moveToFree(tmp, f);
      return published;
    } finally {
      // A refused or failed publish leaves no tmp behind.
      if (!published) await _tryDelete(tmp);
    }
  }

  // Whether anything is at [f]'s path: a file, a directory, or a link (also a
  // dangling one). A slot like that is never published into.
  static bool _occupied(File f) => FileSystemEntity.typeSync(f.path, followLinks: false) != FileSystemEntityType.notFound;

  // Moves the finished file [from] to the free slot [to] without replacing
  // anything. False if something is there now. Where the volume can't do an
  // exclusive publish (no hard links) and the slot is still free, it renames,
  // as the store always did: only for files of the same form (cross-form moves
  // call [publishExclusive] themselves).
  Future<bool> _moveToFree(File from, File to) async {
    try {
      return await publishExclusive(from, to.path);
    } on FileSystemException {
      if (_occupied(to)) return false;
      await from.rename(to.path);
      return true;
    }
  }

  // Looks at the next slot after a lost publish: the same one again if
  // something is there now, else the following one (never a busy loop).
  static int _afterLostPublish(File slot, int k) => _occupied(slot) ? k - 1 : k;

  static Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } on Object {
      // Nothing more to do.
    }
  }

  static String _encode(String folder, String pageId, String time, String? base, String page) =>
      jsonEncode({
        'format': 2,
        'folder': folder,
        'pageId': pageId,
        'time': time,
        'base': base,
        'page': page,
      });

  static DateTime? _tryTime(Object? raw) => DateTime.tryParse('$raw')?.toUtc();

  static DateTime _time(Object? raw) => _tryTime(raw) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  // Whether [held] makes a copy with [text], [base] and [time] redundant: the
  // same page and base, or a strictly later time (when both can be read). An
  // equal time with different content, or a time that can't be read, never
  // does.
  static bool _stands(_Env held, String text, String? base, DateTime? time) =>
      (held.text == text && held.base == base) || (time != null && held.timeOk && held.time.isAfter(time));

  // [_stands] between files of one form. Between files whose raw folder strings
  // differ (an old absolute form and the new one) only identity (same page and
  // base) makes one redundant: a later time never does (cross-form rule).
  bool _standsFrom(_Env held, String rawKey, String text, String? base, DateTime? time) =>
      held.rawKey == rawKey ? _stands(held, text, base, time) : (held.text == text && held.base == base);

  // Whether an entry already holds what an old metadata file holds.
  bool _jsonHeld(_Env e, ({String folder, String id, DateTime? time, String? base}) m) =>
      e.key == _locKey(m.folder) &&
      e.id == m.id &&
      (e.base == m.base ||
          (e.rawKey == _key(m.folder) && m.time != null && e.timeOk && e.time.isAfter(m.time!)));

  // Parses an entry file's text. Throws a FormatException if it isn't one.
  _Env _parse(String text) {
    final meta = jsonDecode(text);
    if (meta is! Map || meta['format'] != 2) throw const FormatException('unknown format');
    final folder = meta['folder'];
    final id = meta['pageId'];
    final b = meta['base'];
    final page = meta['page'];
    if (folder is! String || id is! String || page is! String || (b != null && b is! String)) {
      throw const FormatException('missing fields');
    }
    final t = _tryTime(meta['time']);
    return _Env(folder, id, t ?? _time(null), t != null, b as String?, page, _locKey(folder), _key(folder));
  }

  // The envelope of an entry file, only if [list] would accept it: the
  // embedded page, the base and the file name must agree with the metadata. A
  // file that fails is null, so it is never replaced, never counts as holding
  // or superseding anything, and is left to [list] to report.
  Future<_Env?> _peek(File f) async {
    try {
      final env = _parse(await f.readAsString());
      _checkIdentity(_stemOf(f.path), _rawName(env.folder, env.id), env.id, readPage(env.text), env.base);
      return env;
    } on Object {
      return null;
    }
  }

  /// Writes (or replaces) the entry of [page], belonging in [folder].
  ///
  /// With [replaceable] (generation hashes), a slot that holds anything else
  /// is not replaced: a [RecoveryRefused] is thrown and the slot is left as it
  /// is, even if the index doesn't list it (a file put there from outside).
  Future<RecoveryEntry> write({
    required String folder,
    required NotedPage page,
    required String? baseText,
    required DateTime time,
    Set<String>? replaceable,
    bool freshSlot = false,
  }) => _serial(
    (tx) => _writeNow(
      folder: folder,
      page: page,
      baseText: baseText,
      time: time,
      replaceable: replaceable,
      freshSlot: freshSlot,
      tx: tx,
    ),
  );

  Future<RecoveryEntry> _writeNow({
    required String folder,
    required NotedPage page,
    required String? baseText,
    required DateTime time,
    Set<String>? replaceable,
    bool freshSlot = false,
    RecoveryTx? tx,
  }) async {
    await hook?.call('write');
    await directory.create(recursive: true);
    try {
      // An entry of the old layout for this page is converted first, so the
      // new generation replaces it, not sits beside it.
      await _migrate([], [], tx);
    } on Object {
      // Never let it stop the edit from being kept.
    }
    // The entry of this page and location, or a free name; an entry of
    // another location or page (or one that can't be read) is never replaced.
    final key = _locKey(folder);
    final stored = storedPath(folder, windows: windows);
    File? target;
    String? selectedGen;
    String? replacedGen;
    for (var k = 1; target == null; k++) {
      final f = _slot(folder, page.id, k);
      if (!await f.exists()) {
        target = f;
        break;
      }
      if (freshSlot) continue;
      final e = await _peek(f);
      if (e != null && e.key == key && e.id == page.id) {
        selectedGen = _generationOf(e.folder, e.time, e.base, e.text);
        replacedGen = selectedGen;
        if (replaceable != null && !replaceable.contains(selectedGen)) {
          throw const RecoveryRefused('the recovery folder holds an entry for this page that Noted did not write');
        }
        target = f;
      }
    }
    final text = writePage(page);
    await _atomic(
      target,
      _encode(stored, page.id, time.toUtc().toIso8601String(), baseText, text),
      checkSlot: true,
      selectedGen: selectedGen,
      tx: tx,
    );
    final written = RecoveryEntry._(
      stored,
      resolveStoredPath(stored, windows: windows),
      page.id,
      time.toUtc(),
      baseText,
      text,
      page,
      _stemOf(target.path),
      directory,
    );
    // The generation this one replaced is retired, and so is its old-form twin.
    if (replacedGen != null) _retireTwin(replacedGen);
    _indexPut(written);
    return written;
  }

  // Checks that the identities of an entry agree: the metadata's page id, the
  // page's, the base's and the file name's. Throws a FormatException if not.
  // [allowedStem] is the name the entry must have.
  static void _checkIdentity(String stem, String allowedStem, String id, NotedPage page, String? base) {
    if (page.id != id) {
      throw FormatException('the page is "${page.id}" but the entry says "$id"');
    }
    if (base != null) {
      final b = readPage(base);
      if (b.id != id) throw FormatException('the base is page "${b.id}" but the entry says "$id"');
    }
    if (stem != allowedStem && !RegExp('^${RegExp.escape(allowedStem)}_dup\\d+\$').hasMatch(stem)) {
      throw const FormatException('the file name does not belong to the entry');
    }
  }

  static String _why(Object e) => e is FormatException
      ? e.message
      : e is PageFormatException
      ? e.message
      : _plain(e);

  // Not a format error: a plain reason for the user, the detail to the log.
  static String _plain(Object e) {
    debugPrint('Reading a recovery file failed: $e');
    return "the file couldn't be read";
  }

  static String _stemOf(String path) => path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]*$'), '');

  static void _report(List<String> problems, List<UnreadablePage> damaged, String path, String why) {
    problems.add('$path: $why');
    damaged.add(UnreadablePage(path, "Recovery entry can't be read: $why"));
  }

  // Every readable entry file in the folder.
  Future<List<_Env>> _envelopes() async {
    final out = <_Env>[];
    await for (final f in directory.list()) {
      if (f is File && f.path.endsWith('.entry')) {
        final e = await _peek(f);
        if (e != null) out.add(e);
      }
    }
    return out;
  }

  // Removes the files of an old entry. After it was converted, the metadata
  // goes first, so that what is left after an interruption is a page file
  // that equals the new entry's page. After it was superseded by an entry
  // with other content, the page file goes first, so that what is left is a
  // metadata file that the entry is known to stand for. Either way the
  // leftover is recognised as already dealt with and just removed.
  Future<void> _removeLegacy(String base, {required bool pageFirst}) async {
    final j = File('$base.json');
    final c = File('$base.canvas');
    final (first, second) = pageFirst ? (c, j) : (j, c);
    if (await first.exists()) await first.delete();
    await hook?.call('legacy-first-deleted');
    if (await second.exists()) await second.delete();
  }

  // Converts entries of the old two-file layout to the single file. Safe to
  // stop at any point and to run again: the new file is complete before the
  // old ones are removed, and an old entry that an existing entry of the same
  // page and location stands for (identical page and base, or a strictly later
  // time) is just removed. Otherwise both are kept, the converted one under
  // `<name>_dup<n>`; but one whose time can't be read stays as it is. Old
  // files that can't be converted stay, and are described in [problems] and
  // [damaged].
  Future<void> _migrate(List<String> problems, List<UnreadablePage> damaged, [RecoveryTx? tx]) async {
    final bases = <String>{};
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final p = f.path;
      if (p.endsWith('.canvas') || p.endsWith('.json')) bases.add(p.substring(0, p.lastIndexOf('.')));
    }
    List<_Env>? envs;
    for (final base in bases.toList()..sort()) {
      final stem = _stemOf(base);
      try {
        final metaFile = File('$base.json');
        final pageFile = File('$base.canvas');
        final hasMeta = await metaFile.exists();
        final hasPage = await pageFile.exists();
        if (!hasMeta || !hasPage) {
          // Half an old entry: only removed when an entry already holds it.
          envs ??= await _envelopes();
          if (hasPage) {
            final text = await pageFile.readAsString();
            readPage(text);
            if (envs.any((e) => e.text == text)) {
              await pageFile.delete();
              continue;
            }
            throw const FormatException('the .json file of the entry is missing');
          }
          final m = _legacyMeta(jsonDecode(await metaFile.readAsString()));
          if (envs.any((e) => _jsonHeld(e, m))) {
            await metaFile.delete();
            continue;
          }
          throw const FormatException('the .canvas file of the entry is missing');
        }
        final m = _legacyMeta(jsonDecode(await metaFile.readAsString()));
        final text = await pageFile.readAsString();
        _checkIdentity(stem, _legacyName(m.folder, m.id), m.id, readPage(text), m.base);
        final content = _encode(m.folder, m.id, (m.time ?? _time(null)).toIso8601String(), m.base, text);
        final key = _locKey(m.folder);
        final rawKey = _key(m.folder);
        var already = false;
        // The slots of the entry's own raw name: an old-form entry is
        // converted in its own form and moved by the re-key pass.
        for (var k = 1; ; k++) {
          final f = _slot(m.folder, m.id, k, raw: true);
          if (tx?.abandoned ?? false) throw const RecoveryTimeout();
          if (!_occupied(f)) {
            // Taken without replacing anything; if something appeared
            // meanwhile, the same slot is looked at again.
            if (await _atomicNew(f, content)) break;
            k = _afterLostPublish(f, k);
            continue;
          }
          final e = await _peek(f);
          if (e == null || e.key != key || e.id != m.id) continue;
          if (_standsFrom(e, rawKey, text, m.base, m.time)) {
            already = true;
            break;
          }
          if (m.time == null) {
            throw const FormatException(
              'its time can\'t be read, so it is kept beside the entry that has its name',
            );
          }
        }
        await hook?.call('envelope-published');
        await _removeLegacy(base, pageFirst: already);
      } on Object catch (e) {
        if (e is RecoveryTimeout) rethrow;
        _report(problems, damaged, base, _why(e));
      }
    }
  }

  static ({String folder, String id, DateTime? time, String? base}) _legacyMeta(Object? meta) {
    if (meta is! Map || meta['format'] != 1) throw const FormatException('unknown format');
    final folder = meta['folder'];
    final id = meta['pageId'];
    final b = meta['base'];
    if (folder is! String || id is! String || (b != null && b is! String)) {
      throw const FormatException('missing fields');
    }
    return (folder: folder, id: id, time: _tryTime(meta['time']), base: b as String?);
  }

  // Deals with `.tmp` files left by a write that didn't finish. One that is a
  // complete, consistent entry is promoted if no entry of its page and
  // location holds it, or if it is strictly newer; it is deleted if an entry
  // has the same page and base or a strictly later time; with the same time
  // and other content it is kept under the next free name. One whose time
  // can't be read, and the rest, are kept and reported.
  Future<void> _settleTmps(List<String> problems, List<UnreadablePage> damaged, [RecoveryTx? tx]) async {
    final tmps = <File>[];
    await for (final f in directory.list()) {
      if (f is File && f.path.endsWith('.tmp')) tmps.add(f);
    }
    tmps.sort((a, b) => a.path.compareTo(b.path));
    List<_Env>? envs;
    for (final f in tmps) {
      final file = f.path.split(RegExp(r'[\\/]')).last;
      // A re-key temp is settled by the re-key pass, never renamed over anything.
      if (file.contains(_rekeyMark)) continue;
      try {
        final text = await f.readAsString();
        final at = file.indexOf('.entry.');
        if (at >= 0) {
          final env = _parse(text);
          _checkIdentity(file.substring(0, at), _rawName(env.folder, env.id), env.id, readPage(env.text), env.base);
          // Another slot of this page and location may already hold exactly
          // this; the tmp must not be renamed over an older slot then.
          envs ??= await _envelopes();
          if (envs.any((e) => e.key == env.key && e.id == env.id && e.text == env.text && e.base == env.base)) {
            await f.delete();
            continue;
          }
          // Only the slots of its own raw name: an old-form tmp never meets a
          // new-key slot here (the re-key pass moves it).
          for (var k = 1; ; k++) {
            if (tx?.abandoned ?? false) throw const RecoveryTimeout();
            final target = _slot(env.folder, env.id, k, raw: true);
            if (!_occupied(target)) {
              // Never over a file that appeared meanwhile.
              if (await _moveToFree(f, target)) {
                envs = null; // the entries changed
                break;
              }
              k = _afterLostPublish(target, k);
              continue;
            }
            final e = await _peek(target);
            if (e == null || e.key != env.key || e.id != env.id) continue;
            if (_standsFrom(e, env.rawKey, env.text, env.base, env.timeOk ? env.time : null)) {
              await f.delete();
              break;
            }
            if (!env.timeOk) throw const FormatException('its time can\'t be read, so it is kept');
            if (e.rawKey == env.rawKey && e.timeOk && env.time.isAfter(e.time)) {
              await f.rename(target.path);
              envs = null;
              break;
            }
            // Same time, other content (or the entry's time is unreadable):
            // both are kept; it takes the next free name.
          }
        } else if (file.endsWith('.canvas.tmp') || file.endsWith('.json.tmp')) {
          // An unfinished write of the old layout: removed when an entry
          // already holds what it holds.
          envs ??= await _envelopes();
          var held = false;
          if (file.endsWith('.canvas.tmp')) {
            readPage(text);
            held = envs.any((e) => e.text == text);
          } else {
            final m = _legacyMeta(jsonDecode(text));
            held = envs.any((e) => _jsonHeld(e, m));
          }
          if (!held) throw const FormatException('an unfinished write was left here');
          await f.delete();
        } else {
          throw const FormatException('an unfinished write was left here');
        }
      } on Object catch (e) {
        if (e is RecoveryTimeout) rethrow;
        _report(problems, damaged, f.path, _why(e));
      }
    }
  }

  /// Reads every entry. Files that can't be read, or whose identities
  /// disagree, are reported, not removed, and are never offered.
  ///
  /// Refreshes the index from what it finds.
  Future<RecoveryListing> list() => _serial((tx) => _listNow(tx));

  /// Fills the index from the entry files as they are, without settling,
  /// converting or deleting anything: for a process that doesn't hold the
  /// recovery lock (it only reads).
  Future<void> indexReadOnly() => _serial((tx) async {
    final entries = <RecoveryEntry>[];
    if (await directory.exists()) {
      await for (final f in directory.list()) {
        if (f is! File || !f.path.endsWith('.entry')) continue;
        try {
          final env = _parse(await f.readAsString());
          final page = readPage(env.text);
          final stem = _stemOf(f.path);
          _checkIdentity(stem, _rawName(env.folder, env.id), env.id, page, env.base);
          entries.add(_entryOf(env, page, stem));
        } on Object {
          // Reported by a real listing; not offered here.
        }
      }
    }
    _setIndex(entries);
  });

  /// Reads [entry]'s file again: true only if it holds exactly this generation.
  Future<bool> verify(RecoveryEntry entry) => _serial((tx) async {
    final e = await _peek(entry.file);
    return e != null && _generationOf(e.folder, e.time, e.base, e.text) == entry.gen;
  });

  RecoveryEntry _entryOf(_Env env, NotedPage page, String stem) => RecoveryEntry._(
    env.folder,
    resolveStoredPath(env.folder, windows: windows),
    env.id,
    env.time,
    env.base,
    env.text,
    page,
    stem,
    directory,
  );

  Future<RecoveryListing> _listNow(RecoveryTx tx) async {
    await hook?.call('list');
    final entries = <RecoveryEntry>[];
    final problems = <String>[];
    final damaged = <UnreadablePage>[];
    if (!await directory.exists()) {
      _setIndex(const []);
      return const RecoveryListing([], []);
    }

    // Settling a tmp can publish the entry that an old half-file waits for, so
    // the old files are looked at again afterwards; only that pass reports.
    // A crashed delete-if-unchanged left an entry under a set-aside name: put
    // it back first, so nothing below sees the entry as missing.
    await sweepAsideFiles(directory, extension: '.entry');
    await _migrate([], [], tx);
    await _settleTmps(problems, damaged, tx);
    await _migrate(problems, damaged, tx);
    // Entries of an old app container are moved to the current key before the
    // index is built, so no replay ever sees both keys.
    await _rekeyPass(tx, problems, damaged);
    final names = <String>[];
    await for (final f in directory.list()) {
      if (f is File && f.path.endsWith('.entry')) {
        names.add(f.path.substring(0, f.path.length - '.entry'.length));
      }
    }
    for (final base in names..sort()) {
      final stem = _stemOf(base);
      try {
        final env = _parse(await File('$base.entry').readAsString());
        final page = readPage(env.text);
        _checkIdentity(stem, _rawName(env.folder, env.id), env.id, page, env.base);
        entries.add(_entryOf(env, page, stem));
        if (stem != _rawName(env.folder, env.id)) {
          _report(problems, damaged, base, 'kept under a separate name because another entry had its name');
        }
      } on Object catch (e) {
        _report(problems, damaged, base, _why(e));
      }
    }
    if (tx.abandoned) throw const RecoveryTimeout();
    await _listOnce(entries);
    for (final e in entries) {
      if (_landedOld.contains(e.gen)) _landed.add(e.gen);
    }
    _setIndex(entries);
    return RecoveryListing(entries, problems, damaged);
  }

  // The same generation (page, location, base and text) in two forms is listed
  // once: the copy in the current form stays, the other is deleted if it is
  // unchanged. Copies of one form are left as they are.
  Future<void> _listOnce(List<RecoveryEntry> entries) async {
    final groups = <String, List<RecoveryEntry>>{};
    for (final e in entries) {
      final id = contentHash(utf8.encode(jsonEncode([e.pageId, _locKey(e.storedFolder), e.baseText, e.pageText])));
      (groups[id] ??= []).add(e);
    }
    for (final g in groups.values) {
      if (g.length < 2) continue;
      final keep = g.where((e) => !_isOldForm(e.storedFolder)).firstOrNull;
      if (keep == null) continue;
      for (final other in g) {
        if (identical(other, keep) || _key(other.storedFolder) == _key(keep.storedFolder)) continue;
        try {
          final r = await (deleteForTest ?? deleteFileIfUnchanged)(other.file.path, await other.file.readAsBytes());
          if (!r.deleted && r.outcome != DeleteOutcome.absent) continue; // changed: keep listing it
        } on FileSystemException {
          // Can't be deleted now: listed once all the same, and landed with its twin.
          _twinOf[keep.gen] = other.gen;
        }
        entries.remove(other);
      }
    }
  }

  static const _rekeyMark = '.rekey.';

  /// Test seam: replaces the delete-if-unchanged of an old-form file by the
  /// re-key pass and by the listing of one generation once (for instance to
  /// throw a [FileSystemException], as a file held open does).
  @visibleForTesting
  Future<DeleteResult> Function(String path, List<int> expected)? deleteForTest;

  // Moves the entries of an old app container to the current key (mobile only):
  // see the design note. Each step is safe to stop at; an old file is deleted
  // only after its twin was published exclusively and read back.
  Future<void> _rekeyPass(RecoveryTx tx, List<String> problems, List<UnreadablePage> damaged) async {
    if (!isMobilePlatform) return;
    // Re-key temps of an earlier pass: published to a free slot, or removed if
    // the same generation is held. Never renamed over anything.
    final temps = <File>[];
    final olds = <File>[];
    await for (final f in directory.list()) {
      if (f is! File) continue;
      if (f.path.endsWith('.tmp') && f.path.contains(_rekeyMark)) temps.add(f);
      if (f.path.endsWith('.entry')) olds.add(f);
    }
    temps.sort((a, b) => a.path.compareTo(b.path));
    olds.sort((a, b) => a.path.compareTo(b.path));
    for (final t in temps) {
      if (tx.abandoned || tx.outOfTime) return;
      try {
        final env = _parse(await t.readAsString());
        // The temp is named after the old file, so its name is not checked.
        final n = _rawName(env.folder, env.id);
        _checkIdentity(n, n, env.id, readPage(env.text), env.base);
        await _publishOrHeld(t, env, tx, deleteOnStop: false);
      } on Object catch (e) {
        // Locked, or not a complete entry: left where it is (the old file is
        // still the copy) and reported.
        _report(problems, damaged, t.path, _why(e));
      }
    }
    for (final old in olds) {
      if (tx.abandoned || tx.outOfTime) return;
      final List<int> bytes;
      final _Env env;
      try {
        bytes = await old.readAsBytes();
        env = _parse(utf8.decode(bytes));
        _checkIdentity(_stemOf(old.path), _rawName(env.folder, env.id), env.id, readPage(env.text), env.base);
      } on Object {
        continue; // reported by the listing
      }
      if (!_isOldForm(env.folder)) continue;
      final oldGen = _generationOf(env.folder, env.time, env.base, env.text);
      // A generation that landed (the replay could not delete its entry) is
      // left for deletion, never re-keyed into a new generation that would
      // replay again.
      if (_landedOld.contains(oldGen) || _landed.contains(oldGen)) continue;
      try {
        await _rekeyOne(tx, old, bytes, env, oldGen);
      } on FileSystemException {
        // Locked or full: the old file stays the copy; the next listing retries.
      } on FormatException catch (e) {
        _report(problems, damaged, old.path, e.message);
      }
    }
  }

  Future<void> _rekeyOne(RecoveryTx tx, File old, List<int> bytes, _Env env, String oldGen) async {
    final newFolder = _canon(env.folder);
    final meta = Map<String, Object?>.of(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    meta['folder'] = newFolder;
    final tmp = File('${directory.path}${Platform.pathSeparator}${_stemOf(old.path)}$_rekeyMark'
        '${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(meta), flush: true);
    } on Object {
      await _tryDelete(tmp);
      rethrow;
    }
    // A failure injected here stands for a crash: the temp stays.
    await hook?.call('tmp-written');
    final twin = _Env(newFolder, env.id, env.time, env.timeOk, env.base, env.text, _locKey(newFolder), _key(newFolder));
    final slot = await _publishOrHeld(tmp, twin, tx);
    if (slot == null) return; // abandoned or out of time: the old file stays
    // Read back: only a twin that holds the page, base and text lets the old
    // file go; one we published must be the same generation.
    final back = await _peek(slot.file);
    if (back == null) return;
    final newGen = _generationOf(back.folder, back.time, back.base, back.text);
    if (slot.published && newGen != _generationOf(newFolder, env.time, env.base, env.text)) return;
    if (tx.abandoned) return;
    await hook?.call('rekey-before-delete');
    if (tx.abandoned || tx.outOfTime) return;
    try {
      final r = await (deleteForTest ?? deleteFileIfUnchanged)(old.path, bytes);
      if (r.outcome == DeleteOutcome.changed || r.outcome == DeleteOutcome.changedKept) return;
    } on FileSystemException {
      // The twin exists: this generation is one, and lands once.
      _twinOf[newGen] = oldGen;
    }
  }

  // Publishes the re-key temp [tmp] (the entry [env], in the current form) at
  // the first free slot, or removes it if a slot already holds the same page,
  // location, base and text. Returns the slot that holds the generation, or
  // null (the temp is then removed or, if unreadable, left).
  Future<({File file, bool published})?> _publishOrHeld(
    File tmp,
    _Env env,
    RecoveryTx tx, {
    bool deleteOnStop = true,
  }) async {
    for (var k = 1; ; k++) {
      if (tx.abandoned || tx.outOfTime) {
        if (deleteOnStop) await _tryDelete(tmp);
        return null;
      }
      final slot = _slot(env.folder, env.id, k);
      if (!_occupied(slot)) {
        final bool done;
        try {
          done = await publishExclusive(tmp, slot.path);
        } on FileSystemException {
          // No hard links here (exFAT/FAT, some network or FUSE storage): the
          // entry can't be moved without risking another one. The old file stays.
          if (deleteOnStop) await _tryDelete(tmp);
          throw const FormatException("couldn't be moved to the current folder form; it is kept as it is");
        }
        if (done) {
          await hook?.call('rekey-published');
          return (file: slot, published: true);
        }
        continue; // taken meanwhile: the next slot, with the same temp
      }
      final e = await _peek(slot);
      if (e != null && e.key == env.key && e.id == env.id && e.text == env.text && e.base == env.base) {
        await _tryDelete(tmp);
        return (file: slot, published: false);
      }
    }
  }

  void _setIndex(List<RecoveryEntry> entries) {
    _index
      ..clear()
      ..addAll(entries);
    _indexed = true;
    final gens = {for (final e in entries) e.gen};
    _landed.removeWhere((g) => !gens.contains(g));
  }

  /// Removes [entry]'s file.
  Future<void> delete(RecoveryEntry entry) => _serial((tx) => _deleteNow(entry, tx));

  Future<void> _deleteNow(RecoveryEntry entry, [RecoveryTx? tx]) async {
    // Only the generation that was listed: a newer one written since stays.
    final f = entry.file;
    final e = await _peek(f);
    if (e == null) {
      // Gone or unreadable: nothing of ours to remove; forget it if it's gone.
      if (!await f.exists()) _indexRemove(entry);
      return;
    }
    if (e.text == entry.pageText && e.base == entry.baseText && e.time == entry.time) {
      await hook?.call('delete');
      if (tx?.abandoned ?? false) throw const RecoveryTimeout();
      await f.delete();
      _retireTwin(entry.gen);
      _indexRemove(entry);
    }
  }
}

/// What a recovery transaction can do ([RecoveryStore.transaction]).
class RecoveryTx {
  RecoveryTx._(this.store, this._limit);

  final RecoveryStore store;
  final Duration _limit;
  final Stopwatch _clock = Stopwatch()..start();

  /// Whether most of the transaction's time is used: long work that can be
  /// finished by a later listing stops here rather than exceed the limit.
  bool get outOfTime => _clock.elapsed * 4 > _limit * 3;

  /// Set when the transaction timed out: it must not change the folder any more.
  bool abandoned = false;

  Future<RecoveryListing> list() => store._listNow(this);

  Future<RecoveryEntry> write({
    required String folder,
    required NotedPage page,
    required String? baseText,
    required DateTime time,
    Set<String>? replaceable,
    bool freshSlot = false,
  }) => store._writeNow(
    folder: folder,
    page: page,
    baseText: baseText,
    time: time,
    replaceable: replaceable,
    freshSlot: freshSlot,
    tx: this,
  );

  Future<void> delete(RecoveryEntry entry) => store._deleteNow(entry, this);

  /// Reads [entry]'s file again: true only if it holds exactly this generation.
  Future<bool> verify(RecoveryEntry entry) async {
    final e = await store._peek(entry.file);
    return e != null && RecoveryStore._generationOf(e.folder, e.time, e.base, e.text) == entry.gen;
  }
}

/// Checks a recovered page [result] (read back from disk) against the three
/// pages it came from. Returns null if it is sound, else why not:
///
/// - every box of [theirs] is still there, unless [mine] deleted it and
///   [theirs] had not changed it since [base];
/// - every box of [mine] is still there, unless [theirs] removed it while
///   [mine] hadn't changed it since [base];
/// - a box that [mine] changed keeps [mine]'s content verbatim, or is
///   conflicted (the other version recorded), or was merged by its codec;
///   what must not happen is that [theirs]'s version silently replaces it.
String? verifyRecoveredPage({
  required NotedPage base,
  required NotedPage mine,
  required NotedPage? theirs,
  required NotedPage result,
}) {
  if (result.id != mine.id) return 'the page id changed';
  final out = {for (final n in result.nodes) n.id: n};
  final baseById = {for (final n in base.nodes) n.id: n};
  final theirsById = {for (final n in theirs?.nodes ?? const <CanvasNode>[]) n.id: n};
  final mineIds = {for (final n in mine.nodes) n.id};
  for (final id in theirsById.keys) {
    if (out.containsKey(id)) continue;
    // A box the edits deleted, which the saved file still had as it was in
    // the base, is meant to be gone.
    final b = baseById[id];
    final deletedHere = b != null && !mineIds.contains(id) && theirsById[id]!.toRaw() == b.toRaw();
    if (!deletedHere) return 'box $id of the saved file is missing';
  }
  for (final m in mine.nodes) {
    final b = baseById[m.id];
    final x = out[m.id];
    final changed = b == null || b.toRaw() != m.toRaw();
    if (x == null) {
      if (!changed && theirs != null && !theirsById.containsKey(m.id)) continue; // removed there
      return 'box ${m.id} is missing';
    }
    if (!changed || x.toRaw() == m.toRaw()) continue;
    if (x is BoxRecord && x.isConflicted) continue;
    final t = theirsById[m.id];
    if (t != null && x.toRaw() == t.toRaw()) return 'the edit of box ${m.id} was lost';
  }
  return null;
}
