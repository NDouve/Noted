// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// An edit that couldn't be saved. One generation of one writer's edits of a
/// page; an entry is never replaced, so a page may have several.
///
/// On disk an entry is one file in the recovery folder, named
/// `<page id>-<hash of location and id>.g<gen>.entry` (see
/// [recoveryLocationKey]; `gen` is 32 random hex characters, so two writers
/// never choose the same name). It holds, for example (all strings, `base` may
/// be null):
///
///     {"format":3,"folder":"D:\Notes","pageId":"p1","gen":"...",
///      "writer":{"kind":"edit","session":"..."},
///      "created":"2026-10-25T10:00:00.000Z","base":"...page file text...",
///      "page":"...page file text...","supersedes":["..."]}
///
/// - `page`: exactly the text a normal save of the page writes (`writePage`).
///   Nothing else is derived from the page's content, so an entry never holds
///   anything a page file wouldn't (invariant 3).
/// - `base`: the page file as last read or written by the app, the base of the
///   three-way merge. It is itself a former page file.
/// - `supersedes`: the generations this one was built on (transitively). They
///   are left out of folding and retired with it.
///
/// The file is written to a unique temporary file and published with
/// [publishExclusive], never over anything (a crash leaves a complete `.tmp`,
/// which [RecoveryStore.list] publishes). It is deleted only by
/// [RecoveryStore.retire], once its edits have landed. Before the page file is
/// written, the app renames the entry to `.landing` ([RecoveryStore.markLanding]):
/// the durable record that its edits may have landed. Files added while the
/// folder was away are kept apart, in `<page id>.assets` folders (0098).
///
/// Entries of the older formats are read too: format 2 (one slot per page,
/// `<name>[_dup<n>].entry`) as `legacy` entries, and the two-file format 1
/// pairs `<old name>.canvas` and `<old name>.json`, which [RecoveryStore.list]
/// converts.
class RecoveryEntry {
  RecoveryEntry._(
    this.folder,
    this.pageId,
    this.gen,
    this.kind,
    this.session,
    this.device,
    this.time,
    this.baseText,
    this.pageText,
    this.page,
    this.supersedes,
    this.landing,
    this._stem,
    this._dir,
    this._primary,
    this._bytes,
  );

  /// The folder the page belongs in.
  final String folder;
  final String pageId;

  /// This generation's id: unique to the entry, the same for every name it has.
  final String gen;

  /// Who wrote it: `edit` (an editor session), `ai` (an AI write to a closed
  /// page), `delete` (a page that could not be put back) or `legacy` (a format
  /// 2 file or a converted format 1 pair).
  final String kind;

  /// The editor session that wrote it, if any.
  final String? session;

  /// The computer that wrote it, if it said so (data only).
  final String? device;

  /// When it was created (the order entries are folded in, then [gen]).
  final DateTime time;

  /// The page file as last read or written before the edit; null if unknown.
  final String? baseText;

  /// What a normal save of the page would have written.
  final String pageText;
  final NotedPage page;

  /// The generations this one was built on.
  final List<String> supersedes;

  /// Whether the entry's edits may have landed already: one of its names is
  /// `.landing` (or `.landed`).
  final bool landing;
  final String _stem;
  final Directory _dir;
  final String _primary;
  final List<int> _bytes;

  /// The entry's file (the name the listing read it under).
  File get file => File('${_dir.path}${Platform.pathSeparator}$_primary');

  /// The entry's file name without its extension.
  String get stem => _stem;

  /// The path of the entry without an extension.
  String get path => '${_dir.path}${Platform.pathSeparator}$_stem';

  @override
  bool operator ==(Object other) => other is RecoveryEntry && other.gen == gen && other._stem == _stem;

  @override
  int get hashCode => Object.hash(gen, _stem);
}

/// What a scan of the recovery folder found: [entries] that can be used and
/// [problems] (descriptions of files that can't be read; they are kept).
class RecoveryListing {
  const RecoveryListing(this.entries, this.problems, [this.damaged = const []]);

