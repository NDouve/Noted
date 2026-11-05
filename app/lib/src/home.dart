// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'ai_access_note.dart';
import 'app_commands.dart';
import 'app_settings.dart';
import 'binder_cover.dart';
import 'device_storage.dart';
import 'notebook.dart';
import 'notebook_search.dart';
import 'page_title_field.dart';
import 'save_trouble.dart' show KeptNotice, TroubleKind;
import 'save_trouble_bar.dart';
import 'search_panel.dart';
import 'settings_panel.dart';
import 'page_tree_view.dart';
import 'settings_menu.dart';

/// The snack bar for an attachment notice. A long one (it names a file and
/// says where a copy went) stays 20 seconds and can be closed; a short one
/// keeps the default time.
SnackBar attachmentNoticeBar(String message) {
  final long = message.length > 90;
  return SnackBar(
    content: Text(message),
    duration: long ? const Duration(seconds: 20) : const Duration(milliseconds: 4000),
    showCloseIcon: long,
  );
}

/// Sidebar with the page tree, and the open page's canvas.
class Home extends StatefulWidget {
  const Home({super.key, required this.notebook, this.settings, this.search});

  final Notebook notebook;

  /// Search over all pages. Null: the home makes its own.
  final NotebookSearch? search;

  /// This device's settings; the settings menu is shown when given.
  final AppSettings? settings;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _tree = GlobalKey<PageTreeViewState>();
  final _scaffold = GlobalKey<ScaffoldState>();
  String? _lastChoice;

  // Folded rows; kept here so they outlast the narrow-layout drawer.
  final Set<String> _folded = {};
  int _seenFocusTick = 0;

  Notebook get notebook => widget.notebook;

  late final NotebookSearch _search = widget.search ?? NotebookSearch(notebook);
  late final CommandRegistry _searchCommands = CommandRegistry()..register(searchCommand(_search));

  /// Asks the open page's canvas to open Find on page (from a search result).
  final ValueNotifier<FindRequest?> _findRequests = ValueNotifier<FindRequest?>(null);

  // Pages whose issue sequence the user silenced during this run.
  final IssueSilence _issueSilence = IssueSilence();

  /// The matched range of the title to show in the title field (from a
  /// title result). Only decoration; it never touches the title text.
  final ValueNotifier<TitleHighlight?> _titleHighlight = ValueNotifier<TitleHighlight?>(null);

  /// The open page's canvas, for files dropped on it.
  GlobalKey<PageCanvasState>? _canvasKey;
  String? _canvasKeyFor;

  StreamSubscription<String>? _notices;
  StreamSubscription<KeptNotice>? _kept;

