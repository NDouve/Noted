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
import 'geometry.dart';

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
    required this.scale,
    required this.onGripTap,
  });

  final CanvasNode node;
  final CanvasController controller;

  /// World position of the canvas child's top-left corner.
  final Offset childOrigin;

  /// Current zoom, to turn pointer movement into page distance.
  final double scale;

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
    final node = widget.node;
    final b = node.bounds;
    if (b == null) return const Positioned(left: 0, top: 0, child: SizedBox.shrink());

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
    final editable = module != null && live != null;
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
            readOnly: false,
            autoHeight: c.isAutoHeight(node as BoxRecord),
            autofocus: _autofocus,
            commit: (data) => _commit(node.id, liveBox.codec, data),
            requestBounds: (r) => _requestBounds(node.id, r),
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
    final showChrome = editable && (_hover || selected || editing);

    return Positioned(
      left: b.x - widget.childOrigin.dx - m,
      top: b.y - widget.childOrigin.dy - boxGripHeight,
      width: b.width + 2 * m,
      height: b.height + boxGripHeight + m,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: m,
              top: boxGripHeight,
              width: b.width,
              height: b.height,
              child: ClipRect(child: content),
            ),
            if (showChrome)
              Positioned(
                left: m,
                top: boxGripHeight,
                width: b.width,
                height: b.height,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: selected || editing
                            ? scheme.primary
                            : scheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
              ),
            if (editable) ...[
              Positioned(
                left: m,
                top: 0,
                width: b.width,
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
                    child: showChrome
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: (selected || editing
                                      ? scheme.primary
                                      : scheme.outlineVariant)
                                  .withValues(alpha: 0.35),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
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
            ],
          ],
        ),
      ),
    );
  }

  Widget _handle(_Edge edge, Bounds b) {
    const s = boxHandleSize;
    final w = b.width + s;
    final h = b.height + s / 2;
    final top = boxGripHeight;
    final (Rect r, MouseCursor cursor) = switch (edge) {
      _Edge.left => (Rect.fromLTWH(0, top, s, b.height), SystemMouseCursors.resizeLeftRight),
      _Edge.right => (Rect.fromLTWH(w - s, top, s, b.height), SystemMouseCursors.resizeLeftRight),
      _Edge.bottom => (Rect.fromLTWH(s, top + h - s, w - 2 * s, s), SystemMouseCursors.resizeUpDown),
      _Edge.bottomLeft => (Rect.fromLTWH(0, top + h - s, s, s), SystemMouseCursors.resizeDownLeft),
      _Edge.bottomRight => (Rect.fromLTWH(w - s, top + h - s, s, s), SystemMouseCursors.resizeDownRight),
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
    final d = (global - start) / widget.scale;
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
    widget.controller.updateGesture(widget.node.id, next, setsHeight: setsHeight);
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
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }
}

/// A box shown from its saved snapshot because this device can't run it.
class UnsupportedBoxView extends StatelessWidget {
  const UnsupportedBoxView({super.key, required this.text, required this.label});

  final String text;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
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
            const SizedBox(height: 4),
            Expanded(
              child: Text(text, overflow: TextOverflow.fade, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}
