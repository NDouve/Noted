// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// Where page files live in Prototype 1: one local folder (0007).
///
/// Override with `--dart-define=NOTED_PAGES_DIR=<path>`. The default avoids
/// Documents, which is often redirected into a cloud-synced folder.
Directory defaultPagesDirectory() {
  const override = String.fromEnvironment('NOTED_PAGES_DIR');
  if (override.isNotEmpty) return Directory(override);
  final env = Platform.environment;
  final sep = Platform.pathSeparator;
  if (Platform.isWindows && env['APPDATA'] != null) {
    return Directory('${env['APPDATA']}${sep}Noted${sep}pages');
  }
  return Directory('${env['HOME'] ?? '.'}$sep.noted${sep}pages');
}

/// The file listing the binder folders the app knows (0026): `binders.json`
/// next to the default pages folder.
File defaultBindersFile() {
  final pages = defaultPagesDirectory().absolute;
  return File('${pages.parent.path}${Platform.pathSeparator}binders.json');
}

/// An operation on the notebook failed; [message] is fit to show the user.
class NotebookException implements Exception {
  const NotebookException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Pages removed by one delete, held in full so the delete can be undone.
class DeletedPages {
  DeletedPages._(this.pages, this.openId, this._location);

  /// The deleted page and its subpages, parents before children.
  final List<NotedPage> pages;

  /// The deleted page that was open, if any.
  final String? openId;

  final String _location;
}

/// Whether a binder's folder could be used.
enum BinderStatus {
  available,

  /// The folder is gone or can't be read, e.g. it is on another device
  /// (0027). It stays in the list.
  unavailable,

  /// The folder's binder file is damaged or from a newer app. It is never
  /// overwritten.
  unreadable,
}

/// One binder the app knows: its folder, metadata and page tree.
class BinderSection {
  BinderSection._(
    this.path,
    this.status, {
    this.binder,
    this.store,
    this.reason,
    this.unreadable = const [],
  }) : tree = PageTree.build(const []);

  /// The binder's folder.
  final String path;
  BinderStatus status;
  Binder? binder;
  PageStore? store;

  /// Why the binder is unavailable or unreadable.
  String? reason;

  /// Page files in the folder that couldn't be read.
  List<UnreadablePage> unreadable;
  PageTree tree;

  /// The latest modification of the binder file or one of its page files.
  DateTime? lastEdited;

  bool get available => status == BinderStatus.available;

  String get title {
    final t = binder?.title.trim() ?? '';
    return t.isNotEmpty ? t : _folderName(path);
  }

