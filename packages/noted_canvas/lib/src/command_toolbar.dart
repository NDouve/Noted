// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'commands.dart';
import 'design_tokens.g.dart';
import 'noted_menu.dart';
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
/// [layout], built only from [registry] and drawn to the Toolbar guidelines.
///
/// Each button shows the command's state (checked, disabled), has a tooltip
/// with the label and shortcut, and invokes the command. The toolbar never
/// takes keyboard focus, so pressing a button leaves the editor you were
/// typing in focused (insert table and insert equation need that).
///
/// The last group of the layout (view controls: Fit all, zoom) sits at the
/// far right; the groups before it scroll sideways, or wrap on touch input.
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
    final m = NotedMetrics.of(context);
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final groups = resolveToolbarLayout(
          registry,
          layout,
          readOnly: readOnly,
        );
        // Everything before the last group; the last is the view group.
        final lead = groups.length > 1
            ? groups.sublist(0, groups.length - 1)
            : <List<Command>>[];
        final view = groups.isEmpty ? <Command>[] : groups.last;

        Widget row(List<Command> group) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, c) in group.indexed) ...[
              if (i > 0) SizedBox(width: m.space1),
              ToolbarEntry(key: ValueKey(c.id), command: c, registry: registry),
            ],
          ],
        );
        final leadWidgets = <Widget>[
          for (final (i, g) in lead.indexed) ...[
            if (i > 0) const ToolbarSeparator(),
            row(g),
          ],
        ];

        final Widget body = m.touch
            ? ConstrainedBox(
                constraints: BoxConstraints(minHeight: m.toolbarHeight),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.space4,
                    vertical: m.space1,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          runSpacing: m.space1,
                          children: leadWidgets,
                        ),
                      ),
                      row(view),
                    ],
                  ),
                ),
              )
            : SizedBox(
                height: m.toolbarHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: m.space4),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: leadWidgets),
                        ),
                      ),
                      row(view),
                    ],
                  ),
                ),
              );

        return Material(
          color: scheme.surface,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outline)),
            ),
            child: SizedBox(
              width: double.infinity,
              child: ExcludeFocus(child: body),
            ),
          ),
        );
      },
    );
  }
}

/// The 1 × 24px `border` rule between toolbar groups, with `space-2` on each
/// side.
class ToolbarSeparator extends StatelessWidget {
  const ToolbarSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.space2),
      child: SizedBox(
        width: 1,
        height: m.space6,
        child: ColoredBox(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

/// An ink color swatch for a command's icon builder: a 28px disc in the ink
/// color, with a 2px `accent` ring when [selected]. The toolbar shows a
/// command whose icon is a swatch without a button fill.
class ToolbarSwatch extends StatelessWidget {
  const ToolbarSwatch({super.key, required this.color, required this.selected});

  /// Disc diameter.
  static const double size = 28;

  /// Width of the selection ring.
  static const double ringWidth = 2;

  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = NotedMetrics.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: selected
            ? Border.all(color: scheme.primary, width: ringWidth)
            : null,
      ),
      // A gap of surface between the ring and the disc.
      child: Container(
        width: selected ? size - 2 * (ringWidth + m.space1 / 2) : size,
        height: selected ? size - 2 * (ringWidth + m.space1 / 2) : size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// One command as a toolbar button: an icon button, a ghost text button, an
/// ink swatch, the zoom readout or a dropdown, according to the command.
class ToolbarEntry extends StatelessWidget {
  const ToolbarEntry({super.key, required this.command, this.registry});

  final Command command;

  /// Where a dropdown's commands ([Command.menu]) are looked up.
  final CommandRegistry? registry;

  /// The button of a command that offers a menu: it shows the command's icon
  /// and opens a menu of the listed commands, the checked one marked.
  /// Commands the registry doesn't have are left out.
  Widget _menuButton(BuildContext context, Command c) {
    final r = registry;
    final items = [
      if (r != null)
        for (final id in c.menu)
          if (r[id] != null) r[id]!,
    ];
    return PopupMenuButton<String>(
      tooltip: c.tooltip,
      enabled: c.enabled && items.isNotEmpty,
      iconSize: NotedMetrics.of(context).icon,
      icon: c.iconBuilder?.call(context, false) ?? Icon(c.icon),
      onSelected: (id) => r?.invoke(id),
      itemBuilder: (_) => [
        for (final item in items) NotedMenuItem.forCommand(item, showCheck: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = command;
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final checked = c.checked ?? false;
    final onPressed = c.enabled ? c.run : null;
    if (c.menu.isNotEmpty) return _menuButton(context, c);
    final text = c.text?.call();

    if (c.readout) {
      return Tooltip(
        message: c.tooltip,
        child: Semantics(
          label: c.tooltip,
          child: OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              minimumSize: Size(56, m.controlSize),
              padding: EdgeInsets.symmetric(horizontal: m.space3),
              textStyle: type.numeric,
            ),
            child: Text(text ?? c.label),
          ),
        ),
      );
    }
    if (text != null || c.showLabel) {
      return Tooltip(
        message: c.tooltip,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: Size(m.controlSize, m.controlSize),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: type.body,
          ),
          child: Text(text ?? c.label),
        ),
      );
    }

    final custom = c.iconBuilder?.call(context, checked);
    if (custom is ToolbarSwatch) {
      return Tooltip(
        message: c.tooltip,
        child: Semantics(
          button: true,
          selected: checked,
          enabled: c.enabled,
          label: c.label,
          child: InkResponse(
            onTap: onPressed,
            radius: m.controlSize / 2,
            highlightShape: BoxShape.circle,
            child: SizedBox(
              width: m.controlSize,
              height: m.controlSize,
              child: Center(child: custom),
            ),
          ),
        ),
      );
    }
    return Semantics(
      toggled: c.checked,
      child: IconButton(
        tooltip: c.tooltip,
        isSelected: checked,
        iconSize: m.icon,
        style: checked
            ? IconButton.styleFrom(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.primary,
              )
            : null,
        icon: custom ?? Icon(c.icon),
        onPressed: onPressed,
      ),
    );
  }
}
