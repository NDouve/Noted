// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'app_settings.dart';
import 'recovery_store.dart';

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

/// The built-in default folder for new binders: `binders` next to the default
/// pages folder (`%APPDATA%\Noted\binders` on Windows, `~/.noted/binders`
/// elsewhere).
Directory defaultBindersDirectory() {
  final pages = defaultPagesDirectory().absolute;
  return Directory('${pages.parent.path}${Platform.pathSeparator}binders');
}

/// A folder name for a binder called [name]: characters that are invalid in
/// Windows file names become `_`, trailing dots and spaces go, and reserved
/// device names get a `_` appended. An empty result is "New binder".
String binderFolderName(String name) {
  var n = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
  n = n.replaceAll(RegExp(r'[. ]+$'), '');
  if (n.isEmpty) return 'New binder';
  final stem = n.split('.').first.trim().toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) n = '${n}_';
  return n;
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

/// A save failed because the page's folder isn't there.
class FolderUnavailableException extends NotebookException {
  const FolderUnavailableException() : super('That folder was not found.');
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
    this.missing = false,
  }) : tree = PageTree.build(const []);

  /// The binder's folder.
  final String path;
  BinderStatus status;
  Binder? binder;
  PageStore? store;

  /// Why the binder is unavailable or unreadable.
  String? reason;

  /// The binder's folder isn't there (e.g. it is on another device). The app
  /// looks for it again. While it is away the pages stay listed, read-only,
  /// and nothing is written to the folder.
  bool missing;

  /// Page files in the folder that couldn't be read.
  List<UnreadablePage> unreadable;
  PageTree tree;

  /// The latest modification of the binder file or one of its page files.
  DateTime? lastEdited;

  bool get available => status == BinderStatus.available;

  /// The binder file can't be read: the pages are listed and can be viewed,
  /// but nothing in the binder can be changed.
  bool get readOnly => status == BinderStatus.unreadable;

  String get title {
    final t = binder?.title.trim() ?? '';
    return t.isNotEmpty ? t : _folderName(path);
  }

  /// `#AARRGGBB`.
  String get color => binder?.color ?? binderPalette.first;
}

/// An extra folder of standalone pages besides the default one (0027). Its
/// pages appear in the "Pages" section.
class StandaloneFolder {
  StandaloneFolder._(
    this.path, {
    required this.available,
    this.store,
    this.reason,
    this.unreadable = const [],
    this.missing = false,
  });

  /// The folder.
  final String path;

  /// False if the folder is gone or can't be used, e.g. on another device.
  bool available;

  /// The folder isn't there (as opposed to being unusable). The app looks
  /// for it again, and uses it when it comes back.
  bool missing;
  PageStore? store;

  /// Why the folder is unavailable.
  String? reason;

  /// Page files in the folder that couldn't be read.
  List<UnreadablePage> unreadable;

  String get name => _folderName(path);
}

/// A template found in a templates folder.
class TemplateItem {
  const TemplateItem(this.template, this.path, this.binderPath);

  final NotedTemplate template;

  /// The template file.
  final String path;

  /// The binder the template belongs to; null for an app-wide template.
  final String? binderPath;
}

/// A template file that can't be read. It is listed and never touched.
class UnreadableTemplateItem {
  const UnreadableTemplateItem(this.path, this.reason, this.binderPath);

  final String path;
  final String reason;
  final String? binderPath;
}

/// The templates available for one use.
class TemplateListing {
  const TemplateListing(this.items, this.unreadable);

  final List<TemplateItem> items;
  final List<UnreadableTemplateItem> unreadable;

