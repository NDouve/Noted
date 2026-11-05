// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
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
    this.folder,
    this.pageId,
    this.time,
    this.baseText,
    this.pageText,
    this.page,
    this._stem,
    this._dir,
  );

  /// The folder the page belongs in.
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
  late final String gen = RecoveryStore.generationOf(folder, time, baseText, pageText);
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
  _Env(this.folder, this.id, this.time, this.timeOk, this.base, this.text, this.key);
  final String folder;
  final String id;
  final DateTime time;

  /// False if the time couldn't be read ([time] is then the epoch).
  final bool timeOk;
  final String? base;
  final String text;
  final String key;
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
      final tx = RecoveryTx._(this);
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

  /// The generation hash of an entry with these parts.
  static String generationOf(String folder, DateTime time, String? base, String pageText) =>
      contentHash(utf8.encode(jsonEncode([folder, time.toUtc().toIso8601String(), base, pageText])));

  // The entries this process knows of: built by every listing and kept
  // current by every write and delete. This process is the only writer, so
  // open, preview, the quit notice and the delete question read it without
  // touching the disk.
  final List<RecoveryEntry> _index = [];
  bool _indexed = false;

  // Generations whose page landed but whose entry could not be deleted yet.
  final Set<String> _landed = {};

  /// Whether a listing has filled the index.
  bool get indexed => _indexed;

  /// Every entry the index holds.
  List<RecoveryEntry> get indexEntries => List.unmodifiable(_index);

  /// The entries of [pageId] in [folder], from the index.
  List<RecoveryEntry> entriesFor(String folder, String pageId) {
    final k = _key(folder);
    return [
      for (final e in _index)
        if (e.pageId == pageId && _key(e.folder) == k) e,
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
  void markLanded(String gen) => _landed.add(gen);

  /// The landed generations that are still in the index.
  List<RecoveryEntry> get landedEntries => [
    for (final e in _index)
      if (_landed.contains(e.gen)) e,
  ];

  void _indexPut(RecoveryEntry e) {
    _index.removeWhere((x) => x.file.path == e.file.path);
    _index.add(e);
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

  String _key(String folder) => recoveryLocationKey(folder, windows: windows);

  // The name of the entry of [pageId] in [folder].
  String _name(String folder, String pageId) =>
      '${_safe(pageId)}-${_fnv('${_key(folder)}|$pageId').toRadixString(16)}';

  // The name entries had before the layout changed: it folded case on every
  // platform.
  static String _legacyName(String folder, String pageId) =>
      '${_safe(pageId)}-${_fnv('${folder.replaceAll(r'\', '/').toLowerCase()}|$pageId').toRadixString(16)}';

  String _path(String stem, String ext) => '${directory.path}${Platform.pathSeparator}$stem.$ext';

  // The k-th file an entry of [folder] and [id] may have: the name, then
  // `<name>_dup2`, `_dup3`, ...
  File _slot(String folder, String id, int k) {
    final n = _name(folder, id);
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
      final nowGen = now == null ? (await f.exists() ? '?' : null) : generationOf(now.folder, now.time, now.base, now.text);
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

  // Whether an entry already holds what an old metadata file holds.
  bool _jsonHeld(_Env e, ({String folder, String id, DateTime? time, String? base}) m) =>
      e.key == _key(m.folder) &&
      e.id == m.id &&
      (e.base == m.base || (m.time != null && e.timeOk && e.time.isAfter(m.time!)));

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
    return _Env(folder, id, t ?? _time(null), t != null, b as String?, page, _key(folder));
  }

  // The envelope of an entry file, only if [list] would accept it: the
  // embedded page, the base and the file name must agree with the metadata. A
  // file that fails is null, so it is never replaced, never counts as holding
  // or superseding anything, and is left to [list] to report.
  Future<_Env?> _peek(File f) async {
    try {
      final env = _parse(await f.readAsString());
      _checkIdentity(_stemOf(f.path), _name(env.folder, env.id), env.id, readPage(env.text), env.base);
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
      await _migrate([], []);
    } on Object {
      // Never let it stop the edit from being kept.
    }
    // The entry of this page and location, or a free name; an entry of
    // another location or page (or one that can't be read) is never replaced.
    final key = _key(folder);
    File? target;
    String? selectedGen;
    for (var k = 1; target == null; k++) {
      final f = _slot(folder, page.id, k);
      if (!await f.exists()) {
        target = f;
        break;
      }
      if (freshSlot) continue;
      final e = await _peek(f);
      if (e != null && e.key == key && e.id == page.id) {
        selectedGen = generationOf(e.folder, e.time, e.base, e.text);
        if (replaceable != null && !replaceable.contains(selectedGen)) {
          throw const RecoveryRefused('the recovery folder holds an entry for this page that Noted did not write');
        }
        target = f;
      }
    }
    final text = writePage(page);
    await _atomic(
      target,
      _encode(folder, page.id, time.toUtc().toIso8601String(), baseText, text),
      checkSlot: true,
      selectedGen: selectedGen,
      tx: tx,
    );
    final written = RecoveryEntry._(
      folder,
      page.id,
      time.toUtc(),
      baseText,
      text,
      page,
      _stemOf(target.path),
      directory,
    );
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
  Future<void> _migrate(List<String> problems, List<UnreadablePage> damaged) async {
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
        final key = _key(m.folder);
        File? target;
        var already = false;
        for (var k = 1; ; k++) {
          final f = _slot(m.folder, m.id, k);
          if (!await f.exists()) {
            target = f;
            break;
          }
          final e = await _peek(f);
          if (e == null || e.key != key || e.id != m.id) continue;
          if (_stands(e, text, m.base, m.time)) {
            already = true;
            break;
          }
          if (m.time == null) {
            throw const FormatException(
              'its time can\'t be read, so it is kept beside the entry that has its name',
            );
          }
        }
        if (!already) await _atomic(target!, content);
        await hook?.call('envelope-published');
        await _removeLegacy(base, pageFirst: already);
      } on Object catch (e) {
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
  Future<void> _settleTmps(List<String> problems, List<UnreadablePage> damaged) async {
    final tmps = <File>[];
    await for (final f in directory.list()) {
      if (f is File && f.path.endsWith('.tmp')) tmps.add(f);
    }
    tmps.sort((a, b) => a.path.compareTo(b.path));
    List<_Env>? envs;
    for (final f in tmps) {
      final file = f.path.split(RegExp(r'[\\/]')).last;
      try {
        final text = await f.readAsString();
        final at = file.indexOf('.entry.');
        if (at >= 0) {
          final env = _parse(text);
          _checkIdentity(file.substring(0, at), _name(env.folder, env.id), env.id, readPage(env.text), env.base);
          // Another slot of this page and location may already hold exactly
          // this; the tmp must not be renamed over an older slot then.
          envs ??= await _envelopes();
          if (envs.any((e) => e.key == env.key && e.id == env.id && e.text == env.text && e.base == env.base)) {
            await f.delete();
            continue;
          }
          for (var k = 1; ; k++) {
            final target = _slot(env.folder, env.id, k);
            if (!await target.exists()) {
              await f.rename(target.path);
              envs = null; // the entries changed
              break;
            }
            final e = await _peek(target);
            if (e == null || e.key != env.key || e.id != env.id) continue;
            if (_stands(e, env.text, env.base, env.timeOk ? env.time : null)) {
              await f.delete();
              break;
            }
            if (!env.timeOk) throw const FormatException('its time can\'t be read, so it is kept');
            if (e.timeOk && env.time.isAfter(e.time)) {
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
        _report(problems, damaged, f.path, _why(e));
      }
    }
  }

  /// Reads every entry. Files that can't be read, or whose identities
  /// disagree, are reported, not removed, and are never offered.
  ///
  /// Refreshes the index from what it finds.
  Future<RecoveryListing> list() => _serial((tx) => _listNow());

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
          _checkIdentity(stem, _name(env.folder, env.id), env.id, page, env.base);
          entries.add(RecoveryEntry._(env.folder, env.id, env.time, env.base, env.text, page, stem, directory));
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
    return e != null && generationOf(e.folder, e.time, e.base, e.text) == entry.gen;
  });

  Future<RecoveryListing> _listNow() async {
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
    await _migrate([], []);
    await _settleTmps(problems, damaged);
    await _migrate(problems, damaged);
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
        _checkIdentity(stem, _name(env.folder, env.id), env.id, page, env.base);
        entries.add(RecoveryEntry._(env.folder, env.id, env.time, env.base, env.text, page, stem, directory));
        if (stem != _name(env.folder, env.id)) {
          _report(problems, damaged, base, 'kept under a separate name because another entry had its name');
        }
      } on Object catch (e) {
        _report(problems, damaged, base, _why(e));
      }
    }
    _setIndex(entries);
    return RecoveryListing(entries, problems, damaged);
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
      _indexRemove(entry);
    }
  }
}

/// What a recovery transaction can do ([RecoveryStore.transaction]).
class RecoveryTx {
  RecoveryTx._(this.store);

  final RecoveryStore store;

  /// Set when the transaction timed out: it must not change the folder any more.
  bool abandoned = false;

  Future<RecoveryListing> list() => store._listNow();

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
    return e != null && RecoveryStore.generationOf(e.folder, e.time, e.base, e.text) == entry.gen;
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
