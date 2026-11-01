// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'ai_codec.dart';

/// Command ids of the AI box module.
abstract final class AiCommands {
  /// Insert an AI box. The built-in toolbars already name it; they show a
  /// disabled placeholder until this module registers it.
  static const String insert = 'noted.ai.insert';
}

/// Height of the strip above the note that holds the "AI" label and the
/// "Connected AI" control, in page units.
const double aiHeaderHeight = 28;

/// The AI box module: a note-like document that one AI connection owns and
/// writes to. Text an AI wrote is marked; text the user types is not.
///
/// [connections] is the app's list of AI connections; the module only shows
/// their names and stores the id of the one that owns a box.
final class AiModule extends BoxModule<AiBoxData> {
  AiModule({ValueListenable<List<AiConnectionInfo>>? connections})
    : connections = connections ?? _noConnections;

  static final ValueNotifier<List<AiConnectionInfo>> _noConnections =
      ValueNotifier(const []);

  final ValueListenable<List<AiConnectionInfo>> connections;

  @override
  BoxCodec<AiBoxData> get codec => const AiCodec();

  @override
  Widget buildEditor(BuildContext context, BoxContext<AiBoxData> box) =>
      _AiBox(box: box, editable: true, connections: connections);

  @override
  Widget buildView(BuildContext context, BoxContext<AiBoxData> box) =>
      _AiBox(box: box, editable: false, connections: connections);

  @override
  List<Command> commands(CommandHost host) => [
    Command(
      id: AiCommands.insert,
      label: 'AI box',
      icon: Icons.auto_awesome_rounded,
      text: () => 'AI box',
      enabled: () => !host.controller.readOnly,
      listenable: host.controller,
      invoke: () => insertAiBox(host.controller, host.viewCentre),
    ),
  ];
}

/// Adds an empty AI box below the selected box, or else below the page's
/// content (the host gives a module no view position), and selects it.
@visibleForTesting
void insertAiBox(CanvasController c, Offset? centre) {
  if (c.readOnly) return;
  const size = Size(newBoxWidth, newBoxHeight + aiHeaderHeight);
  if (centre != null) {
    const codec = AiCodec();
    final box = createBox(
      codec,
      Bounds(
        centre.dx - size.width / 2,
        centre.dy - size.height / 2,
        size.width,
        size.height,
      ),
      device: c.deviceName,
    );
    c.insertBox(box, autofocus: true);
    return;
  }
  const gap = 16.0;
  const margin = 40.0;
  final nodes = c.page.nodes;
  Bounds? at;
  final sel = c.selectedId;
  for (final n in nodes) {
    if (sel != null && n.id == sel) at = n.bounds;
  }
  var x = margin;
  var y = margin;
  if (at != null) {
    x = at.x;
    y = at.bottom + gap;
  } else {
    final all = nodes.map((n) => n.bounds).nonNulls.toList();
    if (all.isNotEmpty) {
      final u = all.reduce((a, b) => a.union(b));
      x = u.x;
      y = u.bottom + gap;
    }
  }
  const codec = AiCodec();
  final box = createBox(
    codec,
    Bounds(x, y, newBoxWidth, newBoxHeight + aiHeaderHeight),
    device: c.deviceName,
  );
  c.insertBox(box);
  c.select(box.id);
}

/// The mark on AI-written blocks: a thin bar at the block's left, in the
/// muted text color (the design keeps chrome neutral; accent means
/// selection), which reads in light and dark.
final NoteEditorOptions aiNoteOptions = NoteEditorOptions(
  blockMark: NoteBlockMark(
    dataKey: aiWrittenKey,
    isMarked: isAiWritten,
    color: (context) =>
        Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
  ),
  beforeCommit: stripStaleAiMarks,
);

class _AiBox extends StatefulWidget {
  const _AiBox({
    required this.box,
    required this.editable,
    required this.connections,
  });

  final BoxContext<AiBoxData> box;
  final bool editable;
  final ValueListenable<List<AiConnectionInfo>> connections;

  @override
  State<_AiBox> createState() => _AiBoxState();
}

class _AiBoxState extends State<_AiBox> {
  /// The latest data: the host can rebuild with the data it was last given,
  /// which is older than what was committed since.
  late AiBoxData _current;

  /// [_current]'s note document, the same object the note editor committed
  /// (it tells its own edits from outside changes by identity).
  late NoteData _note;

  /// Bumped on every change from outside (an AI write, undo, a reload). The
  /// note editor compares data to tell its own edits from outside ones, and
  /// an outside change to content it already had would pass as its own; a new
  /// key starts it afresh from the new data.
  int _generation = 0;

  /// Holds the focus whenever the note editor does.
  final FocusNode _editorArea = FocusNode(canRequestFocus: false, skipTraversal: true);

  /// Whether the editor had the focus when an outside change restarted it:
  /// the new one takes it, so the user stays in the box and the page still
  /// knows it is being edited (Escape and undo then work as before).
  bool _refocus = false;

  @override
  void initState() {
    super.initState();
    _current = widget.box.data;
    _note = _current.note;
  }

