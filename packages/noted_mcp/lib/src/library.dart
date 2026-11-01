// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core_read.dart';

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

/// Every saved page this device can reach, read from the page files only
/// (never from a running app's screen), with the AI access of each.
///
/// Reading never writes: no folder is created, no file is changed.
final class NotedLibrary {
  NotedLibrary._(this.pages, this.folders);

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
  static Future<NotedLibrary> load(Directory dataDir) async {
    final sep = Platform.pathSeparator;
    final settings = await _readJson(File('${dataDir.path}${sep}settings.json'));
    final binders = await _readJson(File('${dataDir.path}${sep}binders.json'));
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
      for (final (p, file) in await _readPages(Directory(path))) {
        loose.add((p, loc, file));
      }
    }
    pages.addAll(_withAccess(loose, binder: null, locked: false));
    for (final path in _strings(binders['binders'])) {
      final binder = await _readBinder(Directory(path));
      // A binder that can't be read is left out whole. A locked one is kept,
      // marked: page AI never sees its pages, but its AI boxes stay reachable
      // by their codes.
      if (binder == null) continue;
      final loc = LibraryLocation(path, binder: binder);
      final own = [for (final (p, file) in await _readPages(Directory(path))) (p, loc, file)];
      pages.addAll(_withAccess(own, binder: binder, locked: isLockedBinder(binder)));
    }
    return NotedLibrary._(pages, [...standalone, ..._strings(binders['binders'])]);
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

  static Future<Map<String, Object?>> _readJson(File f) async {
    try {
      if (!await f.exists()) return const {};
      final json = jsonDecode(await f.readAsString());
      return json is Map<String, Object?> ? json : const {};
    } on Object {
      return const {};
    }
  }

  static Future<Binder?> _readBinder(Directory dir) async {
    final f = File('${dir.path}${Platform.pathSeparator}$binderFileName');
    try {
      if (!await f.exists()) return null;
      return Binder.parse(await f.readAsString());
    } on Object {
      return null;
    }
  }

  /// The pages in [dir]: each `*.canvas` file that reads as a page. A
  /// conflict copy (another file with the same page id) is skipped in
  /// favour of `<id>.canvas`.
  static Future<List<(NotedPage, String)>> _readPages(Directory dir) async {
    final byId = <String, (NotedPage, bool, String)>{};
    try {
      if (!await dir.exists()) return const [];
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.canvas')) continue;
        try {
          final page = readPage(await e.readAsString());
          final name = e.path.split(RegExp(r'[\\/]')).last;
          final exact = name == '${page.id}.canvas';
          final seen = byId[page.id];
          if (seen == null || (exact && !seen.$2)) byId[page.id] = (page, exact, e.path);
        } on Object {
          // Unreadable: not given out.
        }
      }
    } on FileSystemException {
      return const [];
    }
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
