// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

/// Indent of a sidebar row for each level of nesting (SidebarRow guidelines).
const double sidebarIndent = 20;

/// Diameter of the conflict dot and the width of a binder chip.
const double sidebarDot = 8;

/// The expand/collapse chevron before a title: ▾ expanded, ▸ collapsed, in
/// `text-muted`. Its slot is [sidebarIndent] wide so titles line up.
class SidebarChevron extends StatelessWidget {
  const SidebarChevron({super.key, required this.collapsed, required this.onPressed});

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return Tooltip(
      message: collapsed ? 'Expand' : 'Collapse',
      child: InkResponse(
        onTap: onPressed,
        radius: sidebarIndent / 2 + 2,
        child: SizedBox(
          width: sidebarIndent,
          height: m.rowSize,
          child: Center(
            child: Icon(
              collapsed ? Icons.chevron_right_rounded : Icons.expand_more_rounded,
              size: m.icon,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the page tree: `row` high (40 on touch), `radius-md`, padding
/// `space-2`, [sidebarIndent] per [depth], the title in `body`. Hover fills
/// `surface-hover`; the active page is `accent-soft` with the title in
/// `body-strong` `accent`. A [conflict] shows an 8px `conflict` dot at the right
/// edge. A [disabled] row (unavailable page or binder) has its title in
/// `text-disabled` and, with a [status], a `small` status line under it.
class SidebarRow extends StatelessWidget {
  const SidebarRow({
    super.key,
    required this.title,
    this.depth = 0,
    this.selected = false,
    this.highlight = false,
    this.disabled = false,
    this.status,
    this.conflict = false,
    this.conflictKey,
    this.chevron,
    this.leading,
    this.trailing,
    this.onTap,
    this.onDoubleTap,
  });

  final String title;
  final int depth;

  /// The page that is open.
  final bool selected;

  /// A page is being dragged onto this row (the same fill as [selected]).
  final bool highlight;
  final bool disabled;

  /// A `small` line under the title: "On another device".
  final String? status;
  final bool conflict;
  final Key? conflictKey;

  /// The expand/collapse chevron of a divider; null for a plain page, which
  /// leaves its slot empty.
  final Widget? chevron;

  /// An icon before the title (used by unavailable rows).
  final Widget? leading;

  /// The row's menu button.
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final titleStyle = disabled
        ? type.body.copyWith(color: colors.textDisabled)
        : selected
        ? type.bodyStrong.copyWith(color: scheme.primary)
        : type.body.copyWith(color: scheme.onSurface);
    final fill = selected || highlight ? scheme.primaryContainer : Colors.transparent;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.space1),
      child: Material(
        color: fill,
        borderRadius: m.borderMd,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          hoverColor: colors.surfaceHover,
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: m.rowSize),
            child: Padding(
              padding: EdgeInsets.only(
                left: m.space2 + depth * sidebarIndent,
                right: m.space2,
              ),
              child: Row(
                children: [
                  SizedBox(width: sidebarIndent, child: chevron),
                  if (leading != null) ...[leading!, SizedBox(width: m.space2)],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                        if (status != null)
                          Text(
                            status!,
                            overflow: TextOverflow.ellipsis,
                            style: type.small.copyWith(color: colors.textDisabled),
                          ),
                      ],
                    ),
                  ),
                  if (conflict)
                    Padding(
                      padding: EdgeInsets.only(left: m.space2),
                      child: Semantics(
                        label: 'Has a conflict',
                        child: Container(
                          key: conflictKey,
                          width: sidebarDot,
                          height: sidebarDot,
                          decoration: BoxDecoration(
                            color: colors.conflict,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  if (trailing != null) trailing! else SizedBox(width: m.space1),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header above a binder's pages or the loose pages: the title in the
/// `label` style, uppercase, `text-muted`, after an 8px `radius-sm` chip in
/// the binder's color ([chipColor]; `text-muted` for loose pages).
class SidebarGroupHeader extends StatelessWidget {
  const SidebarGroupHeader({
    super.key,
    required this.title,
    this.chipColor,
    this.chipKey,
    this.chevron,
    this.fill,
    this.disabled = false,
    this.status,
    this.trailing,
    this.onTap,
  });

  final String title;

  /// The binder's color; null for loose pages.
  final Color? chipColor;
  final Key? chipKey;

  /// A collapse chevron before the chip.
  final Widget? chevron;

  /// Background (a drop target or the open cover).
  final Color? fill;

  /// A binder that is away or damaged: the title is `text-disabled`.
  final bool disabled;
  final String? status;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final muted = disabled ? colors.textDisabled : scheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.space1, m.space3 - m.space1, m.space1, 0),
      child: Material(
        color: fill ?? Colors.transparent,
        borderRadius: m.borderMd,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          hoverColor: colors.surfaceHover,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: m.rowSize),
            child: Padding(
              padding: EdgeInsets.only(left: m.space2, right: m.space1),
              child: Row(
                children: [
                  ?chevron,
                  Container(
                    key: chipKey,
                    width: sidebarDot,
                    height: sidebarDot,
                    decoration: BoxDecoration(
                      color: disabled ? colors.textDisabled : chipColor ?? scheme.onSurfaceVariant,
                      borderRadius: m.borderSm,
                    ),
                  ),
                  SizedBox(width: m.space2),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title.toUpperCase(),
                          overflow: TextOverflow.ellipsis,
                          style: type.label.copyWith(color: muted),
                        ),
                        if (status != null)
                          Text(
                            status!,
                            overflow: TextOverflow.ellipsis,
                            style: type.small.copyWith(color: colors.textDisabled),
                          ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A `⋯` menu button for a sidebar row or header: an 18px rounded icon in a
/// `control` square (a touch target on touch).
class SidebarMenuButton<T> extends StatelessWidget {
  const SidebarMenuButton({
    super.key,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
  });

  final String tooltip;
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    return PopupMenuButton<T>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: m.icon,
      icon: const Icon(Icons.more_horiz_rounded),
      iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      style: IconButton.styleFrom(
        fixedSize: Size.square(m.rowSize),
        minimumSize: Size.square(m.rowSize),
        maximumSize: Size.square(m.rowSize),
      ),
      onSelected: onSelected,
      itemBuilder: itemBuilder,
    );
  }
}
