// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_core/noted_core.dart';

import 'canvas_controller.dart';

/// The colour of a conflicted box's frame and badge.
const Color conflictColor = Color(0xFFF59E0B);

/// Formats [ms] (since the epoch) as local `YYYY-MM-DD HH:MM`.
String formatConflictTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Shows both versions of the conflicted box [boxId] side by side, read-only,
/// with the ways to resolve it (0020).
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

class _ConflictDialog extends StatelessWidget {
  const _ConflictDialog({required this.controller, required this.boxId});

  final CanvasController controller;
  final String boxId;

  @override
  Widget build(BuildContext context) {
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

    void run(void Function(String) action) {
      action(boxId);
      Navigator.of(context).pop();
    }

    return AlertDialog(
      key: const ValueKey('conflict-dialog'),
      title: const Text('Conflicting changes'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (deleted)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
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
                      label: 'This device',
                      text: box.snapshotText,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Side(
                      key: const ValueKey('conflict-theirs'),
                      label: deleted
                          ? 'Other version, deleted ${formatConflictTime(other.at)}'
                          : 'Other version, saved ${formatConflictTime(other.at)}',
                      text: deleted ? '(deleted)' : otherText,
                    ),
                  ),
                ],
              ),
            ),
            if (extra > 0)
              Padding(
                padding: const EdgeInsets.only(top: 12),
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
          TextButton(
            key: const ValueKey('conflict-delete'),
            onPressed: () => run(controller.resolveDelete),
            child: const Text('Delete box'),
          ),
          FilledButton(
            key: const ValueKey('conflict-keep-mine'),
            onPressed: () => run(controller.resolveKeepMine),
            child: const Text('Keep box'),
          ),
        ] else ...[
          TextButton(
            key: const ValueKey('conflict-keep-theirs'),
            onPressed: () => run(controller.resolveKeepTheirs),
            child: const Text('Keep other version'),
          ),
          TextButton(
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
}

class _Side extends StatelessWidget {
  const _Side({super.key, required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Container(
          constraints: const BoxConstraints(minHeight: 80, maxHeight: 320),
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
      ],
    );
  }
}
