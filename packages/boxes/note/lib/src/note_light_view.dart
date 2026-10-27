// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:noted_canvas/noted_canvas.dart' show DesignMetrics;

import 'formula/formula_parser.dart' show isFormulaText;
import 'math_blocks.dart';
import 'note_codec.dart';
import 'note_find.dart';
import 'note_theme.dart';
import 'table_formulas.dart';

/// The light view of a note: its blocks drawn without an editor.
///
/// A page can hold hundreds of notes and an `AppFlowyEditor` is heavy (a
/// widget, state, focus, selection and keyboard services and listeners for
/// every block), so a note builds one only while it is being edited (see
/// `note_module.dart`). Every other note is drawn by this view, which must
/// look exactly like the editor with no caret: the same text styles, padding,
/// block spacing, list markers, table geometry and equations. It builds the
/// same widgets the editor's blocks do, from the same block builders, but
/// with no state, no selection layers and no services.
///
/// What it draws: paragraphs, headings, bulleted, numbered and to-do lists
/// and quotes (without children), dividers, equation blocks, and tables whose
/// cells hold a paragraph or an equation. [noteLightable] says whether a
/// document is made only of those; for any other (an image, an unknown block
/// type, nested blocks, a block with an alignment, text direction or
/// background color) the note keeps the real editor.

/// Whether [root] (a document's page node) holds only blocks the light view
/// draws exactly like the editor does.
bool noteLightable(Node root) {
  if (root.type != PageBlockKeys.type || root.children.isEmpty) return false;
  for (final block in root.children) {
    if (!_lightBlock(block, inCell: false)) return false;
  }
  return true;
}

const Set<String> _textTypes = {
  ParagraphBlockKeys.type,
  HeadingBlockKeys.type,
  BulletedListBlockKeys.type,
  NumberedListBlockKeys.type,
  TodoListBlockKeys.type,
  QuoteBlockKeys.type,
};

/// Attributes the light view doesn't implement.
const List<String> _unsupportedAttributes = [
  blockComponentTextDirection,
  blockComponentAlign,
  blockComponentBackgroundColor,
];

bool _lightBlock(Node node, {required bool inCell}) {
  for (final a in _unsupportedAttributes) {
    if (node.attributes.containsKey(a)) return false;
  }
  final type = node.type;
  if (_textTypes.contains(type)) {
    if (node.children.isNotEmpty || node.delta == null) return false;
    if (inCell && type != ParagraphBlockKeys.type) return false;
    // The editor works out the value of a formula that has none stored when
    // it loads; the light view only shows stored values.
    if (inCell &&
        isFormulaText(node.delta!.toPlainText()) &&
        node.attributes[NoteFormat.formulaValueKey] is! String) {
      return false;
    }
    return true;
  }
  if (type == NoteFormat.mathBlockType) return node.children.isEmpty;
  if (inCell) return false;
  if (type == DividerBlockKeys.type) return node.children.isEmpty;
  if (type == TableBlockKeys.type) return _lightTable(node);
  return false;
}

bool _lightTable(Node table) {
  final cols = table.attributes[TableBlockKeys.colsLen];
  final rows = table.attributes[TableBlockKeys.rowsLen];
  if (cols is! int || rows is! int || cols < 1 || rows < 1) return false;
  if (table.children.length != cols * rows) return false;
  // The editor measures a table after it first draws it and stores the
  // sizes it found; until it has, the table is not the size it will be.
  if (table.attributes[TableBlockKeys.colsHeight] is! num) return false;
  final seen = <int>{};
  for (final cell in table.children) {
    if (cell.type != TableCellBlockKeys.type || cell.children.isEmpty) {
      return false;
    }
    final c = cell.attributes[TableCellBlockKeys.colPosition];
    final r = cell.attributes[TableCellBlockKeys.rowPosition];
    if (c is! int || r is! int || c < 0 || r < 0 || c >= cols || r >= rows) {
      return false;
    }
    if (!seen.add(r * cols + c)) return false;
    if (cell.attributes[TableCellBlockKeys.height] is! num) return false;
    // A cell shows its first block only.
    if (!_lightBlock(cell.children.first, inCell: true)) return false;
  }
  return true;
}

