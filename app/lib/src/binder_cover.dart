// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;
import 'package:noted_core/noted_core.dart';

import 'binder_colors.dart';
import 'notebook.dart';
import 'settings_panel.dart';

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
    _applied = (title: b?.title ?? '', description: b?.description ?? '', owner: b?.owner ?? '');
    _shownId = b?.id;
    widget.notebook.addListener(_takeExternalChanges);
    widget.notebook.registerCoverTyping(widget.path, _typing);
    // A binder just created asks for the caret in its title.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocusIfAsked());
  }

  // The comparison base B: the values the fields were last brought in line with
  // (the notebook lays the folder's unwritten cover changes over it).
  late CoverText _applied;

  // The id of the binder the fields show.
  String? _shownId;

  // What is typed and not sent, with the base and the shown binder, read at once
  // (D2).
  CoverTyping _typing() => (
    text: (title: _title.text, description: _description.text, owner: _owner.text),
    applied: _applied,
    shownId: _shownId,
  );

  // The binder or the folder's unwritten changes changed (another device, a
  // landing, Discard): a field whose text equals the value it showed takes the
  // new one; a field whose text differs keeps it. Focus plays no part.
  void _takeExternalChanges() {
    final b = _section?.binder;
    if (b == null) return;
    void take(TextEditingController c, String was, String now) {
      if (now == was || c.text == now) return;
      if (c.text != was) return; // being edited
      c.text = now;
    }

    take(_title, _applied.title, b.title);
    take(_description, _applied.description, b.description);
    take(_owner, _applied.owner, b.owner);
    _applied = (title: b.title, description: b.description, owner: b.owner);
    _shownId = b.id;
  }

  @override
  void dispose() {
    widget.notebook.removeListener(_takeExternalChanges);
    // Leaving the cover keeps what was typed. The notebook is told after the
    // widget tree has finished updating. The text, the base and the shown binder
    // are captured now; what was already taken (by a state change, quit or hide)
    // equals the base and records nothing.
    final nb = widget.notebook;
    final path = widget.path;
    final text = _typing();
    nb.unregisterCoverTyping(path);
    Future.microtask(
      () => nb.updateBinder(
        path,
        title: text.text.title,
        description: text.text.description,
        owner: text.text.owner,
        applied: text.applied,
        shownId: text.shownId,
      ),
    );
    _titleFocus.dispose();
    _title.dispose();
    _description.dispose();
    _owner.dispose();
    super.dispose();
  }

  void _save() {
    final t = _typing();
    unawaited(
      widget.notebook.updateBinder(
        widget.path,
        title: t.text.title,
        description: t.text.description,
        owner: t.text.owner,
        applied: t.applied,
        shownId: t.shownId,
      ),
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
        readOnly: widget.notebook.isPullOnlyLocation(widget.path),
        // Dimmed, like the settings of a pull-only binder, so it does not look editable.
        enabled: !widget.notebook.isPullOnlyLocation(widget.path),
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
        final pullOnly = widget.notebook.isPullOnlyLocation(widget.path);
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
                  Row(
                    children: [
                      Expanded(child: Text('Binder cover', style: theme.textTheme.labelMedium)),
                      IconButton(
                        key: const ValueKey('cover-settings'),
                        tooltip: 'Binder settings',
                        icon: const Icon(Icons.tune_rounded),
                        iconSize: NotedMetrics.of(context).icon,
                        color: theme.colorScheme.onSurfaceVariant,
                        onPressed: () => showBinderSettings(context, widget.notebook, widget.path),
                      ),
                    ],
                  ),
                  if (pullOnly) ...[
                    Text(
                      Notebook.pullOnlyMessage,
                      key: const ValueKey('cover-read-only'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    SizedBox(height: NotedMetrics.of(context).space2),
                  ],
                  if (widget.notebook.coverNotSaved(widget.path)) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Not saved yet',
                            key: const ValueKey('cover-not-saved'),
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('cover-discard'),
                          onPressed: () => unawaited(widget.notebook.confirmDiscardCoverChanges(widget.path)),
                          child: const Text('Discard'),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: NotedMetrics.of(context).space3),
                  _field('cover-title', 'Title', _title, focusNode: _titleFocus),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  _field('cover-description', 'Description', _description, maxLines: 5),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  _field('cover-owner', 'Owner', _owner),
                  SizedBox(height: NotedMetrics.of(context).space4),
                  Text('Color', style: theme.textTheme.labelMedium),
                  SizedBox(height: NotedMetrics.of(context).space2),
                  Opacity(
                    opacity: pullOnly ? 0.4 : 1,
                    child: Wrap(
                    spacing: NotedMetrics.of(context).space2,
                    runSpacing: NotedMetrics.of(context).space2,
                    children: [
                      for (final hex in binderPalette)
                        Tooltip(
                          message: hex,
                          child: InkResponse(
                            key: ValueKey('cover-color-$hex'),
                            onTap: pullOnly ? null : () => widget.notebook.updateBinder(widget.path, color: hex),
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
