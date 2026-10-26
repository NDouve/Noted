// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_core/noted_core.dart';

import 'binder_colors.dart';
import 'notebook.dart';

/// Reads a binder color (`#AARRGGBB`); falls back to the first palette color.
Color parseBinderColor(String hex) {
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = h.length == 8 ? int.tryParse(h, radix: 16) : null;
  return Color(v ?? int.parse(binderPalette.first.substring(1), radix: 16));
}

String _two(int n) => n.toString().padLeft(2, '0');

String _formatTime(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
}

/// A binder's cover page (0026), shown in place of a canvas: title,
/// description and owner can be edited, the last edited time is automatic.
class BinderCover extends StatefulWidget {
  const BinderCover({super.key, required this.notebook, required this.path});

  final Notebook notebook;
  final String path;

  @override
  State<BinderCover> createState() => _BinderCoverState();
}

class _BinderCoverState extends State<BinderCover> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _owner;
  final FocusNode _titleFocus = FocusNode();

  BinderSection? get _section => widget.notebook.binders
      .cast<BinderSection?>()
      .firstWhere((b) => b!.path == widget.path, orElse: () => null);

  @override
  void initState() {
    super.initState();
    final b = _section?.binder;
    _title = TextEditingController(text: b?.title ?? '');
    _description = TextEditingController(text: b?.description ?? '');
    _owner = TextEditingController(text: b?.owner ?? '');
    _applied = (b?.title ?? '', b?.description ?? '', b?.owner ?? '');
    widget.notebook.addListener(_takeExternalChanges);
    // A binder just created asks for the caret in its title.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocusIfAsked());
  }

  // The values of the binder the fields were last brought in line with.
  late (String, String, String) _applied;

  // The binder file changed on another machine: show the new values. A field
  // whose text the user has changed and not saved yet keeps that text.
  void _takeExternalChanges() {
    final b = _section?.binder;
    if (b == null) return;
    void take(TextEditingController c, String was, String now) {
      if (now == was || c.text == now) return;
      if (c.text != was) return; // being edited
      c.text = now;
    }

    take(_title, _applied.$1, b.title);
    take(_description, _applied.$2, b.description);
    take(_owner, _applied.$3, b.owner);
    _applied = (b.title, b.description, b.owner);
  }

  @override
  void dispose() {
    widget.notebook.removeListener(_takeExternalChanges);
    // Leaving the cover keeps what was typed. The notebook is told after the
    // widget tree has finished updating.
    final nb = widget.notebook;
    final (path, title, description, owner) = (
      widget.path,
      _title.text,
      _description.text,
      _owner.text,
    );
    Future.microtask(
      () => nb.updateBinder(path, title: title, description: description, owner: owner),
    );
    _titleFocus.dispose();
    _title.dispose();
    _description.dispose();
    _owner.dispose();
    super.dispose();
  }

  void _save() {
    widget.notebook.updateBinder(
      widget.path,
      title: _title.text,
      description: _description.text,
      owner: _owner.text,
    );
  }

  void _takeFocusIfAsked() {
    if (!mounted || !widget.notebook.takeTitleFocus('cover:${widget.path}')) return;
    _titleFocus.requestFocus();
    _title.selection = TextSelection(baseOffset: 0, extentOffset: _title.text.length);
  }

  Widget _field(
    String key,
    String label,
    TextEditingController c, {
    int maxLines = 1,
    FocusNode? focusNode,
  }) {
    return Focus(
      onFocusChange: (focused) {
        if (!focused) _save();
      },
      child: TextField(
        key: ValueKey(key),
        controller: c,
        focusNode: focusNode,
        maxLines: maxLines,
        minLines: 1,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onSubmitted: (_) => _save(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.notebook,
      builder: (context, _) {
        final section = _section;
        final binder = section?.binder;
        if (section == null || binder == null) return SizedBox();
        final color = binderPageColor(context, binder.color);
        final last = section.lastEdited;
        return Align(
          alignment: Alignment.topLeft,
          child: SingleChildScrollView(
            padding: EdgeInsets.all(NotedMetrics.of(context).space6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(height: NotedMetrics.of(context).space1, color: color),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  Text('Binder cover', style: theme.textTheme.labelMedium),
                  SizedBox(height: NotedMetrics.of(context).space3),
                  _field('cover-title', 'Title', _title, focusNode: _titleFocus),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  _field('cover-description', 'Description', _description, maxLines: 5),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  _field('cover-owner', 'Owner', _owner),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  Text('Color', style: theme.textTheme.labelMedium),
                  SizedBox(height: NotedMetrics.of(context).space2),
                  Wrap(
                    spacing: NotedMetrics.of(context).space2,
                    runSpacing: NotedMetrics.of(context).space2,
                    children: [
                      for (final hex in binderPalette)
                        Tooltip(
                          message: hex,
                          child: InkResponse(
                            key: ValueKey('cover-color-$hex'),
                            onTap: () => widget.notebook.updateBinder(widget.path, color: hex),
                            child: Container(
                              width: NotedMetrics.of(context).row,
                              height: NotedMetrics.of(context).row,
                              decoration: BoxDecoration(
                                color: binderPageColor(context, hex),
                                shape: BoxShape.circle,
                                border: hex == binder.color
                                    ? Border.all(
                                        color: theme.colorScheme.onSurface,
                                        width: 3,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: NotedMetrics.of(context).space6),
                  Text('Last edited', style: theme.textTheme.labelMedium),
                  Text(
                    last == null ? 'Unknown' : _formatTime(last),
                    key: const ValueKey('cover-last-edited'),
                  ),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  Text('Storage folder', style: theme.textTheme.labelMedium),
                  SelectableText(section.path, key: const ValueKey('cover-path')),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
