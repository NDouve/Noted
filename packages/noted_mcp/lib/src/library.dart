// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core_read.dart';

import 'running_probe.dart';

/// Where Noted keeps this device's files: `settings.json`, `binders.json`
/// and the default `pages` folder (`%APPDATA%\Noted` on Windows,
/// `~/.noted` elsewhere), as the app finds them.
Directory defaultDataDirectory() {
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows && env['APPDATA'] != null) {
    return Directory('${env['APPDATA']}${sep}Noted');
  }
  return Directory('${env['HOME'] ?? '.'}$sep.noted');
}

/// One saved page as read from its file, with where it is and the AI
/// access that applies to it.
final class LibraryPage {
  LibraryPage(this.page, this.location, this.access, {this.locked = false, this.path});

  final NotedPage page;

  /// The page file this was read from.
  final String? path;

  /// The folder (standalone) or binder it is in.
  final LibraryLocation location;

  /// The AI access that applies (own, inherited or the default), by the
  /// same rules as the app (`effectiveAiAccess`). Guarded whatever the
  /// headers say when the page, or a page above it, has more than one copy
  /// ([NotedLibrary.ambiguous]).
  final AiAccess access;

  /// Whether the page is in a locked binder: hidden from page AI whatever its
  /// access. (An AI box on it can still be reached by its box code.)
  final bool locked;

  String get id => page.id;
  String get title => page.meta.title.trim().isEmpty ? 'Untitled page' : page.meta.title.trim();
}

/// A folder of pages: a standalone folder, or a binder.
final class LibraryLocation {
  LibraryLocation(this.path, {this.binder});

  final String path;

  /// The binder, for a binder folder.
  final Binder? binder;

  String get name => binder == null ? 'Pages' : (binder!.title.trim().isEmpty ? 'Binder' : binder!.title.trim());
}

/// What a folder listing found.
enum FolderState { absent, failed, listed }

/// The page ids a `.canvas` file counts for (see [fileIdsOf]).
final class FileIds {
  const FileIds(this.ids, {this.unknown = false});

  /// The ids the file is, or may be.
  final Set<String> ids;

  /// The file can't be read and its name carries no id: it may be any page.
  final bool unknown;

  @override
  bool operator ==(Object other) =>
      other is FileIds && other.unknown == unknown && other.ids.length == ids.length && other.ids.containsAll(ids);

  @override
  int get hashCode => Object.hash(unknown, ids.length);
}

/// One folder as listed by a library load: its state and, if listed, each
/// `*.canvas` path with the ids it counts for.
final class FolderListing {
  FolderListing(this.state, [Map<String, FileIds>? carried, Map<String, String>? stats])
    : carried = carried ?? const {},
      stats = stats ?? const {};

  final FolderState state;
  final Map<String, FileIds> carried;

  /// Each listed file's size and modified time, as one string.
  final Map<String, String> stats;
}

/// The bytes and listings a load worked from, kept only for a closed write
/// (`keepSources`), so that it can show under its hold that the eligibility
/// inputs did not change. An absent file is recorded as null.
final class LibrarySources {
  final Map<String, List<int>?> files = {};
  final Map<String, FolderListing> listings = {};

  /// Every listed binder's file: whether its bytes could be read.
  final Map<String, bool> binderReadable = {};
}

/// Every saved page this device can reach, read from the page files only
/// (never from a running app's screen), with the AI access of each.
///
/// Reading never writes: no folder is created, no file is changed.
final class NotedLibrary {
  NotedLibrary._(this.pages, this.folders, this.standalone, this.sources, this.ambiguous, this.allAmbiguous);

  /// The standalone folders (one tree together).
  final List<String> standalone;

  /// Kept bytes and listings, only after a load with `keepSources`.
  final LibrarySources? sources;

  /// The folders the library listed (standalone folders and binders). The
  /// closed-app writer may replace page files in these folders only.
  final List<String> folders;

  /// All readable pages, Privileged, Guarded and locked ones included; the
  /// tools filter them. One entry per id per tree.
  final List<LibraryPage> pages;

  /// The page ids with more than one file across every folder listed (a file
  /// the server can't use counts for the id it may carry). The app's choice
  /// between same-id files is in its memory only (0137), so none of these is
  /// served by page access; they are all Guarded, and so is everything under
  /// them.
  final Set<String> ambiguous;

