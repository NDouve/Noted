// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'noted_theme.dart';
import 'page_find.dart';

/// The find bar over the top-right of a canvas: the text to look for, how
/// many matches there are ("3 of 12"), previous and next, and close.
///
/// Enter and Shift+Enter step to the next and previous match, Escape closes
/// the bar. The bar takes keyboard focus when it opens.
class FindBar extends StatefulWidget {
  const FindBar({
    super.key,
    required this.find,
    required this.focusNode,
    required this.onClose,
  });

  final PageFind find;
  final FocusNode focusNode;

  /// The bar asked to close (Escape or the close button).
  final VoidCallback onClose;

  /// Width of the bar.
  static const double width = 360;

  @override
  State<FindBar> createState() => _FindBarState();
}

class _FindBarState extends State<FindBar> {
  late final TextEditingController _text = TextEditingController(
    text: widget.find.text,
  );
  int _tick = -1;

  @override
  void initState() {
    super.initState();
    widget.find.addListener(_changed);
    _sync();
  }

  @override
  void dispose() {
    widget.find.removeListener(_changed);
    _text.dispose();
    super.dispose();
  }

  void _changed() {
    _sync();
    if (mounted) setState(() {});
  }

  void _sync() {
    final f = widget.find;
    if (f.text != _text.text) {
      _text.value = TextEditingValue(
        text: f.text,
        selection: TextSelection.collapsed(offset: f.text.length),
      );
    }
    if (f.focusTick != _tick) {
      _tick = f.focusTick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.focusNode.requestFocus();
        _text.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _text.text.length,
        );
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      widget.find.step(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _count() {
    final f = widget.find;
    if (f.query.isEmpty) return '';
    if (f.matches.isEmpty) return 'No matches';
    return '${f.currentIndex + 1} of ${f.matches.length}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final f = widget.find;
    final hasMatches = f.matches.isNotEmpty;
    return Material(
      key: const ValueKey('find-bar'),
      color: scheme.surface,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: m.borderLg,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: SizedBox(
        width: FindBar.width,
        child: Padding(
          padding: EdgeInsets.only(left: m.space3, right: m.space1),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: m.icon,
                color: scheme.onSurfaceVariant,
              ),
              SizedBox(width: m.space2),
              Expanded(
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    key: const ValueKey('find-field'),
                    controller: _text,
                    focusNode: widget.focusNode,
                    style: type.body,
                    cursorColor: scheme.primary,
                    onChanged: f.setText,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      hintText: 'Find on page',
                    ),
                  ),
                ),
              ),
              Text(
                _count(),
                key: const ValueKey('find-count'),
                style: type.small.copyWith(color: scheme.onSurfaceVariant),
              ),
              SizedBox(width: m.space1),
              IconButton(
                key: const ValueKey('find-previous'),
                tooltip: 'Previous match (Shift+Enter)',
                iconSize: m.icon,
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                onPressed: hasMatches ? () => f.step(-1) : null,
              ),
              IconButton(
                key: const ValueKey('find-next'),
                tooltip: 'Next match (Enter)',
                iconSize: m.icon,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                onPressed: hasMatches ? () => f.step(1) : null,
              ),
              IconButton(
                key: const ValueKey('find-close'),
                tooltip: 'Close (Esc)',
                iconSize: m.icon,
                icon: const Icon(Icons.close_rounded),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
