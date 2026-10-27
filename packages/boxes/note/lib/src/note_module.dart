// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'math_blocks.dart';
import 'math_input.dart';
import 'note_codec.dart';
import 'note_commands.dart';
import 'note_editor_state.dart';
import 'note_find.dart';
import 'note_light_view.dart';
import 'note_theme.dart';
import 'table_formulas.dart';
import 'table_menu.dart';
import 'table_headers.dart';
import 'vertical_caret.dart';

/// The plain note box module: an appflowy_editor document that grows with
/// its content (0004, 0015). Always on; it is the box a click creates.
///
/// A note shows its blocks in a light view (`note_light_view.dart`) and
/// builds the real editor only while it is being edited: a page can hold
/// hundreds of notes and an editor per note made opening the page and every
/// frame slow.
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

  @override
  List<Command> commands(CommandHost host) => noteCommands(host);
}

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({required this.box, required this.editable});

  final BoxContext<NoteData> box;
  final bool editable;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

/// Test hook: when false every note keeps its editor (the light view is never
/// used), so a test can compare the two.
@visibleForTesting
bool noteLightViewEnabled = true;

/// The standard blocks for the light view, made once per theme and shared by
/// every note: they hold no state, only the configuration the editor's
/// blocks are built from.
ColorScheme? _lightScheme;
Map<String, BlockComponentBuilder>? _lightBuilders;

Map<String, BlockComponentBuilder> _lightBuildersFor(ColorScheme scheme) {
  if (_lightBuilders == null || _lightScheme != scheme) {
    _lightScheme = scheme;
    _lightBuilders = themedStandardBlocks(
      scheme,
      paragraphPlaceholder: 'Type here',
    );
  }
  return _lightBuilders!;
}