  /// Every readable entry, one for each generation, superseded ones too.
  final List<RecoveryEntry> entries;
  final List<String> problems;

  /// The same damaged entries as [problems], one for each, with the entry's
  /// path (without extension) and a short reason, for the sidebar.
  final List<UnreadablePage> damaged;

  /// The generations named in the `supersedes` of an entry that is listed.
  Set<String> get supersededGens => {
    for (final e in entries) ...e.supersedes,
  };

  /// The entries no listed entry supersedes.
  List<RecoveryEntry> get live {
    final gone = supersededGens;
    return [
      for (final e in entries)
        if (!gone.contains(e.gen)) e,
    ];
  }
}

/// The result of [RecoveryStore.markLanding].
class LandingMark {
  const LandingMark._(this.ok, this.renamed);

  /// Every entry has a `.landing` name now (the publish may run).
  final bool ok;

  /// The entries this call renamed (and a failed publish renames back).
  final List<RecoveryEntry> renamed;
}

// A parsed entry file.
class _Env {
  _Env(
    this.format,
    this.folder,
    this.id,
    this.time,
    this.timeOk,
    this.base,
    this.text,
    this.key,
    this.gen,
    this.kind,
    this.session,
    this.device,
    this.supersedes,
  );
  final int format;
  final String folder;
  final String id;
  final DateTime time;

  /// False if the time couldn't be read ([time] is then the epoch).
  final bool timeOk;
  final String? base;
  final String text;
  final String key;
  final String gen;
  final String kind;
  final String? session;
  final String? device;
  final List<String> supersedes;
}

// A file of the folder that is one name of an entry.
class _Found {
  _Found(this.file, this.stem, this.ext, this.aside, this.bytes);
  final File file;
  final String stem;

  /// `entry`, `landing` or `landed`.
  final String ext;

  /// A `.cas-old` / `.cas-verified` leftover of that name.
  final bool aside;
  final List<int> bytes;

  String get name => file.path.split(RegExp(r'[\\/]')).last;
}

final _random = Random.secure();

/// The recovery folder: entries are only ever added, and deleted by
/// [retire] once their edits have landed.
///
/// Every write, migration, promotion and deletion runs one after another, per
/// folder and across instances, so [list] never sees a write half done. A
/// `hook` runs inside that sequence, so it must not call back into the store.
class RecoveryStore {
  /// [windows] says whether locations compare without regard to case (see
  /// [recoveryLocationKey]); [hook] is called at named points of a write, a
  /// rename or a retire, so tests can inject a failure there (`tmp-written`: a
  /// new generation is complete but not yet published; `entry-published`: it
  /// is published and not yet read back; `landing-renamed`: an entry was
  /// renamed to `.landing`; `retire-name-deleted`: one name of a generation
  /// was deleted; `envelope-published`: an old entry is converted but its old
  /// files are still there; `legacy-first-deleted`: the first of the old files
  /// is removed).
  RecoveryStore(this.directory, {this.windows, this.hook});

  final Directory directory;
  final bool? windows;
  final Future<void> Function(String point)? hook;

  static int _tmpCounter = 0;
  static final Map<String, Future<void>> _chains = {};

