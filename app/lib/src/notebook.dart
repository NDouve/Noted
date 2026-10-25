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

/// The open notebook: the page tree, the page on screen, and autosave.
class Notebook extends ChangeNotifier {
  Notebook(this.store, this.modules, {this.saveDelay = const Duration(milliseconds: 500)});

  final PageStore store;
  final ModuleRegistry modules;
  final Duration saveDelay;

  final Map<String, PageMeta> _metas = {};
  List<UnreadablePage> _unreadable = const [];
  PageTree _tree = PageTree.build(const []);
  CanvasController? _current;
  NotedPage? _pendingSave;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();

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

  /// Deletes a page and all its subpages.
  Future<void> delete(String id) async {
    final ids = [id, ..._tree.descendantsOf(id)];
    if (ids.contains(currentId)) await _closeCurrent();
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
    super.dispose();
  }
}