  /// Something that may hold a copy of any page could not be read or listed:
  /// no id can be trusted for this load.
  final bool allAmbiguous;

  /// Whether [id] has more than one copy, or may have ([allAmbiguous]).
  bool isAmbiguous(String id) => allAmbiguous || ambiguous.contains(id);

  LibraryPage? page(String id) {
    for (final p in pages) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Reads the folders listed by the app in [dataDir]: its `pages` folder,
  /// the default page folder in `settings.json`, and the standalone folders
  /// and binders in `binders.json`.
  static Future<NotedLibrary> load(Directory dataDir, {bool keepSources = false}) async {
    final sep = Platform.pathSeparator;
    final identity = await LockIdentity.of(dataDir);
    final kept = keepSources ? LibrarySources() : null;
    var allAmbiguous = false;
    Future<Map<String, Object?>> readJson(String name) async {
      final r = await _readJson(identity, '${dataDir.path}$sep$name', kept);
      if (r.unreadable) allAmbiguous = true;
      return r.json;
    }

    final settings = await readJson('settings.json');
    final binders = await readJson('binders.json');

    // Each folder once, whatever its spelling or the lists it is in; the first
    // spelling is used.
    final spelling = <String, String>{};
    Future<List<String>> distinct(Iterable<String> paths) async {
      final out = <String>[];
      for (final p in paths) {
        final s = spelling.putIfAbsent(await normalizedPath(p), () => p);
        if (!out.contains(s)) out.add(s);
      }
      return out;
    }

    final standalone = await distinct([
      '${dataDir.path}${sep}pages',
      if (settings['defaultPageFolder'] case final String p when p.isNotEmpty) p,
      for (final p in _strings(binders['standaloneFolders'])) p,
    ]);
    final binderPaths = await distinct(_strings(binders['binders']));

    // Every listed folder is listed and counted first, whatever its binder
    // file says; a file is counted once however it is reached.
    final scans = <String, _FolderScan>{};
    final bySpelling = <String, _FolderScan>{};
    final counts = <String, Set<String>>{};
    for (final path in [...standalone, ...binderPaths]) {
      final key = await normalizedPath(path);
      final done = scans[key];
      if (done != null) {
        bySpelling[path] = done;
        continue;
      }
      final s = await _scanFolder(identity, path, kept);
      scans[key] = s;
      bySpelling[path] = s;
      if (s.state == FolderState.failed) allAmbiguous = true;
      for (final e in s.carried.entries) {
        if (e.value.unknown) allAmbiguous = true;
        final name = e.key.split(RegExp(r'[\\/]')).last;
        final fileKey = '$key/${Platform.isWindows ? name.toLowerCase() : name}';
        for (final id in e.value.ids) {
          counts.putIfAbsent(id, () => {}).add(fileKey);
        }
      }
    }
    final ambiguous = {
      for (final e in counts.entries)
        if (e.value.length > 1) e.key,
    };
    bool isAmb(String id) => allAmbiguous || ambiguous.contains(id);
    // By the spelling `distinct` fixed for each folder.
    _FolderScan scanOf(String path) => bySpelling[path] ?? _FolderScan(FolderState.failed, const [], const {});

    final pages = <LibraryPage>[];
    // Standalone folders share one tree, as in the app.
    final loose = <(NotedPage, LibraryLocation, String)>[];
    for (final path in standalone) {
      final loc = LibraryLocation(path);
      for (final (p, file) in choosePages(scanOf(path).found)) {
        loose.add((p, loc, file));
      }
    }
    pages.addAll(_withAccess(loose, binder: null, locked: false, isAmb: isAmb));
    final standaloneCount = pages.length;
    // The binder entries of a folder that is listed as standalone too.
    final alsoStandalone = <String, int>{};
    for (final path in binderPaths) {
      final binder = await _readBinder(identity, Directory(path), kept);
      // A binder that can't be read is left out whole. A locked one is kept,
      // marked: page AI never sees its pages, but its AI boxes stay reachable
      // by their codes.
      if (binder == null) continue;
      final loc = LibraryLocation(path, binder: binder);
      final own = [for (final (p, file) in choosePages(scanOf(path).found)) (p, loc, file)];
      final made = _withAccess(own, binder: binder, locked: isLockedBinder(binder), isAmb: isAmb);
      for (final p in made) {
        if (standalone.contains(path) && p.path != null) alsoStandalone[p.path!] = pages.length;
        pages.add(p);
      }
    }
    // A folder listed both as standalone and as a binder is served with the
    // stricter of its two accesses, in both trees (nothing more openly than
    // either list alone would).
    for (var i = 0; i < standaloneCount; i++) {
      final a = pages[i];
      final j = a.path == null ? null : alsoStandalone[a.path!];
      if (j == null) continue;
      final b = pages[j];
      final access = AiAccess.strictest(a.access, b.access);
      final locked = a.locked || b.locked;
      pages[i] = LibraryPage(a.page, a.location, access, locked: locked, path: a.path);
      pages[j] = LibraryPage(b.page, b.location, access, locked: locked, path: b.path);
    }
    // The reconciled access reaches every page under a reconciled page, in its
    // own tree: a page is never looser than any ancestor's.
    if (alsoStandalone.isNotEmpty) {
      final trees = <String?, List<int>>{};
      for (var i = 0; i < pages.length; i++) {
        final b = pages[i].location.binder;
        trees.putIfAbsent(b == null ? null : pages[i].location.path, () => []).add(i);
      }
      for (final idx in trees.values) {
        final at = {for (final i in idx) pages[i].id: i};
        final base = {for (final i in idx) pages[i].id: pages[i].access};
        for (final i in idx) {
          var a = base[pages[i].id]!;
          final seen = <String>{pages[i].id};
          var up = pages[i].page.meta.parentId;
          while (up != null && seen.add(up)) {
            final k = at[up];
            if (k == null) break;
            a = AiAccess.strictest(a, base[up]!);
            up = pages[k].page.meta.parentId;
          }
          final p = pages[i];
          if (a != p.access) pages[i] = LibraryPage(p.page, p.location, a, locked: p.locked, path: p.path);
        }
      }
    }
    return NotedLibrary._(pages, [...standalone, ...binderPaths], standalone, kept, ambiguous, allAmbiguous);
  }

  static List<LibraryPage> _withAccess(
    List<(NotedPage, LibraryLocation, String)> pages, {
    required Binder? binder,
    required bool locked,
    required bool Function(String id) isAmb,
  }) {
    // One entry per page id (the first copy is kept). If copies of an id
    // disagree, the strictest access of any copy applies.
    final metas = <String, PageMeta>{};
    final first = <String, (NotedPage, LibraryLocation, String)>{};
    for (final e in pages) {
      metas.putIfAbsent(e.$1.id, () => e.$1.meta);
      first.putIfAbsent(e.$1.id, () => e);
    }
    final access = <String, AiAccess>{};
    for (final (p, _, _) in pages) {
      // Each copy starts its chain from its own header. A parent that is
      // missing, unreadable or looping ends the chain, and the core then
      // starts from the app default (the page is not the top).
      final chain = <PageMeta>[p.meta];
      final seen = <String>{p.id};
      var at = p.meta.parentId;
      // A page with more than one copy, or under such a page, can't take its
      // access from either copy: Guarded.
      var unsure = isAmb(p.id);
      while (at != null && seen.add(at)) {
        if (isAmb(at)) unsure = true;
        final m = metas[at];
        if (m == null) break;
        chain.add(m);
        at = m.parentId;
      }
      final a = unsure ? AiAccess.guarded : effectiveAiAccess(chain, binder: binder).value;
      final before = access[p.id];
      access[p.id] = before == null ? a : AiAccess.strictest(before, a);
    }
    return [
      for (final (p, loc, file) in first.values) LibraryPage(p, loc, access[p.id]!, locked: locked, path: file),
    ];
  }

  static Iterable<String> _strings(Object? list) =>
      list is List ? list.whereType<String>().where((s) => s.isNotEmpty) : const [];

  static String _decode(List<int> bytes) => utf8.decode(bytes);

  /// The page id [bytes] read as, or null if they don't read as a page.
  static String? pageIdOf(List<int> bytes) {
    try {
      return readPage(_decode(bytes)).id;
    } on Object {
      return null;
    }
  }

  // The JSON file's content (empty if absent or damaged). [unreadable]: it is
  // there but its bytes can't be read (`readBytes` says null for both).
  static Future<({Map<String, Object?> json, bool unreadable})> _readJson(
    LockIdentity identity,
    String path,
    LibrarySources? kept,
  ) async {
    final bytes = await identity.readBytes(path);
    kept?.files[path] = bytes;
    if (bytes == null) return (json: const <String, Object?>{}, unreadable: await _exists(path));
    try {
      final json = jsonDecode(_decode(bytes));
      return (json: json is Map<String, Object?> ? json : const <String, Object?>{}, unreadable: false);
    } on Object {
      return (json: const <String, Object?>{}, unreadable: false);
    }
  }

  static Future<bool> _exists(String path) async {
    try {
      return await File(path).exists();
    } on Object {
      return true;
    }
  }

  static Future<Binder?> _readBinder(LockIdentity identity, Directory dir, LibrarySources? kept) async {
    final bytes = await identity.readBytes(binderFilePath(dir.path));
    kept?.files[binderFilePath(dir.path)] = bytes;
    kept?.binderReadable[binderFilePath(dir.path)] = bytes != null;
    if (bytes == null) return null;
    try {
      return Binder.parse(_decode(bytes));
    } on Object {
      return null;
    }
  }

  /// The binder file of the binder folder [folder].
  static String binderFilePath(String folder) => '$folder${Platform.pathSeparator}$binderFileName';

  /// The `*.canvas` files in [path]: each that reads as a page, and the ids
  /// every file counts for.
  static Future<_FolderScan> _scanFolder(LockIdentity identity, String path, LibrarySources? kept) async {
    final dir = Directory(path);
    final found = <(NotedPage, String)>[];
    final carried = <String, FileIds>{};
    final stats = <String, String>{};
    try {
      if (!await dir.exists()) {
        kept?.listings[dir.path] = FolderListing(FolderState.absent);
        return _FolderScan(FolderState.absent, const [], const {});
      }
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.canvas')) continue;
        stats[e.path] = await fileSignature(e.path);
        final bytes = await identity.readBytes(e.path);
        kept?.files[e.path] = bytes;
        String? parsed;
        if (bytes != null) {
          try {
            final page = readPage(_decode(bytes));
            parsed = page.id;
            found.add((page, e.path));
          } on Object {
            // Doesn't parse: not given out, but it may be a copy (fileIdsOf).
          }
        }
        carried[e.path] = fileIdsOf(e.path, bytes, parsedId: parsed);
      }
    } on FileSystemException {
      kept?.listings[dir.path] = FolderListing(FolderState.failed);
      return _FolderScan(FolderState.failed, const [], const {});
    }
    kept?.listings[dir.path] = FolderListing(FolderState.listed, carried, stats);
    return _FolderScan(FolderState.listed, found, carried);
  }
}

