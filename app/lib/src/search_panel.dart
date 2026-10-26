// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'notebook_search.dart';
import 'search_scope.dart';

/// How many snippets one page shows before "N more".
const int maxSnippetsPerPage = 3;

/// The search field at the top of the sidebar.
///
/// Typing searches every page. Enter opens the first result, Escape clears
/// the search. Ctrl+Shift+F puts the caret here and selects what was typed.
class SearchField extends StatefulWidget {
  const SearchField({super.key, required this.search, required this.onOpen});

  final NotebookSearch search;

  /// A result was chosen (Enter in the field opens the first one).
  final void Function(SearchResultPage page, SearchResultBox box) onOpen;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.search.text,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'SearchField');
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _tick = widget.search.focusTick;
    widget.search.addListener(_changed);
  }

  @override
  void dispose() {
    widget.search.removeListener(_changed);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    final s = widget.search;
    if (s.text != _text.text) {
      _text.value = TextEditingValue(
        text: s.text,
        selection: TextSelection.collapsed(offset: s.text.length),
      );
    }
    if (s.focusTick != _tick) {
      _tick = s.focusTick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focus.requestFocus();
        _text.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _text.text.length,
        );
      });
    }
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.search.clear();
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final first = widget.search.results.firstOrNull;
      if (first != null) widget.onOpen(first, first.boxes.first);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final hasText = _text.text.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.space3, m.space3, m.space3, m.space1),
      child: Focus(
        onKeyEvent: _onKey,
        child: TextField(
          key: const ValueKey('search-field'),
          controller: _text,
          focusNode: _focus,
          style: type.body,
          cursorColor: scheme.primary,
          onChanged: widget.search.setText,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search all pages',
            prefixIcon: Icon(Icons.search_rounded, size: m.icon),
            suffixIcon: hasText
                ? IconButton(
                    key: const ValueKey('search-clear'),
                    tooltip: 'Clear search',
                    iconSize: m.icon,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.search.clear,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// The results of the search, grouped by page, with the pages and files that
/// were not searched at the bottom. Shown in place of the page tree while a
/// query is typed.
class SearchResultsView extends StatelessWidget {
  const SearchResultsView({
    super.key,
    required this.search,
    required this.onOpen,
  });

  final NotebookSearch search;

  /// A result was clicked. [box] is the box whose snippet was clicked, or
  /// the page's first matching box when its title was.
  final void Function(SearchResultPage page, SearchResultBox box) onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final m = NotedMetrics.of(context);
        final type = NotedTypography.of(context);
        final scheme = Theme.of(context).colorScheme;
        final results = search.results;
        final children = <Widget>[
          if (search.busy)
            const LinearProgressIndicator(
              key: ValueKey('search-busy'),
              minHeight: 2,
            ),
          if (results.isEmpty && !search.busy)
            Padding(
              key: const ValueKey('search-empty'),
              padding: EdgeInsets.all(m.space4),
              child: Text(
                'No results',
                style: type.body.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          for (final page in results)
            _PageResult(page: page, onOpen: onOpen),
          if (search.notSearched.isNotEmpty) _NotSearched(items: search.notSearched),
        ];
        return ListView(
          key: const ValueKey('search-results'),
          padding: EdgeInsets.only(bottom: m.space4),
          children: children,
        );
      },
    );
  }
}

class _PageResult extends StatelessWidget {
  const _PageResult({required this.page, required this.onOpen});

  final SearchResultPage page;
  final void Function(SearchResultPage page, SearchResultBox box) onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final shown = page.boxes.take(maxSnippetsPerPage).toList();
    final hidden = page.matchCount - shown.fold(0, (n, b) => n + b.matchCount);
    final crumbs = page.path;
    return Column(
      key: ValueKey('search-page-${page.pageId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('search-page-title-${page.pageId}'),
          onTap: () => onOpen(page, page.boxes.first),
          child: Padding(
            padding: EdgeInsets.fromLTRB(m.space3, m.space3, m.space3, m.space1),
            child: Text.rich(
              TextSpan(
                children: [
                  if (crumbs.length > 1)
                    TextSpan(
                      text: '${crumbs.sublist(0, crumbs.length - 1).join(' / ')} / ',
                      style: type.small.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  TextSpan(text: crumbs.last, style: type.bodyStrong),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        for (final box in shown)
          InkWell(
            key: ValueKey('search-result-${page.pageId}-${box.boxId}'),
            onTap: () => onOpen(page, box),
            child: Padding(
              padding: EdgeInsets.fromLTRB(m.space4, m.space1, m.space3, m.space1),
              child: _SnippetText(snippet: box.snippet),
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: EdgeInsets.fromLTRB(m.space4, m.space1, m.space3, m.space1),
            child: Text(
              '+ $hidden more on this page',
              style: type.small.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Divider(height: m.space2, color: scheme.outlineVariant),
      ],
    );
  }
}

/// A snippet with its matches marked.
class _SnippetText extends StatelessWidget {
  const _SnippetText({required this.snippet});

  final SearchSnippet snippet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final text = snippet.text;
    final spans = <TextSpan>[];
    var at = 0;
    for (final h in snippet.highlights) {
      if (h.start > at) spans.add(TextSpan(text: text.substring(at, h.start)));
      spans.add(
        TextSpan(
          text: text.substring(h.start, h.end),
          style: TextStyle(
            fontWeight: FontWeight.w600,
            backgroundColor: scheme.tertiaryContainer,
            color: scheme.onTertiaryContainer,
          ),
        ),
      );
      at = h.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(children: spans),
      style: type.small.copyWith(color: scheme.onSurface),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _NotSearched extends StatelessWidget {
  const _NotSearched({required this.items});

  final List<NotSearched> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    return Column(
      key: const ValueKey('search-not-searched'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(m.space3, m.space4, m.space3, m.space1),
          child: Text(
            'NOT SEARCHED',
            style: type.label.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        for (final item in items)
          Padding(
            key: ValueKey('not-searched-${item.name}'),
            padding: EdgeInsets.fromLTRB(m.space3, m.space1, m.space3, m.space1),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: item.name, style: type.bodyStrong),
                  TextSpan(
                    text: '  ${item.reason}',
                    style: type.small.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
