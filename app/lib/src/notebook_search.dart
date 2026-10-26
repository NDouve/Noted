// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

import 'notebook.dart';
import 'search_scope.dart';

/// One box of a page that matched, as shown in the results.
class SearchResultBox {
  const SearchResultBox(this.boxId, this.snippet, this.matchCount);

  final String boxId;

  /// An excerpt around the first match, with the matches marked.
  final SearchSnippet snippet;

  /// All matches in the box.
  final int matchCount;
}

/// The matches on one page.
class SearchResultPage {
  const SearchResultPage(
    this.pageId,
    this.path,
    this.boxes, {
    this.title = '',
    this.titleRanges = const [],
  });

  final String pageId;

  /// Binder (or `Pages`), parent pages and the page's title.
  final List<String> path;

  /// Empty when only the title matched.
  final List<SearchResultBox> boxes;

  /// The stored title, and where the query is in it (empty if the title did
  /// not match).
  final String title;
  final List<SearchRange> titleRanges;

  bool get titleMatched => titleRanges.isNotEmpty;

  int get matchCount =>
      boxes.fold(titleRanges.length, (n, b) => n + b.matchCount);
}

/// Search over every reachable page (standalone folders and binders).
///
/// The index ([SearchIndex]) is in memory only: this class never writes it,
/// or anything else, to disk, and logs nothing. It is built from the page
/// files through the notebook's stores, the first time search is used, and
/// then kept current:
///
/// - the notebook reports every page it writes and every page it reads after
///   a change on disk ([Notebook.onPageContent]);
/// - whenever the notebook changes (a page deleted or moved, a folder or
///   binder gone or back), the index is compared with what the notebook can
///   read now, and pages that are no longer reachable are dropped and new
///   ones loaded;
/// - the open page is searched as the page model holds it (what has been
///   committed), not as the live editor shows it.
///
/// The index holds only the text snapshots the box modules produced
/// (`BoxRecord.snapshotText`). Nothing here reads a box's data.
class NotebookSearch extends ChangeNotifier {
  NotebookSearch(this.notebook) {
    notebook.addListener(_notebookChanged);
    notebook.onPageContent = _onContent;
  }

  final Notebook notebook;

  /// The index, for tests.
  final SearchIndex index = SearchIndex();

  bool _active = false;
  bool _disposed = false;
  Future<void> _syncing = Future.value();
  bool _syncAgain = false;
  NotedPage? _openIndexed;
  String _text = '';
  SearchQuery _query = SearchQuery.parse('');
  List<SearchResultPage> _results = const [];
  List<NotSearched> _skipped = const [];
  bool _running = false;
  bool _loading = false;
  int _focusTick = 0;

  /// The text typed in the search field.
  String get text => _text;

  SearchQuery get query => _query;

  /// The pages with matches, in the order of the page tree.
  List<SearchResultPage> get results => _results;

  /// Folders, binders and page files the search could not look in, with the
  /// reason. Shown at the bottom of the results.
  List<NotSearched> get notSearched => _skipped;

  /// The index is being built or brought up to date.
  bool get busy => _loading;

  /// Whether search has been used (the index exists).
  bool get isActive => _active;

  /// There is something to show: a query was typed.
  bool get hasQuery => !_query.isEmpty;

  /// Rises each time the search field is asked to take focus.
  int get focusTick => _focusTick;

  /// Asks the search field to take focus (Ctrl+Shift+F).
  void requestFocus() {
    _focusTick++;
    notifyListeners();
    unawaited(ensureReady());
  }

  /// Builds the index if search hasn't been used yet, and brings it up to
  /// date. Completes when it is current.
  Future<void> ensureReady() {
    _active = true;
    return _sync();
  }

  /// Searches for [text] (see [SearchQuery] for the rules).
  Future<void> setText(String text) async {
    _text = text;
    _query = SearchQuery.parse(text);
    if (_query.isEmpty) {
      _results = const [];
      notifyListeners();
      return;
    }
    await ensureReady();
    if (_disposed || text != _text) return;
    _refresh();
  }

  /// Clears the query and the results.
  void clear() {
    _text = '';
    _query = SearchQuery.parse('');
    _results = const [];
    notifyListeners();
  }

  // Keeping the index current ------------------------------------------------