  Future<T> _serial<T>(Future<T> Function() f) {
    final k = recoveryLocationKey(directory.path, windows: windows);
    final prev = _chains[k] ?? Future<void>.value();
    final c = Completer<T>();
    _chains[k] = prev.then((_) async {
      try {
        c.complete(await f());
      } on Object catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
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

  // The name entries of [pageId] in [folder] start with.
  String _name(String folder, String pageId) =>
      '${_safe(pageId)}-${_fnv('${_key(folder)}|$pageId').toRadixString(16)}';

  // The name entries had before the layout changed: it folded case on every
  // platform.
  static String _legacyName(String folder, String pageId) =>
      '${_safe(pageId)}-${_fnv('${folder.replaceAll(r'\', '/').toLowerCase()}|$pageId').toRadixString(16)}';

  String _path(String stem, String ext) => '${directory.path}${Platform.pathSeparator}$stem.$ext';

  // The k-th file a format 2 entry of [folder] and [id] may have: the name,
  // then `<name>_dup2`, `_dup3`, ...
  File _slot(String folder, String id, int k) {
    final n = _name(folder, id);
    return File(_path(k == 1 ? n : '${n}_dup$k', 'entry'));
  }

  static String _newGen() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  static String _tmpSuffix() => '${DateTime.now().microsecondsSinceEpoch}-${_tmpCounter++}.tmp';

  // Deletes a file this store wrote or knows the exact content of, only if it
  // still holds that. Quiet: what stays is found by the next listing.
  static Future<bool> _dropFile(File f, List<int> bytes) async {
    try {
      final r = await deleteFileIfMatches(f.path, bytes: bytes);
      return r.deleted || r.outcome == DeleteOutcome.absent;
    } on Object catch (e) {
      debugPrint('Deleting ${f.path} failed: $e');
      return false;
    }
  }

  static Future<void> _dropUnknown(File f) async {
    try {
      if (!await f.exists()) return;
      await deleteFileIfMatches(f.path, identity: await ContentIdentity.ofFile(f.path));
    } on Object {
      // Nothing more to do.
    }
  }

  static String _encode3({
    required String folder,
    required String pageId,
    required String gen,
    required String kind,
    required String? session,
    required String? device,
    required String created,
    required String? base,
    required String page,
    required List<String> supersedes,
  }) => jsonEncode({
    'format': 3,
    'folder': folder,
    'pageId': pageId,
    'gen': gen,
    'writer': {'kind': kind, 'session': session, 'device': device},
    'created': created,
    'base': base,
    'page': page,
    'supersedes': supersedes,
  });

  static DateTime? _tryTime(Object? raw) => DateTime.tryParse('$raw')?.toUtc();

  static DateTime _time(Object? raw) => _tryTime(raw) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  // Parses an entry file's text (format 2 or 3). Throws a FormatException if
  // it isn't one.
  _Env _parse(String text, {List<int>? bytes}) {
    final meta = jsonDecode(text);
    if (meta is! Map) throw const FormatException('unknown format');
    final format = meta['format'];
    if (format != 2 && format != 3) throw const FormatException('unknown format');
    final folder = meta['folder'];
    final id = meta['pageId'];
    final b = meta['base'];
    final page = meta['page'];
    if (folder is! String || id is! String || page is! String || (b != null && b is! String)) {
      throw const FormatException('missing fields');
    }
    if (format == 2) {
      final t = _tryTime(meta['time']);
      return _Env(
        2,
        folder,
        id,
        t ?? _time(null),
        t != null,
        b as String?,
        page,
        _key(folder),
        'v2-${contentHash(bytes ?? utf8.encode(text)).substring(0, 32)}',
        'legacy',
        null,
        null,
        const [],
      );
    }
    final gen = meta['gen'];
    final writer = meta['writer'];
    final sup = meta['supersedes'];
    if (gen is! String || !RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,63}$').hasMatch(gen)) {
      throw const FormatException('missing fields');
    }
    if (writer is! Map || writer['kind'] is! String) throw const FormatException('missing fields');
    final session = writer['session'];
    if (session != null && session is! String) throw const FormatException('missing fields');
    if (sup is! List || sup.any((e) => e is! String)) throw const FormatException('missing fields');
    final t = _tryTime(meta['created']);
    return _Env(
      3,
      folder,
      id,
      t ?? _time(null),
      t != null,
      b as String?,
      page,
      _key(folder),
      gen,
      writer['kind'] as String,
      session as String?,
      writer['device'] is String ? writer['device'] as String : null,
      [for (final e in sup) e as String],
    );
  }

  // Checks that the identities of an entry agree: the metadata's page id, the
  // page's, the base's and the file name's. Throws a FormatException if not.
  void _checkIdentity(String stem, _Env env, NotedPage page) {
    if (page.id != env.id) {
      throw FormatException('the page is "${page.id}" but the entry says "${env.id}"');
    }
    if (env.base != null) {
      final b = readPage(env.base!);
      if (b.id != env.id) throw FormatException('the base is page "${b.id}" but the entry says "${env.id}"');
    }
    final name = _name(env.folder, env.id);
    final ok = env.format == 3
        ? stem == '$name.g${env.gen}'
        : stem == name || RegExp('^${RegExp.escape(name)}_dup\\d+\$').hasMatch(stem);
    if (!ok) throw const FormatException('the file name does not belong to the entry');
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

  static String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

  static String _stemOf(String path) => _fileName(path).replaceFirst(RegExp(r'\.[^.]*$'), '');

  static void _report(List<String> problems, List<UnreadablePage> damaged, String path, String why) {
    problems.add('$path: $why');
    damaged.add(UnreadablePage(path, "Recovery entry can't be read: $why"));
  }

  static final _nameRe = RegExp(r'^(.+)\.(entry|landing|landed)$');
  static final _asideRe = RegExp(r'^(.+)\.(entry|landing|landed)\.[^.]+\.cas-(?:old|verified)$');

  // Every file of the folder that is a name of an entry, with its bytes. A
  // file that can't be read is reported.
  Future<List<_Found>> _names(List<String> problems, List<UnreadablePage> damaged) async {
    final out = <_Found>[];
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final name = _fileName(f.path);
      final plain = _nameRe.firstMatch(name);
      final aside = plain == null ? _asideRe.firstMatch(name) : null;
      final m = plain ?? aside;
      if (m == null) continue;
      try {
        out.add(_Found(f, m.group(1)!, m.group(2)!, aside != null, await f.readAsBytes()));
      } on Object catch (e) {
        _report(problems, damaged, aside != null ? f.path : f.path.substring(0, f.path.length - m.group(2)!.length - 1), _why(e));
      }
    }
    out.sort((a, b) => a.file.path.compareTo(b.file.path));
    return out;
  }

  // The readable entries in [found], one for each generation. A name that
  // can't be read as an entry is reported. Names of one generation with other
  // content are reported and left out.
  List<RecoveryEntry> _entriesOf(List<_Found> found, List<String> problems, List<UnreadablePage> damaged) {
    final byGen = <String, List<_Found>>{};
    final envs = <_Found, ({_Env env, NotedPage page})>{};
    for (final f in found) {
      final shown = f.aside ? f.file.path : f.file.path.substring(0, f.file.path.length - f.ext.length - 1);
      try {
        final env = _parse(utf8.decode(f.bytes), bytes: f.bytes);
        final page = readPage(env.text);
        _checkIdentity(f.stem, env, page);
        envs[f] = (env: env, page: page);
        (byGen['${f.stem}\u0000${env.gen}'] ??= []).add(f);
        if (env.format == 2 && f.stem != _name(env.folder, env.id) && !f.aside) {
          _report(problems, damaged, shown, 'kept under a separate name because another entry had its name');
        }
      } on Object catch (e) {
        _report(problems, damaged, shown, _why(e));
      }
    }
    final out = <RecoveryEntry>[];
    for (final names in byGen.values) {
      // The plain `.entry` name is the primary one; then `.landing`, `.landed`,
      // then leftovers.
      int rank(_Found f) => f.aside ? 3 : (f.ext == 'entry' ? 0 : (f.ext == 'landing' ? 1 : 2));
      names.sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : a.file.path.compareTo(b.file.path));
      final first = names.first;
      final same = <_Found>[first];
      for (final other in names.skip(1)) {
        if (_sameBytes(first.bytes, other.bytes)) {
          same.add(other);
        } else {
          _report(problems, damaged, other.file.path, 'another file holds the same generation with other content');
        }
      }
      final parsed = envs[first]!;
      final env = parsed.env;
      out.add(
        RecoveryEntry._(
          env.folder,
          env.id,
          env.gen,
          env.kind,
          env.session,
          env.device,
          env.time,
          env.base,
          env.text,
          parsed.page,
          env.supersedes,
          same.any((f) => f.ext != 'entry'),
          first.stem,
          directory,
          first.name,
          first.bytes,
        ),
      );
    }
    out.sort((a, b) => a.file.path.compareTo(b.file.path));
    return out;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Writes a new generation for [page], belonging in [folder], and returns it.
  /// Nothing is replaced and no listing is needed. [supersedes] are the
  /// generations it was built on (it names them and their ancestors).
  Future<RecoveryEntry> write({
    required String folder,
    required NotedPage page,
    required String? baseText,
    required DateTime time,
    String kind = 'edit',
    String? session,
    String? device,
    List<String> supersedes = const [],
  }) => _serial(() async {
    await directory.create(recursive: true);
    final gen = _newGen();
    final stem = '${_name(folder, page.id)}.g$gen';
    final target = File(_path(stem, 'entry'));
    final text = _encode3(
      folder: folder,
      pageId: page.id,
      gen: gen,
      kind: kind,
      session: session,
      device: device,
      created: time.toUtc().toIso8601String(),
      base: baseText,
      page: writePage(page),
      supersedes: supersedes,
    );
    final bytes = utf8.encode(text);
    final tmp = File('${target.path}.${_tmpSuffix()}');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
    } on Object {
      await _dropUnknown(tmp);
      rethrow;
    }
    // A failure injected here stands for a crash: the file stays.
    await hook?.call('tmp-written');
    final bool published;
    try {
      published = await publishExclusive(tmp, target.path);
    } on Object {
      // Not published: the caller keeps the edits, so the complete tmp is
      // not left to be published later by a listing.
      await _dropFile(tmp, bytes);
      rethrow;
    }
    if (!published) {
      await _dropFile(tmp, bytes);
      throw FileSystemException('A recovery entry with this name exists', target.path);
    }
    await hook?.call('entry-published');
    final back = await target.readAsBytes();
    final env = _parse(utf8.decode(back), bytes: back);
    final parsed = readPage(env.text);
    _checkIdentity(stem, env, parsed);
    if (!_sameBytes(back, bytes)) throw const FormatException('the entry reads back differently');
    return RecoveryEntry._(
      folder,
      page.id,
      gen,
      kind,
      session,
      env.device,
      env.time,
      env.base,
      env.text,
      parsed,
      env.supersedes,
      false,
      stem,
      directory,
      target.path.split(RegExp(r'[\\/]')).last,
      back,
    );
  });

  /// Renames each of [entries] to `.landing` (with [publishExclusive], never
  /// over anything): the durable record that its edits may have landed, made
  /// before the page file is written. An entry that is `.landing` already is
  /// left. If a rename fails, the ones this call made are put back and
  /// [LandingMark.ok] is false.
  Future<LandingMark> markLanding(List<RecoveryEntry> entries) => _serial(() async {
    final renamed = <RecoveryEntry>[];
    for (final e in entries) {
      if (e.landing) continue;
      try {
        if (!await _toLanding(e)) throw FileSystemException('The landing name is taken', _path(e._stem, 'landing'));
        renamed.add(e);
        await hook?.call('landing-renamed');
      } on Object catch (ex) {
        debugPrint('Marking the recovery entry ${e.gen} as landing failed: $ex');
        await _backToEntry(renamed);
        return const LandingMark._(false, []);
      }
    }
    return LandingMark._(true, renamed);
  });

  Future<bool> _toLanding(RecoveryEntry e) async {
    final landing = _path(e._stem, 'landing');
    final plain = File(_path(e._stem, 'entry'));
    if (await plain.exists()) return publishExclusive(plain, landing);
    // Only a leftover holds it (or a landed name): write the name from the bytes.
    final tmp = File('$landing.${_tmpSuffix()}');
    await tmp.writeAsBytes(e._bytes, flush: true);
    try {
      return await publishExclusive(tmp, landing);
    } on Object {
      await _dropFile(tmp, e._bytes);
      rethrow;
    }
  }

  /// Puts back to `.entry` the entries [markLanding] renamed, after a publish
  /// that did not land. A rename that fails leaves `.landing`, which still
  /// folds as a live entry.
  Future<void> unmarkLanding(List<RecoveryEntry> renamed) => _serial(() => _backToEntry(renamed));

  Future<void> _backToEntry(List<RecoveryEntry> renamed) async {
    for (final e in renamed) {
      final landing = File(_path(e._stem, 'landing'));
      try {
        if (!await landing.exists()) continue;
        if (await publishExclusive(landing, _path(e._stem, 'entry'))) continue;
        // The `.entry` name is still there (a rename that left its source): if it
        // is the same file, the landing name can go. Anything else there, and
        // the landing name stays.
        if (_sameBytes(await File(_path(e._stem, 'entry')).readAsBytes(), e._bytes)) {
          await _dropFile(landing, e._bytes);
        }
      } on Object catch (ex) {
        debugPrint('Putting the recovery entry ${e.gen} back failed: $ex');
      }
    }
  }

  // The files of the folder that are names of the generation [e]: its
  // `.entry`, `.landing` and `.landed` names, leftovers of `deleteFileIfMatches`
  // and complete temporary files, all with the content of [e] (a file of
  // another content with a similar name is not this entry's).
  Future<List<File>> _namesOf(RecoveryEntry e) async {
    final out = <File>[];
    final prefix = '${e._stem}.';
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final name = _fileName(f.path);
      if (!name.startsWith(prefix) || name.endsWith('.collision')) continue;
      try {
        if (_sameBytes(await f.readAsBytes(), e._bytes)) out.add(f);
      } on PathNotFoundException {
        // Gone meanwhile.
      }
    }
    return out;
  }

