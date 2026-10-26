// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:noted_canvas/noted_canvas.dart' show DesignMetrics, DesignType;

import 'note_codec.dart';

/// appflowy_editor's colors come from constants inside the package (grey
/// placeholders, a light-blue link, a red code color, a fixed quote bar, a
/// fixed light slash menu). Everything it lets a caller set is set here from
/// the app's [ColorScheme], so the editor follows the theme.

/// Text styles for the editor body, links and inline code.
TextStyleConfiguration noteTextStyles(ColorScheme scheme) =>
    TextStyleConfiguration(
      text: DesignType.body.copyWith(
        color: scheme.onSurface,
        fontFamily: DesignType.fontFamily,
        fontFamilyFallback: DesignType.fontFamilyFallback,
      ),
      href: TextStyle(
        color: scheme.primary,
        decoration: TextDecoration.underline,
      ),
      code: TextStyle(
        color: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      autoComplete: TextStyle(color: scheme.onSurfaceVariant),
    );

/// The `/` menu in the theme's colors.
SelectionMenuStyle noteSelectionMenuStyle(ColorScheme scheme) =>
    SelectionMenuStyle(
      selectionMenuBackgroundColor: scheme.surfaceContainerHigh,
      selectionMenuItemTextColor: scheme.onSurface,
      selectionMenuItemIconColor: scheme.onSurface,
      selectionMenuItemSelectedTextColor: scheme.onSecondaryContainer,
      selectionMenuItemSelectedIconColor: scheme.onSecondaryContainer,
      selectionMenuItemSelectedColor: scheme.secondaryContainer,
      selectionMenuUnselectedLabelColor: scheme.onSurfaceVariant,
      selectionMenuDividerColor: scheme.outlineVariant,
      selectionMenuLinkBorderColor: scheme.outline,
      selectionMenuInvalidLinkColor: scheme.error,
      selectionMenuButtonColor: scheme.primary,
      selectionMenuButtonTextColor: scheme.onPrimary,
      selectionMenuButtonIconColor: scheme.onPrimary,
      selectionMenuButtonBorderColor: scheme.primary,
      selectionMenuTabIndicatorColor: scheme.primary,
    );

/// appflowy's standard blocks with [placeholders] (node type to text) and
/// the theme's colors: placeholder text, the quote bar, to-do checkboxes and
/// checked text, the divider and table borders.
Map<String, BlockComponentBuilder> themedStandardBlocks(
  ColorScheme scheme, {
  required String paragraphPlaceholder,
  TableBlockComponentMenuBuilder? tableMenuBuilder,
}) {
  BlockComponentConfiguration config(String Function(Node) placeholder) =>
      standardBlockComponentConfiguration.copyWith(
        placeholderText: placeholder,
        placeholderTextStyle: (_, {TextSpan? textSpan}) =>
            TextStyle(color: scheme.onSurfaceVariant),
      );
  final l10n = AppFlowyEditorL10n.current;
  Widget box(IconData icon, Color color, VoidCallback onTap) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: DesignMetrics.space1),
        child: Icon(icon, size: DesignMetrics.icon, color: color),
      ),
    ),
  );
  return {
    PageBlockKeys.type: PageBlockComponentBuilder(),
    ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
      configuration: config((_) => paragraphPlaceholder),
    ),
    TodoListBlockKeys.type: TodoListBlockComponentBuilder(
      configuration: config((_) => l10n.toDoPlaceholder),
      toggleChildrenTriggers: [
        LogicalKeyboardKey.shift,
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.shiftRight,
      ],
      textStyleBuilder: (checked) => checked
          ? TextStyle(
              decoration: TextDecoration.lineThrough,
              color: scheme.onSurfaceVariant,
            )
          : const TextStyle(),
      iconBuilder: (context, node, onCheck) {
        final checked = node.attributes[TodoListBlockKeys.checked] == true;
        return box(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          checked ? scheme.primary : scheme.onSurfaceVariant,
          onCheck,
        );
      },
    ),
    BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(
      configuration: config((_) => l10n.listItemPlaceholder),
    ),
    NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(
      configuration: config((_) => l10n.listItemPlaceholder),
    ),
    QuoteBlockKeys.type: QuoteBlockComponentBuilder(
      configuration: config((_) => l10n.quote),
      iconBuilder: (context, node) => Container(
        alignment: Alignment.center,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
        padding: const EdgeInsets.only(right: DesignMetrics.space1),
        child: Container(width: DesignMetrics.space1, color: scheme.primary),
      ),
    ),
    HeadingBlockKeys.type: HeadingBlockComponentBuilder(
      configuration: config(
        (node) => 'Heading ${node.attributes[HeadingBlockKeys.level]}',
      ),
    ),
    ImageBlockKeys.type: ImageBlockComponentBuilder(),
    DividerBlockKeys.type: DividerBlockComponentBuilder(
      lineColor: scheme.outline,
      configuration: standardBlockComponentConfiguration.copyWith(
        padding: (node) => const EdgeInsets.symmetric(vertical: DesignMetrics.space2),
      ),
    ),
    TableBlockKeys.type: TableBlockComponentBuilder(
      menuBuilder: tableMenuBuilder,
      tableStyle: TableStyle(
        borderColor: scheme.outline,
        borderHoverColor: scheme.primary,
      ),
    ),
    // The row handles live in the cells, so they need the menu too.
    TableCellBlockKeys.type: TableCellBlockComponentBuilder(
      menuBuilder: tableMenuBuilder,
      colorBuilder: tableCellColors(scheme),
    ),
  };
}

/// The color a [role] fill has in [scheme].
Color fillColor(ColorScheme scheme, FillRole role) => switch (role) {
  FillRole.accent => scheme.primary,
  FillRole.secondary => scheme.secondary,
  FillRole.tertiary => scheme.tertiary,
  FillRole.alert => scheme.error,
}.withValues(alpha: 0.25);

/// The background of a table cell: its column's, else its row's (as in
/// appflowy). A stored role, or a fixed value the first version wrote for a
/// role (see [TableFill]), is resolved in [scheme] each time the cell is
/// built, so it follows the theme; any other value is the fixed color it
/// says. The stored value is never touched.
TableBlockCellComponentColorBuilder tableCellColors(ColorScheme scheme) =>
    (context, node) {
      for (final key in [
        NoteFormat.colBackgroundKey,
        NoteFormat.rowBackgroundKey,
      ]) {
        final stored = node.attributes[key];
        if (stored is! String) continue;
        final role = TableFill.roleOf(stored);
        if (role != null) return fillColor(scheme, role);
        final fixed = stored.tryToColor();
        if (fixed != null) return fixed;
      }
      return null;
    };
