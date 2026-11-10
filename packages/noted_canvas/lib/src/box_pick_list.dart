// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'box_host.dart';
import 'geometry.dart';
import 'canvas_controller.dart';
import 'noted_colors.dart';
import 'noted_menu.dart';
import 'noted_theme.dart';

/// The area of a box that takes clicks: its bounds with the grip above it and
/// the resize handles around it.
Rect boxHitRect(Rect b) => Rect.fromLTRB(
  b.left - boxHandleSize,
  b.top - boxGripHeight,
  b.right + boxHandleSize,
  b.bottom + boxHandleSize,
);

/// The ids of the nodes whose hit rect contains [world], topmost first.
List<String> nodesAtPoint(NotedPage page, Offset world) => [
  for (final n in page.nodes.reversed)
    if (n.bounds != null && boxHitRect(n.bounds!.rect).contains(world)) n.id,
];

/// The most characters of a box's words a row shows.
const int pickRowWords = 60;

/// The row text for [node]: `<Type> · <first words>`. The words are the
/// node's saved snapshot text (a foreign node's `text`) folded to one line,
/// never the box's data. An encrypted box shows its type only (invariant 3).
/// [typeName] gives a known box type's name; [known] says whether a module
/// is registered for the node's type.
String pickRowLabel(
  CanvasNode node, {
  required String? Function(String typeId) typeName,
  required bool known,
}) {
  final String type;
  final String? text;
  switch (node) {
    case BoxRecord():
      if (isEncryptedBox(node)) return 'Encrypted box';
      type = typeName(node.typeId) ?? (known ? 'Box' : 'Unsupported box');
      text = node.snapshotText;
    case ForeignNode():
      type = 'Not a Noted box';
      text = node.text;
  }
  var words = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (words.length > pickRowWords) words = '${words.substring(0, pickRowWords).trimRight()}…';
  return words.isEmpty ? type : '$type · $words';
}

/// Opens the list of the boxes under the page point [world], topmost first,
/// anchored at the screen point [anchor] and kept inside [within] (both
/// global). [highlight] holds the id of the row being pointed at, for the
/// canvas to outline. Completes with the id of the box chosen, or null if
/// the list was closed.
Future<String?> showBoxPickList(
  BuildContext context, {
  required CanvasController controller,
  required Offset world,
  required Offset anchor,
  required Rect within,
  required ValueNotifier<String?> highlight,
  required ValueListenable<bool> closeSignal,
  required String Function(CanvasNode node) label,
}) {
  return Navigator.of(context).push<String>(
    _PickRoute(
      canvas: controller,
      world: world,
      anchor: anchor,
      within: within,
      highlight: highlight,
      closeSignal: closeSignal,
      label: label,
    ),
  );
}

class _PickRoute extends PopupRoute<String> {
  _PickRoute({
    required this.canvas,
    required this.world,
    required this.anchor,
    required this.within,
    required this.highlight,
    required this.closeSignal,
    required this.label,
  });

  final CanvasController canvas;
  final Offset world;
  final Offset anchor;
  final Rect within;
  final ValueNotifier<String?> highlight;
  final ValueListenable<bool> closeSignal;
  final String Function(CanvasNode node) label;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close the list of boxes';
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> b) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: 'Boxes here',
      child: CustomSingleChildLayout(
        delegate: _PickLayout(anchor, within),
        child: _PickPanel(
          controller: canvas,
          world: world,
          highlight: highlight,
          closeSignal: closeSignal,
          label: label,
          maxHeight: math.max(120, within.height - 16),
        ),
      ),
    );
  }
}

class _PickLayout extends SingleChildLayoutDelegate {
  const _PickLayout(this.anchor, this.within);

  final Offset anchor;
  final Rect within;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(math.min(constraints.maxWidth, within.width), constraints.maxHeight));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double clamp(double v, double lo, double hi) => hi < lo ? lo : v.clamp(lo, hi).toDouble();
    return Offset(
      clamp(anchor.dx, within.left + 8, within.right - childSize.width - 8),
      clamp(anchor.dy, within.top + 8, within.bottom - childSize.height - 8),
    );
  }

  @override
  bool shouldRelayout(_PickLayout old) => old.anchor != anchor || old.within != within;
}

class _PickPanel extends StatefulWidget {
  const _PickPanel({
    required this.controller,
    required this.world,
    required this.highlight,
    required this.closeSignal,
    required this.label,
    required this.maxHeight,
  });

  final CanvasController controller;
  final Offset world;
  final ValueNotifier<String?> highlight;
  final ValueListenable<bool> closeSignal;
  final String Function(CanvasNode node) label;
  final double maxHeight;