/// What a click on the light view landed on.
final class LightHit {
  const LightHit(this.node, this.offset, {this.onMath = false, this.href});

  /// The block.
  final Node node;

  /// The offset in the block's text, within its length.
  final int offset;

  /// The click was on an equation block.
  final bool onMath;

  /// The link under the click, if any.
  final String? href;
}

/// What the light view asks of the note that shows it.
final class LightActions {
  const LightActions({
    required this.editable,
    required this.onTap,
    required this.onToggleTodo,
    required this.onEditMathBlock,
    required this.onEditMathInline,
  });

  /// Whether the note can be edited (a read-only page can't).
  final bool editable;

  /// A click on the view, resolved to a block and offset (null: the click
  /// was on nothing; there is no text block).
  final void Function(LightHit? hit) onTap;

  final void Function(Node node) onToggleTodo;
  final void Function(Node node) onEditMathBlock;
  final void Function(Node node, int index) onEditMathInline;
}

/// The note's blocks, in the box's scroll view. [headerKey] and [footerKey]
/// are on the top and bottom padding, which the note measures to fit the box
/// to its content, as it does with the editor.
class NoteLightView extends StatelessWidget {
  const NoteLightView({
    super.key,
    required this.document,
    required this.builders,
    required this.scheme,
    required this.headerKey,
    required this.footerKey,
    required this.actions,
  });

  final Document document;
  final Map<String, BlockComponentBuilder> builders;
  final ColorScheme scheme;
  final Key headerKey;
  final Key footerKey;
  final LightActions actions;

  @override
  Widget build(BuildContext context) {
    final env = _Env(builders, scheme, actions);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // The tap handler has no action to offer a screen reader, and the
      // semantics node of a gesture detector around a scroll view broke
      // the semantics update under Windows accessibility.
      excludeFromSemantics: true,
      onTapUp: (d) {
        final root = context.findRenderObject();
        actions.onTap(
          root == null ? null : lightHitTest(root, d.globalPosition),
        );
      },
      child: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(key: headerKey, height: _verticalPadding),
            for (final block in document.root.children)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignMetrics.space2,
                ),
                child: env.block(context, block),
              ),
            SizedBox(key: footerKey, height: _verticalPadding),
          ],
        ),
      ),
    );
  }
}

const double _verticalPadding = 6;

/// What the blocks of one build share.
final class _Env {
  _Env(this.builders, this.scheme, this.actions)
    : styles = noteTextStyles(scheme) {
    decorator = findSpanDecorator(
      lightFormulaSpanDecorator(
        lightMathSpanDecorator(
          fallback: _linkSpan,
          onEdit: actions.editable
              ? (context, node, index) =>
                    actions.onEditMathInline(node, index)
              : null,
        ),
      ),
    );
  }

  final Map<String, BlockComponentBuilder> builders;
  final ColorScheme scheme;
  final LightActions actions;
  final TextStyleConfiguration styles;
  late final TextSpanDecoratorForAttribute decorator;

  BlockComponentConfiguration config(String type) =>
      builders[type]?.configuration ?? const BlockComponentConfiguration();

  Widget block(BuildContext context, Node node) {
    switch (node.type) {
      case ParagraphBlockKeys.type:
        return _paragraph(node);
      case HeadingBlockKeys.type:
        return _heading(node);
      case BulletedListBlockKeys.type:
      case NumberedListBlockKeys.type:
      case TodoListBlockKeys.type:
        return _listItem(node);
      case QuoteBlockKeys.type:
        return _quote(node);
      case DividerBlockKeys.type:
        return _divider(node);
      case NoteFormat.mathBlockType:
        return _math(node);
      case TableBlockKeys.type:
        return _LightTable(node: node, env: this);
    }
    return const SizedBox.shrink();
  }

  Widget _text(
    Node node, {
    required String placeholder,
    required AppFlowyTextSpanDecorator decorate,
    required AppFlowyTextSpanDecorator decoratePlaceholder,
  }) => _LightText(
    node: node,
    env: this,
    placeholder: placeholder,
    decorate: decorate,
    decoratePlaceholder: decoratePlaceholder,
  );

