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
/// setting that applies to it.
final class LibraryPage {
  LibraryPage(this.page, this.location, this.ai);

  final NotedPage page;

  /// The folder (standalone) or binder it is in.
  final LibraryLocation location;

  /// The AI setting that applies (own, inherited or the default).
  final AiSetting ai;

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
/// (never from a running app's screen), with the AI setting of each.
///
/// Reading never writes: no folder is created, no file is changed.
final class NotedLibrary {
  NotedLibrary._(this.pages, this.connections);

  /// All readable pages, Off ones included; the tools filter them.
  final List<LibraryPage> pages;

  /// The AI connections listed in `settings.json` as of this read.
  final List<AiConnectionInfo> connections;

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
    final loose = <(NotedPage, LibraryLocation)>[];
    for (final path in standalone) {
      final loc = LibraryLocation(path);
      for (final p in await _readPages(Directory(path))) {
        loose.add((p, loc));
      }
    }
    pages.addAll(_withSettings(loose, binder: null));
    for (final path in _strings(binders['binders'])) {
      final binder = await _readBinder(Directory(path));
      // A binder that can't be read, or that is locked, is left out whole.
      if (binder == null || isLockedBinder(binder)) continue;
      final loc = LibraryLocation(path, binder: binder);
      final own = [for (final p in await _readPages(Directory(path))) (p, loc)];
      pages.addAll(_withSettings(own, binder: binder));
    }
    return NotedLibrary._(pages, readAiConnections(settings));
  }

  static List<LibraryPage> _withSettings(List<(NotedPage, LibraryLocation)> pages, {required Binder? binder}) {
    final tree = PageTree.build([for (final (p, _) in pages) p.meta]);
    final metas = {for (final (p, _) in pages) p.id: p.meta};
    return [
      for (final (p, loc) in pages)
        LibraryPage(p, loc, effectiveAiSetting(_chain(p.id, tree, metas), binder: binder)),
    ];
  }

  static List<PageMeta> _chain(String id, PageTree tree, Map<String, PageMeta> metas) {
    final chain = <PageMeta>[];
    final seen = <String>{};
    String? at = id;
    while (at != null && seen.add(at)) {
      final m = metas[at];
      if (m == null) break;
      chain.add(m);
      at = tree.parentIdOf(at);
    }
    return chain;
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
  static Future<List<NotedPage>> _readPages(Directory dir) async {
    final byId = <String, (NotedPage, bool)>{};
    try {
      if (!await dir.exists()) return const [];
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.canvas')) continue;
        try {
          final page = readPage(await e.readAsString());
          final name = e.path.split(RegExp(r'[\\/]')).last;
          final exact = name == '${page.id}.canvas';
          final seen = byId[page.id];
          if (seen == null || (exact && !seen.$2)) byId[page.id] = (page, exact);
        } on Object {
          // Unreadable: not given out.
        }
      }
    } on FileSystemException {
      return const [];
    }
    return [for (final (p, _) in byId.values) p];
  }
}

/// Whether [binder] is locked (binder passwords, a later phase): a binder
/// file that says it is locked or encrypted is left out whole, so its pages
/// are invisible to AI.
bool isLockedBinder(Binder binder) {
  final f = binder.fields;
  return f['locked']?.text == 'true' || f.containsKey('encryption') || f.containsKey('password');
}
