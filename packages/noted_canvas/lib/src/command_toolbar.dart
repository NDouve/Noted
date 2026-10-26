// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'commands.dart';
import 'design_tokens.g.dart';
import 'noted_theme.dart';
import 'toolbar_layout.dart';

/// The commands [layout] names, group by group, in the layout's order.
///
/// A group's ids that no command in [registry] has are skipped, and a group
/// left empty is dropped. On a [readOnly] page only the commands that work
/// there are kept.
List<List<Command>> resolveToolbarLayout(
  CommandRegistry registry,
  ToolbarLayout layout, {
  bool readOnly = false,
}) {
  final groups = <List<Command>>[];
  for (final ids in layout) {
    final group = <Command>[];
    for (final id in ids) {
      final c = registry[id];
      if (c == null || (readOnly && !c.whileReadOnly)) continue;
      group.add(c);
    }
    if (group.isNotEmpty) groups.add(group);
  }
  return groups;
}

/// The toolbar along the top of a canvas: one button for each command in
/// [layout], built only from [registry] and drawn with the theme's colors.
///
/// Each button shows the command's state (checked, disabled), has a tooltip
/// with the label and shortcut, and invokes the command. The toolbar never
/// takes keyboard focus, so pressing a button leaves the editor you were
/// typing in focused (insert table and insert equation need that).
class CommandToolbar extends StatelessWidget {
  const CommandToolbar({
    super.key,
    required this.registry,
    this.layout = defaultToolbarLayout,
    this.readOnly = false,
  });

  final CommandRegistry registry;
  final ToolbarLayout layout;
  final bool readOnly;

  /// The height of the toolbar.
  static const double height = DesignMetrics.toolbarHeight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final metrics = NotedMetrics.of(context);
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final groups = resolveToolbarLayout(
          registry,
          layout,
          readOnly: readOnly,
        );
        return Material(
          color: scheme.surfaceContainer,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: ExcludeFocus(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      SizedBox(width: metrics.space2),
                      for (final (i, group) in groups.indexed) ...[
                        if (i > 0)
                          SizedBox(
                            height: metrics.control - metrics.space2,
                            child: VerticalDivider(width: metrics.space4 + 1),
                          ),
                        for (final c in group)
                          _CommandButton(key: ValueKey(c.id), command: c),
                      ],
                      SizedBox(width: metrics.space2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CommandButton extends StatelessWidget {
  const _CommandButton({super.key, required this.command});

  final Command command;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = command;
    final checked = c.checked ?? false;
    final onPressed = c.enabled ? c.run : null;
    final text = c.text?.call();
    if (text != null || c.showLabel) {
      final label = Text(text ?? c.label);
      return Tooltip(
        message: c.tooltip,
        child: text != null
            ? TextButton(
                onPressed: onPressed,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: NotedMetrics.of(context).control,
                  ),
                  child: Center(widthFactor: 1, child: label),
                ),
              )
            : TextButton.icon(
                onPressed: onPressed,
                icon: Icon(c.icon),
                label: label,
              ),
      );
    }
    return IconButton(
      tooltip: c.tooltip,
      isSelected: checked,
      style: checked
          ? IconButton.styleFrom(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
            )
          : null,
      icon: c.iconBuilder?.call(context, checked) ?? Icon(c.icon),
      onPressed: onPressed,
    );
  }
}
