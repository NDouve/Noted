// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'note_codec.dart';

/// The plain note box module: an appflowy_editor document that grows with
/// its content (0004, 0015). Always on; it is the box a click creates.
final class NoteModule extends BoxModule<NoteData> {
  const NoteModule();

  @override
  BoxCodec<NoteData> get codec => const NoteCodec();

  @override
  Widget buildEditor(BuildContext context, BoxContext<NoteData> box) =>
      _NoteEditor(box: box, editable: true);

  @override
  Widget buildView(BuildContext context, BoxContext<NoteData> box) =>
      _NoteEditor(box: box, editable: false);
}

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({required this.box, required this.editable});

  final BoxContext<NoteData> box;
  final bool editable;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late EditorState _editor;
  late EditorScrollController _scroll;
  late StreamSubscription<EditorTransactionValue> _sub;
  final FocusNode _focus = FocusNode(debugLabel: 'note');
  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _footerKey = GlobalKey();
  bool _measureScheduled = false;

  /// Starts tiny and is raised once the box has been measured; see
  /// [_updateEdgeOffset].
  double _edgeOffset = 1;

  /// The data the editor currently shows: either what it was loaded from or
  /// what it last committed.
  late NoteData _shown;

  @override
  void initState() {
    super.initState();
    _load(widget.box.data);
  }

  void _load(NoteData data) {
    _shown = data;
    // Give the editor its own deep copy: it mutates its document in place.
    final json = jsonDecode(jsonEncode(data.document)) as Map<String, dynamic>;
    _editor = EditorState(document: Document.fromJson(json));
    _scroll = EditorScrollController(editorState: _editor, shrinkWrap: true);
    _sub = _editor.transactionStream.listen(_onTransaction);
  }

  void _unload() {
    _sub.cancel();
    _scroll.dispose();
    _editor.dispose();
  }

  void _onTransaction(EditorTransactionValue value) {
    final (time, _, _) = value;
    if (time != TransactionTime.after) return;
    _scheduleMeasure();
    if (!widget.editable) return;
    final next = NoteData(_editor.document.toJson());
    _shown = next;
    widget.box.commit(next);
  }

  @override
  void didUpdateWidget(_NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Data changed outside this editor (for example a reload): start over.
    if (!identical(widget.box.data, _shown)) {
      _unload();
      _load(widget.box.data);
    }
  }

  @override
  void dispose() {
    _unload();
    _focus.dispose();
    super.dispose();
  }

  /// After the next frame: updates the auto-scroll edge offset and, while the
  /// box has auto height, asks the host to resize it to fit the document.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final root = _rootKey.currentContext?.findRenderObject();
      if (root is! RenderBox || !root.hasSize) return;
      _updateEdgeOffset(root);
      if (widget.box.autoHeight) _fitHeight(root);
    });
  }

  /// Keeps appflowy's auto-scroll target smaller than the box.
  ///
  /// appflowy keeps a square of `autoScrollEdgeOffset` (220 px by default)
  /// around the caret in view. In a viewport shorter than that square, the
  /// square sticks out of both edges at once, so Flutter's
  /// EdgeDraggingAutoScroller scrolls up, then down, then up again without
  /// end: the app freezes. Half the viewport's height, measured both on the
  /// page and on screen (the scroller compares the two at the current zoom),
  /// can never stick out of both edges.
  void _updateEdgeOffset(RenderBox root) {
    final local = root.size.height;
    final screen = MatrixUtils.transformRect(
      root.getTransformTo(null),
      Offset.zero & root.size,
    ).height;
    final edge = (math.min(local, screen) / 2)
        .clamp(1.0, appFlowyEditorAutoScrollEdgeOffset)
        .toDouble();
    if ((edge - _edgeOffset).abs() < 0.5) return;
    // Applied to the editor state at once, so a scroll started in this frame
    // already uses it; the rebuild keeps the widget's value in step.
    _editor.autoScrollEdgeOffset = edge;
    setState(() => _edgeOffset = edge);
  }

  /// The editor needs a finite height (it hosts its own Overlay), so it fills
  /// the box and the content is measured instead. In shrink-wrap mode
  /// appflowy lays the document out as a Column of header, blocks, footer:
  /// the content height is the header's top to the footer's bottom, which
  /// holds even while the editor is scrolled.
  void _fitHeight(RenderBox root) {
    final header = _headerKey.currentContext?.findRenderObject();
    final footer = _footerKey.currentContext?.findRenderObject();
    if (header is! RenderBox || footer is! RenderBox) return;
    if (!header.hasSize || !footer.hasSize) return;
    final top = header.localToGlobal(Offset.zero, ancestor: root).dy;
    final bottom = footer
        .localToGlobal(Offset(0, footer.size.height), ancestor: root)
        .dy;
    final b = widget.box.bounds;
    final h = math.max(bottom - top, minBoxHeight);
    if ((h - b.height).abs() < 0.5) return;
    widget.box.requestBounds(Rect.fromLTWH(b.left, b.top, b.width, h));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _scheduleMeasure();
    // A box with a height the user set scrolls its overflow; BoxScrollScope
    // keeps Ctrl+wheel zooming the canvas.
    return BoxScrollScope(
      child: KeyedSubtree(
        key: _rootKey,
        child: AppFlowyEditor(
          editorState: _editor,
          editorScrollController: _scroll,
          editable: widget.editable,
          shrinkWrap: true,
          autoScrollEdgeOffset: _edgeOffset,
          blockComponentBuilders: _blockBuilders,
          focusNode: _focus,
          autoFocus: widget.editable && widget.box.autofocus,
          header: SizedBox(key: _headerKey, height: _verticalPadding),
          footer: SizedBox(key: _footerKey, height: _verticalPadding),
          editorStyle: EditorStyle.desktop(
            // Applied around every block, so only horizontal; the header and
            // footer give the vertical padding.
            padding: const EdgeInsets.symmetric(horizontal: 10),
            cursorColor: scheme.primary,
            selectionColor: scheme.primary.withValues(alpha: 0.25),
            textStyleConfiguration: TextStyleConfiguration(
              text: TextStyle(fontSize: 15, color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

const double _verticalPadding = 6;

/// Localization delegates the note editor needs. Add these to the app's
/// `localizationsDelegates`.
const List<LocalizationsDelegate<Object>> noteLocalizationsDelegates = [
  AppFlowyEditorLocalizations.delegate,
];

/// appflowy's standard blocks, with a placeholder short enough to fit on
/// one line of a new note.
final Map<String, BlockComponentBuilder> _blockBuilders = {
  ...standardBlockComponentBuilderMap,
  ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      placeholderText: (_) => 'Type here',
    ),
  ),
};