  /// `#AARRGGBB`.
  String get color => binder?.color ?? binderPalette.first;
}

String _folderName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _normalizePath(String path) {
  var p = Directory(path).absolute.path;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\')) && !p.endsWith(':\\')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// The location of standalone pages; binder pages use the binder's path.
const String _standalone = '';

/// The open notebook: standalone pages and binders (0026), the page on
/// screen, and autosave.
class Notebook extends ChangeNotifier {
  Notebook(
    this.store,
    this.modules, {
    this.saveDelay = const Duration(milliseconds: 500),
    this.bindersFile,
    this.pickFolder,
    this.storeFactory = PageStore.new,
  });

  /// The store of standalone pages.
  final PageStore store;
  final ModuleRegistry modules;
  final Duration saveDelay;

  /// Where the list of binder folders is kept; null keeps it in memory only.
  final File? bindersFile;

  /// Asks the user for a folder (null if cancelled). Null: no folder picker,
  /// so binders can't be created from the sidebar.
  final Future<String?> Function()? pickFolder;

  /// Makes the store for a binder folder.
  final PageStore Function(Directory) storeFactory;

  /// The active canvas tool, kept when switching pages.
  final CanvasToolSelection tools = CanvasToolSelection();

  final Map<String, PageMeta> _metas = {};
  // Where each page's file lives: _standalone or a binder's path.
  final Map<String, String> _loc = {};
  final Map<String, BinderSection> _binders = {};
  List<UnreadablePage> _unreadable = const [];
  PageTree _tree = PageTree.build(const []);
  CanvasController? _current;
  NotedPage? _pendingSave;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  DeletedPages? _lastDeleted;
  String? _coverPath;
  RawObject _settings = RawObject.empty;
  bool _settingsCorrupt = false;
  bool _disposed = false;

  /// The standalone pages' tree.
  PageTree get tree => _tree;

  /// Standalone page files that couldn't be read. They are listed, never
  /// overwritten.
  List<UnreadablePage> get unreadable => _unreadable;

  /// The binders, in the order of the list.
  List<BinderSection> get binders => List.unmodifiable(_binders.values);

  CanvasController? get current => _current;
  String? get currentId => _current?.page.id;

  /// The binder whose cover is shown instead of a page, if any.
  String? get coverPath => _coverPath;
  BinderSection? get cover => _coverPath == null ? null : _binders[_coverPath];

  /// The tree [id] belongs to.
  PageTree treeOfPage(String id) => _treeOf(_loc[id] ?? _standalone);

  /// The folder of the binder holding [id]; null for a standalone page.
  String? binderOfPage(String id) {
    final l = _loc[id];
    return l == null || l == _standalone ? null : l;
  }

  PageTree _treeOf(String loc) => loc == _standalone ? _tree : (_binders[loc]?.tree ?? _tree);

  PageStore _storeOf(String loc) {
    if (loc == _standalone) return store;
    final s = _binders[loc];
    final st = s?.store;
    if (s == null || !s.available || st == null) {
      throw const NotebookException('That binder is not available.');
    }
    return st;
  }

  /// Reads the folders and opens the first standalone page, creating one if
  /// there is none.
  Future<void> load() async {
    final entries = await store.scan();
    _metas.clear();
    _loc.clear();
    _binders.clear();
    for (final e in entries.whereType<ReadablePage>()) {
      _metas[e.meta.id] = e.meta;
      _loc[e.meta.id] = _standalone;
    }
    _unreadable = entries.whereType<UnreadablePage>().toList();
    for (final path in await _readBinderPaths()) {
      _binders[path] = await _openBinder(path);
    }
    _rebuildTree();
    if (_tree.roots.isEmpty) {
      await createPage();
    } else {
      await open(_tree.roots.first.id);
    }
  }

  Future<void> open(String id) async {
    if (_coverPath != null) {
      _coverPath = null;
      notifyListeners();
    }
    if (id == currentId) return;
    await _closeCurrent();
    final page = await _storeOf(_loc[id] ?? _standalone).load(id);
    _metas[id] = page.meta;
    _current = CanvasController(page, modules, onChanged: _pageChanged);
    _rebuildTree();
  }

  /// Creates a page and opens it. A subpage when [parentId] is given, in its
  /// parent's location; otherwise a top-level page in the binder [binderPath]
  /// (null: standalone). Giving a page its first subpage makes it a divider
  /// (0025).
  Future<String> createPage({String? parentId, String? binderPath}) async {
    final loc = parentId != null ? (_loc[parentId] ?? _standalone) : (binderPath ?? _standalone);
    final st = _storeOf(loc);
    final meta = PageMeta.create(
      id: newId(),
      parentId: parentId,
      title: 'Untitled page',
      order: _treeOf(loc).nextOrder(parentId),
    );
    final page = NotedPage.create(meta);
    await st.save(page);
    _touch(loc);
    _metas[meta.id] = meta;
    _loc[meta.id] = loc;
    await open(meta.id);
    return meta.id;
  }

  Future<void> rename(String id, String title) async {
    final c = _current;
    if (c != null && c.page.id == id) {
      c.updateMeta(c.page.meta.withTitle(title));
    } else {
      final loc = _loc[id] ?? _standalone;
      final page = await _storeOf(loc).load(id);
      final next = page.withMeta(page.meta.withTitle(title));
      await _storeOf(loc).save(next);
      _touch(loc);
      _metas[id] = next.meta;
    }
    _rebuildTree();
  }

  /// Deletes a page and all its subpages, and keeps their full content in
  /// memory so [undoDelete] can bring them back. Only the latest delete can
  /// be undone: the previous one is dropped.
  Future<DeletedPages> delete(String id) async {
    final loc = _loc[id] ?? _standalone;
    final st = _storeOf(loc);
    final ids = [id, ..._treeOf(loc).descendantsOf(id)];
    final openId = ids.contains(currentId) ? currentId : null;
    // Closing saves the open page, so the copies read below are current.
    if (openId != null) await _closeCurrent();
    final pages = [for (final p in ids) await st.load(p)];
    final deleted = DeletedPages._(pages, openId, loc);
    _lastDeleted = deleted;
    for (final p in ids) {
      await st.delete(p);
      _metas.remove(p);
      _loc.remove(p);
    }
    _touch(loc);
    _rebuildTree();
    if (_current == null) await _openFallback(loc);
    return deleted;
  }

  Future<void> _openFallback(String loc) async {
    final own = _treeOf(loc);
    if (own.roots.isNotEmpty) {
      await open(own.roots.first.id);
    } else if (_tree.roots.isNotEmpty) {
      await open(_tree.roots.first.id);
    } else {
      await createPage();
    }
  }

  /// Writes the pages of [deleted] back, with their original ids, content,
  /// parents and order, and reopens the page that was open. Does nothing if
  /// a later delete replaced it, or if the binder is gone.
  Future<void> undoDelete(DeletedPages deleted) async {
    if (!identical(_lastDeleted, deleted)) return;
    _lastDeleted = null;
    final PageStore st;
    try {
      st = _storeOf(deleted._location);
    } on NotebookException {
      return;
    }
    for (final page in deleted.pages) {
      await st.save(page);
      _metas[page.id] = page.meta;
      _loc[page.id] = deleted._location;
    }
    _touch(deleted._location);
    _rebuildTree();
    final reopen = deleted.openId;
    if (reopen != null) await open(reopen);
  }

  /// Drops the in-memory copy of [deleted] (its snackbar went away).
  void discardDeleted(DeletedPages deleted) {
    if (identical(_lastDeleted, deleted)) _lastDeleted = null;
  }

  /// Moves [id] under [parentId] (null: top level) at [index] among that
  /// parent's other children (null: last). Returns false, changing nothing,
  /// if that would put a page under itself or one of its descendants.
  ///
  /// Within a location, siblings are renumbered 0..n-1; only pages whose
  /// parent or order changed are written, and only those two header values
  /// change. If [parentId] is in another location, the page and its subpages
  /// move there (see [moveToLocation]) and a [NotebookException] reports a
  /// failure.
  Future<bool> move(String id, {required String? parentId, int? index}) async {
    final from = _loc[id];
    if (from == null || !_metas.containsKey(id)) return false;
    if (parentId != null) {
      final to = _loc[parentId];
      if (to == null) return false;
      if (to != from) {
        await _moveAcross(id, to, parentId: parentId, index: index);
        return true;
      }
    }
    final tree = _treeOf(from);
    if (tree.wouldCycle(id, parentId)) return false;
    final siblings = [
      for (final s in parentId == null ? tree.roots : tree.childrenOf(parentId))
        if (s.id != id) s.id,
    ];
    siblings.insert((index ?? siblings.length).clamp(0, siblings.length), id);
    for (var i = 0; i < siblings.length; i++) {
      final sid = siblings[i];
      final m = _metas[sid]!;
      final p = sid == id ? parentId : m.parentId;
      if (m.parentId == p && m.order == i) continue;
      await _setPlacement(sid, p, i);
    }
    _rebuildTree();
    return true;
  }

  /// Moves [id] to the top level of the binder [binderPath] (null:
  /// standalone) at [index] (null: last). Moving to another location moves
  /// the page's file and its subpages' files; throws [NotebookException] if
  /// that fails, leaving everything where it was.
  Future<bool> moveToLocation(String id, {String? binderPath, int? index}) async {
    final from = _loc[id];
    final to = binderPath ?? _standalone;
    if (from == null) return false;
    if (to != _standalone && _binders[to] == null) return false;
    if (from == to) return move(id, parentId: null, index: index);
    await _moveAcross(id, to, parentId: null, index: index);
    return true;
  }

  /// Moves [id] next to [targetId], under the same parent, before it or (with
  /// [after]) after it. The target may be in another location.
  Future<bool> moveRelative(String id, String targetId, {required bool after}) async {
    final to = _loc[targetId];
    if (id == targetId || to == null || !_metas.containsKey(id)) return false;
    final tree = _treeOf(to);
    final parent = tree.parentIdOf(targetId);
    if (to == _loc[id] && tree.wouldCycle(id, parent)) return false;
    final others = [for (final s in tree.siblingsOf(targetId)) if (s.id != id) s.id];
    final at = others.indexOf(targetId) + (after ? 1 : 0);
    return move(id, parentId: parent, index: at);
  }

  /// Moves [id] one place up among its siblings.
  Future<bool> moveUp(String id) async {
    final tree = treeOfPage(id);
    final i = tree.siblingsOf(id).indexWhere((s) => s.id == id);
    if (i <= 0) return false;
    return move(id, parentId: tree.parentIdOf(id), index: i - 1);
  }

  /// Moves [id] one place down among its siblings.
  Future<bool> moveDown(String id) async {
    final tree = treeOfPage(id);
    final siblings = tree.siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    if (i < 0 || i >= siblings.length - 1) return false;
    return move(id, parentId: tree.parentIdOf(id), index: i + 1);
  }

  /// Makes [id] the last subpage of the sibling above it.
  Future<bool> indent(String id) async {
    final siblings = treeOfPage(id).siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    if (i <= 0) return false;
    return move(id, parentId: siblings[i - 1].id);
  }

  /// Moves [id] out to its parent's level, right after the parent.
  Future<bool> outdent(String id) async {
    final parent = treeOfPage(id).parentIdOf(id);
    if (parent == null) return false;
    return moveRelative(id, parent, after: true);
  }

  Future<void> _setPlacement(String id, String? parentId, int order) async {
    final c = _current;
    if (c != null && c.page.id == id) {
      // The open page changes through its controller, so the in-memory page
      // and the autosave stay consistent.
      c.updateMeta(c.page.meta.withPlacement(parentId: parentId, order: order));
      _metas[id] = c.page.meta;
    } else {
      final loc = _loc[id] ?? _standalone;
      final st = _storeOf(loc);
      final page = await st.load(id);
      final next = page.withMeta(page.meta.withPlacement(parentId: parentId, order: order));
      await st.save(next);
      _touch(loc);
      _metas[id] = next.meta;
    }
  }

  /// Moves [id] and its subpages to another location: each page file is
  /// written to the target folder and read back to check it, and only when
  /// all of them check out are the source files deleted. On any failure the
  /// target files are removed again and the sources stay as they were.
  Future<void> _moveAcross(String id, String toLoc, {String? parentId, int? index}) async {
    final fromLoc = _loc[id]!;
    final fromStore = _storeOf(fromLoc);
    final toStore = _storeOf(toLoc);
    final ids = [id, ..._treeOf(fromLoc).descendantsOf(id)];
    final reopen = ids.contains(currentId) ? currentId : null;
    // Closing or flushing writes pending edits, so the copies read below are
    // current.
    if (reopen != null) {
      await _closeCurrent();
    } else {
      await flush();
    }
    try {
      final originals = [for (final p in ids) await fromStore.load(p)];
      // Only the moved page's parent and order change; its subpages keep
      // theirs.
      final moved = [
        for (var i = 0; i < originals.length; i++)
          i == 0
              ? originals[i].withMeta(
                  originals[i].meta.withPlacement(
                    parentId: parentId,
                    order: _treeOf(toLoc).nextOrder(parentId),
                  ),
                )
              : originals[i],
      ];

      final written = <String>[];
      Future<void> removeCopies() async {
        for (final w in written) {
          try {
            await toStore.delete(w);
          } on Object catch (e) {
            debugPrint('Removing copy of page $w failed: $e');
          }
        }
      }

      try {
        for (final p in moved) {
          written.add(p.id);
          await toStore.save(p);
          if (await toStore.readText(p.id) != writePage(p)) {
            throw const NotebookException(
              'A page was not copied correctly, so nothing was moved.',
            );
          }
        }
      } on Object catch (e) {
        await removeCopies();
        if (e is NotebookException) rethrow;
        throw NotebookException('Could not move the page: $e');
      }

      final removed = <int>[];
      try {
        for (var i = 0; i < ids.length; i++) {
          await fromStore.delete(ids[i]);
          removed.add(i);
        }
      } on Object catch (e) {
        // Put back what was already deleted, so no page is left twice.
        for (final i in removed) {
          try {
            await fromStore.save(originals[i]);
          } on Object catch (e2) {
            debugPrint('Restoring page ${ids[i]} failed: $e2');
          }
        }
        await removeCopies();
        throw NotebookException('Could not remove the old files, so nothing was moved: $e');
      }

      for (final p in moved) {
        _metas[p.id] = p.meta;
        _loc[p.id] = toLoc;
      }
      _touch(fromLoc);
      _touch(toLoc);
      _rebuildTree();
      if (index != null) await move(id, parentId: parentId, index: index);
    } finally {
      if (reopen != null && _current == null && _loc.containsKey(reopen)) {
        await open(reopen);
      }
    }
  }

  // Binders -----------------------------------------------------------------

  /// Asks for a folder with [pickFolder] and adds it as a binder (see
  /// [addBinder]), then shows its cover. Returns null if cancelled.
  Future<BinderSection?> newBinder() async {
    final pick = pickFolder;
    if (pick == null) return null;
    final path = await pick();
    if (path == null) return null;
    final section = await addBinder(path);
    if (section.available) showCover(section.path);
    return section;
  }

  /// Adds the folder [path] to the binders. A folder that already has a
  /// binder file is opened as it is; otherwise a binder file is created in
  /// it and the page files already there become its pages.
  Future<BinderSection> addBinder(String path) async {
    path = _normalizePath(path);
    final known = _binders[path];
    if (known != null) return known;
    if (path == _normalizePath(store.directory.path)) {
      throw const NotebookException('That folder holds the standalone pages.');
    }
    await flush();
    final section = await _openBinder(path, create: true);
    _binders[path] = section;
    _rebuildTree();
    await _saveBinderPaths();
    return section;
  }

  /// Takes the binder out of the sidebar. Its folder and files stay.
  Future<void> removeBinder(String path) async {
    final section = _binders[path];
    if (section == null) return;
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId);
    if (openHere) await _closeCurrent();
    for (final id in ids) {
      _metas.remove(id);
      _loc.remove(id);
    }
    _binders.remove(path);
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _rebuildTree();
    await _saveBinderPaths();
    if (openHere) await _openFallback(_standalone);
  }

  /// Shows the cover of the available binder [path] instead of a page.
  void showCover(String path) {
    final s = _binders[path];
    if (s == null || !s.available) return;
    _coverPath = path;
    notifyListeners();
  }

  /// Changes cover fields of the binder and writes `noted-binder.json`.
  Future<void> updateBinder(
    String path, {
    String? title,
    String? description,
    String? owner,
    String? color,
  }) async {
    final s = _binders[path];
    var b = s?.binder;
    if (s == null || b == null || !s.available) return;
    final before = b;
    if (title != null && title != b.title) b = b.withTitle(title);
    if (description != null && description != b.description) b = b.withDescription(description);
    if (owner != null && owner != b.owner) b = b.withOwner(owner);
    if (color != null && color != b.color) b = b.withColor(color);
    if (identical(b, before)) return;
    s.binder = b;
    s.lastEdited = DateTime.now();
    notifyListeners();
    final job = _saving.then((_) async {
      final latest = s.binder;
      if (latest != null) await BinderStore(Directory(path)).save(latest);
    }).catchError((Object e) {
      debugPrint('Saving binder $path failed: $e');
    });
    _saving = job;
    await job;
  }

  Future<BinderSection> _openBinder(String path, {bool create = false}) async {
    BinderSection unavailable(String why) =>
        BinderSection._(path, BinderStatus.unavailable, reason: why);
    final dir = Directory(path);
    try {
      if (!await dir.exists()) return unavailable('Folder not found. It may be on another device.');
      final binders = BinderStore(dir);
      var read = await binders.read();
      if (read is BinderMissing) {
        if (!create) return unavailable('No $binderFileName in this folder.');
        read = BinderFound(
          await binders.create(
            Binder.create(
              title: _folderName(path),
              color: binderPalette[_binders.length % binderPalette.length],
            ),
          ),
        );
      }
      if (read is BinderUnreadable) {
        return BinderSection._(path, BinderStatus.unreadable, reason: read.reason);
      }
      final binder = (read as BinderFound).binder;
      final pages = storeFactory(dir);
      final entries = await pages.scan();
      var latest = (await binders.file.lastModified());
      final bad = <UnreadablePage>[...entries.whereType<UnreadablePage>()];
      final section = BinderSection._(
        path,
        BinderStatus.available,
        binder: binder,
        store: pages,
        unreadable: bad,
      );
      for (final e in entries.whereType<ReadablePage>()) {
        if (_metas.containsKey(e.meta.id)) {
          bad.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
          continue;
        }
        _metas[e.meta.id] = e.meta;
        _loc[e.meta.id] = path;
        final m = await File(e.path).lastModified();
        if (m.isAfter(latest)) latest = m;
      }
      section.lastEdited = latest;
      return section;
    } on FileSystemException catch (e) {
      return unavailable('${e.message}${e.path == null ? '' : ': ${e.path}'}');
    }
  }

  void _touch(String loc) {
    if (loc == _standalone) return;
    final s = _binders[loc];
    if (s == null) return;
    s.lastEdited = DateTime.now();
    if (!_disposed) notifyListeners();
  }

  // `binders.json`: {"format":1,"binders":["<folder>", ...]}.
  Future<List<String>> _readBinderPaths() async {
    final f = bindersFile;
    if (f == null) return const [];
    try {
      if (!await f.exists()) return const [];
      _settings = RawObject.parse(await f.readAsString());
      final list = _settings['binders']?.decode();
      return [
        for (final p in list is List ? list : const [])
          if (p is String && p.isNotEmpty) p,
      ];
    } on FormatException {
      _settingsCorrupt = true;
      return const [];
    } on FileSystemException catch (e) {
      debugPrint('Reading ${f.path} failed: $e');
      return const [];
    }
  }

  Future<void> _saveBinderPaths() async {
    final f = bindersFile;
    if (f == null) return;
    final paths = _binders.keys.toList();
    final job = _saving.then((_) async {
      await f.parent.create(recursive: true);
      if (_settingsCorrupt) {
        // Keep the damaged file instead of overwriting it.
        try {
          await f.rename('${f.path}.bad');
        } on FileSystemException catch (e) {
          debugPrint('Keeping ${f.path} failed: $e');
        }
        _settingsCorrupt = false;
      }
      _settings = _settings
          .set('format', RawJson.encode(1))
          .set('binders', RawJson.encode(paths));
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString('${_settings.toRaw().text}\n', flush: true);
      await tmp.rename(f.path);
    }).catchError((Object e) {
      debugPrint('Saving ${f.path} failed: $e');
    });
    _saving = job;
    await job;
  }

  // Autosave ------------------------------------------------------------------

  /// Writes any unsaved change now.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final p = _pendingSave;
    _pendingSave = null;
    if (p != null) _enqueueSave(p);
    await _saving;
  }

