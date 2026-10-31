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

/// The toolbar along the top of a canvas, laid out by [layout] (one of the
/// built-in [ToolbarStyle]s) and built only from [registry]. Commands the
/// layout names that the registry doesn't have are skipped.
///
/// - [TabbedToolbarLayout]: a row of tabs, with the layout's leading
///   commands left of them and its trailing commands at the right end, above
///   a bar with the chosen tab's commands. A tab with nothing to show (all
///   its commands are left out on a read-only page) is hidden.
/// - [ContextualToolbarLayout]: one bar; the leading commands at the left,
///   the trailing ones at the right, and between them a shaded section, the
///   first of the layout's sections whose condition holds.
///
/// Each button shows the command's state (checked, disabled), has a tooltip
/// with the label and shortcut, and invokes the command. The toolbar never
/// takes keyboard focus, so pressing a button leaves the editor you were
/// typing in focused (the note commands need that).
///
/// The bar's trailing commands sit at the far right and shrink to fit; the
/// commands before them scroll sideways, or wrap on touch input.
class CommandToolbar extends StatefulWidget {
  const CommandToolbar({
    super.key,
    required this.registry,
    this.layout = contextualToolbarLayout,
    this.readOnly = false,
  });

  final CommandRegistry registry;
  final ToolbarArrangement layout;
  final bool readOnly;

  /// The height of one bar: the whole [ContextualToolbarLayout] toolbar, or
  /// the command bar under a [TabbedToolbarLayout]'s tabs.
  static const double height = DesignMetrics.toolbarHeight;

  /// The height of the row of tabs, on desktop.
  static const double tabRowHeight =
      DesignMetrics.control + DesignMetrics.space1;

  /// The toolbar's height for [layout] on desktop.
  static double heightFor(ToolbarArrangement layout) => switch (layout) {
    TabbedToolbarLayout() => tabRowHeight + height,
    ContextualToolbarLayout() => height,
  };

  /// The key of the tab with [id] in the row of tabs.
  static Key tabKey(String id) => ValueKey('toolbar-tab-$id');

  /// The key of the shaded middle section with [id] of a contextual
  /// toolbar.
  static Key sectionKey(String id) => ValueKey('toolbar-section-$id');

  @override
  State<CommandToolbar> createState() => _CommandToolbarState();
}

class _CommandToolbarState extends State<CommandToolbar> {
  /// The chosen tab of a tabbed layout (null: the first shown).
  String? _tab;