  /// Deletes every name of [e]'s generation, each only if it still holds the
  /// content that was listed ([deleteFileIfMatches]): hard-link leftovers of
  /// a temporary file or of the `.entry` a `.landing` rename left, `.cas-old`
  /// and `.cas-verified` files, then `.entry`, then `.landing` or `.landed`
  /// last, so the record that the edits may have landed outlives the rest.
  /// Returns true only when no name of the generation is left; otherwise the
  /// caller keeps the entry waiting to be retired and calls again.
  Future<bool> retire(RecoveryEntry e) => _serial(() async {
    try {
      final names = await _namesOf(e);
      int order(File f) {
        final n = _fileName(f.path);
        if (n == '${e._stem}.landing' || n == '${e._stem}.landed') return 2;
        if (n == '${e._stem}.entry') return 1;
        return 0;
      }

      // A name that can't be deleted stops the later groups: the landing
      // record must outlive every other name.
      for (var group = 0; group < 3; group++) {
        for (final f in names.where((f) => order(f) == group)) {
          await hook?.call('retire-before-delete');
          final r = await deleteFileIfMatches(f.path, bytes: e._bytes);
          if (!r.deleted && r.outcome != DeleteOutcome.absent) return false;
          await hook?.call('retire-name-deleted');
        }
      }
      return (await _namesOf(e)).isEmpty;
    } on Object catch (ex) {
      debugPrint('Retiring the recovery entry ${e.gen} failed: $ex');
      return false;
    }
  });

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
    await _dropWhole(first);
    await hook?.call('legacy-first-deleted');
    await _dropWhole(second);
  }

  static Future<void> _dropWhole(File f) async {
    if (!await f.exists()) return;
    final r = await deleteFileIfMatches(f.path, identity: await ContentIdentity.ofFile(f.path));
    if (!r.deleted && r.outcome != DeleteOutcome.absent) {
      throw FileSystemException('The old recovery file could not be removed', f.path);
    }
  }

  // Whether an entry in [entries] already holds the page and base of an old
  // one.
  bool _holds(Iterable<RecoveryEntry> entries, String key, String id, String text, String? base) => entries.any(
    (e) => _key(e.folder) == key && e.pageId == id && e.pageText == text && e.baseText == base,
  );

  // Converts entries of the old two-file layout to a format 3 entry. Safe to
  // stop at any point and to run again: the new file is complete before the
  // old ones are removed, and the old ones are removed only when an entry with
  // the same page and base exists. Old files that can't be converted stay, and
  // are described in [problems] and [damaged].
  Future<void> _migrate(List<String> problems, List<UnreadablePage> damaged) async {
    final bases = <String>{};
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final p = f.path;
      if (p.endsWith('.canvas') || p.endsWith('.json')) bases.add(p.substring(0, p.lastIndexOf('.')));
    }
    List<RecoveryEntry>? envs;
    Future<List<RecoveryEntry>> current() async =>
        envs ??= _entriesOf(await _names([], []), [], []);
    for (final base in bases.toList()..sort()) {
      final stem = _stemOf(base);
      try {
        final metaFile = File('$base.json');
        final pageFile = File('$base.canvas');
        final hasMeta = await metaFile.exists();
        final hasPage = await pageFile.exists();
        if (!hasMeta || !hasPage) {
          // Half an old entry: only removed when an entry already holds it.
          if (hasPage) {
            final text = await pageFile.readAsString();
            readPage(text);
            if ((await current()).any((e) => e.pageText == text)) {
              await _dropWhole(pageFile);
              continue;
            }
            throw const FormatException('the .json file of the entry is missing');
          }
          final m = _legacyMeta(jsonDecode(await metaFile.readAsString()));
          if ((await current()).any((e) => _key(e.folder) == _key(m.folder) && e.pageId == m.id && e.baseText == m.base)) {
            await _dropWhole(metaFile);
            continue;
          }
          throw const FormatException('the .canvas file of the entry is missing');
        }
        final m = _legacyMeta(jsonDecode(await metaFile.readAsString()));
        final text = await pageFile.readAsString();
        final page = readPage(text);
        if (page.id != m.id) throw FormatException('the page is "${page.id}" but the entry says "${m.id}"');
        if (m.base != null && readPage(m.base!).id != m.id) {
          throw FormatException('the base is page "${readPage(m.base!).id}" but the entry says "${m.id}"');
        }
        if (stem != _legacyName(m.folder, m.id) && !RegExp('^${RegExp.escape(_legacyName(m.folder, m.id))}_dup\\d+\$').hasMatch(stem)) {
          throw const FormatException('the file name does not belong to the entry');
        }
        // The generation comes from the pair's bytes, so converting the same pair
        // twice gives the same entry.
        final gen =
            'v1-${contentHash([...await metaFile.readAsBytes(), ...await pageFile.readAsBytes()]).substring(0, 32)}';
        final already =
            (await current()).any((e) => e.gen == gen) ||
            _holds(await current(), _key(m.folder), m.id, text, m.base);
        if (!already) {
          final out = File(_path('${_name(m.folder, m.id)}.g$gen', 'entry'));
          final content = _encode3(
            folder: m.folder,
            pageId: m.id,
            gen: gen,
            kind: 'legacy',
            session: 'v1',
            device: '',
            created: (m.time ?? (await pageFile.lastModified()).toUtc()).toIso8601String(),
            base: m.base,
            page: text,
            supersedes: const [],
          );
          final tmp = File('${out.path}.${_tmpSuffix()}');
          await tmp.writeAsString(content, flush: true);
          try {
            if (!await publishExclusive(tmp, out.path)) {
              if (!_sameBytes(await out.readAsBytes(), utf8.encode(content))) {
                throw const FormatException('the new entry could not be published');
              }
              await _dropFile(tmp, utf8.encode(content));
            }
          } on Object {
            await _dropFile(tmp, utf8.encode(content));
            rethrow;
          }
          envs = null;
        }
        await hook?.call('envelope-published');
        await _removeLegacy(base, pageFirst: false);
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
  // complete, consistent entry is published exclusively under the name in its
  // own content, or deleted when that name (or another name of its
  // generation) already holds identical bytes (a hard-linked leftover); with
  // other content at the name it is kept and reported. A format 2 tmp goes to
  // the first free slot, unless an entry holds its page and base. A torn tmp,
  // and the rest, are kept and reported. Time is never compared.
  Future<void> _settleTmps(List<String> problems, List<UnreadablePage> damaged) async {
    final tmps = <File>[];
    await for (final f in directory.list()) {
      if (f is File && f.path.endsWith('.tmp')) tmps.add(f);
    }
    tmps.sort((a, b) => a.path.compareTo(b.path));
    List<RecoveryEntry>? envs;
    for (final f in tmps) {
      final file = _fileName(f.path);
      try {
        final bytes = await f.readAsBytes();
        final text = utf8.decode(bytes);
        final at = file.indexOf('.entry.');
        final lat = file.indexOf('.landing.');
        if (at >= 0 || lat >= 0) {
          final env = _parse(text, bytes: bytes);
          final cut = at >= 0 ? at : lat;
          final ext = at >= 0 ? 'entry' : 'landing';
          final tmpStem = file.substring(0, cut);
          _checkIdentity(tmpStem, env, readPage(env.text));
          envs ??= _entriesOf(await _names([], []), [], []);
          if (env.format == 3) {
            // Any name of the generation with the same bytes holds it.
            final held = (await _namesOfStem(tmpStem)).any((n) => _sameBytes(n.$2, bytes));
            if (held) {
              await _dropFile(f, bytes);
              continue;
            }
            if (await publishExclusive(f, _path(tmpStem, ext))) {
              envs = null;
              continue;
            }
            throw const FormatException('another file has the name of this unfinished write, so it is kept');
          }
          // Format 2 (an older build): the first free slot, unless an entry
          // holds the same page and base.
          if (_holds(envs, env.key, env.id, env.text, env.base)) {
            await _dropFile(f, bytes);
            continue;
          }
          for (var k = 1; ; k++) {
            final target = _slot(env.folder, env.id, k);
            if (!await target.exists()) {
              if (await publishExclusive(f, target.path)) {
                envs = null;
                break;
              }
            }
          }
        } else if (file.endsWith('.canvas.tmp') || file.endsWith('.json.tmp')) {
          // An unfinished write of the old layout: removed when an entry
          // already holds what it holds.
          envs ??= _entriesOf(await _names([], []), [], []);
          var held = false;
          if (file.endsWith('.canvas.tmp')) {
            readPage(text);
            held = envs.any((e) => e.pageText == text);
          } else {
            final m = _legacyMeta(jsonDecode(text));
            held = envs.any((e) => _key(e.folder) == _key(m.folder) && e.pageId == m.id && e.baseText == m.base);
          }
          if (!held) throw const FormatException('an unfinished write was left here');
          await _dropFile(f, bytes);
        } else {
          throw const FormatException('an unfinished write was left here');
        }
      } on Object catch (e) {
        _report(problems, damaged, f.path, _why(e));
      }
    }
  }

  // The names (and bytes) of the files whose name starts with `<stem>.` and is
  // not a temporary file.
  Future<List<(File, List<int>)>> _namesOfStem(String stem) async {
    final out = <(File, List<int>)>[];
    await for (final f in directory.list()) {
      if (f is! File) continue;
      final n = _fileName(f.path);
      if (!n.startsWith('$stem.') || n.endsWith('.tmp') || n.endsWith('.collision')) continue;
      try {
        out.add((f, await f.readAsBytes()));
      } on PathNotFoundException {
        // Gone meanwhile.
      }
    }
    return out;
  }

  /// Reads every entry. Files that can't be read, or whose identities
  /// disagree, are reported, not removed, and are never offered.
  Future<RecoveryListing> list() => _serial(() async {
    await hook?.call('list');
    final problems = <String>[];
    final damaged = <UnreadablePage>[];
    if (!await directory.exists()) return const RecoveryListing([], []);

    // Settling a tmp can publish the entry that an old half-file waits for, so
    // the old files are looked at again afterwards; only that pass reports.
    await _migrate([], []);
    await _settleTmps(problems, damaged);
    await _migrate(problems, damaged);
    final entries = _entriesOf(await _names(problems, damaged), problems, damaged);
    return RecoveryListing(entries, problems, damaged);
  });
}

/// Checks a recovered page [result] (read back from disk) against the three
/// pages it came from. Returns null if it is sound, else why not:
///
/// - every box of [theirs] is still there;
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
  for (final id in theirsById.keys) {
    if (!out.containsKey(id)) return 'box $id of the saved file is missing';
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