  void _pageChanged(NotedPage page) {
    _pendingSave = page;
    if (_metas[page.id] != page.meta) {
      _metas[page.id] = page.meta;
      _rebuildTree();
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  // Saves run one after another, so an older version never lands last.
  void _enqueueSave(NotedPage page) {
    _saving = _saving.then((_) async {
      final loc = _loc[page.id];
      if (loc == null) return;
      await _storeOf(loc).save(page);
      _touch(loc);
    }).catchError((Object e) {
      debugPrint('Saving page ${page.id} failed: $e');
    });
  }

  Future<void> _closeCurrent() async {
    // Leaving a page ends editing, so an empty new box is discarded, not saved.
    final c = _current;
    final editing = c?.editingId;
    if (c != null && editing != null) c.setEditing(editing, false);
    await flush();
    _current?.dispose();
    _current = null;
  }

  void _rebuildTree() {
    final groups = <String, List<PageMeta>>{};
    for (final e in _metas.entries) {
      (groups[_loc[e.key] ?? _standalone] ??= []).add(e.value);
    }
    _tree = PageTree.build(groups[_standalone] ?? const []);
    for (final b in _binders.values) {
      b.tree = PageTree.build(groups[b.path] ?? const []);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _current?.dispose();
    tools.dispose();
    super.dispose();
  }
}