/// What listing one folder found.
final class _FolderScan {
  _FolderScan(this.state, this.found, this.carried);

  final FolderState state;

  /// Every file that reads as a page (before [choosePages] drops copies).
  final List<(NotedPage, String)> found;
  final Map<String, FileIds> carried;
}

final RegExp _idShape = RegExp(r'^[0-9a-f]{16}$');

/// The ids the `.canvas` file [path] with [bytes] (null: can't be read)
/// counts for, so that a copy the server can't use still makes its id
/// ambiguous:
/// - a file that parses counts only for [parsedId];
/// - one that doesn't, but reads, counts for the id in its header (found by
///   [scanHeaderId]) and for the page ids its name carries ([nameIds]), both;
///   with neither it isn't a page and counts for nothing;
/// - one that can't be read counts for its name's ids; with none it may be
///   any page ([FileIds.unknown]).
FileIds fileIdsOf(String path, List<int>? bytes, {String? parsedId}) {
  if (parsedId != null) return FileIds({parsedId});
  if (bytes != null) {
    final scanned = scanHeaderId(utf8.decode(bytes, allowMalformed: true));
    return FileIds({?scanned, ...nameIds(path)});
  }
  final ids = nameIds(path);
  return FileIds(ids, unknown: ids.isEmpty);
}

