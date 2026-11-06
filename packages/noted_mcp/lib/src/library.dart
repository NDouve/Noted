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
  /// same rules as the app (`effectiveAiAccess`).
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

/// One folder as listed by a library load: its state and, if listed, each
/// `*.canvas` path with the page id it read as (null if unreadable).
final class FolderListing {
  FolderListing(this.state, [Map<String, String?>? pageIds]) : pageIds = pageIds ?? const {};

  final FolderState state;
  final Map<String, String?> pageIds;
}

/// The bytes and listings a load worked from, kept only for a closed write
/// (`keepSources`), so that it can show under its hold that the eligibility
/// inputs did not change. An absent file is recorded as null.
final class LibrarySources {
  final Map<String, List<int>?> files = {};
  final Map<String, FolderListing> listings = {};
}

/// Every saved page this device can reach, read from the page files only
/// (never from a running app's screen), with the AI access of each.
///
/// Reading never writes: no folder is created, no file is changed.
final class NotedLibrary {
  NotedLibrary._(this.pages, this.folders, this.standalone, this.sources);

  /// The standalone folders (one tree together).
  final List<String> standalone;

  /// Kept bytes and listings, only after a load with `keepSources`.
  final LibrarySources? sources;

  /// The folders the library listed (standalone folders and binders). The
  /// closed-app writer may replace page files in these folders only.
  final List<String> folders;

  /// All readable pages, Privileged, Guarded and locked ones included; the
  /// tools filter them.
  final List<LibraryPage> pages;

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
    final settings = await _readJson(identity, '${dataDir.path}${sep}settings.json', kept);
    final binders = await _readJson(identity, '${dataDir.path}${sep}binders.json', kept);
    final standalone = <String>{
      '${dataDir.path}${sep}pages',
      if (settings['defaultPageFolder'] case final String p when p.isNotEmpty) p,
      for (final p in _strings(binders['standaloneFolders'])) p,
    };
    final pages = <LibraryPage>[];
    // Standalone folders share one tree, as in the app.
    final loose = <(NotedPage, LibraryLocation, String)>[];
    for (final path in standalone) {
      final loc = LibraryLocation(path);
      for (final (p, file) in await _readPages(identity, Directory(path), kept)) {
        loose.add((p, loc, file));
      }
    }
    pages.addAll(_withAccess(loose, binder: null, locked: false));
    for (final path in _strings(binders['binders'])) {
      final binder = await _readBinder(identity, Directory(path), kept);
      // A binder that can't be read is left out whole. A locked one is kept,
      // marked: page AI never sees its pages, but its AI boxes stay reachable
      // by their codes.
      if (binder == null) continue;
      final loc = LibraryLocation(path, binder: binder);
      final own = [for (final (p, file) in await _readPages(identity, Directory(path), kept)) (p, loc, file)];
      pages.addAll(_withAccess(own, binder: binder, locked: isLockedBinder(binder)));
    }
    return NotedLibrary._(pages, [...standalone, ..._strings(binders['binders'])], standalone.toList(), kept);
  }

  static List<LibraryPage> _withAccess(
    List<(NotedPage, LibraryLocation, String)> pages, {
    required Binder? binder,
    required bool locked,
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
      while (at != null && seen.add(at)) {
        final m = metas[at];
        if (m == null) break;
        chain.add(m);
        at = m.parentId;
      }
      final a = effectiveAiAccess(chain, binder: binder).value;
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

  static Future<Map<String, Object?>> _readJson(LockIdentity identity, String path, LibrarySources? kept) async {
    final bytes = await identity.readBytes(path);
    kept?.files[path] = bytes;
    if (bytes == null) return const {};
    try {
      final json = jsonDecode(_decode(bytes));
      return json is Map<String, Object?> ? json : const {};
    } on Object {
      return const {};
    }
  }

  static Future<Binder?> _readBinder(LockIdentity identity, Directory dir, LibrarySources? kept) async {
    final bytes = await identity.readBytes(binderFilePath(dir.path));
    kept?.files[binderFilePath(dir.path)] = bytes;
    if (bytes == null) return null;
    try {
      return Binder.parse(_decode(bytes));
    } on Object {
      return null;
    }
  }

  /// The binder file of the binder folder [folder].
  static String binderFilePath(String folder) => '$folder${Platform.pathSeparator}$binderFileName';

  /// The pages in [dir]: each `*.canvas` file that reads as a page. A
  /// conflict copy (another file with the same page id) is skipped in
  /// favour of `<id>.canvas`.
  static Future<List<(NotedPage, String)>> _readPages(
    LockIdentity identity,
    Directory dir,
    LibrarySources? kept,
  ) async {
    final byId = <String, (NotedPage, bool, String)>{};
    final names = <String, String?>{};
    try {
      if (!await dir.exists()) {
        kept?.listings[dir.path] = FolderListing(FolderState.absent);
        return const [];
      }
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.canvas')) continue;
        final bytes = await identity.readBytes(e.path);
        kept?.files[e.path] = bytes;
        names[e.path] = null;
        if (bytes == null) continue;
        try {
          final page = readPage(_decode(bytes));
          names[e.path] = page.id;
          final name = e.path.split(RegExp(r'[\/]')).last;
          final exact = name == '${page.id}.canvas';
          final seen = byId[page.id];
          if (seen == null || (exact && !seen.$2)) byId[page.id] = (page, exact, e.path);
        } on Object {
          // Unreadable: not given out.
        }
      }
    } on FileSystemException {
      kept?.listings[dir.path] = FolderListing(FolderState.failed);
      return const [];
    }
    kept?.listings[dir.path] = FolderListing(FolderState.listed, names);
    return [for (final (p, _, path) in byId.values) (p, path)];
  }
}

/// Whether [binder] is locked (binder passwords, a later phase): a binder
/// file that says it is locked or encrypted. Its pages are invisible to page
/// AI.
bool isLockedBinder(Binder binder) {
  final f = binder.fields;
  return f['locked']?.text == 'true' || f.containsKey('encryption') || f.containsKey('password');
}
