// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_core/noted_core.dart';

import 'box_module.dart';
import 'canvas_controller.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';

/// Height of one editable pane in the manual merge view.
const double _paneHeight = 320;

/// Formats [ms] (since the epoch) as local `YYYY-MM-DD HH:MM`.
String formatConflictTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Shows both versions of the conflicted box [boxId] side by side, with the
/// ways to resolve it (0020).
Future<void> showConflictDialog(
  BuildContext context,
  CanvasController controller,
  String boxId,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ConflictDialog(controller: controller, boxId: boxId),
  );
}

/// The data of one version in the manual merge view. The module's editor
/// commits into it; nothing reaches the page until a version is chosen.
class _Held {
  _Held(this.module, this.data);

  final BoxModule<Object?> module;
  Object? data;
}

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog({required this.controller, required this.boxId});

  final CanvasController controller;
  final String boxId;

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  _Held? _mine;
  _Held? _theirs;

  CanvasController get controller => widget.controller;
  String get boxId => widget.boxId;

  /// The two versions of [box] decoded for the module's editor, or null if
  /// this device can't run both (or the conflict is a deletion).
  (_Held, _Held)? _versions(BoxRecord box, BoxConflict other) {
    if (other.deleted || other.node == null) return null;
    final otherNode = readNode(other.node!, fallbackId: boxId);
    if (otherNode is! BoxRecord || otherNode.typeId != box.typeId) return null;
    final module = controller.modules.moduleFor(box.typeId);
    if (module == null) return null;
    final codecs = controller.modules.codecs;
    final a = codecs.resolve(box);
    final b = codecs.resolve(otherNode);
    if (a is! LiveBox || b is! LiveBox) return null;
    return (_Held(module, a.data), _Held(module, b.data));
  }

  @override
  Widget build(BuildContext context) {
    final metrics = NotedMetrics.of(context);
    final box = controller.page.node(boxId);
    if (box is! BoxRecord || !box.isConflicted) {
      return const SizedBox.shrink();
    }
    final conflicts = box.conflicts;
    final deleted = conflicts.last.deleted;
    final other = conflicts.lastWhere((c) => c.node != null, orElse: () => conflicts.last);
    final otherNode = other.node == null ? null : readNode(other.node!, fallbackId: boxId);
    final otherText = switch (otherNode) {
      BoxRecord() => otherNode.snapshotText,
      ForeignNode() => otherNode.text ?? '',
      null => '',
    };
    final extra = conflicts.length - 1;

    final mineLabel = _mineLabel(box);
    final theirsLabel = _theirsLabel(other, otherNode, deleted);

    if (_mine != null && _theirs != null) {
      return _editDialog(mineLabel, theirsLabel);
    }

    final canEdit = !deleted && _versions(box, other) != null;

    void run(void Function(String) action) {
      action(boxId);
      Navigator.of(context).pop();
    }

    return AlertDialog(
      key: const ValueKey('conflict-dialog'),
      clipBehavior: Clip.antiAlias,
      titlePadding: EdgeInsets.zero,
      title: ConflictHeader(title: 'Conflicting changes'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (deleted)
              Padding(
                padding: EdgeInsets.only(bottom: metrics.space3),
                child: Text(
                  'This box was deleted on the other side while it was edited '
                  'here. It was kept.',
                ),
              ),
            Flexible(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Side(
                      key: const ValueKey('conflict-mine'),
                      label: mineLabel,
                      text: box.snapshotText,
                    ),
                  ),
                  SizedBox(width: metrics.space3),
                  Expanded(
                    child: _Side(
                      key: const ValueKey('conflict-theirs'),
                      label: theirsLabel,
                      text: deleted ? '(deleted)' : otherText,
                    ),
                  ),
                ],
              ),
            ),
            if (extra > 0)
              Padding(
                padding: EdgeInsets.only(top: metrics.space3),
                child: Text('$extra more version${extra == 1 ? '' : 's'} recorded.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (deleted) ...[
          OutlinedButton(
            key: const ValueKey('conflict-delete'),
            style: notedDestructiveButtonStyle(context),
            onPressed: () => run(controller.resolveDelete),
            child: const Text('Delete box'),
          ),
          FilledButton(
            key: const ValueKey('conflict-keep-mine'),
            onPressed: () => run(controller.resolveKeepMine),
            child: const Text('Keep box'),
          ),
        ] else ...[
          if (canEdit)
            OutlinedButton(
              key: const ValueKey('conflict-edit'),
              onPressed: () {
                final v = _versions(box, other);
                if (v == null) return;
                setState(() {
                  _mine = v.$1;
                  _theirs = v.$2;
                });
              },
              child: const Text('Edit manually'),
            ),
          OutlinedButton(
            key: const ValueKey('conflict-keep-theirs'),
            onPressed: () => run(controller.resolveKeepTheirs),
            child: const Text('Keep other version'),
          ),
          OutlinedButton(
            key: const ValueKey('conflict-keep-both'),
            onPressed: () => run(controller.resolveKeepBoth),
            child: const Text('Keep both'),
          ),
          FilledButton(
            key: const ValueKey('conflict-keep-mine'),
            onPressed: () => run(controller.resolveKeepMine),
            child: const Text('Keep mine'),
          ),
        ],
      ],
    );
  }

  String _mineLabel(BoxRecord box) {
    final name = controller.deviceName;
    final at = box.editedAt;
    return 'This device${name == null ? '' : ' ($name)'}'
        '${at == null ? '' : ' · edited ${formatConflictTime(at)}'}';
  }

  String _theirsLabel(BoxConflict other, CanvasNode? node, bool deleted) {
    final at = other.at > 0
        ? other.at
        : (node is BoxRecord ? node.editedAt : null);
    final name = other.device ?? (node is BoxRecord ? node.device : null) ?? 'Other device';
    final verb = deleted ? 'deleted' : 'saved';
    return '$name${at == null ? '' : ' · $verb ${formatConflictTime(at)}'}';
  }

  Widget _editDialog(String mineLabel, String theirsLabel) {
    final mine = _mine!;
    final theirs = _theirs!;
    final metrics = NotedMetrics.of(context);

    void use(_Held held) {
      if (controller.resolveWithData(boxId, held.data)) {
        Navigator.of(context).pop();
      }
    }

    return AlertDialog(
      key: const ValueKey('conflict-edit-dialog'),
      clipBehavior: Clip.antiAlias,
      titlePadding: EdgeInsets.zero,
      title: ConflictHeader(title: 'Edit manually'),
      content: SizedBox(
        width: 900,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _EditPane(
                key: const ValueKey('conflict-edit-mine'),
                boxId: boxId,
                label: mineLabel,
                held: mine,
                useKey: const ValueKey('conflict-use-mine'),
                primary: true,
                onUse: () => use(mine),
              ),
            ),
            SizedBox(width: metrics.space3),
            Expanded(
              child: _EditPane(
                key: const ValueKey('conflict-edit-theirs'),
                boxId: boxId,
                label: theirsLabel,
                held: theirs,
                useKey: const ValueKey('conflict-use-theirs'),
                onUse: () => use(theirs),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('conflict-edit-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// One version in the manual merge view: the module's own editor on
/// in-memory data, and the button that makes it the box's content.
class _EditPane extends StatelessWidget {
  const _EditPane({
    super.key,
    required this.boxId,
    required this.label,
    required this.held,
    required this.useKey,
    required this.onUse,
    this.primary = false,
  });

  final String boxId;
  final String label;
  final _Held held;
  final Key useKey;
  final VoidCallback onUse;

  /// The dialog's one primary button is the one for this device's version.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final metrics = NotedMetrics.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        SizedBox(height: metrics.space1),
        Container(
          height: _paneHeight,
          width: double.infinity,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: metrics.borderSm,
          ),
          child: LayoutBuilder(
            builder: (context, c) => held.module.hostBuild(
              context,
              BoxBinding(
                boxId: boxId,
                data: held.data,
                bounds: Rect.fromLTWH(0, 0, c.maxWidth, c.maxHeight),
                readOnly: false,
                autoHeight: false,
                autofocus: false,
                commit: (d) => held.data = d,
                requestBounds: (_) {},
              ),
            ),
          ),
        ),
        SizedBox(height: metrics.space2),
        if (primary)
          FilledButton(
            key: useKey,
            onPressed: onUse,
            child: const Text('Use this version'),
          )
        else
          OutlinedButton(
            key: useKey,
            onPressed: onUse,
            child: const Text('Use this version'),
          ),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final metrics = NotedMetrics.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        SizedBox(height: metrics.space1),
        Container(
          constraints: const BoxConstraints(minHeight: 80, maxHeight: 320),
          width: double.infinity,
          padding: EdgeInsets.all(metrics.space2),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: metrics.borderSm,
          ),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
      ],
    );
  }
}

/// The conflict view's header: the title on a `conflict-soft` band across
/// the top of the dialog.
class ConflictHeader extends StatelessWidget {
  const ConflictHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return ColoredBox(
      key: const ValueKey('conflict-header'),
      color: NotedColors.of(context).conflictSoft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(m.space6, m.space4, m.space6, m.space4),
        child: SizedBox(width: double.infinity, child: Text(title)),
      ),
    );
  }
}
