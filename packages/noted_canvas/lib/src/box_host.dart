// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:noted_core/noted_core.dart';

import 'box_module.dart';
import 'canvas_controller.dart';
import 'conflict_dialog.dart';
import 'geometry.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';
import 'page_find.dart';

/// Width of the resize strip on each edge, centred on the edge.
const double boxHandleSize = 10;

/// Height of the drag grip above a box.
const double boxGripHeight = 14;

enum _Edge { left, right, bottom, bottomLeft, bottomRight }

/// One node on the canvas: its frame, drag grip and resize handles around
/// either its module's widget or, for a box this device can't run, its
/// read-only snapshot (0035).
class BoxHost extends StatefulWidget {
  const BoxHost({
    super.key,
    required this.node,
    required this.controller,
    required this.childOrigin,
    required this.scaleOf,
    required this.onGripTap,
    this.readOnly = false,
    this.find,
  });

  final CanvasNode node;
  final CanvasController controller;

  /// Show every box with its module's read-only view and without grip,
  /// handles or conflict badge.
  final bool readOnly;

  /// Find on page: the boxes with a match are framed, and the module is told
  /// what is being looked for (Box API 0.6).
  final PageFind? find;

  /// World position of the canvas child's top-left corner.
  final Offset childOrigin;

  /// Current zoom, read when it is needed (to turn pointer movement into
  /// page distance), so that zooming does not rebuild every box.
  final ValueGetter<double> scaleOf;

  /// Called when the grip is clicked, so the canvas can take focus.
  final VoidCallback onGripTap;

  @override
  State<BoxHost> createState() => _BoxHostState();
}

class _BoxHostState extends State<BoxHost> {
  bool _hover = false;
  bool _autofocus = false;

  // Decoded data, cached by the identity of the raw data it came from. After
  // a commit the module's own object is cached, so it gets it back unchanged.
  RawJson? _decodedFrom;
  BoxResolution? _resolution;

  Offset? _gestureStart;
  Bounds? _gestureBounds;

  @override
  void initState() {
    super.initState();
    _autofocus = widget.controller.takeAutofocus(widget.node.id);
  }

  BoxResolution _resolve(BoxRecord box) {
    final raw = box.data;
    if (_resolution == null || !identical(raw, _decodedFrom)) {
      _resolution = widget.controller.modules.codecs.resolve(box);
      _decodedFrom = raw;
    }
    return _resolution!;
  }