class _NoteEditorState extends State<_NoteEditor>
    implements NoteCommandTarget {
  /// The editor's state, made when the note is first edited and then kept
  /// (also while the light view is shown), so that its undo history lasts as
  /// long as the page is open. Null until then.
  NoteEditorState? _editor;

  /// Whether the editor widget is in the tree. Otherwise the light view is.
  bool _editing = false;

  /// The note's document for the light view, made from the data when there
  /// is no editor yet. Never edited.
  Document? _lightDoc;

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
  final GlobalKey _lightHeaderKey = GlobalKey();
  final GlobalKey _lightFooterKey = GlobalKey();
  final GlobalKey<TableHeadersState> _headersKey = GlobalKey();
  late TableFormulas _formulas;
  bool _syncing = false;
  bool _measureScheduled = false;
  bool _revealScheduled = false;
  bool _demoteScheduled = false;

  /// The editor is there only because the light view can't draw this note
  /// yet (nobody asked to edit it); it goes back to the light view as soon
  /// as the note can be drawn, without waiting for a focus change.
  bool _forced = false;

  /// The route this note is on; while a menu or dialog is above it the
  /// editor stays (its own overlays take the focus).
  ModalRoute<Object?>? _route;

  /// The data the editor currently shows: either what it was loaded from or
  /// what it last committed.
  late NoteData _shown;

  @override
  void initState() {
    super.initState();
    installMathSlicing();
    _focus.addListener(_focusChanged);
    widget.box.find.addListener(_findChanged);
    _shown = widget.box.data;
    // A box a click just created starts as an editor, and so does a note
    // the light view can't draw.
    _forced = !noteLightable(_document.root);
    _editing =
        !noteLightViewEnabled ||
        (widget.editable && widget.box.autofocus) ||
        _forced;
  }

  /// The note's blocks: the editor's document once there is an editor, else
  /// a read-only one made from the data.
  Document get _document =>
      _editor?.document ?? (_lightDoc ??= Document.fromJson(_shown.document));

  // Find on page (Box API 0.6). The matches in this note's blocks, found in
  // the note's own snapshot; rebuilt when the query, the current match or
  // the note's content changes.
  BoxFind? _findFor;
  NoteData? _findData;
  NoteFind? _findModel;

  void _findChanged() => _rebuildSoon();

  /// setState that is safe to ask for at any time.
  void _rebuildSoon() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  NoteFind? _currentFind() {
    final f = widget.box.find.value;
    if (f == null) {
      _findFor = null;
      return _findModel = null;
    }
    if (f != _findFor || !identical(_findData, _shown)) {
      _findFor = f;
      _findData = _shown;
      _findModel = NoteFind.build(_shown, f, widget.box.boxId);
    }
    return _findModel;
  }

  // The note commands (insert table, insert equation) act on the editor
  // that has focus.
  void _focusChanged() {
    NoteCommandFocus.report(
      this,
      focused: widget.editable && _focus.hasFocus,
    );
    if (!_focus.hasFocus) {
      _scheduleDemote();
    } else if (!_editing) {
      // The editor was on its way out (it is still in the tree until the
      // next frame) and the user got back into it.
      _editing = true;
      _forced = false;
      _rebuildSoon();
    }
  }

  @override
  bool get canInsert =>
      mounted && widget.editable && _editor != null && _focus.hasFocus;

  @override
  Future<void> insertTable() async {
    if (canInsert) insertTableAtCaret(_editor!, context);
  }

  @override
  Future<void> insertEquation() async {
    if (canInsert) insertEquationAtCaret(_editor!, context);
  }

  // The editor's life ---------------------------------------------------

  /// Makes the editor state from the note's data, if there is none.
  void _ensureEditor() {
    if (_editor != null) return;
    // Give the editor its own deep copy: it mutates its document in place.
    final json =
        jsonDecode(jsonEncode(_shown.document)) as Map<String, dynamic>;
    final editor = NoteEditorState(document: Document.fromJson(json));
    _editor = editor;
    _lightDoc = null;
    _scroll = EditorScrollController(editorState: editor, shrinkWrap: true);
    _formulas = TableFormulas(editor);
    // Fills in the stored value of formula cells that have none (before the
    // listener below, so loading never counts as an edit).
    if (widget.editable) _formulas.initialize();
    _sub = editor.transactionStream.listen(_onTransaction);
    editor.selectionNotifier.addListener(_scheduleReveal);
    _applyTheme(_scheme!, renderer: false);
  }

  void _disposeEditor() {
    final editor = _editor;
    if (editor == null) return;
    editor.selectionNotifier.removeListener(_scheduleReveal);
    _sub.cancel();
    _scroll.dispose();
    editor.dispose();
    _editor = null;
  }

  /// Makes the blocks and the slash menu for [scheme]. The editor widget
  /// only reads the builders when it starts, so on a theme change the
  /// editor's renderer is replaced too.
  void _applyTheme(ColorScheme scheme, {required bool renderer}) {
    final editor = _editor!;
    _scheme = scheme;
    _builders = _blockBuilders(editor, scheme, _formulas);
    _shortcuts = _characterShortcuts(scheme);
    if (renderer) {
      editor.renderer = BlockComponentRenderer(builders: {..._builders});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scheme = Theme.of(context).colorScheme;
    final changed = scheme != _scheme;
    final first = _scheme == null;
    _scheme = scheme;
    if (changed && _editor != null) _applyTheme(scheme, renderer: !first);
    final route = ModalRoute.of(context);
    final covered = _route != null && !_route!.isCurrent;
    _route = route;
    // A menu or dialog above this note just went away.
    if (covered && route != null && route.isCurrent) _scheduleDemote();
    if (first && _editing) {
      _ensureEditor();
      if (_forced) _scheduleDemote();
    }
  }

  /// Puts the editor in the tree, with the caret at [selection].
  /// [afterMount] runs once the editor is there.
  void _activate({Selection? selection, VoidCallback? afterMount}) {
    if (!mounted) return;
    _ensureEditor();
    _forced = false;
    if (!_editing) setState(() => _editing = true);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final editor = _editor;
      if (!mounted || !_editing || editor == null || editor.isDisposed) return;
      if (selection != null) {
        // A UI event: the editor takes the keyboard focus. (Only a change of
        // selection does that, and the one it had when it was last in the
        // tree may be the same.)
        editor.selection = null;
        editor.updateSelectionWithReason(
          selection,
          reason: SelectionUpdateReason.uiEvent,
        );
      }
      afterMount?.call();
    });
  }

  /// Back to the light view once the editor lost the focus, unless one of
  /// its own menus or dialogs is open or a change is being applied.
  void _scheduleDemote() {
    if (!_editing || _demoteScheduled) return;
    _demoteScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _demoteScheduled = false;
      _demote();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _demote() {
    final editor = _editor;
    if (!mounted || !_editing || editor == null) return;
    if (!noteLightViewEnabled) return;
    if (_focus.hasFocus || keepEditorFocusNotifier.shouldKeepFocus) return;
    final route = _route;
    if (route != null && !route.isCurrent) return;
    if (!noteLightable(editor.document.root)) return;
    if (_hasTable(editor.document.root)) {
      // appflowy's table adds listeners to its nodes that it never removes,
      // and the ones left by an unmounted editor measure the table with a
      // stale layout and fight the live ones (row heights flip forever
      // after a column is duplicated). So an editor with a table is not
      // mounted a second time: one the user has been in stays (with its
      // undo history); one that was only there for the light view to wait
      // for the table's measurements is thrown away, and the next click
      // makes a new one from the committed data.
      if (!_forced) return;
      if (!noteLightable(Document.fromJson(_shown.document).root)) return;
      setState(() => _editing = false);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_editing) {
          _disposeEditor();
          _lightDoc = null;
        }
      });
      return;
    }
    setState(() => _editing = false);
  }

  void _onTransaction(EditorTransactionValue value) {
    final (time, _, options) = value;
    if (time != TransactionTime.after) return;
    _scheduleMeasure();
    if (_forced && _editing && !_focus.hasFocus) _scheduleDemote();
    if (!widget.editable || _syncing) return;
    // Formula values, and references after rows or columns changed. Its own
    // transactions come back here and are skipped; this call commits.
    _syncing = true;
    try {
      _formulas.sync(options.resolvedSource);
    } finally {
      _syncing = false;
    }
    final next = NoteData(_editor!.document.toJson());
    _shown = next;
    widget.box.commit(next);
    // Find on page: the highlights follow what was typed.
    if (widget.box.find.value != null) _findChanged();
    // The light view shows the editor's document.
    if (!_editing) _rebuildSoon();
  }

  @override
  void didUpdateWidget(_NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.box.find != widget.box.find) {
      oldWidget.box.find.removeListener(_findChanged);
      widget.box.find.addListener(_findChanged);
    }
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
      _disposeEditor();
      _lightDoc = null;
      _shown = widget.box.data;
      if (!_editing && !noteLightable(_document.root)) {
        _editing = true;
        _forced = true;
      }
      if (_editing) _ensureEditor();
    }
  }

  @override
  void dispose() {
    NoteCommandFocus.release(this);
    widget.box.find.removeListener(_findChanged);
    _focus.removeListener(_focusChanged);
    _disposeEditor();
    _focus.dispose();
    super.dispose();
  }

  // The light view's clicks ----------------------------------------------

  void _lightTap(LightHit? hit) {
    if (!mounted || _editing) return;
    if (hit == null) {
      _activate(selection: Selection.collapsed(Position(path: [0])));
      return;
    }
    final href = hit.href;
    if (href != null &&
        (!widget.editable ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      editorLaunchUrl(href);
      return;
    }
    if (hit.onMath && widget.editable) {
      _lightEditMathBlock(hit.node);
      return;
    }
    _activate(
      selection: Selection.collapsed(
        Position(path: hit.node.path, offset: hit.offset),
      ),
    );
  }

  void _lightEditMathBlock(Node lightNode) {
    final path = lightNode.path;
    _activate(
      selection: Selection.collapsed(Position(path: path)),
      afterMount: () {
        final editor = _editor;
        final node = editor?.getNodeAtPath(path);
        if (editor != null && node != null && mounted) {
          editMathBlock(context, editor, node);
        }
      },
    );
  }

  void _lightEditMathInline(Node lightNode, int index) {
    final path = lightNode.path;
    _activate(
      selection: Selection.collapsed(Position(path: path, offset: index)),
      afterMount: () {
        final editor = _editor;
        final node = editor?.getNodeAtPath(path);
        if (editor != null && node != null && mounted) {
          editMathInline(context, editor, node, index);
        }
      },
    );
  }

  /// Checks or unchecks a to-do item without putting the editor in the
  /// tree: the change goes through the editor's state, so it can be undone.
  void _lightToggleTodo(Node lightNode) {
    final path = lightNode.path;
    _ensureEditor();
    final editor = _editor!;
    final node = editor.getNodeAtPath(path);
    if (node == null || node.type != TodoListBlockKeys.type) return;
    final checked = node.attributes[TodoListBlockKeys.checked] == true;
    editor.apply(
      editor.transaction
        ..updateNode(node, {TodoListBlockKeys.checked: !checked}),
      withUpdateSelection: false,
    );
  }

  // Layout ----------------------------------------------------------------

  GlobalKey get _headerKeyNow => _editing ? _headerKey : _lightHeaderKey;
  GlobalKey get _footerKeyNow => _editing ? _footerKey : _lightFooterKey;

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
    final editor = _editor;
    if (editor == null || !_editing) return;
    final selection = editor.selection;
    final header = _headerKey.currentContext;
    if (selection == null || header == null) return;
    final scrollable = Scrollable.maybeOf(header);
    final viewport = scrollable?.context.findRenderObject();
    if (scrollable == null || viewport is! RenderBox || !viewport.hasSize) {
      return;
    }
    final caret = caretOnScreen(editor, selection.end);
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
  /// holds even while the editor is scrolled. The light view lays its blocks
  /// out the same way and has the same header and footer.
  void _fitHeight(RenderBox root) {
    final header = _headerKeyNow.currentContext?.findRenderObject();
    final footer = _footerKeyNow.currentContext?.findRenderObject();
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
          child: NoteFindScope(
            find: _currentFind(),
            child: _editing ? _editorView(scheme) : _lightView(scheme),
          ),
        ),
      ),
    );
  }

  Widget _lightView(ColorScheme scheme) => NoteLightView(
    document: _document,
    builders: _lightBuildersFor(scheme),
    scheme: scheme,
    headerKey: _lightHeaderKey,
    footerKey: _lightFooterKey,
    actions: LightActions(
      editable: widget.editable,
      onTap: _lightTap,
      onToggleTodo: _lightToggleTodo,
      onEditMathBlock: _lightEditMathBlock,
      onEditMathInline: _lightEditMathInline,
    ),
  );

  Widget _editorView(ColorScheme scheme) {
    _ensureEditor();
    return Stack(
      fit: StackFit.expand,
      children: [
        _editorWidget(scheme),
        if (widget.editable)
          Positioned.fill(
            child: TableHeaders(
              key: _headersKey,
              editor: _editor!,
              rootKey: _rootKey,
            ),
          ),
      ],
    );
  }

  Widget _editorWidget(ColorScheme scheme) {
    final editor = _editor!;
    return AppFlowyEditor(
      editorState: editor,
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
        padding: const EdgeInsets.symmetric(horizontal: DesignMetrics.space2),
        textSpanDecorator: findSpanDecorator(
          formulaSpanDecorator(editor, mathTextSpanDecorator(editor)),
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

bool _hasTable(Node root) =>
    root.children.any((n) => n.type == TableBlockKeys.type);

/// appflowy's typing shortcuts, with the math ones first and the slash menu
/// extended with the equation item.
List<CharacterShortcutEvent> _characterShortcuts(ColorScheme scheme) => [
  inlineMathShortcut,
  blockMathShortcut,
  for (final e in standardCharacterShortcutEvents)
    if (e.key != slashCommand.key) e,
  noteSlashCommandWith(noteSelectionMenuStyle(scheme)),
];