  @override
  void dispose() {
    _editorArea.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AiBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    final d = widget.box.data;
    if (!identical(d, oldWidget.box.data) && !identical(d, _current)) {
      _current = d;
      _note = d.note;
      // A box that can't be edited commits nothing, so its editor can't
      // write over the change and takes it the usual way; restarting it
      // would drop a focus it can't take back.
      if (!widget.editable) return;
      _generation++;
      _refocus = _editorArea.hasFocus;
      if (_refocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refocus = false);
      }
    }
  }

  void _commitNote(NoteData note) {
    _note = note;
    _current = _current.withNote(note);
    widget.box.commit(_current);
  }

  void _setOwner(String? id) {
    if (id == _current.owner) return;
    _current = _current.withOwner(id);
    widget.box.commit(_current);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: aiHeaderHeight,
          child: _AiHeader(
            connections: widget.connections,
            owner: _current.owner,
            enabled: widget.editable && !widget.box.readOnly,
            onOwner: _setOwner,
          ),
        ),
        Expanded(
          child: Focus(
            focusNode: _editorArea,
            child: NoteEditorView(
              key: ValueKey(_generation),
              box: _NoteBox(this),
              editable: widget.editable,
              options: aiNoteOptions,
            ),
          ),
        ),
      ],
    );
  }
}

/// The note editor's view of the box: the note document alone, in the
/// box minus the header strip.
final class _NoteBox implements BoxContext<NoteData> {
  _NoteBox(this._s) : data = _s._note;

  final _AiBoxState _s;

  BoxContext<AiBoxData> get _b => _s.widget.box;

  @override
  String get boxId => _b.boxId;
  @override
  /// The note as of this build: the editor tells its own edits from outside
  /// changes by comparing this with the one of the previous build.
  final NoteData data;
  @override
  Rect get bounds {
    final r = _b.bounds;
    return Rect.fromLTWH(r.left, r.top, r.width, math.max(0, r.height - aiHeaderHeight));
  }

  @override
  bool get readOnly => _b.readOnly;
  @override
  bool get autoHeight => _b.autoHeight;
  @override
  bool get autofocus => _b.autofocus || _s._refocus;
  @override
  void commit(NoteData data) => _s._commitNote(data);
  @override
  ValueListenable<BoxFind?> get find => _b.find;
  @override
  void requestBounds(Rect bounds) => _b.requestBounds(
    Rect.fromLTWH(bounds.left, bounds.top, bounds.width, bounds.height + aiHeaderHeight),
  );
  @override
  AttachmentStore? get attachments => _b.attachments;
  @override
  void insertFilesBeside(List<IncomingFile> files) => _b.insertFilesBeside(files);
}

/// The value of the "None" item (a menu item with a null value would not
/// report a choice).
const String _none = '';

class _AiHeader extends StatelessWidget {
  const _AiHeader({
    required this.connections,
    required this.owner,
    required this.enabled,
    required this.onOwner,
  });

  final ValueListenable<List<AiConnectionInfo>> connections;
  final String? owner;
  final bool enabled;
  final void Function(String? id) onOwner;

  @override
  Widget build(BuildContext context) {
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final m = NotedMetrics.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.space2),
      child: Row(
        children: [
          Container(
            key: const ValueKey('ai-box-label'),
            padding: EdgeInsets.symmetric(horizontal: m.space2, vertical: 1),
            decoration: BoxDecoration(
              color: colors.surfaceHover,
              borderRadius: m.borderSm,
            ),
            child: Text(
              'AI',
              style: type.label.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<List<AiConnectionInfo>>(
            valueListenable: connections,
            builder: (context, list, _) {
              AiConnectionInfo? current;
              for (final c in list) {
                if (c.id == owner) current = c;
              }
              final name = current == null
                  ? 'No connected AI'
                  : (current.name.isEmpty ? 'Unnamed' : current.name);
              final text = Text(
                name,
                key: const ValueKey('ai-box-owner'),
                overflow: TextOverflow.ellipsis,
                style: type.small.copyWith(color: scheme.onSurfaceVariant),
              );
              if (!enabled) return Flexible(child: text);
              return Flexible(
                child: PopupMenuButton<String>(
                  key: const ValueKey('ai-box-picker'),
                  tooltip: 'Connected AI',
                  padding: EdgeInsets.zero,
                  onSelected: (id) => onOwner(id == _none ? null : id),
                  itemBuilder: (_) => [
                    const NotedMenuHeading('Connected AI'),
                    for (final c in list)
                      NotedMenuItem<String>(
                        key: ValueKey('ai-owner-${c.id}'),
                        value: c.id,
                        label: c.name.isEmpty ? 'Unnamed' : c.name,
                        leading: MenuCheckMark(checked: c.id == owner),
                      ),
                    if (list.isNotEmpty) const NotedMenuDivider(),
                    NotedMenuItem<String>(
                      key: const ValueKey('ai-owner-none'),
                      value: _none,
                      label: 'None',
                      leading: MenuCheckMark(checked: current == null),
                    ),
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: text),
                      Icon(
                        Icons.arrow_drop_down_rounded,
                        size: m.icon,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
