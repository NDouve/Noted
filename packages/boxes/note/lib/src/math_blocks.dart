// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import 'note_codec.dart';

/// LaTeX equations in a note, as blocks and inside text.
///
/// appflowy_editor ships no equation component (decision 0022: its old
/// LaTeX plugin was dropped; only the table is built in), so both are written
/// here against its public block and text-span APIs. Rendering is
/// flutter_math_fork (Apache-2.0). The formula source is the only thing
/// stored: a `math_equation` block has `data.formula`, and an inline
/// equation is a one-character text run (see [NoteFormat.inlineMathChar])
/// whose `formula` attribute holds the source.

/// A new block equation node.
Node mathBlockNode([String formula = '']) => Node(
  type: NoteFormat.mathBlockType,
  attributes: {NoteFormat.formulaKey: formula},
);

/// The block-component builders for the note: appflowy's standard blocks plus
/// the equation block. [editor] is the state the blocks belong to; appflowy
/// hands it out through `provider`, which is not a dependency of this
/// package, so it is passed in instead.
Map<String, BlockComponentBuilder> mathBlockBuilders(EditorState editor) => {
  NoteFormat.mathBlockType: MathBlockComponentBuilder(editor),
};

/// A formula, rendered, or a placeholder when it is empty or invalid.
///
/// Parse and layout errors are caught by flutter_math_fork and routed to
/// [MathErrorPlaceholder], so malformed LaTeX never throws into the editor.
class MathView extends StatelessWidget {
  const MathView({
    super.key,
    required this.formula,
    required this.display,
    required this.style,
  });

  final String formula;

  /// True for a block equation (large operators, centred); false for one
  /// inside a line of text.
  final bool display;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (formula.trim().isEmpty) {
      return Text(
        display ? 'Empty equation: click to edit' : '[ ]',
        style: style.copyWith(
          color: style.color?.withValues(alpha: 0.5),
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Math.tex(
      formula,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style,
      onErrorFallback: (error) =>
          MathErrorPlaceholder(formula: formula, style: style),
    );
  }
}

/// What an equation that cannot be rendered shows: its source, marked.
class MathErrorPlaceholder extends StatelessWidget {
  const MathErrorPlaceholder({
    super.key,
    required this.formula,
    required this.style,
  });

  final String formula;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'This equation is not valid LaTeX',
      child: Text(
        formula,
        style: style.copyWith(
          color: scheme.error,
          fontFamily: 'monospace',
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.wavy,
          decorationColor: scheme.error,
        ),
      ),
    );
  }
}

/// Asks for a formula. Returns null if cancelled.
///
/// Opens on the root navigator, so [context] only has to be mounted now, and
/// the dialog is not scaled with a zoomed canvas.
Future<String?> showMathDialog(
  BuildContext context, {
  required String initial,
  required bool block,
}) => showDialog<String>(
  context: context,
  useRootNavigator: true,
  builder: (_) => _MathDialog(initial: initial, block: block),
);

class _MathDialog extends StatefulWidget {
  const _MathDialog({required this.initial, required this.block});

  final String initial;
  final bool block;

  @override
  State<_MathDialog> createState() => _MathDialogState();
}

