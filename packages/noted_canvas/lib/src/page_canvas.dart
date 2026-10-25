// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'box_host.dart';
import 'canvas_controller.dart';
import 'canvas_view.dart';
import 'geometry.dart';

/// A page's freeform canvas (0002, 0003).
///
/// Built on [InteractiveViewer] for the transform, with its own pan and zoom
/// gestures switched off. All view changes go through [CanvasGeometry], so
/// pan bounds and zoom limits are enforced in one place. Input, with the
/// select/type tool (0033):
/// - click empty canvas: new note box (0015)
/// - wheel: scroll; Shift+wheel: scroll sideways; Ctrl+wheel: zoom
/// - middle-drag or two-finger touchpad: pan; pinch: zoom
/// - drag a box's grip to move it, its edges to resize it
class PageCanvas extends StatefulWidget {
  const PageCanvas({super.key, required this.controller});

  final CanvasController controller;

  @override
  State<PageCanvas> createState() => PageCanvasState();
}

class PageCanvasState extends State<PageCanvas> {
  final TransformationController _transform = TransformationController();
  final FocusNode _focus = FocusNode(debugLabel: 'PageCanvas');

  CanvasView? _view;
  CanvasGeometry? _geometry;
  Rect? _content;
  int? _middlePointer;
  double _panZoomScale = 1;

  CanvasController get _c => widget.controller;

  /// The current view, for tests and the app shell.
  CanvasView? get view => _view;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void didUpdateWidget(PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _view = null;
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _transform.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  /// Page bounds follow the content, except during a drag or resize: they
  /// update when the gesture ends, never under the pointer (0016).
  Rect? _contentRect() {
    if (!_c.isInteracting) _content = _c.page.contentBounds?.rect;
    return _content;
  }

  void _setView(CanvasView Function(CanvasGeometry g, CanvasView v) f) {
    final g = _geometry;
    final v = _view;
    if (g == null || v == null) return;
    setState(() => _view = f(g, v));
  }

  void fitAll() => _setView((g, _) => g.fitAll(_content));

  void zoomBy(double factor) => _setView(
    (g, v) => g.zoomAt(v, g.viewport.center(Offset.zero), factor),
  );

  void zoomTo(double scale) => zoomBy(scale / (_view?.scale ?? 1));

  void _onSignal(PointerSignalEvent event) {
    // Registering lets a scrollable box claim the wheel first.
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is PointerScrollEvent) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _setView(
            (g, v) => g.zoomAt(v, e.localPosition, math.exp(-e.scrollDelta.dy / 300)),
          );
        } else {
          var d = e.scrollDelta;
          if (HardwareKeyboard.instance.isShiftPressed && d.dx == 0) {
            d = Offset(d.dy, 0);
          }
          _setView((g, v) => g.pan(v, -d));
        }
      } else if (e is PointerScaleEvent) {
        _setView((g, v) => g.zoomAt(v, e.localPosition, e.scale));
      }
    });
  }

  void _onBackgroundTap(TapUpDetails d) {
    final v = _view;
    if (v == null) return;
    final world = v.toWorld(d.localPosition);
    // A click that lands on a box's chrome or snapshot isn't a canvas click.
    for (final n in _c.page.nodes) {
      final b = n.bounds?.rect;
      if (b == null) continue;
      final hit = Rect.fromLTRB(
        b.left - boxHandleSize,
        b.top - boxGripHeight,
        b.right + boxHandleSize,
        b.bottom + boxHandleSize,
      );
      if (hit.contains(world)) return;
    }
    // Place the box so the caret lands near the click.
    _c.createBoxAt(Bounds(world.dx - 10, world.dy - 14, 0, 0));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (ctrl && (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd)) {
      zoomBy(1.25);
      return KeyEventResult.handled;
    }
    if (ctrl && (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract)) {
      zoomBy(1 / 1.25);
      return KeyEventResult.handled;
    }
    if (ctrl && (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0)) {
      zoomTo(1);
      return KeyEventResult.handled;
    }

    // Keys bubble up from a focused editor; leave its keys to it.
    if (_c.editingId != null) {
      if (k == LogicalKeyboardKey.escape) {
        _focus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      final id = _c.selectedId;
      if (id == null) return KeyEventResult.ignored;
      _c.delete(id);
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      shift ? _c.redo() : _c.undo();
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyY) {
      _c.redo();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _c.select(null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final content = _contentRect();
          final g = CanvasGeometry.compute(content: content, viewport: size);
          _geometry = g;
          final view = g.clamp(_view ?? g.initial(content));
          _view = view;
          final matrix = g.matrixFor(view);
          if (_transform.value != matrix) _transform.value = matrix;

          return Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerSignal: _onSignal,
                  onPointerDown: (e) {
                    if (e.buttons & kMiddleMouseButton != 0) _middlePointer = e.pointer;
                  },
                  onPointerMove: (e) {
                    if (e.pointer == _middlePointer) {
                      _setView((g, v) => g.pan(v, e.delta));
                    }
                  },
                  onPointerUp: (e) {
                    if (e.pointer == _middlePointer) _middlePointer = null;
                  },
                  onPointerCancel: (e) {
                    if (e.pointer == _middlePointer) _middlePointer = null;
                  },
                  onPointerPanZoomStart: (_) => _panZoomScale = 1,
                  onPointerPanZoomUpdate: (e) {
                    final factor = e.scale / _panZoomScale;
                    _panZoomScale = e.scale;
                    _setView((g, v) {
                      final panned = g.pan(v, e.panDelta);
                      return factor == 1 ? panned : g.zoomAt(panned, e.localPosition, factor);
                    });
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _onBackgroundTap,
                    child: ColoredBox(
                      color: scheme.surface,
                      child: InteractiveViewer(
                        transformationController: _transform,
                        constrained: false,
                        panEnabled: false,
                        scaleEnabled: false,
                        boundaryMargin: g.boundaryMargin,
                        minScale: g.minScale,
                        maxScale: g.maxScale,
                        child: SizedBox(
                          width: g.child.width,
                          height: g.child.height,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              for (final node in _c.page.nodes)
                                BoxHost(
                                  key: ValueKey(node.id),
                                  node: node,
                                  controller: _c,
                                  childOrigin: g.child.topLeft,
                                  scale: view.scale,
                                  onGripTap: _focus.requestFocus,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: _ZoomBar(
                  scale: view.scale,
                  onZoomIn: () => zoomBy(1.25),
                  onZoomOut: () => zoomBy(1 / 1.25),
                  onReset: () => zoomTo(1),
                  onFitAll: fitAll,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ZoomBar extends StatelessWidget {
  const _ZoomBar({
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.onFitAll,
  });

  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onFitAll;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Zoom out (Ctrl+-)',
              icon: const Icon(Icons.remove),
              onPressed: onZoomOut,
            ),
            TextButton(
              onPressed: onReset,
              child: Text('${(scale * 100).round()}%'),
            ),
            IconButton(
              tooltip: 'Zoom in (Ctrl+=)',
              icon: const Icon(Icons.add),
              onPressed: onZoomIn,
            ),
            TextButton.icon(
              onPressed: onFitAll,
              icon: const Icon(Icons.fit_screen),
              label: const Text('Fit all'),
            ),
          ],
        ),
      ),
    );
  }
}
