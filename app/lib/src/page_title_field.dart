// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'notebook.dart';

/// The title above a page's canvas, edited in place. Enter or leaving the
/// field renames the page; an empty title is put back to the old one.
///
/// A page just created asks for the caret here ([Notebook.requestTitleFocus]),
/// with the whole title selected so typing replaces "Untitled page".
class PageTitleField extends StatefulWidget {
  const PageTitleField({super.key, required this.notebook, required this.pageId});

  final Notebook notebook;
  final String pageId;

  @override
  State<PageTitleField> createState() => _PageTitleFieldState();
}

class _PageTitleFieldState extends State<PageTitleField> {
  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();

  // The title as last shown or saved, to tell whether the text was changed.
  String _known = '';

  Notebook get _nb => widget.notebook;

  String get _title => _nb.current?.page.meta.title ?? '';

  @override
  void initState() {
    super.initState();
    _known = _title;
    _text = TextEditingController(text: _title);
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
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _text.dispose();
    super.dispose();
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