  TextSpan Function(TextSpan) _plain(BlockComponentConfiguration c, Node node) =>
      (s) => s.updateTextStyle(c.textStyle(node, textSpan: s));

  TextSpan Function(TextSpan) _placeholderStyle(
    BlockComponentConfiguration c,
    Node node,
  ) =>
      (s) => s.updateTextStyle(c.placeholderTextStyle(node, textSpan: s));

  Widget _paragraph(Node node) {
    final c = config(ParagraphBlockKeys.type);
    return Padding(
      padding: c.margin(node),
      child: _BlockTag(
        node: node,
        child: Padding(
          padding: c.padding(node),
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _text(
                  node,
                  // The "Type here" hint only shows where the caret is.
                  placeholder: ' ',
                  decorate: _plain(c, node),
                  decoratePlaceholder: _placeholderStyle(c, node),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _heading(Node node) {
    final c = config(HeadingBlockKeys.type);
    final b = builders[HeadingBlockKeys.type] as HeadingBlockComponentBuilder?;
    final level = node.attributes[HeadingBlockKeys.level] as int? ?? 1;
    TextStyle? style() =>
        b?.textStyleBuilder?.call(level) ?? _defaultHeading(level);
    return Padding(
      padding: c.margin(node),
      child: _BlockTag(
        node: node,
        child: Padding(
          padding: c.padding(node),
          child: SizedBox(
            width: double.infinity,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: _text(
                    node,
                    placeholder: c.placeholderText(node),
                    decorate: (s) => s
                        .updateTextStyle(c.textStyle(node, textSpan: s))
                        .updateTextStyle(style()),
                    decoratePlaceholder: (s) => s
                        .updateTextStyle(style())
                        .updateTextStyle(
                          c.placeholderTextStyle(node, textSpan: s),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static TextStyle _defaultHeading(int level) {
    const sizes = [32.0, 28.0, 24.0, 18.0, 18.0, 18.0];
    return TextStyle(
      fontSize: level >= 0 && level < sizes.length ? sizes[level] : 18.0,
      fontWeight: FontWeight.bold,
    );
  }

  Widget _listItem(Node node) {
    final type = node.type;
    final c = config(type);
    final Widget marker;
    AppFlowyTextSpanDecorator decorate = _plain(c, node);
    if (type == BulletedListBlockKeys.type) {
      final b = builders[type] as BulletedListBlockComponentBuilder?;
      marker = Builder(
        builder: (context) =>
            b?.iconBuilder?.call(context, node) ??
            _BulletMarker(textStyle: c.textStyle(node)),
      );
    } else if (type == NumberedListBlockKeys.type) {
      final b = builders[type] as NumberedListBlockComponentBuilder?;
      marker = Builder(
        builder: (context) =>
            b?.iconBuilder?.call(context, node, TextDirection.ltr) ??
            _NumberMarker(
              text: _numberLabel(node),
              base: styles.text,
              textStyle: c.textStyle(node),
            ),
      );
    } else {
      final b = builders[type] as TodoListBlockComponentBuilder?;
      final checked = node.attributes[TodoListBlockKeys.checked] == true;
      marker = _TodoMarker(
        builder: b?.iconBuilder,
        node: node,
        checked: checked,
        onCheck: actions.editable ? () => actions.onToggleTodo(node) : () {},
      );
      TextStyle? done() =>
          b?.textStyleBuilder?.call(checked) ??
          (checked
              ? TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Colors.grey.shade400,
                )
              : null);
      decorate = (s) =>
          s.updateTextStyle(c.textStyle(node)).updateTextStyle(done());
    }
    return Padding(
      padding: c.margin(node),
      child: _BlockTag(
        node: node,
        child: Padding(
          padding: c.padding(node),
          child: SizedBox(
            width: double.infinity,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                marker,
                Flexible(
                  child: _text(
                    node,
                    placeholder: c.placeholderText(node),
                    decorate: decorate,
                    decoratePlaceholder: _placeholderStyle(c, node),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quote(Node node) {
    final c = config(QuoteBlockKeys.type);
    final b = builders[QuoteBlockKeys.type] as QuoteBlockComponentBuilder?;
    return Padding(
      padding: c.margin(node),
      child: _BlockTag(
        node: node,
        child: Padding(
          padding: c.padding(node),
          child: SizedBox(
            width: double.infinity,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (context) =>
                        b?.iconBuilder?.call(context, node) ??
                        const _QuoteMarker(),
                  ),
                  Flexible(
                    child: _text(
                      node,
                      placeholder: c.placeholderText(node),
                      decorate: _plain(c, node),
                      decoratePlaceholder: _placeholderStyle(c, node),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider(Node node) {
    final c = config(DividerBlockKeys.type);
    final b = builders[DividerBlockKeys.type] as DividerBlockComponentBuilder?;
    return Padding(
      padding: c.margin(node),
      child: Padding(
        padding: c.padding(node),
        child: Container(
          height: b?.height ?? 10,
          alignment: Alignment.center,
          child: Divider(color: b?.lineColor ?? Colors.grey, thickness: 1),
        ),
      ),
    );
  }

  Widget _math(Node node) {
    const c = BlockComponentConfiguration();
    return Padding(
      padding: c.margin(node),
      child: _BlockTag(
        node: node,
        math: true,
        child: Padding(
          padding: c.padding(node),
          child: Builder(
            builder: (context) => mathBlockContent(
              context,
              node: node,
              textStyle: styles.text,
              onTap: actions.editable
                  ? () => actions.onEditMathBlock(node)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// A link's text. Clicks are handled by the view as a whole.
InlineSpan _linkSpan(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  if (text.attributes?[AppFlowyRichTextKeys.href] is! String) return before;
  return TextSpan(
    style: before.style,
    text: text.text,
    mouseCursor: SystemMouseCursors.click,
  );
}


/// The text of one block: the editor's `AppFlowyRichText` with no selection
/// layers: a placeholder and the text, stacked.
class _LightText extends StatelessWidget {
  const _LightText({
    required this.node,
    required this.env,
    required this.placeholder,
    required this.decorate,
    required this.decoratePlaceholder,
  });

  final Node node;
  final _Env env;
  final String placeholder;
  final AppFlowyTextSpanDecorator decorate;
  final AppFlowyTextSpanDecorator decoratePlaceholder;

  @override
  Widget build(BuildContext context) {
    final styles = env.styles;
    final delta = node.delta!;
    final behavior = TextHeightBehavior(
      applyHeightToFirstAscent: styles.applyHeightToFirstAscent,
      applyHeightToLastDescent: styles.applyHeightToLastDescent,
      leadingDistribution: styles.leadingDistribution,
    );
    final scaler = TextScaler.linear(1);

    var hint = TextSpan(
      text: placeholder,
      style: styles.text.copyWith(height: styles.lineHeight),
    );
    hint = _adjust(decoratePlaceholder(hint), styles);
    if (delta.isNotEmpty) hint = hint.copyWith(text: '');

    var span = _textSpan(context, delta.whereType<TextInsert>());
    span = _adjust(decorate(span), styles);

    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: Stack(
        children: [
          RichText(
            textHeightBehavior: behavior,
            text: hint,
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          ),
          _ParagraphTag(
            child: RichText(
              textAlign: env.config(node.type).textAlign(node),
              textHeightBehavior: behavior,
              text: span,
              textDirection: TextDirection.ltr,
              textScaler: scaler,
            ),
          ),
        ],
      ),
    );
  }

  TextSpan _textSpan(BuildContext context, Iterable<TextInsert> inserts) {
    final styles = env.styles;
    var offset = 0;
    final spans = <InlineSpan>[];
    for (final insert in inserts) {
      var style = styles.text.copyWith(height: styles.lineHeight);
      final a = insert.attributes;
      if (a != null) {
        if (a.bold) style = style.combine(styles.bold);
        if (a.italic) style = style.combine(styles.italic);
        if (a.underline) style = style.combine(styles.underline);
        if (a.strikethrough) style = style.combine(styles.strikethrough);
        if (a.href != null) style = style.combine(styles.href);
        if (a.code) style = style.combine(styles.code);
        if (a.backgroundColor != null) {
          style = style.combine(TextStyle(backgroundColor: a.backgroundColor));
        }
        if (a.findBackgroundColor != null) {
          style = style.combine(
            TextStyle(backgroundColor: a.findBackgroundColor),
          );
        }
        if (a.color != null) style = style.combine(TextStyle(color: a.color));
        if (a.fontFamily != null) {
          style = style.combine(TextStyle(fontFamily: a.fontFamily));
        }
        if (a.fontSize != null) {
          style = style.combine(TextStyle(fontSize: a.fontSize));
        }
      }
      final base = TextSpan(text: insert.text, style: style);
      spans.add(env.decorator(context, node, offset, insert, base, decorate(base)));
      offset += insert.length;
    }
    return TextSpan(children: spans);
  }
}

/// appflowy's workaround for the caret height when the parent style is null.
TextSpan _adjust(TextSpan span, TextStyleConfiguration styles) {
  if (span.style != null || span.children == null) return span;
  var height = 0.0;
  var fontSize = 0.0;
  span.visitChildren((s) {
    final style = s.style;
    if (style != null) {
      if (style.height != null) height = math.max(height, style.height!);
      if (style.fontSize != null) fontSize = math.max(fontSize, style.fontSize!);
    }
    return true;
  });
  if (height == 0.0 || fontSize == 0.0) return span;
  return span.copyWith(
    style: styles.text.copyWith(height: height, fontSize: fontSize),
  );
}

/// The bullet of a bulleted item.
class _BulletMarker extends StatelessWidget {
  const _BulletMarker({required this.textStyle});

  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
    padding: const EdgeInsets.only(right: 4),
    child: Center(
      child: Text(
        '●',
        style: textStyle,
        textScaler: const TextScaler.linear(0.5),
      ),
    ),
  );
}

/// The number of a numbered item ("1.", "2.", ...).
class _NumberMarker extends StatelessWidget {
  const _NumberMarker({
    required this.text,
    required this.base,
    required this.textStyle,
  });

  final String text;
  final TextStyle base;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
    padding: const EdgeInsets.only(right: 4),
    child: Center(
      child: Text.rich(
        textScaler: const TextScaler.linear(1),
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: false,
          applyHeightToLastDescent: false,
        ),
        TextSpan(text: text, style: base.combine(textStyle)),
        textDirection: TextDirection.ltr,
      ),
    ),
  );
}

/// The number label of a top-level numbered item: its place among the
/// numbered items just before it.
String _numberLabel(Node node) {
  var index = 1;
  var previous = node.previous;
  if (previous == null || previous.type != NumberedListBlockKeys.type) {
    return '${node.attributes[NumberedListBlockKeys.number] ?? index}.';
  }
  int? start;
  while (previous != null && previous.type == NumberedListBlockKeys.type) {
    start = previous.attributes[NumberedListBlockKeys.number] as int?;
    index++;
    previous = previous.previous;
  }
  return '${start != null ? start + index - 1 : index}.';
}

class _TodoMarker extends StatelessWidget {
  const _TodoMarker({
    required this.builder,
    required this.node,
    required this.checked,
    required this.onCheck,
  });

  final TodoListIconBuilder? builder;
  final Node node;
  final bool checked;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final b = builder;
    if (b != null) return b(context, node, onCheck);
    return GestureDetector(
      onTap: onCheck,
      child: Container(
        constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
        padding: const EdgeInsets.only(right: 4),
        child: Icon(
          checked
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded,
          size: 18,
        ),
      ),
    );
  }
}

class _QuoteMarker extends StatelessWidget {
  const _QuoteMarker();

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    constraints: const BoxConstraints(minWidth: 26, minHeight: 22),
    padding: const EdgeInsets.only(right: 4),
    child: Container(width: 4, color: '#00BCF0'.tryToColor()),
  );
}

/// A table, laid out as the editor's is: columns of cells with borders, in a
/// sideways scroll view, with the room the editor keeps for its "add" buttons.
class _LightTable extends StatefulWidget {
  const _LightTable({required this.node, required this.env});

  final Node node;
  final _Env env;

  @override
  State<_LightTable> createState() => _LightTableState();
}

class _LightTableState extends State<_LightTable> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static double? _num(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v');

  @override
  Widget build(BuildContext context) {
    final env = widget.env;
    final table = widget.node;
    final c = env.config(TableBlockKeys.type);
    final style = (env.builders[TableBlockKeys.type]
            as TableBlockComponentBuilder?)
        ?.tableStyle;
    final borderColor = style?.borderColor ?? env.scheme.outline;
    final borderWidth =
        _num(table.attributes[TableBlockKeys.borderWidth]) ??
        TableDefaults.borderWidth;
    final colDefault =
        _num(table.attributes[TableBlockKeys.colDefaultWidth]) ??
        TableDefaults.colWidth;
    final rowDefault =
        _num(table.attributes[TableBlockKeys.rowDefaultHeight]) ??
        TableDefaults.rowHeight;
    final cols = table.attributes[TableBlockKeys.colsLen] as int;
    final rows = table.attributes[TableBlockKeys.rowsLen] as int;

    final grid = List.generate(cols, (_) => List<Node?>.filled(rows, null));
    for (final cell in table.children) {
      grid[cell.attributes[TableCellBlockKeys.colPosition] as int][cell
              .attributes[TableCellBlockKeys.rowPosition]
          as int] =
          cell;
    }
    double rowHeight(int row) =>
        _num(grid[0][row]!.attributes[TableCellBlockKeys.height]) ??
        rowDefault;
    double colWidth(int col) =>
        _num(grid[col][0]!.attributes[TableCellBlockKeys.width]) ??
        colDefault;
    double cellHeight(Node cell, int row) =>
        _num(cell.attributes[TableCellBlockKeys.height]) ??
        _num(grid[0][row]!.attributes[TableCellBlockKeys.height]) ??
        rowDefault;
    double cellWidth(Node cell, int col) =>
        _num(cell.attributes[TableCellBlockKeys.width]) ??
        _num(grid[col][0]!.attributes[TableCellBlockKeys.width]) ??
        colDefault;

    var colsHeight = borderWidth;
    for (var r = 0; r < rows; r++) {
      colsHeight += rowHeight(r) + borderWidth;
    }
    var tableWidth = borderWidth;
    for (var i = 0; i < cols; i++) {
      tableWidth += colWidth(i) + borderWidth;
    }
    final storedHeight = table.attributes[TableBlockKeys.colsHeight];
    final borderHeight = storedHeight is num ? storedHeight.toDouble() : null;
    final colorBuilder = (env.builders[TableCellBlockKeys.type]
            as TableCellBlockComponentBuilder?)
        ?.colorBuilder;

    Widget border() =>
        Container(width: borderWidth, height: borderHeight, color: borderColor);

    Widget cell(Node cellNode, int col, int row) {
      final color =
          colorBuilder?.call(context, cellNode) ??
          (cellNode.attributes[TableCellBlockKeys.colBackgroundColor]
                  as String?)
              ?.tryToColor() ??
          (cellNode.attributes[TableCellBlockKeys.rowBackgroundColor]
                  as String?)
              ?.tryToColor();
      return Stack(
        key: ValueKey('note-cell-$row-$col'),
        children: [
          Container(
            constraints: BoxConstraints(
              minHeight: cellHeight(cellNode, row),
            ),
            color: color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: env.block(context, cellNode.children.first),
                ),
              ],
            ),
          ),
        ],
      );
    }

    Widget column(int col) {
      final divider = Container(height: borderWidth, color: borderColor);
      return Row(
        children: [
          if (col == 0) border(),
          SizedBox(
            width: cellWidth(grid[col][0]!, col),
            child: Stack(
              children: [
                Column(
                  children: [
                    divider,
                    for (var r = 0; r < rows; r++) ...[
                      cell(grid[col][r]!, col, r),
                      divider,
                    ],
                  ],
                ),
              ],
            ),
          ),
          border(),
        ],
      );
    }

    Widget child = Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 10, left: 10, bottom: 4),
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              children: [
                Row(
                  children: [
                    for (var i = 0; i < cols; i++) column(i),
                    // Room for the editor's "add column" button.
                    SizedBox(width: 28, height: colsHeight),
                  ],
                ),
                // Room for the editor's "add row" button.
                SizedBox(width: tableWidth, height: 28),
              ],
            ),
          ],
        ),
      ),
    );
    child = Padding(padding: c.padding(table), child: child);
    return Padding(padding: c.margin(table), child: child);
  }
}

/// Marks a block's extent (with its padding) for click resolution.
class _BlockTag extends SingleChildRenderObjectWidget {
  const _BlockTag({required this.node, this.math = false, super.child});

  final Node node;
  final bool math;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTag(node, math ? _Kind.math : _Kind.block);

  @override
  void updateRenderObject(BuildContext context, _RenderTag renderObject) {
    renderObject
      ..node = node
      ..kind = math ? _Kind.math : _Kind.block;
  }
}

/// Marks a block's text paragraph.
class _ParagraphTag extends SingleChildRenderObjectWidget {
  const _ParagraphTag({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTag(null, _Kind.paragraph);
}

enum _Kind { block, math, paragraph }

class _RenderTag extends RenderProxyBox {
  _RenderTag(this.node, this.kind);

  Node? node;
  _Kind kind;
}

/// Resolves a click at [global] to the block and text offset it landed on.
/// A click on no block goes to the nearest one, preferring the one level
/// with it (so a click to the right of a short line is that line's).
LightHit? lightHitTest(RenderObject root, Offset global) {
  final blocks = <_RenderTag>[];
  void collect(RenderObject r) {
    if (r is _RenderTag && r.kind != _Kind.paragraph && r.hasSize) {
      blocks.add(r);
    }
    r.visitChildren(collect);
  }

  collect(root);
  if (blocks.isEmpty) return null;

  Rect rectOf(_RenderTag t) =>
      MatrixUtils.transformRect(t.getTransformTo(null), Offset.zero & t.size);

  _RenderTag? best;
  var bestDy = double.infinity;
  var bestDx = double.infinity;
  for (final b in blocks) {
    final r = rectOf(b);
    final dy = math.max(0.0, math.max(r.top - global.dy, global.dy - r.bottom));
    final dx = math.max(
      0.0,
      math.max(r.left - global.dx, global.dx - r.right),
    );
    if (dy < bestDy || (dy == bestDy && dx < bestDx)) {
      best = b;
      bestDy = dy;
      bestDx = dx;
    } else if (dy == 0 && dx == 0 && best != null) {
      // Inside several: the innermost (smallest) wins.
      final a = rectOf(best);
      if (r.width * r.height < a.width * a.height) best = b;
    }
  }
  final tag = best!;
  final node = tag.node!;
  if (tag.kind == _Kind.math) {
    return LightHit(node, 0, onMath: bestDy == 0 && bestDx == 0);
  }

  // The block's paragraph.
  RenderParagraph? paragraph;
  void find(RenderObject r) {
    if (paragraph != null) return;
    if (r is _RenderTag && r.kind == _Kind.paragraph && r.child is RenderParagraph) {
      paragraph = r.child as RenderParagraph;
      return;
    }
    r.visitChildren(find);
  }

  find(tag);
  final p = paragraph;
  final delta = node.delta;
  if (p == null || delta == null || !p.hasSize) return LightHit(node, 0);
  final length = delta.length;
  final local = p.globalToLocal(global);
  var offset = p.getPositionForOffset(local).offset.clamp(0, length);
  // A formula cell shows its value, not its formula: the caret goes to the
  // end of the formula.
  if (node.parent?.type == NoteFormat.tableCellType &&
      node.attributes[NoteFormat.formulaValueKey] is String &&
      isFormulaText(delta.toPlainText())) {
    offset = length;
  }
  String? href;
  if (local.dx >= 0 &&
      local.dy >= 0 &&
      local.dx <= p.size.width &&
      local.dy <= p.size.height) {
    var at = 0;
    for (final op in delta) {
      if (op is TextInsert) {
        if (offset >= at && offset < at + op.length) {
          final h = op.attributes?[AppFlowyRichTextKeys.href];
          if (h is String) href = h;
          break;
        }
        at += op.length;
      }
    }
  }
  return LightHit(node, offset, href: href);
}