  @override
  Widget build(BuildContext context) {
    // The page's current node, not the one this widget was built with: a
    // content commit doesn't rebuild the canvas, so a rebuild for another
    // reason (hover, a menu opening) must not hand the module older data.
    final node = widget.controller.page.node(widget.node.id) ?? widget.node;
    final b = node.bounds;
    if (b == null) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final c = widget.controller;
    BoxModule<Object?>? module;
    LiveBox? live;
    if (node is BoxRecord) {
      final r = _resolve(node);
      if (r is LiveBox) {
        live = r;
        module = c.modules.moduleFor(node.typeId);
      }
    }
    final readOnly = widget.readOnly || c.readOnly;
    final editable = module != null && live != null && !readOnly;
    final liveBox = live;
    final selected = c.selectedId == node.id;
    final editing = c.editingId == node.id;
    const m = boxHandleSize / 2;

    Widget content;
    if (module != null && liveBox != null) {
      content = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (focused) _autofocus = false;
          c.setEditing(node.id, focused);
        },
        child: module.hostBuild(
          context,
          BoxBinding(
            boxId: node.id,
            data: liveBox.data,
            bounds: b.rect,
            readOnly: readOnly,
            autoHeight: c.isAutoHeight(node as BoxRecord),
            autofocus: _autofocus,
            commit: (data) => _commit(node.id, liveBox.codec, data),
            requestBounds: (r) => _requestBounds(node.id, r),
            find: widget.find?.boxFind,
          ),
        ),
      );
    } else {
      content = UnsupportedBoxView(
        text: switch (node) {
          BoxRecord() => node.snapshotText,
          ForeignNode() => node.text ?? '',
        },
        label: node is BoxRecord
            ? 'Editable on other devices'
            : 'Not a Noted box (${(node as ForeignNode).nodeType ?? 'unknown'})',
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final noted = NotedColors.of(context);
    final metrics = NotedMetrics.of(context);
    final type = NotedTypography.of(context);
    final conflicted = node is BoxRecord && node.isConflicted;
    final frameless = module?.frameStyle == BoxFrameStyle.framelessUntilSelected;
    final lit = selected || editing;
    final showGrip = editable && (_hover || lit);
    final w = b.width;
    final h = b.height;

    return Positioned(
      left: b.x - widget.childOrigin.dx - m,
      top: b.y - widget.childOrigin.dy - boxGripHeight,
      width: w + 2 * m,
      height: h + boxGripHeight + m,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The frame's fill, and the selection ring (shadow-selected).
            // A frameless box (drawing) has neither.
            if (!frameless)
              Positioned(
                left: m,
                top: boxGripHeight,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('box-frame-fill'),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: metrics.borderLg,
                      boxShadow: lit ? metrics.shadowSelected : null,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: m,
              top: boxGripHeight,
              width: w,
              height: h,
              child: ClipRRect(
                borderRadius: frameless
                    ? BorderRadius.zero
                    : BorderRadius.circular(metrics.radiusLg - 1),
                child: content,
              ),
            ),
            // The border: 1px border-box idle, 1px accent selected, 2px
            // conflict. A frameless box shows a dashed accent outline only
            // while selected.
            if (conflicted)
              Positioned(
                left: m,
                top: boxGripHeight,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('conflict-frame'),
                    decoration: BoxDecoration(
                      borderRadius: metrics.borderLg,
                      border: Border.fromBorderSide(
                        BorderSide(color: noted.conflict, width: 2),
                      ),
                    ),
                  ),
                ),
              )
            else if (frameless && lit)
              Positioned(
                left: m,
                top: boxGripHeight,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('box-frame-dashed'),
                    painter: DashedOutlinePainter(
                      color: scheme.primary,
                      radius: metrics.radiusLg,
                    ),
                  ),
                ),
              )
            else if (!frameless)
              Positioned(
                left: m,
                top: boxGripHeight,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('box-frame-border'),
                    decoration: BoxDecoration(
                      borderRadius: metrics.borderLg,
                      border: Border.all(
                        color: lit ? scheme.primary : scheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
            // Find on page: a frame around every box with a match, stronger
            // on the one that holds the current match.
            if (widget.find != null)
              Positioned(
                left: m,
                top: boxGripHeight,
                width: w,
                height: h,
                child: IgnorePointer(
                  child: ListenableBuilder(
                    listenable: widget.find!,
                    builder: (context, _) {
                      final f = widget.find!;
                      if (!f.isOpen || !f.matchedBoxIds.contains(node.id)) {
                        return const SizedBox.shrink();
                      }
                      final current = f.currentMatch?.boxId == node.id;
                      return DecoratedBox(
                        key: ValueKey(
                          current ? 'find-frame-current' : 'find-frame-match',
                        ),
                        decoration: BoxDecoration(
                          borderRadius: metrics.borderLg,
                          border: Border.all(
                            color: current
                                ? scheme.tertiary
                                : scheme.tertiary.withValues(alpha: 0.55),
                            width: current ? 3 : 1.5,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (editable) ...[
              Positioned(
                left: m,
                top: 0,
                width: w,
                height: boxGripHeight,
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onTap: () {
                      widget.onGripTap();
                      c.select(node.id);
                    },
                    onPanStart: (d) => _begin(d.globalPosition),
                    onPanUpdate: (d) => _update(d.globalPosition, null),
                    onPanEnd: (_) => _end(),
                    onPanCancel: _end,
                    child: showGrip
                        ? Center(
                            child: DecoratedBox(
                              key: const ValueKey('box-grip'),
                              decoration: BoxDecoration(
                                color: lit
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                                borderRadius: metrics.borderFull,
                              ),
                              child: SizedBox(
                                width: metrics.space6,
                                height: metrics.space1,
                              ),
                            ),
                          )
                        : const SizedBox.expand(),
                  ),
                ),
              ),
              _handle(_Edge.left, b),
              _handle(_Edge.right, b),
              _handle(_Edge.bottom, b),
              _handle(_Edge.bottomLeft, b),
              _handle(_Edge.bottomRight, b),
              if (lit) ..._handleSquares(b, scheme, metrics),
            ],
            if (conflicted && !readOnly)
              Positioned(
                right: m + metrics.space2,
                // Centered on the top edge of the frame.
                top: boxGripHeight - _badgeHeight / 2,
                height: _badgeHeight,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: ValueKey('conflict-badge-${node.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => showConflictDialog(context, c, node.id),
                    child: DecoratedBox(
                      key: const ValueKey('conflict-badge'),
                      decoration: BoxDecoration(
                        color: noted.conflict,
                        borderRadius: metrics.borderFull,
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: metrics.space2,
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            'Conflict',
                            style: type.small.copyWith(
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: noted.onConflict,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static const double _badgeHeight = 20;

  /// The visible resize handles: `handle` (8px) squares, `surface` fill and a
  /// 1px `accent` border, on the left, right and bottom edges and the bottom
  /// corners. They sit on the frame; the drag areas stay the larger invisible
  /// ones of [_handle].
  List<Widget> _handleSquares(Bounds b, ColorScheme scheme, NotedMetrics m) {
    final s = m.handle;
    final left = boxHandleSize / 2;
    final top = boxGripHeight;
    final spots = <String, Offset>{
      'left': Offset(left, top + b.height / 2),
      'right': Offset(left + b.width, top + b.height / 2),
      'bottom': Offset(left + b.width / 2, top + b.height),
      'bottomLeft': Offset(left, top + b.height),
      'bottomRight': Offset(left + b.width, top + b.height),
    };
    return [
      for (final e in spots.entries)
        Positioned(
          left: e.value.dx - s / 2,
          top: e.value.dy - s / 2,
          width: s,
          height: s,
          child: IgnorePointer(
            child: DecoratedBox(
              key: ValueKey('box-handle-${e.key}'),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border.all(color: scheme.primary),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _handle(_Edge edge, Bounds b) {
    const s = boxHandleSize;
    final w = b.width + s;
    final h = b.height + s / 2;
    final top = boxGripHeight;
    final (Rect r, MouseCursor cursor) = switch (edge) {
      _Edge.left => (
        Rect.fromLTWH(0, top, s, b.height),
        SystemMouseCursors.resizeLeftRight,
      ),
      _Edge.right => (
        Rect.fromLTWH(w - s, top, s, b.height),
        SystemMouseCursors.resizeLeftRight,
      ),
      _Edge.bottom => (
        Rect.fromLTWH(s, top + h - s, w - 2 * s, s),
        SystemMouseCursors.resizeUpDown,
      ),
      _Edge.bottomLeft => (
        Rect.fromLTWH(0, top + h - s, s, s),
        SystemMouseCursors.resizeDownLeft,
      ),
      _Edge.bottomRight => (
        Rect.fromLTWH(w - s, top + h - s, s, s),
        SystemMouseCursors.resizeDownRight,
      ),
    };
    return Positioned.fromRect(
      rect: r,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          // Double-clicking the bottom edge returns the box to growing with
          // its content.
          onDoubleTap: edge == _Edge.left || edge == _Edge.right
              ? null
              : () => widget.controller.setAutoHeight(widget.node.id),
          onPanStart: (d) => _begin(d.globalPosition),
          onPanUpdate: (d) => _update(d.globalPosition, edge),
          onPanEnd: (_) => _end(),
          onPanCancel: _end,
        ),
      ),
    );
  }

  void _begin(Offset global) {
    final b = widget.node.bounds;
    if (b == null) return;
    _gestureStart = global;
    _gestureBounds = b;
    widget.controller.beginGesture(widget.node.id);
  }

  void _update(Offset global, _Edge? edge) {
    final start = _gestureStart;
    final sb = _gestureBounds;
    if (start == null || sb == null) return;
    final d = (global - start) / widget.scaleOf();
    final Bounds next;
    var setsHeight = false;
    if (edge == null) {
      next = Bounds(sb.x + d.dx, sb.y + d.dy, sb.width, sb.height);
    } else {
      var x = sb.x;
      var w = sb.width;
      var h = sb.height;
      if (edge == _Edge.left || edge == _Edge.bottomLeft) {
        final dx = math.min(d.dx, sb.width - minBoxWidth);
        x += dx;
        w -= dx;
      }
      if (edge == _Edge.right || edge == _Edge.bottomRight) {
        w = math.max(minBoxWidth, sb.width + d.dx);
      }
      if (edge == _Edge.bottom ||
          edge == _Edge.bottomLeft ||
          edge == _Edge.bottomRight) {
        h = math.max(minBoxHeight, sb.height + d.dy);
        setsHeight = h != sb.height;
      }
      next = Bounds(x, sb.y, w, h);
    }
    widget.controller.updateGesture(
      widget.node.id,
      next,
      setsHeight: setsHeight,
    );
  }

  void _end() {
    if (_gestureStart == null) return;
    _gestureStart = null;
    _gestureBounds = null;
    widget.controller.endGesture(widget.node.id);
  }

  void _commit(String id, BoxCodec<Object?> codec, Object? data) {
    final next = widget.controller.commit(id, data);
    if (next == null) return;
    _decodedFrom = next.data;
    _resolution = LiveBox(codec, data);
  }

  void _requestBounds(String id, Rect r) {
    void apply() {
      if (mounted) widget.controller.requestBounds(id, r.bounds);
    }

    // Never change the model in the middle of build, layout or paint.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }
}

/// Paints a 1px dashed outline with rounded corners around its box: the
/// selection outline of a frameless (drawing) box.
class DashedOutlinePainter extends CustomPainter {
  const DashedOutlinePainter({
    required this.color,
    required this.radius,
    this.dash = 4,
    this.gap = 3,
  });

  final Color color;
  final double radius;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ).deflate(0.5),
      );
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(DashedOutlinePainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.dash != dash ||
      old.gap != gap;
}

/// A box shown from its saved snapshot because this device can't run it.
class UnsupportedBoxView extends StatelessWidget {
  const UnsupportedBoxView({
    super.key,
    required this.text,
    required this.label,
  });

  final String text;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = NotedMetrics.of(context);
    return DecoratedBox(
      // The frame (fill and border) comes from the host.
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: Padding(
        padding: EdgeInsets.all(metrics.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: metrics.space1),
            Expanded(
              child: Text(
                text,
                overflow: TextOverflow.fade,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