class _MathDialogState extends State<_MathDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium ?? const TextStyle();
    return AlertDialog(
      title: Text(widget.block ? 'Equation' : 'Inline equation'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('math-source'),
              controller: _controller,
              autofocus: true,
              minLines: 1,
              maxLines: widget.block ? 5 : 2,
              decoration: const InputDecoration(
                labelText: 'LaTeX',
                hintText: r'x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}',
              ),
            ),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: _controller,
              builder: (_, _) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: MathView(
                  formula: _controller.text,
                  display: widget.block,
                  style: style,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Lets the user edit the equation block [node].
Future<void> editMathBlock(
  BuildContext context,
  EditorState editor,
  Node node,
) async {
  final current = node.attributes[NoteFormat.formulaKey];
  final formula = await showMathDialog(
    context,
    initial: current is String ? current : '',
    block: true,
  );
  // The block may have been deleted while the dialog was open.
  if (node.parent == null) return;
  // A table cell shows only its first block, so an equation there stands in
  // for the cell's text. Left empty (cancelled when new, or emptied), it
  // goes back to being a line of text.
  if (node.parent!.type == NoteFormat.tableCellType &&
      (formula ?? (current is String ? current : '')).isEmpty) {
    final path = node.path;
    await editor.apply(
      editor.transaction
        ..deleteNode(node)
        ..insertNode(path, paragraphNode())
        ..afterSelection = Selection.collapsed(Position(path: path)),
    );
    return;
  }
  if (formula == null || formula == current) return;
  await editor.apply(
    editor.transaction..updateNode(node, {NoteFormat.formulaKey: formula}),
  );
}

/// Lets the user edit the inline equation at [index] in [node]; an emptied
/// formula removes it.
Future<void> editMathInline(
  BuildContext context,
  EditorState editor,
  Node node,
  int index,
) async {
  String? formulaAt() {
    final delta = node.delta;
    if (node.parent == null || delta == null || index >= delta.length) {
      return null;
    }
    final run = delta.slice(index, index + 1).firstOrNull;
    final f = run?.attributes?[NoteFormat.formulaKey];
    return f is String ? f : null;
  }

  final current = formulaAt();
  if (current == null) return;
  final formula = await showMathDialog(context, initial: current, block: false);
  // Edits made while the dialog was open may have moved or removed the run.
  if (formula == null || formulaAt() != current) return;
  final tx = editor.transaction;
  if (formula.isEmpty) {
    tx.deleteText(node, index, 1);
  } else {
    tx.formatText(node, index, 1, {NoteFormat.formulaKey: formula});
  }
  await editor.apply(tx);
}

/// Renders inline equations. Everything else falls through to appflowy's
/// own decorator (links).
TextSpanDecoratorForAttribute mathTextSpanDecorator(EditorState editor) =>
    (context, node, index, text, before, after) {
      final formula = text.attributes?[NoteFormat.formulaKey];
      if (formula is! String) {
        return defaultTextSpanDecoratorForAttribute(
          context,
          node,
          index,
          text,
          before,
          after,
        );
      }
      final style = before.style ?? const TextStyle();
      // Runs with the same formula merge into one text insert, but each
      // character is still one equation.
      return TextSpan(
        children: [
          for (var i = 0; i < text.text.length; i++)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _InlineMath(
                formula: formula,
                style: style,
                onTap: editor.editable
                    ? () => editMathInline(context, editor, node, index + i)
                    : null,
              ),
            ),
        ],
      );
    };

class _InlineMath extends StatelessWidget {
  const _InlineMath({
    required this.formula,
    required this.style,
    required this.onTap,
  });

  final String formula;
  final TextStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = MathView(formula: formula, display: false, style: style);
    if (onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

/// Typing right after an equation must not continue it, so `formula` is not
/// inherited by the text appflowy inserts next to an inline equation.
///
/// appflowy decides which attributes new text inherits in one global
/// function; this wraps it once.
void installMathSlicing() {
  if (_slicingInstalled) return;
  _slicingInstalled = true;
  final inner = appflowyEditorSliceAttributes;
  appflowyEditorSliceAttributes = (delta, index) {
    final attributes = inner?.call(delta, index);
    if (attributes == null || !attributes.containsKey(NoteFormat.formulaKey)) {
      return attributes;
    }
    final rest = {...attributes}..remove(NoteFormat.formulaKey);
    return rest.isEmpty ? null : rest;
  };
}

bool _slicingInstalled = false;

/// The block equation component, shaped like appflowy's divider: one block
/// with no text, selectable as a whole.
class MathBlockComponentBuilder extends BlockComponentBuilder {
  MathBlockComponentBuilder(this.editor, {super.configuration});

  final EditorState editor;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return MathBlockComponentWidget(
      key: node.key,
      node: node,
      editor: editor,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate =>
      (node) => node.children.isEmpty;
}

class MathBlockComponentWidget extends BlockComponentStatefulWidget {
  const MathBlockComponentWidget({
    super.key,
    required super.node,
    required this.editor,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
  });

  final EditorState editor;

  @override
  State<MathBlockComponentWidget> createState() =>
      _MathBlockComponentWidgetState();
}

class _MathBlockComponentWidgetState extends State<MathBlockComponentWidget>
    with SelectableMixin, BlockComponentConfigurable {
  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  final GlobalKey _contentKey = GlobalKey();

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final formula = node.attributes[NoteFormat.formulaKey];
    final style = editor.editorStyle.textStyleConfiguration.text.copyWith(
      fontSize: 18,
    );

    Widget child = Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: MathView(
          formula: formula is String ? formula : '',
          display: true,
          style: style,
        ),
      ),
    );
    if (editor.editable) {
      child = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => editMathBlock(context, editor, node),
          child: child,
        ),
      );
    }
    child = Padding(key: _contentKey, padding: padding, child: child);

    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editor.selectionNotifier,
      remoteSelection: editor.remoteSelections,
      blockColor: editor.editorStyle.selectionColor,
      cursorColor: editor.editorStyle.cursorColor,
      selectionColor: editor.editorStyle.selectionColor,
      supportTypes: const [
        BlockSelectionType.block,
        BlockSelectionType.cursor,
        BlockSelectionType.selection,
      ],
      child: child,
    );

    if (widget.showActions && widget.actionBuilder != null) {
      child = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        actionTrailingBuilder: widget.actionTrailingBuilder,
        child: child,
      );
    }

    return Padding(padding: margin, child: child);
  }

  @override
  Position start() => Position(path: widget.node.path);

  @override
  Position end() => Position(path: widget.node.path, offset: 1);

  @override
  Position getPositionInOffset(Offset start) => end();

  @override
  bool get shouldCursorBlink => false;

  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) =>
      getRectsInSelection(Selection.invalid()).first;

  @override
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) return null;
    return getRectsInSelection(
      Selection.collapsed(position),
      shiftWithBaseOffset: shiftWithBaseOffset,
    ).firstOrNull;
  }

  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) {
    final parentBox = _renderBox;
    if (parentBox == null) return [];
    final contentBox = _contentKey.currentContext?.findRenderObject();
    if (contentBox is RenderBox) {
      return [
        (shiftWithBaseOffset
                ? contentBox.localToGlobal(Offset.zero, ancestor: parentBox)
                : Offset.zero) &
            contentBox.size,
      ];
    }
    return [Offset.zero & parentBox.size];
  }

  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      _renderBox!.localToGlobal(offset);

  @override
  TextDirection textDirection() => TextDirection.ltr;
}