  List<List<Command>> _resolve(ToolbarLayout groups) => resolveToolbarLayout(
    widget.registry,
    groups,
    readOnly: widget.readOnly,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.registry,
      builder: (context, _) => Material(
        color: scheme.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: scheme.outline)),
          ),
          child: SizedBox(
            width: double.infinity,
            child: ExcludeFocus(
              child: switch (widget.layout) {
                final TabbedToolbarLayout l => _tabbed(context, l),
                final ContextualToolbarLayout l => _contextual(context, l),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(List<Command> group) {
    final m = NotedMetrics.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, c) in group.indexed) ...[
          if (i > 0) SizedBox(width: m.space1),
          ToolbarEntry(
            key: ValueKey(c.id),
            command: c,
            registry: widget.registry,
          ),
        ],
      ],
    );
  }

  List<Widget> _groups(List<List<Command>> groups) => [
    for (final (i, g) in groups.indexed) ...[
      if (i > 0) const ToolbarSeparator(),
      _row(g),
    ],
  ];

  /// One bar: [leading] fixed at the left, [middle] scrolling after it,
  /// [trailing] at the far right; the fixed ends shrink to fit a narrow bar.
  /// On touch input [leading] and [middle] wrap together instead.
  Widget _bar({
    List<Widget> leading = const [],
    List<Widget> middle = const [],
    List<Widget> trailing = const [],
  }) {
    final m = NotedMetrics.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        // Each fixed end may take at most 40% of the bar; the rest is for
        // the middle.
        Widget fit(List<Widget> children, Alignment alignment) =>
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: c.maxWidth * 0.4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: alignment,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              ),
            );
        final end = trailing.isEmpty
            ? const SizedBox.shrink()
            : fit(trailing, Alignment.centerRight);
        final start = [
          if (leading.isNotEmpty) fit(leading, Alignment.centerLeft),
          if (leading.isNotEmpty && middle.isNotEmpty) SizedBox(width: m.space2),
        ];
        if (m.touch) middle = [...leading, ...middle];
        return m.touch
            ? ConstrainedBox(
                constraints: BoxConstraints(minHeight: m.toolbarHeight),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.space4,
                    vertical: m.space1,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          runSpacing: m.space1,
                          children: middle,
                        ),
                      ),
                      end,
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
                      ...start,
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: middle),
                        ),
                      ),
                      end,
                    ],
                  ),
                ),
              );
      },
    );
  }

  Widget _contextual(BuildContext context, ContextualToolbarLayout l) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    ContextualSection? shown;
    var groups = <List<Command>>[];
    for (final s in l.sections) {
      final g = _resolve(s.groups);
      final holds =
          s.unconditional ||
          (s.whileChecked != null &&
              (widget.registry[s.whileChecked!]?.checked ?? false)) ||
          (s.whileEnabled && g.any((group) => group.any((c) => c.enabled)));
      if (holds && g.isNotEmpty) {
        shown = s;
        groups = g;
        break;
      }
    }
    return _bar(
      leading: _groups(_resolve(l.leading)),
      middle: [
        if (shown != null)
          Container(
            key: CommandToolbar.sectionKey(shown.id),
            padding: EdgeInsets.symmetric(
              horizontal: m.space1,
              vertical: m.space1 / 2,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: m.borderMd,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _groups(groups),
            ),
          ),
      ],
      trailing: _groups(_resolve(l.trailing)),
    );
  }

  Widget _tabbed(BuildContext context, TabbedToolbarLayout l) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final tabs = [
      for (final t in l.tabs)
        if (_resolve(t.groups).isNotEmpty) t,
    ];
    final current = tabs.where((t) => t.id == _tab).firstOrNull ?? tabs.firstOrNull;
    final leading = _groups(_resolve(l.leading));
    Widget tab(ToolbarTab t) {
      final selected = t.id == current?.id;
      return Semantics(
        selected: selected,
        child: TextButton(
          key: CommandToolbar.tabKey(t.id),
          onPressed: () => setState(() => _tab = t.id),
          style: TextButton.styleFrom(
            minimumSize: Size(m.controlSize, m.controlSize),
            padding: EdgeInsets.symmetric(horizontal: m.space3),
            foregroundColor: selected ? scheme.primary : scheme.onSurface,
            textStyle: selected ? type.bodyStrong : type.body,
            shape: RoundedRectangleBorder(borderRadius: m.borderMd),
          ),
          child: DecoratedBox(
            // The chosen tab is underlined in accent.
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? scheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(t.label),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          // Exactly this tall on desktop (Windows pads buttons to 48px
          // otherwise); on touch it grows with its controls.
          constraints: m.touch
              ? BoxConstraints(minHeight: m.controlSize + m.space1)
              : BoxConstraints.tightFor(height: m.controlSize + m.space1),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: m.space4),
            child: Row(
              children: [
                ...leading,
                if (leading.isNotEmpty) const ToolbarSeparator(),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (i, t) in tabs.indexed) ...[
                          if (i > 0) SizedBox(width: m.space1),
                          tab(t),
                        ],
                      ],
                    ),
                  ),
                ),
                ..._groups(_resolve(l.trailing)),
              ],
            ),
          ),
        ),
        _bar(
          middle: current == null ? const [] : _groups(_resolve(current.groups)),
        ),
      ],
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
        for (final item in items)
          NotedMenuItem.forCommand(item, showCheck: true),
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
      // Checked (the paragraph style at the caret) is shown as on a checked
      // icon button, but not given a toggled semantics flag: with that flag
      // changing as the caret moved, the Windows app exited without an error
      // during the integration suite (3 of 4 runs; 0 of 3 without it).
      return Tooltip(
        message: c.tooltip,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: Size(m.controlSize, m.controlSize),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: type.body,
            backgroundColor: checked ? scheme.primaryContainer : null,
            foregroundColor: checked ? scheme.primary : null,
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