  @override
  void initState() {
    super.initState();
    _seenFocusTick = _search.focusTick;
    _search.addListener(_searchChanged);
    _notices = notebook.attachmentNotices.listen(_showNotice);
    _kept = notebook.keptNotices.listen(_showKept);
    final settings = widget.settings;
    if (settings != null) {
      unawaited(
        notebook.loaded.then((_) {
          if (!mounted) return;
          // After the next frame, with the loaded notebook on screen.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(showAiAccessNoteIfNeeded(context, notebook, settings));
          });
          WidgetsBinding.instance.ensureVisualUpdate();
        }),
      );
    }
  }

  // Edits put in recovery on leaving a page: about 30 seconds, with Show.
  void _showKept(KeptNotice n) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(keptNoticeBar(n, () => unawaited(notebook.open(n.pageId))));
  }

  // A one-line notice about attachments (a file too large to embed).
  void _showNotice(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(attachmentNoticeBar(message));
  }

  // A new canvas (and key) for each page, as the page id key gave before.
  GlobalKey<PageCanvasState> _keyFor(String pageId) {
    if (_canvasKeyFor != pageId || _canvasKey == null) {
      _canvasKeyFor = pageId;
      _canvasKey = GlobalKey<PageCanvasState>(debugLabel: pageId);
    }
    return _canvasKey!;
  }

  // No drag and drop on a phone or tablet (0129).
  Widget _droppable(Widget canvas) => isMobilePlatform ? canvas : DropTarget(onDragDone: _dropped, child: canvas);

  // Files dropped on the canvas become boxes where they were dropped.
  Future<void> _dropped(DropDoneDetails d) async {
    final canvas = _canvasKey?.currentState;
    if (canvas == null) return;
    final files = <IncomingFile>[];
    for (final f in d.files) {
      try {
        files.add(IncomingFile(f.name, await f.readAsBytes()));
      } on FileSystemException catch (e) {
        debugPrint('Reading dropped file ${f.path} failed: $e');
      }
    }
    if (files.isNotEmpty && canvas.mounted) await canvas.dropFiles(files, d.globalPosition);
  }

  // Clearing the search also clears the title highlight it put there.
  void _searchChanged() {
    if (!_search.hasQuery) _titleHighlight.value = null;
    if (_search.focusTick == _seenFocusTick) return;
    _seenFocusTick = _search.focusTick;
    // The search field lives in the drawer on a narrow window: open it, and
    // ask for the focus again once the field exists.
    _openDrawer(then: () {
      _search.requestFocus();
      _seenFocusTick = _search.focusTick;
    });
  }

  // Opens the drawer (narrow windows, when it is shut), then runs [then]
  // after the frame that builds its content.
  void _openDrawer({VoidCallback? then}) {
    final scaffold = _scaffold.currentState;
    if (scaffold == null || !isNarrowLayout(context) || scaffold.isDrawerOpen) return;
    scaffold.openDrawer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) then?.call();
    });
  }

  void _closeDrawer() {
    final scaffold = _scaffold.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  @override
  void dispose() {
    _search.removeListener(_searchChanged);
    _titleHighlight.dispose();
    unawaited(_notices?.cancel());
    unawaited(_kept?.cancel());
    _searchCommands.dispose();
    _findRequests.dispose();
    if (widget.search == null) _search.dispose();
    super.dispose();
  }

  /// A search result was chosen: opens its page, and the page's canvas brings
  /// the match into view and highlights it, with the search text in its find
  /// bar.
  Future<void> _openResult(SearchResultPage page, SearchResultBox? box) async {
    // A result on the page that is already open changes nothing to close on.
    _closeDrawer();
    try {
      await notebook.open(page.pageId);
    } on NotebookException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!mounted) return;
    if (box == null) {
      // A title result: the title shows the match; the find bar stays shut.
      _titleHighlight.value = TitleHighlight(
        pageId: page.pageId,
        title: page.title,
        ranges: page.titleRanges,
      );
      return;
    }
    _titleHighlight.value = null;
    _findRequests.value = FindRequest(
      pageId: page.pageId,
      text: _search.text,
      boxId: box.boxId,
    );
  }

  /// App-level shortcuts (Ctrl+N: new page, Ctrl+Shift+F: search). Keys bubble
  /// up from the canvas, a note editor or the title field to here; only the
  /// commands that work while editing answer, and the rest is left alone.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    if (!k.isControlPressed && !k.isMetaPressed) return KeyEventResult.ignored;
    final actions = _tree.currentState;
    if (actions == null) {
      // A narrow window with the drawer shut: the tree isn't there.
      final search = _searchCommands.resolve(event, editing: true);
      if (search != null) {
        search.run();
        return KeyEventResult.handled;
      }
      if ([newPageShortcut, ...newPageAlternateShortcuts].any((a) => a.accepts(event, k))) {
        unawaited(_newPage());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final command =
        pagesHeaderCommands(notebook, actions).resolve(event, editing: true) ??
        _searchCommands.resolve(event, editing: true);
    if (command == null) return KeyEventResult.ignored;
    command.run();
    return KeyEventResult.handled;
  }

  // Ctrl+N with no page tree on screen: the same as the tree's New page.
  Future<void> _newPage() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await notebook.createPage(focusTitle: true);
    } on NotebookException catch (e) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(content: Text(e.message), persist: e.needsAction, showCloseIcon: e.needsAction),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        key: _scaffold,
        // On a narrow window the sidebar is a drawer (0129).
        drawer: isNarrowLayout(context)
            ? Drawer(
                width: NotedMetrics.of(context).sidebarWidth,
                shape: const RoundedRectangleBorder(),
                child: _sidebar(NotedMetrics.of(context)),
              )
            : null,
        body: _body(),
      ),
    );
  }

  // The page tree with search and settings; inline, or in the drawer on a
  // narrow window.
  Widget _sidebar(NotedMetrics m) {
    return SizedBox(
      width: m.sidebarWidth,
      child: ColoredBox(
        color: NotedColors.of(context).bgSidebar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchField(search: _search, onOpen: _openResult),
            Expanded(
              child: ListenableBuilder(
                listenable: _search,
                builder: (context, _) {
                  final searching = _search.hasQuery;
                  // The tree stays mounted (its expanded state and
                  // the page shortcuts) while results are shown.
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Offstage(
                          offstage: searching,
                          child: PageTreeView(
                            key: _tree,
                            notebook: notebook,
                            collapsed: _folded,
                            onPageChosen: _closeDrawer,
                          ),
                        ),
                      ),
                      if (searching)
                        Positioned.fill(
                          child: SearchResultsView(search: _search, onOpen: _openResult),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (widget.settings != null)
              SettingsMenu(settings: widget.settings!, notebook: notebook),
          ],
        ),
      ),
    );
  }

  // Closes the drawer once a page (or the cover) has been chosen in it.
  void _closeDrawerOnChoice() {
    final choice = notebook.cover != null ? 'cover-${notebook.coverPath}' : notebook.currentId;
    if (choice == _lastChoice) return;
    _lastChoice = choice;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scaffold = _scaffold.currentState;
      if (mounted && scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
    });
  }

  Widget _menuButton(NotedMetrics m) => IconButton(
    key: const ValueKey('sidebar-menu'),
    tooltip: 'Pages',
    icon: const Icon(Icons.menu_rounded),
    iconSize: m.icon,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    onPressed: () => _scaffold.currentState?.openDrawer(),
  );

  // The menu button over a view that has no title row.
  Widget _withMenu(bool narrow, NotedMetrics m, Widget child) => narrow
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(m.space2, m.space2, 0, 0),
              child: Align(alignment: Alignment.centerLeft, child: _menuButton(m)),
            ),
            Expanded(child: child),
          ],
        )
      : child;

  Widget _body() {
    return ListenableBuilder(
      // The settings choose the toolbar; a change applies at once.
      listenable: Listenable.merge([notebook, ?widget.settings]),
      builder: (context, _) {
        final current = notebook.current;
        final m = NotedMetrics.of(context);
        final narrow = isNarrowLayout(context);
        _closeDrawerOnChoice();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!narrow) ...[
              _sidebar(m),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: notebook.cover != null
                  ? _withMenu(
                      narrow,
                      m,
                      BinderCover(
                        key: ValueKey('cover-${notebook.coverPath}'),
                        notebook: notebook,
                        path: notebook.coverPath!,
                      ))
                  : current == null
                  ? _withMenu(narrow, m, const Center(child: CircularProgressIndicator()))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(m.space6, m.space4, m.space6, m.space2),
                          child: Row(
                            children: [
                              if (narrow) _menuButton(m),
                              Expanded(
                                child: PageTitleField(
                                  key: ValueKey('title-${current.page.id}'),
                                  notebook: notebook,
                                  pageId: current.page.id,
                                  highlight: _titleHighlight,
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('page-settings'),
                                tooltip: 'Page settings',
                                icon: const Icon(Icons.tune_rounded),
                                iconSize: m.icon,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                onPressed: () => showPageSettings(context, notebook, current.page.id),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (notebook.trouble.isTrouble) SaveTroubleBar(notebook: notebook),
                        if (notebook.readOnlyReason != null && notebook.trouble.kind != TroubleKind.preview)
                          ReadOnlyBanner(
                            key: const ValueKey('read-only-banner'),
                            reason: notebook.readOnlyReason!,
                          ),
                        Expanded(
                          child: _droppable(
                            PageCanvas(
                              key: _keyFor(current.page.id),
                              attachments: notebook.attachments,
                              disallowedTypes: notebook.disallowedBoxTypesFor(current.page.id),
                              controller: current,
                              tools: notebook.tools,
                              readOnly: notebook.readOnlyReason != null,
                              findRequests: _findRequests,
                              issueSilence: _issueSilence,
                              aiMerge: notebook.aiMerge,
                              extraCommands: () => [searchCommand(_search)],
                              toolbar: (widget.settings?.toolbar ?? ToolbarStyle.tabs).layout,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