/// The page ids the file name of [path] starts with: `<id>.canvas`, a sync
/// client's copy `<id>-DEVICE.canvas` (and `-1`), or the server's aside file
/// `<id>-NOTED-MCP-<hex>.canvas`, by the rules of core's
/// `conflictCopyOriginalNames` (every hyphen may start the suffix). An id is
/// 16 hex digits.
Set<String> nameIds(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  if (!name.endsWith('.canvas')) return const {};
  final stem = name.substring(0, name.length - '.canvas'.length);
  final suffix = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*$');
  final out = <String>{stem};
  for (var i = 1; i < stem.length - 1; i++) {
    if (stem[i] == '-' && suffix.hasMatch(stem.substring(i + 1))) out.add(stem.substring(0, i));
  }
  return {
    for (final s in out)
      if (_idShape.hasMatch(s)) s,
  };
}

/// The `pageId` of the page header (the top-level `noted` object) in [text], which
/// may be cut short or damaged elsewhere; null if it isn't reached. Never an
/// `pageId` of any other object (a box's, say).
String? scanHeaderId(String text) {
  var i = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? 1 : 0;
  final n = text.length;
  // Open containers ('{' or '['), and the key each one is the value of.
  final open = <String>[];
  final under = <String?>[];
  String? key; // the key whose value comes next

  // The string that starts at [i] (a quote), or null if the text ends inside
  // it. Leaves [i] after the closing quote.
  String? readString() {
    final start = i;
    i++;
    while (i < n) {
      final c = text[i];
      if (c == r'\') {
        i += 2;
        continue;
      }
      if (c == '"') {
        i++;
        try {
          final v = jsonDecode(text.substring(start, i));
          return v is String ? v : '';
        } on Object {
          return '';
        }
      }
      i++;
    }
    i = n;
    return null;
  }

  void skipSpace() {
    while (i < n && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n')) {
      i++;
    }
  }

  while (i < n) {
    final c = text[i];
    if (c == '{' || c == '[') {
      open.add(c);
      under.add(key);
      key = null;
      i++;
    } else if (c == '}' || c == ']') {
      if (open.isNotEmpty) {
        open.removeLast();
        under.removeLast();
      }
      key = null;
      i++;
    } else if (c == ',') {
      key = null;
      i++;
    } else if (c == '"') {
      final s = readString();
      if (s == null) return null;
      skipSpace();
      if (open.isNotEmpty && open.last == '{' && i < n && text[i] == ':') {
        i++;
        key = s;
        // The header's own id: the `id` key of the top-level `noted` object.
        if (s == 'pageId' && open.length == 2 && under[1] == 'noted') {
          skipSpace();
          if (i < n && text[i] == '"') {
            final v = readString();
            return v == null || v.isEmpty ? null : v;
          }
          return null;
        }
      } else {
        key = null;
      }
    } else {
      i++;
    }
  }
  return null;
}

