// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'commands.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';

/// The minimum width of a menu (Menu guidelines), content box.
const double notedMenuMinWidth = 220;

/// One item of a popup menu, drawn to the Menu guidelines: `row` high (40 on
/// touch), `radius-md`, padding `space-2` × 10, `body` in `text`, hover and
/// keyboard focus fill `surface-hover`, and an optional shortcut right-aligned
/// in `small` `text-muted`. A disabled item is `text-disabled` with no hover;
/// a [destructive] one (Delete page, Delete row) is `error`.
///
/// The menu's own container (`surface`, 1px `border`, `radius-lg`, popover
/// shadow, padding `space-1`) comes from the theme's `PopupMenuThemeData`
/// (`notedThemeData`), so every `PopupMenuButton` and `showMenu` follows.
class NotedMenuItem<T> extends PopupMenuEntry<T> {
  const NotedMenuItem({
    super.key,
    this.value,
    required this.label,
    this.icon,
    this.leading,
    this.shortcut,
    this.destructive = false,
    this.enabled = true,
  });

  /// The item for [command]: its label, its shortcut, enabled as it is. The
  /// menu's value is the command's id.
  static NotedMenuItem<String> forCommand(
    Command command, {
    bool destructive = false,
    bool showIcon = false,
    bool showCheck = false,
  }) => NotedMenuItem<String>(
    key: ValueKey('menu-${command.id}'),
    value: command.id,
    label: command.label,
    icon: showIcon ? command.icon : null,
    leading: showCheck ? MenuCheckMark(checked: command.checked ?? false) : null,
    shortcut: command.shortcut == null ? null : shortcutLabel(command.shortcut!),
    destructive: destructive,
    enabled: command.enabled,
  );

  /// What the menu returns when the item is chosen.
  final T? value;
  final String label;

  /// An icon before the label (a rounded Material icon).
  final IconData? icon;

  /// A custom widget before the label (for example a color swatch), instead
  /// of [icon].
  final Widget? leading;

  /// The shortcut as shown to the user ("Ctrl+Z").
  final String? shortcut;
  final bool destructive;
  final bool enabled;

  // The real height is NotedMetrics.rowSize, read when the item is built.
  @override
  double get height => NotedMetrics.touchRow;

  @override
  bool represents(T? value) => value == this.value;

  @override
  State<NotedMenuItem<T>> createState() => _NotedMenuItemState<T>();
}

class _NotedMenuItemState<T> extends State<NotedMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final w = widget;
    final Color fg = !w.enabled
        ? colors.textDisabled
        : w.destructive
        ? scheme.error
        : scheme.onSurface;
    final leading =
        w.leading ??
        (w.icon == null ? null : Icon(w.icon, size: m.icon, color: fg));
    final item = Semantics(
      button: true,
      enabled: w.enabled,
      child: InkWell(
        borderRadius: m.borderMd,
        hoverColor: colors.surfaceHover,
        focusColor: colors.surfaceHover,
        splashColor: colors.surfaceHover,
        highlightColor: colors.surfaceHover,
        canRequestFocus: w.enabled,
        onTap: w.enabled ? () => Navigator.pop<T>(context, w.value) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: m.rowSize,
            // The container (min width 220) pads its items by space-1.
            minWidth: notedMenuMinWidth - 2 * m.space1,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: m.space1),
            child: Row(
              children: [
                if (leading != null) ...[leading, SizedBox(width: m.space3)],
                Expanded(
                  child: Text(
                    w.label,
                    style: type.body.copyWith(color: fg),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (w.shortcut != null) ...[
                  SizedBox(width: m.space4),
                  Text(
                    w.shortcut!,
                    key: const ValueKey('menu-shortcut'),
                    style: type.small.copyWith(
                      color: w.enabled ? scheme.onSurfaceVariant : fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return Material(type: MaterialType.transparency, child: item);
  }
}

/// A separator: 1px `border` with `space-1` margins above and below.
class NotedMenuDivider extends PopupMenuEntry<Never> {
  const NotedMenuDivider({super.key});

  @override
  double get height => 9;

  @override
  bool represents(void value) => false;

  @override
  State<NotedMenuDivider> createState() => _NotedMenuDividerState();
}

class _NotedMenuDividerState extends State<NotedMenuDivider> {
  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: m.space1),
      child: Divider(
        height: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// A section label in a menu (disabled, `small`, `text-muted`).
class NotedMenuHeading extends PopupMenuEntry<Never> {
  const NotedMenuHeading(this.label, {super.key});

  final String label;

  @override
  double get height => 24;

  @override
  bool represents(void value) => false;

  @override
  State<NotedMenuHeading> createState() => _NotedMenuHeadingState();
}

class _NotedMenuHeadingState extends State<NotedMenuHeading> {
  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: m.space1),
      child: Text(
        widget.label,
        style: NotedTypography.of(context).small.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The leading check column of a menu item that is one of a set of choices:
/// a check mark when [checked], otherwise an empty space of the same width.
class MenuCheckMark extends StatelessWidget {
  const MenuCheckMark({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final size = NotedMetrics.of(context).icon;
    return SizedBox(
      width: size,
      child: checked ? Icon(Icons.check_rounded, size: size) : null,
    );
  }
}
