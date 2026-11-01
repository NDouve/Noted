// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'ai_box_access.dart';
import 'ai_codec.dart';
import 'ai_connect_dialog.dart';
import 'ai_connections_dialog.dart';

/// Command ids of the AI box module.
abstract final class AiCommands {
  /// Insert an AI box. The built-in toolbars already name it; they show a
  /// disabled placeholder until this module registers it.
  static const String insert = 'noted.ai.insert';
}

/// Height of the strip above the note that holds the "AI" label and the
/// connection controls, in page units.
const double aiHeaderHeight = 28;

/// The AI box module: a note-like document that AI chats connect to with
/// per-box codes. A Writer's text is marked; text the user types is not.
///
/// [access] is the app's store of this box's codes, settings and
/// activity; without one (tests, a host with no AI access) the box can't
/// connect a chat.
final class AiModule extends BoxModule<AiBoxData> {
  AiModule({AiBoxAccess? access}) : access = access ?? NoAiBoxAccess();

  final AiBoxAccess access;

  @override
  BoxCodec<AiBoxData> get codec => const AiCodec();

  @override
  Widget buildEditor(BuildContext context, BoxContext<AiBoxData> box) =>
      _AiBox(box: box, editable: true, access: access);

  @override
  Widget buildView(BuildContext context, BoxContext<AiBoxData> box) =>
      _AiBox(box: box, editable: false, access: access);

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

/// The mark on AI-written blocks: a 2 px bar in the margin left of the text
/// column, in the muted text color (the design keeps chrome neutral; accent
/// means selection), which reads in light and dark. Consecutive marked
/// blocks draw one unbroken bar. See docs/design/ai-box.md.
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
    required this.access,
  });

  final BoxContext<AiBoxData> box;
  final bool editable;
  final AiBoxAccess access;

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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: aiHeaderHeight,
          child: _AiHeader(
            access: widget.access,
            boxId: widget.box.boxId,
            showConnect: widget.editable,
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

/// Below this width the header drops its words and keeps the icons.
const double _narrowHeader = 260;

class _AiHeader extends StatelessWidget {
  const _AiHeader({
    required this.access,
    required this.boxId,
    required this.showConnect,
  });

  final AiBoxAccess access;
  final String boxId;

  /// False in a view that can't edit: no Connect control at all.
  final bool showConnect;

  @override
  Widget build(BuildContext context) {
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final m = NotedMetrics.of(context);
    final muted = scheme.onSurfaceVariant;
    final available = access is! NoAiBoxAccess;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.space2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < _narrowHeader;
          return Row(
            children: [
              Container(
                key: const ValueKey('ai-box-label'),
                padding: EdgeInsets.symmetric(horizontal: m.space2, vertical: 1),
                decoration: BoxDecoration(
                  color: colors.surfaceHover,
                  borderRadius: m.borderSm,
                ),
                child: Text('AI', style: type.label.copyWith(color: muted)),
              ),
              const Spacer(),
              if (available)
                Flexible(
                  child: ListenableBuilder(
                    listenable: access,
                    builder: (context, _) {
                      final now = DateTime.now();
                      final live = access
                          .connections(boxId)
                          .where((c) => !c.isExpired(now))
                          .length;
                      final problem = access.problem != null;
                      final text = problem
                          ? 'Connections unavailable'
                          : live == 0
                          ? 'No chats'
                          : live == 1
                          ? '1 chat'
                          : '$live chats';
                      return Tooltip(
                        message: 'Connections, approvals and activity',
                        child: InkWell(
                          key: const ValueKey('ai-box-connections'),
                          borderRadius: m.borderSm,
                          onTap: () => showAiConnectionsDialog(context, access, boxId),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: m.space1, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  problem ? Icons.error_outline_rounded : Icons.link_rounded,
                                  size: m.icon - 2,
                                  color: muted,
                                ),
                                if (!narrow) ...[
                                  SizedBox(width: m.space1),
                                  Flexible(
                                    child: Text(
                                      text,
                                      key: const ValueKey('ai-box-connections-text'),
                                      overflow: TextOverflow.ellipsis,
                                      style: type.small.copyWith(color: muted),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (showConnect) ...[
                SizedBox(width: m.space1),
                Tooltip(
                  message: available
                      ? 'Connect a chat'
                      : 'AI connections are not available here',
                  child: TextButton.icon(
                    key: const ValueKey('ai-box-connect'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 24),
                      padding: EdgeInsets.symmetric(horizontal: m.space2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: available
                        ? () => showAiConnectDialog(context, access, boxId)
                        : null,
                    icon: Icon(Icons.add_link_rounded, size: m.icon - 2),
                    label: narrow ? const SizedBox.shrink() : const Text('Connect a chat'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