  @override
  State<_PickPanel> createState() => _PickPanelState();
}

class _PickPanelState extends State<_PickPanel> {
  final FocusNode _focus = FocusNode(debugLabel: 'BoxPickList');
  bool _closing = false;

  /// The canvas asked for the list to close (its controller or page went
  /// away): nothing here acts on the controller or the highlight any more.
  bool _gone = false;

  CanvasController get _c => widget.controller;
  List<String> get _rows => nodesAtPoint(_c.page, widget.world);

  @override
  void initState() {
    super.initState();
    widget.closeSignal.addListener(_onSignal);
    if (widget.closeSignal.value) _onSignal();
  }

  void _onSignal() {
    if (!widget.closeSignal.value || _gone) return;
    _gone = true;
    // Not while the canvas is being taken down or rebuilt.
    WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    widget.closeSignal.removeListener(_onSignal);
    _focus.dispose();
    super.dispose();
  }

  void _close([String? id]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop<String>(id);
  }

  void _move(List<String> rows, int Function(int? current) to) {
    if (rows.isEmpty) return;
    final at = rows.indexOf(widget.highlight.value ?? '');
    widget.highlight.value = rows[to(at < 0 ? null : at).clamp(0, rows.length - 1)];
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || _gone) return KeyEventResult.ignored;
    final rows = _rows;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _move(rows, (i) => i == null ? 0 : i + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(rows, (i) => i == null ? rows.length - 1 : i - 1);
    } else if (key == LogicalKeyboardKey.home) {
      _move(rows, (_) => 0);
    } else if (key == LogicalKeyboardKey.end) {
      _move(rows, (_) => rows.length - 1);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      // A row's button has its own Enter.
      final id = widget.highlight.value;
      if (FocusManager.instance.primaryFocus != node || id == null || !rows.contains(id)) {
        return KeyEventResult.ignored;
      }
      _close(id);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _tap(String id, PointerDeviceKind kind) {
    if (_gone) return;
    // A finger first points at a row, then chooses it (there is no hover).
    if (kind != PointerDeviceKind.mouse && widget.highlight.value != id) {
      widget.highlight.value = id;
      return;
    }
    _close(id);
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: Listenable.merge([_c, widget.highlight]),
        builder: (context, _) {
          final rows = _rows;
          // A merge can take the last box away: nothing is left to pick.
          if (rows.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _close());
          }
          final lit = widget.highlight.value;
          if (lit != null && !rows.contains(lit)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_gone && widget.highlight.value == lit) widget.highlight.value = null;
            });
          }
          return ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: notedMenuMinWidth,
              maxWidth: 360,
              maxHeight: widget.maxHeight,
            ),
            child: DecoratedBox(
              key: const ValueKey('box-pick-list'),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border.all(color: scheme.outline),
                borderRadius: m.borderLg,
                boxShadow: m.shadowPopover,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Padding(
                  padding: EdgeInsets.all(m.space1),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final id in rows) _row(context, id),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, String id) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final type = NotedTypography.of(context);
    final node = _c.page.node(id);
    if (node == null) return const SizedBox.shrink();
    final lit = widget.highlight.value == id;
    // A node without an id of its own cannot be restacked: no buttons.
    final buttons = hasOwnId(node);
    Widget button(StackMove move, String tooltip, IconData icon, String key) {
      final on = !_gone && _c.canRestack(id, move);
      return Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) {
          if (f) widget.highlight.value = id;
        },
        child: IconButton(
          key: ValueKey('pick-$key-$id'),
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          iconSize: m.icon,
          constraints: BoxConstraints.tightFor(width: m.rowSize - 8, height: m.rowSize - 8),
          padding: EdgeInsets.zero,
          icon: Icon(icon),
          onPressed: on ? () => _c.restack(id, move) : null,
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => widget.highlight.value = id,
      child: GestureDetector(
        key: ValueKey('pick-row-$id'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _tap(id, d.kind),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: lit ? colors.surfaceHover : Colors.transparent,
            borderRadius: m.borderMd,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: m.rowSize),
            child: Padding(
              padding: EdgeInsets.only(left: 10, right: m.space1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label(node),
                      style: type.body.copyWith(color: Theme.of(context).colorScheme.onSurface),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  if (buttons) ...[
                    SizedBox(width: m.space2),
                    button(StackMove.front, 'Bring to front', Icons.flip_to_front_rounded, 'front'),
                    button(StackMove.back, 'Send to back', Icons.flip_to_back_rounded, 'back'),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
