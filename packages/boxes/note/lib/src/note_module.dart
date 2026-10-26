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

import 'math_blocks.dart';
import 'math_input.dart';
import 'note_codec.dart';
import 'note_editor_state.dart';
import 'note_theme.dart';
import 'table_formulas.dart';
import 'table_menu.dart';
import 'table_headers.dart';
import 'vertical_caret.dart';

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

  /// Built once per editor state: a new map on every build would make the
  /// editor rebuild every block.
  late Map<String, BlockComponentBuilder> _builders;

  /// The typing shortcuts, with the slash menu in the theme's colors.
  late List<CharacterShortcutEvent> _shortcuts;

  /// The theme the builders and shortcuts were made for; null until the
  /// first build.
  ColorScheme? _scheme;
  late EditorScrollController _scroll;
  late StreamSubscription<EditorTransactionValue> _sub;
  final FocusNode _focus = FocusNode(debugLabel: 'note');
  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _footerKey = GlobalKey();
  final GlobalKey<TableHeadersState> _headersKey = GlobalKey();
  late TableFormulas _formulas;
  bool _syncing = false;
  bool _measureScheduled = false;
  bool _revealScheduled = false;

  /// The data the editor currently shows: either what it was loaded from or
  /// what it last committed.
  late NoteData _shown;

  @override
  void initState() {
    super.initState();
    installMathSlicing();
    _load(widget.box.data);
  }

  void _load(NoteData data) {
    _shown = data;
    // Give the editor its own deep copy: it mutates its document in place.
    final json = jsonDecode(jsonEncode(data.document)) as Map<String, dynamic>;
    _editor = NoteEditorState(document: Document.fromJson(json));
    _scroll = EditorScrollController(editorState: _editor, shrinkWrap: true);
    _formulas = TableFormulas(_editor);
    // Fills in the stored value of formula cells that have none (before the
    // listener below, so loading never counts as an edit).
    if (widget.editable) _formulas.initialize();
    _sub = _editor.transactionStream.listen(_onTransaction);
    _editor.selectionNotifier.addListener(_scheduleReveal);
  }

  /// Makes the blocks and the slash menu for [scheme]. The editor widget
  /// only reads the builders when it starts, so on a theme change the
  /// editor's renderer is replaced too.
  void _applyTheme(ColorScheme scheme, {required bool renderer}) {
    _scheme = scheme;
    _builders = _blockBuilders(_editor, scheme, _formulas);
    _shortcuts = _characterShortcuts(scheme);
    if (renderer) {
      _editor.renderer = BlockComponentRenderer(builders: {..._builders});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scheme = Theme.of(context).colorScheme;
    if (scheme != _scheme) _applyTheme(scheme, renderer: _scheme != null);
  }

  void _unload() {
    _editor.selectionNotifier.removeListener(_scheduleReveal);
    _sub.cancel();
    _scroll.dispose();
    _editor.dispose();
  }

  void _onTransaction(EditorTransactionValue value) {
    final (time, _, options) = value;
    if (time != TransactionTime.after) return;
    _scheduleMeasure();
    if (!widget.editable || _syncing) return;
    // Formula values, and references after rows or columns changed. Its own
    // transactions come back here and are skipped; this call commits.
    _syncing = true;
    try {
      _formulas.sync(options.resolvedSource);
    } finally {
      _syncing = false;
    }
    final next = NoteData(_editor.document.toJson());
    _shown = next;
    widget.box.commit(next);
  }

  @override
  void didUpdateWidget(_NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Data changed outside this editor (for example a reload): start over.
    if (!identical(widget.box.data, _shown)) {
      // The host can rebuild with data older than what this editor has
      // committed: it only hears of a commit when something else changes the
      // page, so a rebuild for another reason (the pointer entering or
      // leaving the box, which a table's menu causes) hands over the node it
      // was last given. That is the data it gave last time, not a change
      // from outside; starting over from it would drop the editor's undo
      // history and its latest edits.
      if (identical(widget.box.data, oldWidget.box.data) ||
          jsonEncode(widget.box.data.document) ==
              jsonEncode(oldWidget.box.data.document)) {
        return;
      }
      // The same content in another object (the host decoded it again): the
      // editor already shows it.
      if (jsonEncode(widget.box.data.document) == jsonEncode(_shown.document)) {
        _shown = widget.box.data;
        return;
      }
      _unload();
      _load(widget.box.data);
      _applyTheme(_scheme!, renderer: false);
    }
  }

  @override
  void dispose() {
    _unload();
    _focus.dispose();
    super.dispose();
  }

  /// While the box has auto height: after the next frame, asks the host to
  /// resize the box to fit the document.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || !widget.box.autoHeight) return;
      final root = _rootKey.currentContext?.findRenderObject();
      if (root is RenderBox && root.hasSize) _fitHeight(root);
    });
  }

  /// Keeps the caret in view when the box scrolls (its height is fixed).
  ///
  /// This replaces appflowy's auto-scroll, which is switched off. Its
  /// scroller keeps a 220 px square around the caret in view; in a viewport
  /// shorter than that the square sticks out of both edges at once, and
  /// Flutter's EdgeDraggingAutoScroller scrolls up, down, up... forever: the
  /// app froze. Its caret rectangle is also wrong on a zoomed canvas, so even
  /// with a smaller square it stopped short when zoomed out. Here the caret
  /// is measured correctly at any zoom ([caretOnScreen]) and the editor
  /// scrolls once, just enough to show it, so nothing can loop.
  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted) _revealCaret();
    });
  }

  void _revealCaret() {
    final selection = _editor.selection;
    final header = _headerKey.currentContext;
    if (selection == null || header == null) return;
    final scrollable = Scrollable.maybeOf(header);
    final viewport = scrollable?.context.findRenderObject();
    if (scrollable == null || viewport is! RenderBox || !viewport.hasSize) {
      return;
    }
    final caret = caretOnScreen(_editor, selection.end);
    if (caret == null) return;
    final (rect, scale) = caret;
    final visible = MatrixUtils.transformRect(
      viewport.getTransformTo(null),
      Offset.zero & viewport.size,
    );
    final position = scrollable.position;
    double? target;
    if (rect.top < visible.top) {
      target =
          position.pixels - (visible.top - rect.top) / scale - _revealMargin;
    } else if (rect.bottom > visible.bottom) {
      target =
          position.pixels +
          (rect.bottom - visible.bottom) / scale +
          _revealMargin;
    }
    if (target == null) return;
    position.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
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
      child: NotificationListener<ScrollNotification>(
        // A table scrolling sideways moves its column headers.
        onNotification: (_) {
          _headersKey.currentState?.refresh();
          return false;
        },
        child: KeyedSubtree(
          key: _rootKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _editorWidget(scheme),
              if (widget.editable)
                Positioned.fill(
                  child: TableHeaders(
                    key: _headersKey,
                    editor: _editor,
                    rootKey: _rootKey,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editorWidget(ColorScheme scheme) {
    return AppFlowyEditor(
      editorState: _editor,
      editorScrollController: _scroll,
      editable: widget.editable,
      shrinkWrap: true,
      // Caret-follow is done by _revealCaret; see there for why.
      disableAutoScroll: true,
      blockComponentBuilders: _builders,
      characterShortcutEvents: _shortcuts,
      commandShortcutEvents: _formulas.commandShortcuts(noteCommandShortcuts),
      focusNode: _focus,
      autoFocus: widget.editable && widget.box.autofocus,
      header: SizedBox(key: _headerKey, height: _verticalPadding),
      footer: SizedBox(key: _footerKey, height: _verticalPadding),
      editorStyle: EditorStyle.desktop(
        // Applied around every block, so only horizontal; the header and
        // footer give the vertical padding.
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textSpanDecorator: formulaSpanDecorator(
          _editor,
          mathTextSpanDecorator(_editor),
        ),
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.25),
        textStyleConfiguration: noteTextStyles(scheme),
      ),
    );
  }
}

const double _verticalPadding = 6;

/// Page pixels kept between the caret and the edge when scrolling to it.
const double _revealMargin = 4;

/// Localization delegates the note editor needs. Add these to the app's
/// `localizationsDelegates`.
const List<LocalizationsDelegate<Object>> noteLocalizationsDelegates = [
  AppFlowyEditorLocalizations.delegate,
];

/// appflowy's standard blocks (which include the table), with a placeholder
/// short enough to fit on one line of a new note, plus the equation block.
Map<String, BlockComponentBuilder> _blockBuilders(
  EditorState editor,
  ColorScheme scheme,
  TableFormulas formulas,
) => {
  ...themedStandardBlocks(
    scheme,
    paragraphPlaceholder: 'Type here',
    tableMenuBuilder: tableMenuBuilder(formulas, scheme),
  ),
  ...mathBlockBuilders(editor),
};

/// appflowy's typing shortcuts, with the math ones first and the slash menu
/// extended with the equation item.
List<CharacterShortcutEvent> _characterShortcuts(ColorScheme scheme) => [
  inlineMathShortcut,
  blockMathShortcut,
  for (final e in standardCharacterShortcutEvents)
    if (e.key != slashCommand.key) e,
  noteSlashCommandWith(noteSelectionMenuStyle(scheme)),
];
