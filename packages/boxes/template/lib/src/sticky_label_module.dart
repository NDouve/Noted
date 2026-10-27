// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'sticky_label_codec.dart';

/// The Flutter side of the sticky label box (0034): one text field and a
/// colour from a small fixed palette.
///
/// A module is a [BoxModule] that points at its [codec] and builds two
/// widgets. Its content reaches the page only through [BoxContext.commit].
///
/// Optional hooks this module does not use (see `BoxModule`):
/// - `buildSettings`: a settings panel for the box.
/// - `tools` and `commands`: canvas tools (a pen) and commands (an
///   "insert sticky label" button or shortcut). Command ids are namespaced
///   by module and must be unique. This module adds none, so a label is
///   created in code or by a future command, not from the toolbar.
/// - `frameStyle`: `BoxFrameStyle.framelessUntilSelected` for content that
///   sits straight on the page (the drawing box does this).
/// - `snapshotImage`: an image snapshot (0035); null means text only.
/// - `BoxContext.find`: while Find on page is open, a module may mark the
///   matches inside its own content by matching the query against its own
///   text snapshot (`SearchQuery.rangesIn`). Without it the canvas still
///   frames the boxes that match.
/// - `BoxContext.requestBounds`: ask the host to resize the box.
final class StickyLabelModule extends BoxModule<StickyLabelData> {
  const StickyLabelModule();

  @override
  BoxCodec<StickyLabelData> get codec => const StickyLabelCodec();

  /// The live box, shown when the page is editable.
  @override
  Widget buildEditor(BuildContext context, BoxContext<StickyLabelData> box) =>
      _StickyLabelEditor(box: box);

  /// The box shown read-only (a read-only page, a conflict preview).
  @override
  Widget buildView(BuildContext context, BoxContext<StickyLabelData> box) =>
      _LabelSurface(
        color: box.data.color,
        child: Text(
          box.data.text,
          key: const ValueKey('sticky-label-text'),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
}

/// The shade for a palette name in the current theme. A name this version
/// doesn't know gets the default shade.
Color stickyLabelShade(BuildContext context, String name) {
  final c = NotedColors.of(context);
  return switch (name) {
    'orange' => c.inkOrange,
    'green' => c.inkGreen,
    'purple' => c.inkPurple,
    _ => c.inkBlue,
  };
}

/// A tinted background with an accent bar, so the colour reads in both
/// light and dark themes.
class _LabelSurface extends StatelessWidget {
  const _LabelSurface({required this.color, required this.child});

  final String color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shade = stickyLabelShade(context, color);
    return DecoratedBox(
      key: const ValueKey('sticky-label-surface'),
      decoration: BoxDecoration(
        color: shade.withValues(alpha: 0.16),
        border: Border(left: BorderSide(color: shade, width: 4)),
      ),
      child: Padding(padding: const EdgeInsets.all(8), child: child),
    );
  }
}

class _StickyLabelEditor extends StatefulWidget {
  const _StickyLabelEditor({required this.box});

  final BoxContext<StickyLabelData> box;

  @override
  State<_StickyLabelEditor> createState() => _StickyLabelEditorState();
}

class _StickyLabelEditorState extends State<_StickyLabelEditor> {
  late final TextEditingController _controller;

  /// What this editor last committed. The host hands the same object back as
  /// `box.data`, so a different object means the data changed elsewhere
  /// (undo, a reload, a merge) and the field must follow it.
  late StickyLabelData _current;

  @override
  void initState() {
    super.initState();
    _current = widget.box.data;
    _controller = TextEditingController(text: _current.text);
  }

  @override
  void didUpdateWidget(_StickyLabelEditor old) {
    super.didUpdateWidget(old);
    final data = widget.box.data;
    if (!identical(data, _current)) {
      _current = data;
      if (_controller.text != data.text) _controller.text = data.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Commits [next]. `copyWith` keeps the unknown keys of the data.
  void _commit(StickyLabelData next) {
    setState(() => _current = next);
    widget.box.commit(next);
  }

  @override
  Widget build(BuildContext context) {
    return _LabelSurface(
      color: _current.color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('sticky-label-field'),
              controller: _controller,
              autofocus: widget.box.autofocus,
              maxLines: null,
              expands: true,
              decoration: const InputDecoration.collapsed(hintText: 'Label'),
              style: Theme.of(context).textTheme.bodyLarge,
              onChanged: (text) => _commit(_current.copyWith(text: text)),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final name in stickyLabelColors)
                _Swatch(
                  name: name,
                  shade: stickyLabelShade(context, name),
                  selected: name == _current.color,
                  onTap: () => _commit(_current.copyWith(color: name)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.shade,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color shade;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Label colour $name',
      child: GestureDetector(
        key: ValueKey('sticky-label-color-$name'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: shade,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
