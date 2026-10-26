// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_core/noted_core.dart';

import 'notebook.dart';

/// A matched range of a page's title to mark in the title field, after a
/// title result of the search was opened. Decoration only: it is painted
/// over the text and never selects, focuses or edits it.
@immutable
class TitleHighlight {
  const TitleHighlight({
    required this.pageId,
    required this.title,
    required this.ranges,
  });

  final String pageId;

  /// The title the ranges are in. The highlight shows only while the field
  /// still holds exactly this text.
  final String title;
  final List<SearchRange> ranges;
}

class _HighlightingController extends TextEditingController {
  _HighlightingController({super.text});

  TitleHighlight? highlight;
  Color? background;
  Color? foreground;

  void repaint() => notifyListeners();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final h = highlight;
    if (h == null || h.title != text || value.composing.isValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final spans = <TextSpan>[];
    var at = 0;
    for (final r in h.ranges) {
      if (r.start < at || r.end > text.length) continue;
      if (r.start > at) spans.add(TextSpan(text: text.substring(at, r.start)));
      spans.add(
        TextSpan(
          text: text.substring(r.start, r.end),
          style: TextStyle(backgroundColor: background, color: foreground),
        ),
      );
      at = r.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(style: style, children: spans);
  }
}

/// The title above a page's canvas, edited in place. Enter or leaving the
/// field renames the page; an empty title is put back to the old one.
///
/// A page just created asks for the caret here ([Notebook.requestTitleFocus]),
/// with the whole title selected so typing replaces "Untitled page".
class PageTitleField extends StatefulWidget {
  const PageTitleField({
    super.key,
    required this.notebook,
    required this.pageId,
    this.highlight,
  });

  final Notebook notebook;
  final String pageId;

  /// The range of the title to mark, if it is for this page. Cleared when
  /// the title is edited and when the field goes away.
  final ValueNotifier<TitleHighlight?>? highlight;

  @override
  State<PageTitleField> createState() => _PageTitleFieldState();
}

class _PageTitleFieldState extends State<PageTitleField> {
  late final _HighlightingController _text;
  final FocusNode _focus = FocusNode();

  // The title as last shown or saved, to tell whether the text was changed.
  String _known = '';

  Notebook get _nb => widget.notebook;

  String get _title => _nb.current?.page.meta.title ?? '';

  @override
  void initState() {
    super.initState();
    _known = _title;
    _text = _HighlightingController(text: _title);
    _text.addListener(_textChanged);
    widget.highlight?.addListener(_highlightChanged);
    _highlightChanged();
    _focus.addListener(_onFocus);
    _nb.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocusIfAsked());
  }

  @override
  void dispose() {
    // Leaving the page keeps what was typed, as the cover does.
    final typed = _text.text.trim();
    final (nb, id) = (_nb, widget.pageId);
    if (typed.isNotEmpty && typed != _known && nb.readOnlyReason == null) {
      Future.microtask(() => nb.rename(id, typed).catchError((Object _) {}));
    }
    _nb.removeListener(_sync);
    widget.highlight?.removeListener(_highlightChanged);
    final h = widget.highlight;
    if (h != null && h.value?.pageId == widget.pageId) {
      // Opening another page drops the mark.
      Future.microtask(() {
        if (h.value?.pageId == id) h.value = null;
      });
    }
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _highlightChanged() {
    final h = widget.highlight?.value;
    final mine = h != null && h.pageId == widget.pageId ? h : null;
    if (!identical(_text.highlight, mine)) {
      _text.highlight = mine;
      // Repaint with (or without) the mark; the text itself is unchanged.
      _text.repaint();
    }
  }

  // Any edit of the title drops the mark.
  void _textChanged() {
    final h = _text.highlight;
    if (h != null && h.title != _text.text) {
      widget.highlight?.value = null;
    }
  }

  // The page was renamed elsewhere (the sidebar): show it, unless the title
  // is being typed.
  void _sync() {
    if (!_focus.hasFocus && _text.text != _title) {
      _text.text = _title;
      _known = _title;
    }
    _takeFocusIfAsked();
  }

  void _takeFocusIfAsked() {
    if (!mounted || !_nb.takeTitleFocus(widget.pageId)) return;
    _focus.requestFocus();
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
  }

  void _onFocus() {
    if (!_focus.hasFocus) _commit();
  }

  Future<void> _commit() async {
    final t = _text.text.trim();
    if (t.isEmpty || t == _title) {
      if (t.isEmpty) _text.text = _title;
      return;
    }
    try {
      _known = t;
      await _nb.rename(widget.pageId, t);
    } on NotebookException {
      if (mounted) _text.text = _title;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _text
      ..background = scheme.tertiaryContainer
      ..foreground = scheme.onTertiaryContainer;
    return TextField(
      key: const ValueKey('page-title-field'),
      controller: _text,
      focusNode: _focus,
      readOnly: _nb.readOnlyReason != null,
      style: Theme.of(context).textTheme.headlineSmall,
      maxLines: 1,
      decoration: const InputDecoration.collapsed(hintText: 'Untitled page'),
      onSubmitted: (_) {
        _commit();
        _focus.unfocus();
      },
    );
  }
}
