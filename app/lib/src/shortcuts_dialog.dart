// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

/// The commands that have a shortcut in [registries], as `(label, keys)` in
/// the order found and once per command id. A registry may be null (no page
/// is open).
List<(String, String)> shortcutRows(Iterable<CommandRegistry?> registries) {
  final seen = <String>{};
  final rows = <(String, String)>[];
  for (final r in registries) {
    if (r == null) continue;
    for (final c in r.commands) {
      final keys = menuShortcutFor(c);
      if (keys == null || !seen.add(c.id)) continue;
      rows.add((c.label, keys));
    }
  }
  return rows;
}

/// Help > Keyboard shortcuts: a read-only list of every command that has a
/// shortcut in the live registries.
Future<void> showShortcutsDialog(BuildContext context, Iterable<CommandRegistry?> registries) {
  final rows = shortcutRows(registries);
  return showDialog<void>(
    context: context,
    builder: (context) {
      final m = NotedMetrics.of(context);
      final type = NotedTypography.of(context);
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 420,
          child: ListView(
            key: const ValueKey('shortcuts-list'),
            shrinkWrap: true,
            children: [
              for (final (label, keys) in rows)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: m.space1),
                  child: Row(
                    children: [
                      Expanded(child: Text(label, style: type.body)),
                      SizedBox(width: m.space4),
                      Text(keys, style: type.small.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      );
    },
  );
}