  void _onContent(String location, NotedPage page) {
    if (!_active || _disposed) return;
    index.setPage(page, location);
    if (page.id == notebook.currentId) _openIndexed = null;
    _refreshSoon();
  }

  void _notebookChanged() {
    if (!_active || _disposed) return;
    unawaited(_sync());
  }

  Future<void> _sync() {
    // One pass at a time; a change during a pass starts another after it.
    if (_running) {
      _syncAgain = true;
      return _syncing;
    }
    _running = true;
    _syncing = _runSync();
    return _syncing;
  }

  Future<void> _runSync() async {
    try {
      do {
        _syncAgain = false;
        await _reconcile();
      } while (_syncAgain && !_disposed);
    } finally {
      _running = false;
      if (!_disposed) {
        if (hasQuery) {
          _refresh();
        } else {
          notifyListeners();
        }
      }
    }
  }

  Future<void> _reconcile() async {
    final scope = notebook.searchScope();
    final reachable = {for (final p in scope.pages) p.id: p};
    // Pages that are gone, or not reachable now (a folder away, a binder
    // damaged), or that moved to another location.
    for (final id in index.pageIds.toList()) {
      final p = reachable[id];
      if (p == null || index.locationOf(id) != p.location) index.removePage(id);
    }
    final skipped = [...scope.skipped];
    var loaded = 0;
    for (final p in scope.pages) {
      if (index.containsPage(p.id)) continue;
      if (!_loading) {
        _loading = true;
        notifyListeners();
      }
      try {
        index.setPage(await p.load(), p.location);
      } on Object catch (e) {
        skipped.add(NotSearched(notebook.pagePath(p.id).last, _reasonOf(e)));
      }
      // Results appear while a large notebook is still being read.
      if (++loaded % 25 == 0 && hasQuery && !_disposed) _refresh();
      if (_disposed) return;
    }
    if (_loading) {
      _loading = false;
    }
    // The open page is searched as the model holds it.
    final open = notebook.current?.page;
    if (open != null && reachable.containsKey(open.id)) {
      if (!identical(open, _openIndexed)) {
        index.setPage(open, reachable[open.id]!.location);
        _openIndexed = open;
      }
    }
    _skipped = skipped;
  }

  static String _reasonOf(Object e) {
    if (e is PageFormatException) return e.message;
    if (e is FileSystemException) return e.message;
    return 'The page file could not be read.';
  }

  Timer? _soon;

  void _refreshSoon() {
    if (!hasQuery || _disposed) return;
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 50), () {
      if (!_disposed) _refresh();
    });
  }

  /// Searches the index again for the current query.
  void _refresh() {
    if (_disposed) return;
    // The open page may have changed in the model since it was indexed.
    final open = notebook.current?.page;
    if (open != null && index.containsPage(open.id) && !identical(open, _openIndexed)) {
      final loc = index.locationOf(open.id)!;
      index.setPage(open, loc);
      _openIndexed = open;
    }
    final hits = index.search(_query);
    final order = _pageOrder();
    final pages = [
      for (final h in hits)
        SearchResultPage(h.pageId, notebook.pagePath(h.pageId), [
          for (final b in h.boxes)
            SearchResultBox(b.boxId, b.snippet(), b.ranges.length),
        ], title: h.title, titleRanges: h.titleRanges),
    ];
    // Title matches first, then box-only matches; sidebar order in each.
    int rank(SearchResultPage p) =>
        (p.titleMatched ? 0 : 1 << 31) + (order[p.pageId] ?? 1 << 30);
    pages.sort((a, b) => rank(a) - rank(b));
    _results = pages;
    notifyListeners();
  }

  /// The position of each page in the sidebar: standalone pages, then each
  /// binder's, depth first.
  Map<String, int> _pageOrder() {
    final order = <String, int>{};
    void walk(PageTree tree) {
      void visit(PageMeta p) {
        order[p.id] = order.length;
        for (final c in tree.childrenOf(p.id)) {
          visit(c);
        }
      }

      for (final r in tree.roots) {
        visit(r);
      }
    }

    walk(notebook.tree);
    for (final b in notebook.binders) {
      walk(b.tree);
    }
    return order;
  }

  @override
  void dispose() {
    _disposed = true;
    _soon?.cancel();
    notebook.removeListener(_notebookChanged);
    if (notebook.onPageContent == _onContent) notebook.onPageContent = null;
    super.dispose();
  }
}