/// The normal form of the folder path [path] for telling two spellings of one
/// place apart: symbolic links resolved where it exists, separators unified,
/// no `.` or `..` parts, and the case folded on Windows (as the app compares).
Future<String> normalizedPath(String path) async {
  var p = path;
  try {
    final d = Directory(p);
    p = await d.exists() ? await d.resolveSymbolicLinks() : d.absolute.path;
  } on Object {
    p = File(p).absolute.path;
  }
  if (Platform.isWindows) p = p.replaceAll(r'\', '/').toLowerCase();
  final out = <String>[];
  for (final part in p.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(part);
  }
  return '${p.startsWith('/') ? '/' : ''}${out.join('/')}';
}

/// Whether [binder] is locked (binder passwords, a later phase): a binder
/// file that says it is locked or encrypted. Its pages are invisible to page
/// AI.
bool isLockedBinder(Binder binder) {
  final f = binder.fields;
  return f['locked']?.text == 'true' || f.containsKey('encryption') || f.containsKey('password');
}

/// A file's size and modified time as one string, for telling a rewritten file
/// from one left alone ('-' if it can't be examined).
Future<String> fileSignature(String path) async {
  try {
    final s = await File(path).stat();
    return '${s.size}/${s.modified.microsecondsSinceEpoch}';
  } on Object {
    return '-';
  }
}

/// One entry per page id from the page files found in a folder, in any order: a
/// conflict copy (another file with the same page id) is skipped in favour of
/// `<id>.canvas`; otherwise the first found is kept.
List<(NotedPage, String)> choosePages(Iterable<(NotedPage, String)> found) {
  final byId = <String, (NotedPage, bool, String)>{};
  for (final (page, path) in found) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final exact = name == '${page.id}.canvas';
    final seen = byId[page.id];
    if (seen == null || (exact && !seen.$2)) byId[page.id] = (page, exact, path);
  }
  return [for (final (p, _, path) in byId.values) (p, path)];
}