  bool get isEmpty => items.isEmpty && unreadable.isEmpty;
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
    this.watchFiles = false,
    this.watchDebounce = const Duration(milliseconds: 300),
    this.deviceName,
    this.templatesDirectory,
    this.folderCheckInterval = const Duration(seconds: 3),
    this.recoveryDirectory,
    this.settings,
  });

  /// This device's settings; they hold the default page and binder folders.
  /// Null: the built-in defaults.
  final AppSettings? settings;

  // Which title field should take the caret next: a page id, or
  // `cover:<binder path>`. Set after creating a page or binder.
  String? _titleFocus;

  /// Asks the title field of [target] (a page id, or `cover:<binder path>`)
  /// to take focus when it is shown.
  void requestTitleFocus(String target) => _titleFocus = target;

  /// True once if the title field of [target] was asked to take focus.
  bool takeTitleFocus(String target) {
    if (_titleFocus != target) return false;
    _titleFocus = null;
    return true;
  }

  /// Where edits that can't be saved are kept (see [RecoveryStore]). Null:
  /// `recovery` next to [bindersFile]; with neither, nothing is kept.
  final Directory? recoveryDirectory;

  RecoveryStore? get _recovery {
    final d = recoveryDirectory ?? (bindersFile == null ? null : defaultRecoveryDirectory(bindersFile!));
    return d == null ? null : RecoveryStore(d);
  }

  List<String> _recoveryProblems = const [];

  /// Recovery files that couldn't be read. They are kept, never deleted.
  List<String> get recoveryProblems => _recoveryProblems;

  List<UnreadablePage> _recoveryDamaged = const [];

  /// [recoveryProblems] as sidebar entries (path and reason). They stay
  /// until fixed or removed outside the app.
  List<UnreadablePage> get recoveryDamaged => _recoveryDamaged;

  /// The recovery entries and unreadable recovery files waiting now.
  Future<RecoveryListing> pendingRecovery() async =>
      await _recovery?.list() ?? const RecoveryListing([], []);

  /// How often, with [watchFiles] on, the standalone folders are checked for
  /// having disappeared or come back (a watcher can't watch a folder that
  /// isn't there). [Duration.zero] turns the timer off; [checkFolders] still
  /// works.
  final Duration folderCheckInterval;

  /// The folder of app-wide templates. Null: `templates` next to
  /// [bindersFile]; with neither, templates can't be saved.
  final Directory? templatesDirectory;

  /// This computer's name, stamped on box content written here (0020).
  final String? deviceName;

  /// Watch the storage folders for page files changed by someone else, for
  /// example a sync client (0020). Off by default; the app turns it on.
  final bool watchFiles;

  /// How long a file must stay quiet before a change to it is looked at.
  final Duration watchDebounce;

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
  // Extra standalone folders by path; their pages' location is that path.
  final Map<String, StandaloneFolder> _folders = {};
  List<UnreadablePage> _unreadable = const [];
  PageTree _tree = PageTree.build(const []);
  CanvasController? _current;
  // The open page as last read from or written to disk: the base of the
  // three-way merge when its file changes (0020).
  NotedPage? _base;
  // The exact text last written or read for each page file (by path key), so
  // the app's own writes aren't taken for outside changes.
  final Map<String, String> _known = {};
  // Page id of each page file (by path key).
  final Map<String, String> _pathId = {};
  // Pages with a conflicted box (0020).
  final Set<String> _conflicts = {};
  // The exact text last written or read for each binder file (by the key of
  // the binder's folder).
  final Map<String, String> _binderText = {};
  // Conflict copies found by a scan, to be merged once the folders are set up.
  final List<String> _pendingCopies = [];
  final Map<String, StreamSubscription<FileSystemEvent>> _watchers = {};
  final Map<String, Timer> _debounce = {};
  Future<void> _checking = Future.value();
  NotedPage? _pendingSave;
  Timer? _saveTimer;
  Future<void> _saving = Future.value();
  DeletedPages? _lastDeleted;
  String? _coverPath;
  RawObject _settings = RawObject.empty;
  bool _settingsCorrupt = false;
  bool _disposed = false;
  Timer? _folderTimer;
  // The default folder disappeared while the app was running.
  bool _defaultGone = false;
  // The location of the open page when that folder went away: the page stays
  // open, read-only, although it is no longer in the tree. And why the open
  // page is read-only now.
  String? _orphanLoc;
  String? _readOnlyReason;

  /// The standalone pages' tree.
  PageTree get tree => _tree;

  /// False if the default folder of standalone pages disappeared while the app
  /// was running. Its pages are gone from the tree until it comes back.
  bool get defaultFolderAvailable => !_defaultGone;

  /// Why the open page can't be edited, or null if it can. The page is shown
  /// read-only when its binder's file can't be read or its folder isn't
  /// available.
  String? get readOnlyReason => _readOnlyReason;

  /// Whether the page [id] can't be changed, moved, renamed or deleted: it is
  /// in a binder whose file can't be read, or in a folder that isn't there.
  bool isReadOnlyPage(String id) {
    final loc = _loc[id];
    return loc != null && _isLocked(loc);
  }

  // A location whose files must not be written.
  bool _isLocked(String loc) {
    if (loc == _standalone) return _defaultGone;
    final f = _folders[loc];
    if (f != null) return !f.available;
    final s = _binders[loc];
    return s == null || !s.available;
  }

  String _lockedMessage(String loc) {
    final s = _binders[loc];
    if (s != null && s.readOnly) {
      return "This binder's file can't be read, so its pages are read-only.";
    }
    if (s != null) return 'That binder is not available.';
    return 'That folder is not available.';
  }

  void _assertWritable(String loc) {
    if (_isLocked(loc)) throw NotebookException(_lockedMessage(loc));
  }

  /// Standalone page files that couldn't be read. They are listed, never
  /// overwritten.
  List<UnreadablePage> get unreadable => [
    ..._unreadable,
    for (final f in _folders.values) ...f.unreadable,
  ];

  /// The binders, in the order of the list.
  List<BinderSection> get binders => List.unmodifiable(_binders.values);

  /// The extra standalone folders, in the order of the list.
  List<StandaloneFolder> get standaloneFolders => List.unmodifiable(_folders.values);

  /// The default folder of standalone pages.
  String get defaultFolderPath => _normalizePath(store.directory.path);

  /// The folder a new top-level standalone page goes to: the "Default page
  /// folder" setting, or the built-in default folder ([defaultFolderPath]).
  String get newPageFolderPath {
    final s = settings?.defaultPageFolder;
    return s == null ? defaultFolderPath : _normalizePath(s);
  }

  /// The built-in default folder for new binders: `binders` next to the
  /// settings file.
  String get builtinBinderFolderPath {
    final parent = bindersFile?.absolute.parent ?? store.directory.absolute.parent;
    return _normalizePath('${parent.path}${Platform.pathSeparator}binders');
  }

  /// The folder new binders are created in (one subfolder per binder): the
  /// "Default binder folder" setting, or [builtinBinderFolderPath].
  String get defaultBinderFolderPath {
    final s = settings?.defaultBinderFolder;
    return s == null ? builtinBinderFolderPath : _normalizePath(s);
  }

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
    return l == null || _isStandaloneLoc(l) ? null : l;
  }

  // Standalone pages from every standalone folder share one tree.
  bool _isStandaloneLoc(String loc) => loc == _standalone || _folders.containsKey(loc);

  PageTree _treeOf(String loc) =>
      _isStandaloneLoc(loc) ? _tree : (_binders[loc]?.tree ?? _tree);

  PageStore _storeOf(String loc) {
    if (loc == _standalone) return store;
    final f = _folders[loc];
    if (f != null) {
      final st = f.store;
      if (!f.available || st == null) {
        throw const NotebookException('That folder is not available.');
      }
      return st;
    }
    // A binder whose file can't be read keeps its store, for reading.
    final st = _binders[loc]?.store;
    if (st == null) throw const NotebookException('That binder is not available.');
    return st;
  }

  /// Reads the folders and opens the first standalone page, creating one if
  /// there is none.
  Future<void> load() async {
    final entries = await store.scan();
    _metas.clear();
    _loc.clear();
    _binders.clear();
    _folders.clear();
    _defaultGone = false;
    _adoptDefault(entries);
    for (final path in await _readBinderPaths()) {
      _binders[path] = await _openBinder(path);
    }
    // A default page folder chosen in the settings is a standalone folder in
    // use, so the pages already there are listed.
    final chosen = settings?.defaultPageFolder;
    for (final raw in [..._readFolderPaths(), ?chosen]) {
      final path = _normalizePath(raw);
      if (path == defaultFolderPath || _folders.containsKey(path)) continue;
      if (_binders.keys.any((b) => _key(b) == _key(path))) continue;
      _folders[path] = await _openFolder(path);
    }
    _rebuildTree();
    _syncWatchers();
    _startFolderTimer();
    await _mergePendingCopies();
    await _recoverPending();
    if (_tree.roots.isEmpty) {
      await _createFallbackPage();
    } else {
      await open(_tree.roots.first.id);
    }
  }

  // A page for an empty notebook: in the default page folder, or in the
  // built-in folder if the chosen one can't be used.
  Future<void> _createFallbackPage() async {
    try {
      await createPage();
    } on NotebookException {
      if (_key(newPageFolderPath) == _key(defaultFolderPath)) rethrow;
      await createPage(folderPath: defaultFolderPath);
    }
  }

  // The pages found in the default folder.
  void _adoptDefault(List<PageEntry> entries) {
    for (final e in entries.whereType<ReadablePage>()) {
      _metas[e.meta.id] = e.meta;
      _loc[e.meta.id] = _standalone;
      _pathId[_key(e.path)] = e.meta.id;
      if (e.conflicted) _conflicts.add(e.meta.id);
    }
    _unreadable = entries.whereType<UnreadablePage>().toList();
    _pendingCopies.addAll(entries.whereType<ConflictCopyPage>().map((c) => c.path));
  }

  Future<void> open(String id) async {
    if (_coverPath != null) {
      _coverPath = null;
      notifyListeners();
    }
    if (id == currentId) return;
    // A page of a binder whose folder is away can't be read.
    if (_binders[_loc[id]]?.missing ?? false) {
      throw const NotebookException('That binder is not available.');
    }
    await _closeCurrent();
    final st = _storeOf(_loc[id] ?? _standalone);
    final text = await st.readText(id);
    final page = readPage(text);
    _known[_key(st.pathFor(id))] = text;
    _base = page;
    _metas[id] = page.meta;
    _setConflict(id, hasConflicts(page));
    _current = CanvasController(
      page,
      modules,
      onChanged: _pageChanged,
      deviceName: deviceName,
    );
    _syncReadOnly();
    _rebuildTree();
  }

  // Makes the open page read-only if its location can't be written, and
  // writable again when it can.
  void _syncReadOnly() {
    final c = _current;
    String? why;
    if (c != null) {
      final loc = _loc[c.page.id];
      if (loc == null) {
        why = _orphanLoc == null ? null : "This page's folder isn't available, so it is read-only.";
      } else if (_isLocked(loc)) {
        why = _binders[loc]?.readOnly ?? false
            ? "This binder's file can't be read, so this page is read-only."
            : "This page's folder isn't available, so it is read-only.";
      }
      c.readOnly = why != null;
    }
    if (why != _readOnlyReason) {
      _readOnlyReason = why;
      if (!_disposed) notifyListeners();
    }
  }

  /// Creates a page and opens it. A subpage when [parentId] is given, in its
  /// parent's location; otherwise a top-level page in the binder [binderPath]
  /// (null: standalone). Giving a page its first subpage makes it a divider
  /// (0025).
  ///
  /// A top-level standalone page goes to the default folder, or to
  /// [folderPath] (remembered as a standalone folder, see
  /// [addStandaloneFolder]).
  ///
  /// With [focusTitle] the page's title field is asked to take the caret when
  /// the page is shown (see [requestTitleFocus]).
  Future<String> createPage({
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle = false,
  }) async {
    final loc = await _placeFor(parentId, binderPath, folderPath);
    final meta = PageMeta.create(
      id: newId(),
      parentId: parentId,
      title: 'Untitled page',
      order: _treeOf(loc).nextOrder(parentId),
    );
    final page = NotedPage.create(meta);
    await _write(loc, page);
    _touch(loc);
    _metas[meta.id] = meta;
    _loc[meta.id] = loc;
    if (focusTitle) requestTitleFocus(meta.id);
    await open(meta.id);
    return meta.id;
  }

  // The location a new page goes to; throws if it is not available.
  Future<String> _placeFor(String? parentId, String? binderPath, String? folderPath) async {
    final String loc;
    if (parentId != null) {
      loc = _loc[parentId] ?? _standalone;
    } else if (binderPath != null) {
      loc = binderPath;
    } else if (folderPath != null) {
      loc = await addStandaloneFolder(folderPath);
    } else {
      // The default page folder. Unlike a chosen folder, the built-in one is
      // created when it is missing (see PageStore.scan).
      loc = await addStandaloneFolder(newPageFolderPath);
    }
    _assertWritable(loc); // throws if the binder or folder can't be written
    _storeOf(loc);
    return loc;
  }

  Future<void> rename(String id, String title) async {
    _assertWritable(_loc[id] ?? _standalone);
    final c = _current;
    if (c != null && c.page.id == id) {
      c.updateMeta(c.page.meta.withTitle(title));
    } else {
      final loc = _loc[id] ?? _standalone;
      final page = await _storeOf(loc).load(id);
      final next = page.withMeta(page.meta.withTitle(title));
      await _write(loc, next);
      _touch(loc);
      _metas[id] = next.meta;
    }
    _rebuildTree();
  }

  /// Chooses the background of page [id]. The open page changes through its
  /// controller (one undo step, autosaved); another page is loaded, changed
  /// in its header only, and saved.
  Future<void> setBackground(String id, PageBackground background) async {
    _assertWritable(_loc[id] ?? _standalone);
    final c = _current;
    if (c != null && c.page.id == id) {
      c.setBackground(background);
      return;
    }
    final loc = _loc[id] ?? _standalone;
    final page = await _storeOf(loc).load(id);
    final meta = page.meta.withBackground(background);
    if (identical(meta, page.meta)) return;
    final next = page.withMeta(meta);
    await _write(loc, next);
    _touch(loc);
    _metas[id] = next.meta;
    _rebuildTree();
  }

  /// Deletes a page and all its subpages, and keeps their full content in
  /// memory so [undoDelete] can bring them back. Only the latest delete can
  /// be undone: the previous one is dropped.
  Future<DeletedPages> delete(String id) async {
    final loc = _loc[id] ?? _standalone;
    _assertWritable(loc);
    final st = _storeOf(loc);
    final ids = [id, ..._treeOf(loc).descendantsOf(id)];
    final openId = ids.contains(currentId) ? currentId : null;
    // Closing saves the open page, so the copies read below are current.
    if (openId != null) await _closeCurrent();
    final pages = [for (final p in ids) await st.load(p)];
    final deleted = DeletedPages._(pages, openId, loc);
    _lastDeleted = deleted;
    for (final p in ids) {
      await _delete(loc, p);
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
      await _createFallbackPage();
    }
  }

  /// Writes the pages of [deleted] back, with their original ids, content,
  /// parents and order, and reopens the page that was open. Does nothing if
  /// a later delete replaced it, or if the binder is gone.
  Future<void> undoDelete(DeletedPages deleted) async {
    if (!identical(_lastDeleted, deleted)) return;
    _lastDeleted = null;
    try {
      _assertWritable(deleted._location);
      _storeOf(deleted._location);
    } on NotebookException {
      return;
    }
    for (final page in deleted.pages) {
      await _write(deleted._location, page);
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
  /// change. If [parentId] is in another location (a binder, or another
  /// standalone folder), the page and its subpages move there (see
  /// [moveToLocation]) and a [NotebookException] reports a failure.
  Future<bool> move(String id, {required String? parentId, int? index}) async {
    final from = _loc[id];
    if (from == null || !_metas.containsKey(id)) return false;
    var to = from;
    if (parentId != null) {
      final parentLoc = _loc[parentId];
      if (parentLoc == null) return false;
      to = parentLoc;
    }
    return _place(id, to, parentId: parentId, index: index);
  }

  // Puts [id] under [parentId] in the location [to], which may be another
  // location than the page's own.
  Future<bool> _place(String id, String to, {required String? parentId, int? index}) async {
    final from = _loc[id];
    if (from == null || !_metas.containsKey(id)) return false;
    _assertWritable(from);
    if (to != from) {
      _assertWritable(to);
      // Standalone folders share one tree.
      if (_isStandaloneLoc(from) && _isStandaloneLoc(to) && _tree.wouldCycle(id, parentId)) {
        return false;
      }
      await _moveAcross(id, to, parentId: parentId, index: index);
      return true;
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
    // "Pages" is one section: dropping a page from another standalone folder
    // there only makes it a top-level page of its own folder.
    if (from == to || (to == _standalone && _isStandaloneLoc(from))) {
      return move(id, parentId: null, index: index);
    }
    await _moveAcross(id, to, parentId: null, index: index);
    return true;
  }

  /// Moves [id] next to [targetId], under the same parent, before it or (with
  /// [after]) after it. The target may be in another location (a binder or
  /// another standalone folder): the page then moves to the target's location.
  Future<bool> moveRelative(String id, String targetId, {required bool after}) async {
    final to = _loc[targetId];
    final from = _loc[id];
    if (id == targetId || to == null || from == null || !_metas.containsKey(id)) return false;
    final tree = _treeOf(to);
    final parent = tree.parentIdOf(targetId);
    final sameTree = to == from || (_isStandaloneLoc(from) && _isStandaloneLoc(to));
    if (sameTree && tree.wouldCycle(id, parent)) return false;
    final others = [for (final s in tree.siblingsOf(targetId)) if (s.id != id) s.id];
    final at = others.indexOf(targetId) + (after ? 1 : 0);
    return _place(id, to, parentId: parent, index: at);
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
      await _write(loc, next);
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
    _assertWritable(fromLoc);
    _assertWritable(toLoc);
    final fromStore = _storeOf(fromLoc);
    final toStore = _storeOf(toLoc);
    // The page and the subpages stored with it (standalone folders share a
    // tree, so a subpage kept in another folder stays where it is).
    final tree = _treeOf(fromLoc);
    final ids = <String>[id];
    void collect(String parent) {
      for (final c in tree.childrenOf(parent)) {
        if (_loc[c.id] != fromLoc) continue;
        ids.add(c.id);
        collect(c.id);
      }
    }

    collect(id);
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
            await _delete(toLoc, w);
          } on Object catch (e) {
            debugPrint('Removing copy of page $w failed: $e');
          }
        }
      }

      try {
        for (final p in moved) {
          written.add(p.id);
          await _write(toLoc, p);
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
          await _delete(fromLoc, ids[i]);
          removed.add(i);
        }
      } on Object catch (e) {
        // Put back what was already deleted, so no page is left twice.
        for (final i in removed) {
          try {
            await _write(fromLoc, originals[i]);
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

  /// Creates a binder at once in a new subfolder of the default binder
  /// folder ([defaultBinderFolderPath]) named after [name] (see
  /// [binderFolderName]; a number is added if the folder exists), shows its
  /// cover and asks for its title field to take focus.
  ///
  /// The built-in default folder is created if it is missing. A default
  /// folder the user chose is never created: a missing one throws a
  /// [NotebookException].
  Future<BinderSection> createBinder({String name = 'New binder'}) async {
    final root = defaultBinderFolderPath;
    final builtin = settings?.defaultBinderFolder == null || _key(root) == _key(builtinBinderFolderPath);
    try {
      if (builtin) {
        await Directory(root).create(recursive: true);
      } else if (!await Directory(root).exists()) {
        throw const NotebookException(
          'The default binder folder was not found. Choose another one in Settings.',
        );
      }
      final base = binderFolderName(name);
      for (var n = 1;; n++) {
        final path = _normalizePath(
          '$root${Platform.pathSeparator}${n == 1 ? base : '$base $n'}',
        );
        if (_binders.keys.any((b) => _key(b) == _key(path)) ||
            await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
          continue;
        }
        await Directory(path).create();
        final section = await addBinder(path);
        if (section.available) {
          requestTitleFocus('cover:${section.path}');
          showCover(section.path);
        }
        return section;
      }
    } on FileSystemException catch (e) {
      throw NotebookException('Could not create the binder: ${e.message}');
    }
  }

  /// Asks for a folder with [pickFolder] and adds it as a binder (see
  /// [addBinder]), then shows its cover. A folder that has a binder is
  /// opened. Returns null if cancelled.
  Future<BinderSection?> newBinderInFolder() async {
    final pick = pickFolder;
    if (pick == null) return null;
    final path = await pick();
    if (path == null) return null;
    final section = await addBinder(path);
    if (section.available) showCover(section.path);
    return section;
  }

  /// Asks for a folder with [pickFolder] and opens the binder in it, then
  /// shows its cover. A folder without a binder file is refused. Returns
  /// null if cancelled.
  Future<BinderSection?> openBinder() async {
    final pick = pickFolder;
    if (pick == null) return null;
    final path = await pick();
    if (path == null) return null;
    if (!await BinderStore(Directory(_normalizePath(path))).file.exists()) {
      throw const NotebookException('That folder has no binder. Use "New binder in another folder…" to make one.');
    }
    final section = await addBinder(path);
    if (section.available) showCover(section.path);
    return section;
  }

  /// Sets the default page folder: the folder must exist and not hold a
  /// binder. It becomes a standalone folder in use (so its pages are listed),
  /// and new top-level pages go there. Pages in the old default stay listed.
  Future<void> setDefaultPageFolder(String path) async {
    final s = settings;
    if (s == null) return;
    final normal = await checkStandaloneFolder(path);
    await addStandaloneFolder(normal);
    s.defaultPageFolder = normal;
    notifyListeners();
  }

  /// Sets the default binder folder, which must exist.
  Future<void> setDefaultBinderFolder(String path) async {
    final s = settings;
    if (s == null) return;
    final normal = _normalizePath(path);
    if (!await Directory(normal).exists()) {
      throw const NotebookException('That folder was not found.');
    }
    s.defaultBinderFolder = normal;
    notifyListeners();
  }

  /// Moves the page [id] and its subpages to the standalone folder [path]
  /// (made a standalone folder in use), as a top-level page there. Uses the
  /// same copy, verify, delete algorithm as other moves; throws a
  /// [NotebookException] on failure with the sources left in place. A binder
  /// folder is refused. Returns false if the page is in that folder already.
  Future<bool> moveToFolder(String id, String path) async {
    final from = _loc[id];
    if (from == null) return false;
    final to = await addStandaloneFolder(path);
    if (to == from) return false;
    await _moveAcross(id, to, parentId: null);
    return true;
  }

  /// Adds the folder [path] to the binders. A folder that already has a
  /// binder file is opened as it is; otherwise a binder file is created in
  /// it and the page files already there become its pages.
  Future<BinderSection> addBinder(String path) async {
    path = _normalizePath(path);
    final known = _binders[path];
    if (known != null) return known;
    if (path == defaultFolderPath || _folders.containsKey(path)) {
      throw const NotebookException('That folder holds the standalone pages.');
    }
    await flush();
    final section = await _openBinder(path, create: true);
    _binders[path] = section;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    await _mergePendingCopies();
    return section;
  }

  // Standalone folders ---------------------------------------------------------

  /// Checks that [path] can hold standalone pages and returns it in its
  /// normal form. Throws [NotebookException] for a folder that is a binder
  /// (listed, or with a binder file).
  Future<String> checkStandaloneFolder(String path) async {
    path = _normalizePath(path);
    final isBinder =
        _binders.keys.any((b) => _key(b) == _key(path)) ||
        await BinderStore(Directory(path)).file.exists();
    if (isBinder) {
      throw const NotebookException(
        'That folder holds a binder. Choose another folder for standalone pages.',
      );
    }
    if (!await Directory(path).exists()) {
      throw const NotebookException('That folder was not found.');
    }
    return path;
  }

  /// Makes [path] a folder of standalone pages and remembers it. Returns the
  /// location key: '' for the default folder. Does nothing if the folder is
  /// known already. Throws [NotebookException] if the folder can't be used
  /// (see [checkStandaloneFolder]).
  Future<String> addStandaloneFolder(String path) async {
    path = _normalizePath(path);
    if (_key(path) == _key(defaultFolderPath)) return _standalone;
    final known = _folders.keys.where((f) => _key(f) == _key(path)).firstOrNull;
    if (known != null) {
      if (_folders[known]!.available) return known;
      throw const NotebookException('That folder is not available.');
    }
    await checkStandaloneFolder(path);
    await flush();
    final folder = await _openFolder(path);
    if (!folder.available) throw NotebookException(folder.reason ?? 'That folder is not available.');
    _folders[path] = folder;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    await _mergePendingCopies();
    return path;
  }

  /// Takes the folder out of the list. Its files stay where they are.
  Future<void> removeStandaloneFolder(String path) async {
    final folder = _folders[path];
    if (folder == null) return;
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId) || _orphanLoc == path;
    if (openHere) await _closeCurrent();
    for (final id in ids) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    for (final e in _pathId.entries.toList()) {
      if (ids.contains(e.value)) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
    _folders.remove(path);
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
    if (openHere) await _openFallback(_standalone);
  }

  Future<StandaloneFolder> _openFolder(String path) async {
    StandaloneFolder unavailable(String why, {bool missing = false}) =>
        StandaloneFolder._(path, available: false, reason: why, missing: missing);
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        return unavailable('Folder not found. It may be on another device.', missing: true);
      }
      if (await BinderStore(dir).file.exists()) return unavailable('This folder holds a binder.');
      final pages = storeFactory(dir);
      final entries = await pages.scan();
      _pendingCopies.addAll(entries.whereType<ConflictCopyPage>().map((c) => c.path));
      final bad = <UnreadablePage>[...entries.whereType<UnreadablePage>()];
      for (final e in entries.whereType<ReadablePage>()) {
        if (_metas.containsKey(e.meta.id)) {
          bad.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
          continue;
        }
        _metas[e.meta.id] = e.meta;
        _loc[e.meta.id] = path;
        _pathId[_key(e.path)] = e.meta.id;
        if (e.conflicted) _conflicts.add(e.meta.id);
      }
      return StandaloneFolder._(path, available: true, store: pages, unreadable: bad);
    } on FileSystemException catch (e) {
      return unavailable('${e.message}${e.path == null ? '' : ': ${e.path}'}');
    }
  }

  // Templates ------------------------------------------------------------------

  /// The folder of app-wide templates, or null if there is no place for it.
  Directory? get appTemplatesDirectory {
    final d = templatesDirectory;
    if (d != null) return d;
    final f = bindersFile;
    return f == null ? null : Directory('${f.parent.path}${Platform.pathSeparator}templates');
  }

  Directory _templatesDirFor(String? binderPath) {
    if (binderPath != null) {
      return Directory('$binderPath${Platform.pathSeparator}templates');
    }
    final d = appTemplatesDirectory;
    if (d == null) throw const NotebookException('There is no folder for app-wide templates.');
    return d;
  }

  /// The templates of [kind] that can be used in the binder [binderPath]
  /// (null: not in a binder): the binder's own and the app-wide ones. Files
  /// that can't be read are listed apart and never touched.
  Future<TemplateListing> listTemplates(TemplateKind kind, {String? binderPath}) async {
    final items = <TemplateItem>[];
    final bad = <UnreadableTemplateItem>[];
    final scopes = <String?>[
      if (binderPath != null && kind == TemplateKind.page) binderPath,
      if (appTemplatesDirectory != null) null,
    ];
    for (final scope in scopes) {
      final entries = await TemplateStore(_templatesDirFor(scope)).scan();
      for (final e in entries) {
        switch (e) {
          case ReadableTemplate():
            if (e.template.kind == kind) items.add(TemplateItem(e.template, e.path, scope));
          case UnreadableTemplate():
            bad.add(UnreadableTemplateItem(e.path, e.reason, scope));
        }
      }
    }
    return TemplateListing(items, bad);
  }

  /// Saves the page [pageId], as it is now, as a template named [name]:
  /// in its binder's templates if [inBinder], otherwise app-wide. Subpages
  /// are not included.
  Future<NotedTemplate> savePageAsTemplate(
    String pageId, {
    required String name,
    bool inBinder = false,
  }) async {
    final loc = _loc[pageId];
    if (loc == null) throw const NotebookException('That page is not available.');
    final binder = binderOfPage(pageId);
    if (inBinder && binder == null) {
      throw const NotebookException('Only a page in a binder can be saved to the binder.');
    }
    if (inBinder) _assertWritable(binder!); // the binder's folder is not written when damaged
    final dir = _templatesDirFor(inBinder ? binder : null);
    await flush();
    final page = await _storeOf(loc).load(pageId);
    final title = page.meta.title.trim();
    final template = NotedTemplate.forPage(
      name: name.trim().isNotEmpty ? name.trim() : (title.isEmpty ? 'Untitled page' : title),
      page: page,
    );
    await _saveTemplate(dir, template);
    return template;
  }

  /// Saves the settings and whole page tree of the binder [path] as an
  /// app-wide binder template.
  Future<NotedTemplate> saveBinderAsTemplate(String path, {required String name}) async {
    final section = _binders[path];
    final binder = section?.binder;
    final st = section?.store;
    if (section == null || !section.available || binder == null || st == null) {
      throw const NotebookException('That binder is not available.');
    }
    final dir = _templatesDirFor(null);
    await flush();
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    // Parents before children, in tree order.
    final ordered = <String>[];
    void walk(PageMeta p) {
      ordered.add(p.id);
      section.tree.childrenOf(p.id).forEach(walk);
    }

    section.tree.roots.forEach(walk);
    for (final id in ids) {
      if (!ordered.contains(id)) ordered.add(id);
    }
    final pages = [for (final id in ordered) await st.load(id)];
    final template = NotedTemplate.forBinder(
      name: name.trim().isNotEmpty ? name.trim() : section.title,
      binder: binder,
      pages: pages,
    );
    await _saveTemplate(dir, template);
    return template;
  }

  Future<void> _saveTemplate(Directory dir, NotedTemplate template) async {
    try {
      await TemplateStore(dir).save(template);
    } on FileSystemException catch (e) {
      throw NotebookException('Could not save the template: ${e.message}');
    }
  }

  /// Deletes a template file found by [listTemplates].
  Future<void> deleteTemplate(TemplateItem item) async {
    try {
      await TemplateStore(_templatesDirFor(item.binderPath)).delete(item.path);
    } on FileSystemException catch (e) {
      throw NotebookException('Could not delete the template: ${e.message}');
    }
  }

  /// Creates a page from the page template [template] and opens it, placed
  /// as [createPage] would place it.
  Future<String> createPageFromTemplate(
    NotedTemplate template, {
    String? parentId,
    String? binderPath,
    String? folderPath,
    bool focusTitle = false,
  }) async {
    if (template.kind != TemplateKind.page) {
      throw const NotebookException('That is not a page template.');
    }
    final loc = await _placeFor(parentId, binderPath, folderPath);
    final page = template.instantiatePage(
      parentId: parentId,
      order: _treeOf(loc).nextOrder(parentId),
    );
    await _write(loc, page);
    _touch(loc);
    _metas[page.id] = page.meta;
    _loc[page.id] = loc;
    if (focusTitle) requestTitleFocus(page.id);
    await open(page.id);
    return page.id;
  }

  /// Creates a binder in the folder [path] from the binder template
  /// [template]: its settings (with a new binder id) and page tree (with new
  /// ids), then adds it like [addBinder] and shows its cover. A folder that
  /// has a binder is refused.
  Future<BinderSection> createBinderFromTemplate(NotedTemplate template, String path) async {
    if (template.kind != TemplateKind.binder) {
      throw const NotebookException('That is not a binder template.');
    }
    path = _normalizePath(path);
    if (path == defaultFolderPath || _folders.containsKey(path)) {
      throw const NotebookException('That folder holds the standalone pages.');
    }
    final dir = Directory(path);
    final binders = BinderStore(dir);
    if (_binders.containsKey(path) || await binders.file.exists()) {
      throw const NotebookException(
        'That folder already has a binder. Choose an empty folder for the new binder.',
      );
    }
    await flush();
    final made = template.instantiateBinder();
    final pages = storeFactory(dir);
    final written = <String>[];
    try {
      await binders.create(made.binder);
      for (final p in made.pages) {
        await pages.save(p);
        written.add(p.id);
      }
    } on Object catch (e) {
      for (final id in written) {
        try {
          await pages.delete(id);
        } on Object catch (e2) {
          debugPrint('Removing page $id failed: $e2');
        }
      }
      try {
        await binders.file.delete();
      } on Object catch (e2) {
        debugPrint('Removing binder file failed: $e2');
      }
      throw NotebookException('Could not create the binder: $e');
    }
    final section = await addBinder(path);
    if (section.available) showCover(section.path);
    return section;
  }

  // Binders -----------------------------------------------------------------

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
      _conflicts.remove(id);
    }
    _binders.remove(path);
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _rebuildTree();
    _syncWatchers();
    await _saveSettings();
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
      if (latest != null) {
        await BinderStore(Directory(path)).save(latest);
        _binderText[_key(path)] = latest.write();
      }
    }).catchError((Object e) {
      debugPrint('Saving binder $path failed: $e');
    });
    _saving = job;
    await job;
  }

  Future<BinderSection> _openBinder(String path, {bool create = false}) async {
    BinderSection unavailable(String why, {bool missing = false}) =>
        BinderSection._(path, BinderStatus.unavailable, reason: why, missing: missing);
    final dir = Directory(path);
    try {
      if (!await dir.exists()) {
        return unavailable('Folder not found. It may be on another device.', missing: true);
      }
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
      // A binder whose file can't be read still lists its pages, read-only.
      final binder = read is BinderFound ? read.binder : null;
      try {
        _binderText[_key(path)] = await binders.file.readAsString();
      } on Object {
        _binderText.remove(_key(path));
      }
      final pages = storeFactory(dir);
      final entries = await pages.scan();
      if (binder != null) {
        // Conflict copies are merged by writing, which a damaged binder forbids.
        _pendingCopies.addAll(entries.whereType<ConflictCopyPage>().map((c) => c.path));
      }
      var latest = (await binders.file.lastModified());
      final bad = <UnreadablePage>[...entries.whereType<UnreadablePage>()];
      final section = BinderSection._(
        path,
        binder != null ? BinderStatus.available : BinderStatus.unreadable,
        binder: binder,
        store: pages,
        reason: read is BinderUnreadable ? read.reason : null,
        unreadable: bad,
      );
      for (final e in entries.whereType<ReadablePage>()) {
        if (_metas.containsKey(e.meta.id) && _loc[e.meta.id] != path) {
          bad.add(UnreadablePage(e.path, 'duplicate page id ${e.meta.id}'));
          continue;
        }
        _metas[e.meta.id] = e.meta;
        _loc[e.meta.id] = path;
        _pathId[_key(e.path)] = e.meta.id;
        if (e.conflicted) _conflicts.add(e.meta.id);
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

  // `binders.json`, the app settings file:
  //   {"format":1,"binders":["<folder>", ...],"standaloneFolders":["<folder>", ...]}
  // `standaloneFolders` is absent until a second standalone folder is used.
  // Fields this build doesn't know are kept.
  List<String> _readFolderPaths() {
    final list = _settings['standaloneFolders']?.decode();
    return [
      for (final p in list is List ? list : const [])
        if (p is String && p.isNotEmpty) p,
    ];
  }

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

  Future<void> _saveSettings() async {
    final f = bindersFile;
    if (f == null) return;
    final paths = _binders.keys.toList();
    final folders = _folders.keys.toList();
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
      if (folders.isNotEmpty || _settings.containsKey('standaloneFolders')) {
        _settings = _settings.set('standaloneFolders', RawJson.encode(folders));
      }
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
    final loc = _loc[page.id];
    if (loc != null && _isLocked(loc)) return; // a read-only page is never saved
    _pendingSave = page;
    if (_metas[page.id] != page.meta) {
      _metas[page.id] = page.meta;
      _rebuildTree();
    }
    _setConflict(page.id, hasConflicts(page));
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  // Saves run one after another, so an older version never lands last.
  void _enqueueSave(NotedPage page) {
    _saving = _saving.then((_) async {
      final loc = _loc[page.id];
      if (loc == null || _isLocked(loc)) return;
      final st = _storeOf(loc);
      var toSave = page;
      final path = st.pathFor(page.id);
      if (_current?.page.id == page.id && _known.containsKey(_key(path))) {
        // Merge what someone else wrote since the last look first, so this
        // save doesn't overwrite it.
        await _checkFile(path);
        final c = _current;
        if (c != null && c.page.id == page.id) toSave = c.page;
      }
      try {
        await _write(loc, toSave);
      } on FolderUnavailableException {
        await _keepForRecovery(loc, st, toSave);
        return;
      } on FileSystemException {
        // The folder may have vanished during the write.
        if (await st.directory.exists()) rethrow;
        await _keepForRecovery(loc, st, toSave);
        return;
      }
      if (_current?.page.id == toSave.id) _base = toSave;
      _touch(loc);
    }).catchError((Object e) {
      debugPrint('Saving page ${page.id} failed: $e');
    });
  }

  // Throws unless the pages of [loc] may be written. A folder that has gone
  // is never created again by a save.
  Future<void> _assertCanWrite(String loc) async {
    _assertWritable(loc);
    final st = _storeOf(loc);
    if (!await st.directory.exists()) {
      throw const FolderUnavailableException();
    }
  }

  // Recovery ------------------------------------------------------------------

  // A save couldn't land because the folder is gone: keep exactly what the
  // save would have written, so the edit survives quitting (0066).
  Future<void> _keepForRecovery(String loc, PageStore st, NotedPage page) async {
    final rec = _recovery;
    if (rec == null) return;
    var base = _known[_key(st.pathFor(page.id))];
    final b = _base;
    if (base == null && b != null && _current?.page.id == page.id) base = writePage(b);
    try {
      await rec.write(
        folder: _normalizePath(st.directory.path),
        page: page,
        baseText: base,
        time: DateTime.now(),
      );
    } on Object catch (e) {
      debugPrint('Keeping page ${page.id} for recovery failed: $e');
    }
  }

  String? _locOfFolder(String folder) {
    final k = _key(folder);
    if (k == _key(store.directory.path)) return _standalone;
    for (final f in _folders.values) {
      if (_key(f.path) == k) return f.path;
    }
    for (final b in _binders.values) {
      if (_key(b.path) == k) return b.path;
    }
    return null;
  }

  // Merges the recovery entries whose folder is available (only those of
  // [onlyLoc] if given) into the saved pages and deletes each entry once the
  // result has been read back and checked. An entry that can't be applied
  // stays.
  Future<void> _recoverPending({
    String? onlyLoc,
    ({bool ran, NotedPage? theirs})? resumed,
  }) async {
    final rec = _recovery;
    if (rec == null) return;
    final listing = await rec.list();
    _recoveryProblems = listing.problems;
    _recoveryDamaged = listing.damaged;
    for (final e in listing.entries) {
      if (_disposed) return;
      final loc = _locOfFolder(e.folder);
      if (loc == null || _isLocked(loc) || (onlyLoc != null && loc != onlyLoc)) continue;
      try {
        await _recoverEntry(rec, e, loc, resumed);
      } on Object catch (ex) {
        debugPrint('Recovering page ${e.pageId} failed: $ex');
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _recoverEntry(
    RecoveryStore rec,
    RecoveryEntry e,
    String loc,
    ({bool ran, NotedPage? theirs})? resumed,
  ) async {
    final mine = e.page;
    final id = mine.id;
    final st = _storeOf(loc);
    if (!await st.directory.exists()) return;
    final base = e.baseText == null ? NotedPage.create(mine.meta) : readPage(e.baseText!);
    final c = _current;
    if (c != null && c.page.id == id) {
      // The page is open: it holds the edit and was merged with its file by
      // _resumeOpenPage; saving it lands the result.
      NotedPage? theirs;
      if (resumed != null && resumed.ran) {
        theirs = resumed.theirs;
      } else if (_orphanLoc == loc && _loc[id] == null) {
        // Its file was deleted while the folder was away: keep the page.
        _loc[id] = loc;
        _metas[id] = c.page.meta;
        _orphanLoc = null;
        _syncReadOnly();
        _rebuildTree();
      } else {
        return;
      }
      if (theirs == null) _enqueueSave(c.page);
      await flush();
      final back = readPage(await st.readText(id));
      final why = verifyRecoveredPage(base: base, mine: mine, theirs: theirs, result: back);
      if (why != null) {
        debugPrint('Recovered page $id not accepted: $why');
        return;
      }
      await rec.delete(e);
      return;
    }
    final path = st.pathFor(id);
    final file = File(path);
    NotedPage? theirs;
    String? theirsText;
    var time = DateTime.now().millisecondsSinceEpoch;
    if (await file.exists()) {
      theirsText = await file.readAsString();
      theirs = readPage(theirsText);
      time = (await file.lastModified()).millisecondsSinceEpoch;
      if (theirs.id != id) return;
    }
    final merged = theirs == null
        ? mine
        : mergePage(base, mine, theirs, modules.codecs, theirsTime: time).page;
    final out = writePage(merged);
    if (out != theirsText) await _write(loc, merged);
    final back = await st.readText(id);
    if (back != out) {
      debugPrint('Recovered page $id not accepted: the saved page differs from what was written');
      return;
    }
    final why = verifyRecoveredPage(base: base, mine: mine, theirs: theirs, result: readPage(back));
    if (why != null) {
      debugPrint('Recovered page $id not accepted: $why');
      return;
    }
    await _applyClosed(readPage(back), loc, _key(path), path);
    await rec.delete(e);
  }

  Future<void> _write(String loc, NotedPage page) async {
    await _assertCanWrite(loc);
    final st = _storeOf(loc);
    await st.save(page);
    final key = _key(st.pathFor(page.id));
    _known[key] = writePage(page);
    _pathId[key] = page.id;
    if (page.id != currentId) _setConflict(page.id, hasConflicts(page));
  }

  Future<void> _delete(String loc, String id) async {
    _assertWritable(loc);
    final st = _storeOf(loc);
    final key = _key(st.pathFor(id));
    await st.delete(id);
    _known.remove(key);
    _pathId.remove(key);
    _conflicts.remove(id);
  }

  // External changes (0020) ---------------------------------------------------

  /// Whether the page [id] has a conflicted box, on screen or in its file.
  bool hasConflict(String id) => _conflicts.contains(id);

  /// Records whether page [id] has a conflicted box. Tells the listeners if
  /// that changed.
  void _setConflict(String id, bool value) {
    final changed = value ? _conflicts.add(id) : _conflicts.remove(id);
    if (changed && !_disposed) notifyListeners();
  }

  /// A comparable form of a file path: absolute, with forward slashes and,
  /// on Windows, lower case.
  static String _key(String path) {
    final p = File(path).absolute.path.replaceAll(r'\', '/');
    return Platform.isWindows ? p.toLowerCase() : p;
  }

  String? _locationOf(String path) {
    final dir = _key(File(path).parent.path);
    if (dir == _key(store.directory.path)) return _defaultGone ? null : _standalone;
    for (final f in _folders.values) {
      if (f.available && _key(f.path) == dir) return f.path;
    }
    for (final b in _binders.values) {
      // A binder with a damaged file still has its pages looked after.
      if ((b.available || b.readOnly) && _key(b.path) == dir) return b.path;
    }
    return null;
  }

  /// Starts and stops the folder watchers to match the available folders.
  void _syncWatchers() {
    if (!watchFiles || _disposed) return;
    final wanted = <String, String>{
      if (!_defaultGone) _standalone: store.directory.path,
      for (final f in _folders.values)
        if (f.available) f.path: f.path,
      // A binder that can't be used is watched too, as long as its folder
      // exists, so a repaired or restored binder file brings it back.
      for (final b in _binders.values)
        if (!b.missing && (b.available || Directory(b.path).existsSync())) b.path: b.path,
    };
    for (final loc in _watchers.keys.toList()) {
      if (!wanted.containsKey(loc)) unawaited(_watchers.remove(loc)!.cancel());
    }
    wanted.forEach((loc, dir) {
      if (_watchers.containsKey(loc)) return;
      try {
        // A watcher that fails or ends usually means its folder went away:
        // look at the folders now instead of waiting for the timer.
        _watchers[loc] = Directory(dir).watch().listen(
          _onFileEvent,
          onError: (Object e) {
            debugPrint('Watching $dir failed: $e');
            unawaited(checkFolders());
          },
          onDone: () {
            _watchers.remove(loc);
            unawaited(checkFolders());
          },
        );
      } on FileSystemException catch (e) {
        debugPrint('Watching $dir failed: $e');
      }
    });
  }

  void _onFileEvent(FileSystemEvent e) {
    _schedule(e.path);
    if (e is FileSystemMoveEvent && e.destination != null) _schedule(e.destination!);
  }

  // Only `.canvas` files and binder files matter; the temporary files of our
  // own atomic writes end in `.tmp` and are ignored here.
  void _schedule(String path) {
    final binderFile = _isBinderFile(path);
    if (!binderFile && !path.endsWith(PageStore.extension)) return;
    final key = _key(path);
    _debounce[key]?.cancel();
    _debounce[key] = Timer(watchDebounce, () {
      _debounce.remove(key);
      unawaited(binderFile ? checkBinderFile(path) : checkFile(path));
    });
  }

  bool _isBinderFile(String path) =>
      path.split(RegExp(r'[\\/]')).last == binderFileName;

  /// Looks at the page file [path] after it may have been changed by someone
  /// else, and brings the tree and the open page up to date (0020).
  ///
  /// Does nothing if the file still holds exactly what this app last wrote or
  /// read. A page that isn't open has its header re-read (a new file adds a
  /// page, a deleted one removes it, an unreadable one is listed). The open
  /// page is merged per box with the file, keeping unsaved local edits; if its
  /// file was deleted the page stays as it is and the next save writes it
  /// again.
  Future<void> checkFile(String path) {
    final job = _checking.then((_) async {
      await _saving; // let writes in flight land first
      if (!_disposed) await _checkFile(path);
    }).catchError((Object e) {
      debugPrint('Checking $path failed: $e');
    });
    _checking = job;
    return job;
  }

  /// Looks at a binder's `noted-binder.json` ([path]) after it may have been
  /// changed by someone else.
  ///
  /// Does nothing if the file still holds exactly what this app last wrote or
  /// read. A changed cover is taken over (the sidebar and the cover update). A
  /// file that is damaged or from a newer app marks the binder unreadable, and
  /// a deleted one marks it unavailable, as at startup; the file is never
  /// written in either case. A binder that was unusable and has a good file
  /// again is opened afresh.
  Future<void> checkBinderFile(String path) {
    final job = _checking.then((_) async {
      await _saving;
      if (!_disposed) await _checkBinderFile(path);
    }).catchError((Object e) {
      debugPrint('Checking $path failed: $e');
    });
    _checking = job;
    return job;
  }

  Future<void> _checkBinderFile(String path) async {
    if (!_isBinderFile(path)) return;
    final dirKey = _key(File(path).parent.path);
    final section = _binders.values.where((b) => _key(b.path) == dirKey).firstOrNull;
    if (section == null) return;
    if (section.missing) return; // checkFolders brings a returned folder back
    String? text;
    String? unreadable;
    try {
      text = await File(path).readAsString();
    } on FileSystemException {
      text = null;
    } on FormatException {
      unreadable = 'not valid UTF-8 text';
    }
    if (_disposed) return;
    if (text == null && unreadable == null && !await Directory(section.path).exists()) {
      // The folder is gone, not just the file.
      if (_disposed) return;
      await _binderGone(section);
      return;
    }
    if (text != null && _binderText[dirKey] == text) return;
    Binder? binder;
    if (text != null) {
      _binderText[dirKey] = text;
      try {
        binder = Binder.parse(text);
      } on BinderFormatException catch (e) {
        unreadable = e.message;
      }
    } else {
      _binderText.remove(dirKey);
    }

    if (binder != null) {
      if (section.available) {
        section.binder = binder;
        section.lastEdited = DateTime.now();
        notifyListeners();
      } else {
        await _reopenBinder(section.path);
      }
      return;
    }
    if (text == null && unreadable == null) {
      if (section.status == BinderStatus.unavailable) return;
      await _disableBinder(
        section,
        BinderStatus.unavailable,
        'No $binderFileName in this folder.',
      );
    } else if (section.available) {
      await _damageBinder(section, unreadable ?? 'unreadable');
    } else if (section.status == BinderStatus.unavailable) {
      // The folder was unusable and now holds a damaged file: list its pages.
      await _reopenBinder(section.path);
    } else if (section.reason != unreadable) {
      section.reason = unreadable;
      notifyListeners();
    }
  }

  /// The binder file of an available binder can't be read any more. The binder
  /// stays in the sidebar with its pages, which turn read-only: an open page
  /// is saved first, then switched to a read-only view. Neither the binder file
  /// nor any page of the binder is written until the file is readable again.
  Future<void> _damageBinder(BinderSection section, String reason) async {
    final path = section.path;
    await flush(); // pending edits of the open page land while writing is allowed
    if (_disposed || _binders[path] != section) return;
    section
      ..status = BinderStatus.unreadable
      ..reason = reason
      ..binder = null;
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _syncReadOnly();
    notifyListeners();
  }

  /// Takes the pages of the binder out of the notebook and marks it unusable.
  /// Its files, binder file included, are not touched.
  Future<void> _disableBinder(BinderSection section, BinderStatus status, String reason) async {
    section.missing = false;
    final path = section.path;
    final ids = [for (final e in _loc.entries) if (e.value == path) e.key];
    final openHere = ids.contains(currentId);
    if (openHere) await _closeCurrent(); // saves while the store still works
    for (final id in ids) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    for (final e in _pathId.entries.toList()) {
      if (ids.contains(e.value)) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    section
      ..status = status
      ..reason = reason
      ..binder = null
      ..store = null
      ..unreadable = const []
      ..tree = PageTree.build(const []);
    if (_coverPath == path) _coverPath = null;
    _rebuildTree();
    _syncWatchers();
    if (openHere) await _openFallback(_standalone);
  }

  /// A binder whose file is readable again: reads the folder afresh.
  Future<void> _reopenBinder(String path) async {
    // Pages left over from a binder that was listed read-only are read again;
    // the open one stays, so its view isn't torn down.
    for (final e in _loc.entries.where((e) => e.value == path && e.key != currentId).toList()) {
      _forgetPage(e.key);
    }
    final fresh = await _openBinder(path);
    if (_disposed) return;
    _binders[path] = fresh;
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    await _mergePendingCopies(inQueue: true);
  }

  // Drops what the notebook knows of page [id] (not its file).
  void _forgetPage(String id) {
    _metas.remove(id);
    _loc.remove(id);
    _conflicts.remove(id);
    for (final e in _pathId.entries.toList()) {
      if (e.value == id) {
        _pathId.remove(e.key);
        _known.remove(e.key);
      }
    }
  }

  Future<void> _checkFile(String path) async {
    if (!path.endsWith(PageStore.extension)) return;
    final loc = _locationOf(path);
    if (loc == null) return;
    final key = _key(path);
    final file = File(path);
    String? text;
    var time = DateTime.now().millisecondsSinceEpoch;
    try {
      text = await file.readAsString();
      time = (await file.lastModified()).millisecondsSinceEpoch;
    } on FileSystemException {
      text = null;
    } on FormatException {
      if (_disposed) return;
      _knownUnreadable(loc, key, path, 'not valid UTF-8 text');
      return;
    }
    if (_disposed) return;
    if (text == null) {
      // The whole folder going away is not the page file being deleted:
      // checkFolders deals with that.
      if (_binders.containsKey(loc) && !await Directory(File(path).parent.path).exists()) return;
      _fileGone(loc, key, path);
      return;
    }
    if (conflictCopyOriginalNames(path.split(RegExp(r'[\\/]')).last).isNotEmpty &&
        !_isLocked(loc) &&
        await _tryConflictCopy(loc, key, path, text, time)) {
      return;
    }
    if (_known[key] == text) return;
    _known[key] = text;
    final NotedPage page;
    try {
      page = readPage(text);
    } on PageFormatException catch (e) {
      _knownUnreadable(loc, key, path, e.message);
      return;
    }
    if (_current?.page.id == page.id && _loc[page.id] == loc) {
      _mergeOpen(page, text, time);
    } else {
      await _applyClosed(page, loc, key, path);
    }
  }

  /// Merges the conflict copies a scan found, and forgets them.
  Future<void> _mergePendingCopies({bool inQueue = false}) async {
    final paths = List<String>.of(_pendingCopies);
    _pendingCopies.clear();
    for (final p in paths) {
      await (inQueue ? _checkFile(p) : checkFile(p));
    }
  }

  /// Handles [path] if it is a sync client's conflict copy of another page
  /// file (same page id, see [conflictCopyOriginalNames]): merges it into the
  /// original, checks the saved result and only then deletes the copy. Returns
  /// false if the file is not a conflict copy. If anything fails the copy is
  /// left where it is and listed as a file that can't be opened.
  Future<bool> _tryConflictCopy(
    String loc,
    String key,
    String path,
    String text,
    int time,
  ) async {
    final NotedPage copy;
    try {
      copy = readPage(text);
    } on PageFormatException {
      return false;
    }
    final originalPath = await PageStore.findConflictOriginal(path, copy);
    if (originalPath == null) return false;
    try {
      await _mergeConflictCopy(loc, path, originalPath, copy, time);
      _known.remove(key);
      _dropUnreadable(loc, path);
    } on Object catch (e) {
      debugPrint('Merging conflict copy $path failed, keeping it: $e');
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'Could not be merged into its page: $e');
    }
    return true;
  }

  Future<void> _mergeConflictCopy(
    String loc,
    String copyPath,
    String originalPath,
    NotedPage copy,
    int time,
  ) async {
    final id = copy.id;
    final st = _storeOf(loc);
    final c = _current;
    final isOpen = c != null && c.page.id == id && _loc[id] == loc;
    final NotedPage original;
    final String? failure;
    if (isOpen) {
      // Merge into the page on screen, keeping unsaved edits, and save it.
      original = c.page;
      final merged = mergeConflictCopy(original, copy, modules.codecs, copyTime: time).page;
      if (writePage(merged) != writePage(original)) c.applyExternal(merged);
      await flush();
      failure = verifyConflictCopyMerge(readPage(await st.readText(id)), original, copy);
    } else {
      final text = await File(originalPath).readAsString();
      original = readPage(text);
      final merged = mergeConflictCopy(original, copy, modules.codecs, copyTime: time).page;
      final out = writePage(merged);
      if (out != text) {
        // Make the store write to the file the original was read from.
        if (_key(st.pathFor(id)) != _key(originalPath)) await st.scan();
        await _write(loc, merged);
        final back = await st.readText(id);
        if (back != out) throw const FormatException('the saved page differs from what was written');
        failure = verifyConflictCopyMerge(readPage(back), original, copy);
        if (_loc[id] != loc) {
          await _applyClosed(merged, loc, _key(originalPath), originalPath);
        }
      } else {
        failure = verifyConflictCopyMerge(readPage(text), original, copy);
      }
    }
    if (failure != null) throw FormatException(failure);
    await File(copyPath).delete();
  }

  /// The file is gone.
  void _fileGone(String loc, String key, String path) {
    _known.remove(key);
    final id = _pathId.remove(key);
    if (id == null) {
      _dropUnreadable(loc, path);
      return;
    }
    if (_loc[id] != loc || id == currentId) return; // moved, or open: keep it
    _metas.remove(id);
    _loc.remove(id);
    _conflicts.remove(id);
    _touch(loc);
    _rebuildTree();
  }

  /// The file can't be read as a page. An open page stays as it is; any
  /// other page is taken out of the tree and listed as one that can't be
  /// opened.
  void _knownUnreadable(String loc, String key, String path, String reason) {
    final id = _pathId[key];
    if (id != null && id == currentId) return;
    if (id != null && _loc[id] == loc) {
      _metas.remove(id);
      _loc.remove(id);
      _conflicts.remove(id);
    }
    _pathId.remove(key);
    _dropUnreadable(loc, path, rebuild: false);
    final entry = UnreadablePage(path, reason);
    if (loc == _standalone) {
      _unreadable = [..._unreadable, entry];
    } else if (_folders[loc] case final f?) {
      f.unreadable = [...f.unreadable, entry];
    } else {
      final s = _binders[loc];
      if (s != null) s.unreadable = [...s.unreadable, entry];
    }
    _touch(loc);
    _rebuildTree();
  }

  void _dropUnreadable(String loc, String path, {bool rebuild = true}) {
    final key = _key(path);
    bool other(UnreadablePage u) => _key(u.path) != key;
    var removed = false;
    if (loc == _standalone) {
      final next = _unreadable.where(other).toList();
      removed = next.length != _unreadable.length;
      _unreadable = next;
    } else if (_folders[loc] case final f?) {
      final next = f.unreadable.where(other).toList();
      removed = next.length != f.unreadable.length;
      f.unreadable = next;
    } else {
      final s = _binders[loc];
      if (s != null) {
        final next = s.unreadable.where(other).toList();
        removed = next.length != s.unreadable.length;
        s.unreadable = next;
      }
    }
    if (removed && rebuild) _rebuildTree();
  }

  /// A page that isn't open: take its header (and conflict state) from the
  /// file.
  Future<void> _applyClosed(NotedPage page, String loc, String key, String path) async {
    final id = page.id;
    final elsewhere = _pathId.entries.where((e) => e.value == id && e.key != key);
    if (elsewhere.isNotEmpty) {
      // Two files claim the page id; keep the first and list this one.
      _known.remove(key);
      _knownUnreadable(loc, key, path, 'duplicate page id $id');
      return;
    }
    final previous = _pathId[key];
    if (previous != null && previous != id && _loc[previous] == loc) {
      _metas.remove(previous);
      _loc.remove(previous);
      _conflicts.remove(previous);
    }
    _dropUnreadable(loc, path, rebuild: false);
    _pathId[key] = id;
    _metas[id] = page.meta;
    _loc[id] = loc;
    if (_isStandaloneLoc(loc) || _binders[loc]?.store != null) {
      final st = _storeOf(loc);
      // Make the store find files whose names aren't the page id.
      // (Never when the folder is gone: a scan would create it.)
      if (_key(st.pathFor(id)) != key && await st.directory.exists()) await st.scan();
    }
    _setConflict(id, hasConflicts(page));
    _touch(loc);
    _rebuildTree();
  }

  /// The open page's file changed: merge it into the page on screen.
  void _mergeOpen(NotedPage theirs, String text, int time) {
    final c = _current!;
    final base = _base;
    _base = theirs;
    if (base == null) return;
    final result = mergePage(base, c.page, theirs, modules.codecs, theirsTime: time);
    final merged = result.page;
    final save = writePage(merged) != text || _pendingSave?.id == merged.id;
    _metas[merged.id] = merged.meta;
    c.applyExternal(merged, save: save);
    _setConflict(merged.id, hasConflicts(merged));
    _rebuildTree();
  }

  // Folders that come and go -------------------------------------------------

  void _startFolderTimer() {
    _folderTimer?.cancel();
    _folderTimer = null;
    if (!watchFiles || _disposed || folderCheckInterval <= Duration.zero) return;
    _folderTimer = Timer.periodic(folderCheckInterval, (_) => unawaited(checkFolders()));
  }

  /// Looks for standalone folders (the default one and the extra ones) that
  /// have disappeared or come back since the last look; with [watchFiles] on
  /// this also runs every [folderCheckInterval] and when a watcher fails.
  ///
  /// A folder that is gone loses its pages from the tree and is listed as
  /// "on another device". Its open page is saved if possible, then stays open
  /// read-only. When the folder comes back it is read again, its watcher is
  /// restarted and the open page is merged with its file. The folder itself is
  /// never created or deleted here.
  Future<void> checkFolders() {
    final job = _checking.then((_) async {
      await _saving;
      if (!_disposed) await _checkFolders();
    }).catchError((Object e) {
      debugPrint('Checking the folders failed: $e');
    });
    _checking = job;
    return job;
  }

  Future<void> _checkFolders() async {
    final defaultExists = await store.directory.exists();
    if (_disposed) return;
    if (!_defaultGone && !defaultExists) {
      await _folderGone(_standalone);
    } else if (_defaultGone && defaultExists) {
      await _folderBack(_standalone);
    }
    for (final b in _binders.values.toList()) {
      if (_disposed) return;
      if (!identical(_binders[b.path], b)) continue;
      final exists = await Directory(b.path).exists();
      if (_disposed) return;
      if (b.missing) {
        if (exists) await _binderBack(b.path);
      } else if (!exists) {
        await _binderGone(b);
      }
    }
    for (final f in _folders.values.toList()) {
      if (_disposed) return;
      if (!identical(_folders[f.path], f)) continue;
      final exists = await Directory(f.path).exists();
      if (_disposed) return;
      if (f.available && !exists) {
        await _folderGone(f.path);
      } else if (!f.available && f.missing && exists) {
        await _folderBack(f.path);
      }
    }
    _syncWatchers(); // restarts a watcher that ended
  }

  Future<void> _folderGone(String loc) async {
    // Pending edits of the open page are written first if that is still
    // possible; if not, they stay in the page on screen.
    await flush();
    if (_disposed) return;
    final ids = [for (final e in _loc.entries) if (e.value == loc) e.key];
    if (ids.contains(currentId)) _orphanLoc = loc;
    for (final id in ids) {
      _forgetPage(id);
    }
    if (loc == _standalone) {
      _defaultGone = true;
      _unreadable = const [];
    } else {
      final f = _folders[loc];
      if (f != null) {
        f
          ..available = false
          ..missing = true
          ..store = null
          ..reason = 'Folder not found. It may be on another device.'
          ..unreadable = const [];
      }
    }
    final last = _lastDeleted;
    if (last != null && last._location == loc) _lastDeleted = null;
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
  }

  /// A binder's folder disappeared. Pending edits are written first if that
  /// is still possible. The binder stays in the sidebar as "on another
  /// device" with its pages listed, read-only; an open page stays open. Its
  /// watcher stops and nothing is written until the folder is back.
  Future<void> _binderGone(BinderSection section) async {
    await flush();
    final path = section.path;
    if (_disposed || _binders[path] != section || section.missing) return;
    section
      ..missing = true
      ..status = BinderStatus.unavailable
      ..reason = 'Folder not found. It may be on another device.';
    if (_coverPath == path) _coverPath = null;
    final last = _lastDeleted;
    if (last != null && last._location == path) _lastDeleted = null;
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
  }

  /// A binder's folder is back: reads the binder file and the pages again,
  /// restarts the watcher, merges conflict copies and merges the open page.
  Future<void> _binderBack(String path) async {
    final old = _binders[path];
    if (old == null) return;
    for (final e in _loc.entries.where((e) => e.value == path && e.key != currentId).toList()) {
      _forgetPage(e.key);
    }
    final fresh = await _openBinder(path);
    if (_disposed || !identical(_binders[path], old)) return;
    if (fresh.missing) return; // gone again
    if (fresh.status == BinderStatus.unavailable) {
      // No binder file (or unusable): as at startup.
      await _disableBinder(old, BinderStatus.unavailable, fresh.reason ?? '');
      return;
    }
    _binders[path] = fresh;
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    await _mergePendingCopies(inQueue: true);
    final resumed = await _resumeOpenPage(path, force: true);
    await _recoverPending(onlyLoc: path, resumed: resumed);
  }

  Future<void> _folderBack(String loc) async {
    if (loc == _standalone) {
      final entries = await store.scan();
      _defaultGone = false;
      _adoptDefault(entries);
    } else {
      final fresh = await _openFolder(loc);
      if (_disposed) return;
      if (!fresh.available) {
        // Still can't be used (for example it now holds a binder).
        final f = _folders[loc];
        if (f != null) {
          f
            ..missing = fresh.missing
            ..reason = fresh.reason;
        }
        return;
      }
      _folders[loc] = fresh;
    }
    _syncReadOnly();
    _rebuildTree();
    _syncWatchers();
    await _mergePendingCopies(inQueue: true);
    final resumed = await _resumeOpenPage(loc);
    await _recoverPending(onlyLoc: loc, resumed: resumed);
  }

  // The open page was kept read-only while its folder was away: it is
  // writable again and merged with whatever its file holds now.
  //
  // Returns whether it ran, and the page read from the file (null: the file
  // is gone).
  Future<({bool ran, NotedPage? theirs})> _resumeOpenPage(String loc, {bool force = false}) async {
    final c = _current;
    if (c == null || (!force && _orphanLoc != loc)) return (ran: false, theirs: null);
    final id = c.page.id;
    if (_loc[id] != loc) return (ran: false, theirs: null); // not in the folder any more
    _orphanLoc = null;
    _syncReadOnly();
    try {
      final path = _storeOf(loc).pathFor(id);
      final file = File(path);
      final String text;
      try {
        text = await file.readAsString();
      } on PathNotFoundException {
        return (ran: true, theirs: null);
      }
      final time = (await file.lastModified()).millisecondsSinceEpoch;
      final page = readPage(text);
      _known[_key(path)] = text;
      if (_current == c) _mergeOpen(page, text, time);
      return (ran: true, theirs: page);
    } on Object catch (e) {
      debugPrint('Reading the open page after its folder came back failed: $e');
      return (ran: false, theirs: null);
    }
  }

  Future<void> _closeCurrent() async {
    // Leaving a page ends editing, so an empty new box is discarded, not saved.
    final c = _current;
    final editing = c?.editingId;
    if (c != null && editing != null) c.setEditing(editing, false);
    await flush();
    _current?.dispose();
    _current = null;
    _base = null;
    _orphanLoc = null;
    _readOnlyReason = null;
  }

  void _rebuildTree() {
    final groups = <String, List<PageMeta>>{};
    for (final e in _metas.entries) {
      (groups[_loc[e.key] ?? _standalone] ??= []).add(e.value);
    }
    _tree = PageTree.build([
      for (final e in groups.entries)
        if (_isStandaloneLoc(e.key)) ...e.value,
    ]);
    for (final b in _binders.values) {
      b.tree = PageTree.build(groups[b.path] ?? const []);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _folderTimer?.cancel();
    for (final t in _debounce.values) {
      t.cancel();
    }
    _debounce.clear();
    for (final w in _watchers.values) {
      unawaited(w.cancel());
    }
    _watchers.clear();
    _current?.dispose();
    tools.dispose();
    super.dispose();
  }
}
