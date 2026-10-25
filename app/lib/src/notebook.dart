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

/// Pages removed by one delete, held in full so the delete can be undone.
class DeletedPages {
  DeletedPages._(this.pages, this.openId);

  /// The deleted page and its subpages, parents before children.
  final List<NotedPage> pages;

  /// The deleted page that was open, if any.
  final String? openId;
}

/// The open notebook: the page tree, the page on screen, and autosave.
class Notebook extends ChangeNotifier {
  Notebook(this.store, this.modules, {this.saveDelay = const Duration(milliseconds: 500)});

  final PageStore store;
  final ModuleRegistry modules;
  final Duration saveDelay;

  /// The active canvas tool, kept when switching pages.
  final CanvasToolSelection tools = CanvasToolSelection();

  final Map<String, PageMeta> _metas = {};
  List<UnreadablePage> _unreadable = const [];
  PageTree _tree = PageTree.build(const []);
  CanvasController? _current;
  NotedPage? _pendingSave;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  DeletedPages? _lastDeleted;

  PageTree get tree => _tree;

  /// Page files that couldn't be read. They are listed, never overwritten.
  List<UnreadablePage> get unreadable => _unreadable;

  CanvasController? get current => _current;
  String? get currentId => _current?.page.id;

  /// Reads the folder and opens the first page, creating one if there is
  /// none.
  Future<void> load() async {
    final entries = await store.scan();
    _metas
      ..clear()
      ..addEntries(entries.whereType<ReadablePage>().map((e) => MapEntry(e.meta.id, e.meta)));
    _unreadable = entries.whereType<UnreadablePage>().toList();
    _rebuildTree();
    if (_tree.roots.isEmpty) {
      await createPage();
    } else {
      await open(_tree.roots.first.id);
    }
  }

  Future<void> open(String id) async {
    if (id == currentId) return;
    await _closeCurrent();
    final page = await store.load(id);
    _metas[id] = page.meta;
    _current = CanvasController(page, modules, onChanged: _pageChanged);
    _rebuildTree();
  }

  /// Creates a page (a subpage when [parentId] is given) and opens it.
  /// Giving a page its first subpage makes it a divider (0025).
  Future<String> createPage({String? parentId}) async {
    final meta = PageMeta.create(
      id: newId(),
      parentId: parentId,
      title: 'Untitled page',
      order: _tree.nextOrder(parentId),
    );
    await store.save(NotedPage.create(meta));
    _metas[meta.id] = meta;
    await open(meta.id);
    return meta.id;
  }

  Future<void> rename(String id, String title) async {
    final c = _current;
    if (c != null && c.page.id == id) {
      c.updateMeta(c.page.meta.withTitle(title));
    } else {
      final page = await store.load(id);
      final next = page.withMeta(page.meta.withTitle(title));
      await store.save(next);
      _metas[id] = next.meta;
    }
    _rebuildTree();
  }

  /// Deletes a page and all its subpages, and keeps their full content in
  /// memory so [undoDelete] can bring them back. Only the latest delete can
  /// be undone: the previous one is dropped.
  Future<DeletedPages> delete(String id) async {
    final ids = [id, ..._tree.descendantsOf(id)];
    final openId = ids.contains(currentId) ? currentId : null;
    // Closing saves the open page, so the copies read below are current.
    if (openId != null) await _closeCurrent();
    final pages = [for (final p in ids) await store.load(p)];
    final deleted = DeletedPages._(pages, openId);
    _lastDeleted = deleted;
    for (final p in ids) {
      await store.delete(p);
      _metas.remove(p);
    }
    _rebuildTree();
    if (_current == null) {
      if (_tree.roots.isEmpty) {
        await createPage();
      } else {
        await open(_tree.roots.first.id);
      }
    }
    return deleted;
  }

  /// Writes the pages of [deleted] back, with their original ids, content,
  /// parents and order, and reopens the page that was open. Does nothing if
  /// a later delete replaced it.
  Future<void> undoDelete(DeletedPages deleted) async {
    if (!identical(_lastDeleted, deleted)) return;
    _lastDeleted = null;
    for (final page in deleted.pages) {
      await store.save(page);
      _metas[page.id] = page.meta;
    }
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
  /// Siblings are renumbered 0..n-1; only pages whose parent or order
  /// changed are written, and only those two header values change.
  Future<bool> move(String id, {required String? parentId, int? index}) async {
    if (_tree[id] == null || _tree.wouldCycle(id, parentId)) return false;
    if (parentId != null && _tree[parentId] == null) return false;
    final siblings = [
      for (final s in parentId == null ? _tree.roots : _tree.childrenOf(parentId))
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

  /// Moves [id] next to [targetId], under the same parent, before it or (with
  /// [after]) after it.
  Future<bool> moveRelative(String id, String targetId, {required bool after}) async {
    if (id == targetId || _tree[targetId] == null) return false;
    final parent = _tree.parentIdOf(targetId);
    if (_tree.wouldCycle(id, parent)) return false;
    final others = [for (final s in _tree.siblingsOf(targetId)) if (s.id != id) s.id];
    final at = others.indexOf(targetId) + (after ? 1 : 0);
    return move(id, parentId: parent, index: at);
  }

  /// Moves [id] one place up among its siblings.
  Future<bool> moveUp(String id) async {
    final i = _tree.siblingsOf(id).indexWhere((s) => s.id == id);
    if (i <= 0) return false;
    return move(id, parentId: _tree.parentIdOf(id), index: i - 1);
  }

  /// Moves [id] one place down among its siblings.
  Future<bool> moveDown(String id) async {
    final siblings = _tree.siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    if (i < 0 || i >= siblings.length - 1) return false;
    return move(id, parentId: _tree.parentIdOf(id), index: i + 1);
  }

  /// Makes [id] the last subpage of the sibling above it.
  Future<bool> indent(String id) async {
    final siblings = _tree.siblingsOf(id);
    final i = siblings.indexWhere((s) => s.id == id);
    if (i <= 0) return false;
    return move(id, parentId: siblings[i - 1].id);
  }

  /// Moves [id] out to its parent's level, right after the parent.
  Future<bool> outdent(String id) async {
    final parent = _tree.parentIdOf(id);
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
      final page = await store.load(id);
      final next = page.withMeta(page.meta.withPlacement(parentId: parentId, order: order));
      await store.save(next);
      _metas[id] = next.meta;
    }
  }

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
    _saving = _saving.then((_) => store.save(page)).catchError((Object e) {
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
    _tree = PageTree.build(_metas.values);
    notifyListeners();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _current?.dispose();
    tools.dispose();
    super.dispose();
  }
}
