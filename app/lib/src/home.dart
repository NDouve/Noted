// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'app_commands.dart';
import 'app_settings.dart';
import 'binder_cover.dart';
import 'notebook.dart';
import 'notebook_search.dart';
import 'page_title_field.dart';
import 'search_panel.dart';
import 'page_tree_view.dart';
import 'settings_menu.dart';

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

  Notebook get notebook => widget.notebook;

  late final NotebookSearch _search = widget.search ?? NotebookSearch(notebook);
  late final CommandRegistry _searchCommands = CommandRegistry()..register(searchCommand(_search));

  /// Asks the open page's canvas to open Find on page (from a search result).
  final ValueNotifier<FindRequest?> _findRequests = ValueNotifier<FindRequest?>(null);

  /// The matched range of the title to show in the title field (from a
  /// title result). Only decoration; it never touches the title text.
  final ValueNotifier<TitleHighlight?> _titleHighlight = ValueNotifier<TitleHighlight?>(null);

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
  }

  // Clearing the search also clears the title highlight it put there.
  void _searchChanged() {
    if (!_search.hasQuery) _titleHighlight.value = null;
  }

  @override
  void dispose() {
    _search.removeListener(_searchChanged);
    _titleHighlight.dispose();
    _searchCommands.dispose();
    _findRequests.dispose();
    if (widget.search == null) _search.dispose();
    super.dispose();
  }

  /// A search result was chosen: opens its page, and the page's canvas brings
  /// the match into view and highlights it, with the search text in its find
  /// bar.
  Future<void> _openResult(SearchResultPage page, SearchResultBox? box) async {
    try {
      await notebook.open(page.pageId);
    } on NotebookException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
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
    final actions = _tree.currentState;
    if (actions == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    if (!k.isControlPressed && !k.isMetaPressed) return KeyEventResult.ignored;
    final command =
        pagesHeaderCommands(notebook, actions).resolve(event, editing: true) ??
        _searchCommands.resolve(event, editing: true);
    if (command == null) return KeyEventResult.ignored;
    command.run();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Scaffold(body: _body()),
    );
  }

  Widget _body() {
    return ListenableBuilder(
      listenable: notebook,
      builder: (context, _) {
        final current = notebook.current;
        final m = NotedMetrics.of(context);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
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
                                  child: PageTreeView(key: _tree, notebook: notebook),
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
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: notebook.cover != null
                  ? BinderCover(
                      key: ValueKey('cover-${notebook.coverPath}'),
                      notebook: notebook,
                      path: notebook.coverPath!,
                    )
                  : current == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(m.space6, m.space4, m.space6, m.space2),
                          child: PageTitleField(
                            key: ValueKey('title-${current.page.id}'),
                            notebook: notebook,
                            pageId: current.page.id,
                            highlight: _titleHighlight,
                          ),
                        ),
                        const Divider(height: 1),
                        if (notebook.readOnlyReason != null)
                          ReadOnlyBanner(
                            key: const ValueKey('read-only-banner'),
                            reason: notebook.readOnlyReason!,
                          ),
                        Expanded(
                          child: PageCanvas(
                            key: ValueKey(current.page.id),
                            controller: current,
                            tools: notebook.tools,
                            readOnly: notebook.readOnlyReason != null,
                            findRequests: _findRequests,
                            extraCommands: () => [searchCommand(_search)],
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
