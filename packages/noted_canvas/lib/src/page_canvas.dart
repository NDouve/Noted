// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:noted_core/noted_core.dart';

import 'box_host.dart';
import 'box_scroll.dart';
import 'canvas_controller.dart';
import 'canvas_tool.dart';
import 'canvas_view.dart';
import 'geometry.dart';

/// Auto-pan during a tool session: the edge zone, in screen pixels.
const double autoPanEdge = 40;

/// Auto-pan speed (screen pixels per second) at the very edge, and the cap
/// once the pointer is far past it.
const double autoPanSpeedAtEdge = 600;
const double autoPanMaxSpeed = 3000;

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
///
/// With a module's canvas tool active (0033: the tool decides what input
/// does, not the device), every pointer except the middle button goes to
/// the tool and boxes receive none; wheel, Ctrl+wheel, middle-drag and the
/// touchpad still pan and zoom.
class PageCanvas extends StatefulWidget {
  const PageCanvas({super.key, required this.controller, this.tools});

  final CanvasController controller;

  /// The clipped overlay that shows a tool session's live feedback.
  static const Key overlayKey = ValueKey('PageCanvas.toolOverlay');

  /// The active tool, shared across pages. If null the canvas keeps its own.
  final CanvasToolSelection? tools;

  @override
  State<PageCanvas> createState() => PageCanvasState();
}

class PageCanvasState extends State<PageCanvas>
    with SingleTickerProviderStateMixin
    implements ToolContext {
  final TransformationController _transform = TransformationController();
  final FocusNode _focus = FocusNode(debugLabel: 'PageCanvas');
  final CanvasToolSelection _ownTools = CanvasToolSelection();
  final _OverlayRepaint _overlay = _OverlayRepaint();

  /// Pointer events per tool session, for the debug readout.
  final ValueNotifier<_InputStats?> _stats = ValueNotifier(null);

  CanvasView? _view;
  CanvasGeometry? _geometry;
  Rect? _content;
  int? _middlePointer;
  double _panZoomScale = 1;
  ToolSession? _session;
  int? _sessionPointer;
  PointerEvent? _lastToolEvent;
  Duration _sampleTime = Duration.zero;

  /// Everything the view has shown during the current tool session; pan
  /// bounds include it, so auto-pan can reach new space.
  Rect? _sessionArea;
  Ticker? _autoPan;
  Duration _lastTick = Duration.zero;

  CanvasController get _c => widget.controller;
  CanvasToolSelection get _tools => widget.tools ?? _ownTools;

  /// The current view, for tests and the app shell.
  CanvasView? get view => _view;

  /// The running tool session, for tests.
  ToolSession? get toolSession => _session;

  @override
  CanvasController get controller => _c;

  @override
  double get scale => _view?.scale ?? 1;

  @override
  void repaintOverlay() => _overlay.repaint();

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _tools.addListener(_toolChanged);
  }

  @override
  void didUpdateWidget(PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _cancelSession();
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _view = null;
    }
    if (oldWidget.tools != widget.tools) {
      (oldWidget.tools ?? _ownTools).removeListener(_toolChanged);
      _tools.addListener(_toolChanged);
    }
  }

  @override
  void dispose() {
    _cancelSession();
    _autoPan?.dispose();
    _c.removeListener(_changed);
    _tools.removeListener(_toolChanged);
    _transform.dispose();
    _focus.dispose();
    _ownTools.dispose();
    _overlay.dispose();
    _stats.dispose();
    super.dispose();
  }

  void _toolChanged() {
    _cancelSession();
    // Picking a tool ends text editing.
    if (_tools.active != null) _focus.requestFocus();
    setState(() {});
  }

  ToolPointer _toolPointer(PointerEvent e) => ToolPointer(
    position: _view!.toWorld(e.localPosition),
    kind: e.kind,
    time: e.timeStamp,
    pressure:
        e.kind == PointerDeviceKind.mouse || e.pressureMax <= e.pressureMin
        ? null
        : ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
              .clamp(0.0, 1.0),
  );

  void _toolDown(PointerDownEvent e) {
    final tool = _tools.active;
    if (tool == null || _session != null || _view == null) return;
    final usable = e.kind == PointerDeviceKind.mouse
        ? e.buttons & kPrimaryButton != 0
        : e.buttons & kMiddleMouseButton == 0;
    if (!usable) return;
    final session = tool.start(this, _toolPointer(e));
    if (session == null) return;
    _c.beginToolSession();
    _session = session;
    _sessionPointer = e.pointer;
    _lastToolEvent = e;
    _sampleTime = e.timeStamp;
    _sessionArea = _view!.visible(_geometry!.viewport);
    _stats.value = _InputStats.start(e.timeStamp);
    _updateAutoPan();
    _overlay.repaint();
  }

  void _toolMove(PointerMoveEvent e) {
    if (e.pointer != _sessionPointer) return;
    _lastToolEvent = e;
    if (e.timeStamp > _sampleTime) _sampleTime = e.timeStamp;
    _session!.update(_toolPointer(e));
    _stats.value = _stats.value?.add(e.timeStamp);
    _updateAutoPan();
  }

  void _toolUp(PointerUpEvent e) {
    if (e.pointer != _sessionPointer) return;
    final session = _session!;
    _endSession();
    // The session commits and the overlay clears in the same frame, so the
    // finished stroke never disappears for a frame.
    session.end();
    _c.endToolSession();
    _overlay.repaint();
  }

  void _cancelSession() {
    final session = _session;
    if (session == null) return;
    _endSession();
    session.cancel();
    _c.endToolSession();
    _overlay.repaint();
  }

  void _endSession() {
    _session = null;
    _sessionPointer = null;
    _lastToolEvent = null;
    _sessionArea = null;
    _autoPan?.stop();
  }

  /// Auto-scroll while a tool is in use, like a text selection in a document:
  /// with the pointer within [autoPanEdge] of the canvas edge, or past it,
  /// the canvas pans toward that edge, faster the further out the pointer
  /// is. Each tick also gives the session a sample at the pointer's screen
  /// position, so a stroke keeps following the pointer while it scrolls.
  void _updateAutoPan() {
    final e = _lastToolEvent;
    final g = _geometry;
    final moving =
        e != null &&
        g != null &&
        _autoPanVelocity(e.localPosition, g.viewport) != Offset.zero;
    final ticker = _autoPan ??= createTicker(_autoPanTick);
    if (moving && !ticker.isActive) {
      _lastTick = Duration.zero;
      ticker.start();
    } else if (!moving && ticker.isActive) {
      ticker.stop();
    }
  }

  /// Screen pixels per second to pan, per axis, toward the edges [local]
  /// is near or past.
  static Offset _autoPanVelocity(Offset local, Size viewport) {
    double axis(double p, double extent) {
      if (p < autoPanEdge) return -_autoPanSpeed(autoPanEdge - p);
      if (p > extent - autoPanEdge) {
        return _autoPanSpeed(p - (extent - autoPanEdge));
      }
      return 0;
    }

    return Offset(
      axis(local.dx, viewport.width),
      axis(local.dy, viewport.height),
    );
  }

  /// Speed for a pointer [depth] pixels into the edge zone (more than
  /// [autoPanEdge] once it is past the edge).
  static double _autoPanSpeed(double depth) =>
      (depth / autoPanEdge * autoPanSpeedAtEdge)
          .clamp(0, autoPanMaxSpeed)
          .toDouble();

  void _autoPanTick(Duration elapsed) {
    final e = _lastToolEvent;
    final session = _session;
    final view = _view;
    final g = _geometry;
    if (e == null || session == null || view == null || g == null) {
      _autoPan?.stop();
      return;
    }
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    final v = _autoPanVelocity(e.localPosition, g.viewport);
    if (v == Offset.zero) {
      _autoPan?.stop();
      return;
    }
    final seconds = dt.inMicroseconds / 1e6;
    // Moving the view toward an edge shows what lies beyond it. Pan bounds
    // grow with everything shown during the session, so the stroke can go
    // into new space; the build won't clamp the view back.
    final next = CanvasView(view.scale, view.offset - v * seconds);
    _sessionArea = _sessionArea!.expandToInclude(next.visible(g.viewport));
    _sampleTime += dt;
    setState(() => _view = next);
    session.update(
      ToolPointer(
        position: next.toWorld(e.localPosition),
        kind: e.kind,
        time: _sampleTime,
        pressure: _toolPointer(e).pressure,
      ),
    );
    _overlay.repaint();
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

  void zoomBy(double factor) =>
      _setView((g, v) => g.zoomAt(v, g.viewport.center(Offset.zero), factor));

  void zoomTo(double scale) => zoomBy(scale / (_view?.scale ?? 1));

  void _onSignal(PointerSignalEvent event) {
    // Registering lets a scrollable box claim the wheel first.
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      if (e is PointerScrollEvent) {
        if (HardwareKeyboard.instance.isControlPressed) {
          _setView(
            (g, v) =>
                g.zoomAt(v, e.localPosition, math.exp(-e.scrollDelta.dy / 300)),
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
    if (v == null || _tools.active != null) return;
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

    if (ctrl &&
        (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd)) {
      zoomBy(1.25);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (k == LogicalKeyboardKey.minus ||
            k == LogicalKeyboardKey.numpadSubtract)) {
      zoomBy(1 / 1.25);
      return KeyEventResult.handled;
    }
    if (ctrl &&
        (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0)) {
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
      // First Escape leaves the tool, the next clears the selection.
      _tools.active != null ? _tools.select(null) : _c.select(null);
      return KeyEventResult.handled;
    }
    if (!ctrl && k == LogicalKeyboardKey.keyV) {
      _tools.select(null);
      return KeyEventResult.handled;
    }
    if (!ctrl) {
      for (final tool in _c.modules.tools) {
        if (tool.shortcut == k) {
          _tools.select(tool);
          return KeyEventResult.handled;
        }
      }
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
          final area = _sessionArea;
          final g = CanvasGeometry.compute(
            content: area == null
                ? content
                : (content?.expandToInclude(area) ?? area),
            viewport: size,
          );
          _geometry = g;
          final view = g.clamp(_view ?? g.initial(content));
          _view = view;
          final matrix = g.matrixFor(view);
          if (_transform.value != matrix) _transform.value = matrix;

          final tool = _tools.active;
          return Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerSignal: _onSignal,
                  onPointerDown: (e) {
                    if (e.buttons & kMiddleMouseButton != 0) {
                      _middlePointer = e.pointer;
                    } else {
                      _toolDown(e);
                    }
                  },
                  onPointerMove: (e) {
                    if (e.pointer == _middlePointer) {
                      _setView((g, v) => g.pan(v, e.delta));
                    } else {
                      _toolMove(e);
                    }
                  },
                  onPointerUp: (e) {
                    if (e.pointer == _middlePointer) _middlePointer = null;
                    _toolUp(e);
                  },
                  onPointerCancel: (e) {
                    if (e.pointer == _middlePointer) _middlePointer = null;
                    if (e.pointer == _sessionPointer) _cancelSession();
                  },
                  onPointerPanZoomStart: (_) => _panZoomScale = 1,
                  onPointerPanZoomUpdate: (e) {
                    final factor = e.scale / _panZoomScale;
                    _panZoomScale = e.scale;
                    // A box that scrolls has claimed this gesture's panning
                    // (BoxScrollScope); a pinch still zooms the canvas.
                    final pans = !TrackpadClaims.isClaimed(e.pointer);
                    _setView((g, v) {
                      final panned = pans ? g.pan(v, e.panDelta) : v;
                      return factor == 1
                          ? panned
                          : g.zoomAt(panned, e.localPosition, factor);
                    });
                  },
                  onPointerPanZoomEnd: (e) => TrackpadClaims.release(e.pointer),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _onBackgroundTap,
                    child: MouseRegion(
                      cursor: tool?.cursor ?? MouseCursor.defer,
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
                            // With a tool active, input goes to the tool only.
                            child: IgnorePointer(
                              ignoring: tool != null,
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
                ),
              ),
              // The tool session's live feedback, in page coordinates, above
              // every box (0016: the stroke in progress is on a top overlay).
              Positioned.fill(
                child: IgnorePointer(
                  // Clipped to the canvas: ink in progress never paints
                  // over the sidebar or other UI.
                  child: ClipRect(
                    key: PageCanvas.overlayKey,
                    child: CustomPaint(
                      painter: _ToolOverlayPainter(this, _overlay),
                    ),
                  ),
                ),
              ),
              if (_c.modules.tools.isNotEmpty)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _ToolBar(
                    tools: _c.modules.tools,
                    active: tool,
                    onSelect: _tools.select,
                  ),
                ),
              if (kDebugMode)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _InputReadout(stats: _stats),
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

class _OverlayRepaint extends ChangeNotifier {
  void repaint() => notifyListeners();
}

/// Paints the running tool session in page coordinates.
class _ToolOverlayPainter extends CustomPainter {
  _ToolOverlayPainter(this._canvas, Listenable repaint)
    : super(repaint: repaint);

  final PageCanvasState _canvas;

  @override
  void paint(Canvas canvas, Size size) {
    final session = _canvas._session;
    final view = _canvas._view;
    if (session == null || view == null) return;
    canvas.save();
    canvas.translate(view.offset.dx, view.offset.dy);
    canvas.scale(view.scale);
    session.paint(canvas, view.scale);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ToolOverlayPainter oldDelegate) => true;
}

/// Pointer events received during the latest tool session.
@immutable
final class _InputStats {
  const _InputStats(this.points, this.first, this.last);

  const _InputStats.start(Duration t) : this(1, t, t);

  final int points;
  final Duration first;
  final Duration last;

  _InputStats add(Duration t) => _InputStats(points + 1, first, t);

  @override
  String toString() {
    final seconds = (last - first).inMicroseconds / 1e6;
    final rate = seconds > 0 ? (points - 1) / seconds : 0;
    return 'Input: ${rate.round()} pts/s · $points pts · ${seconds.toStringAsFixed(2)} s';
  }
}

/// Debug builds only: how many pointer events the last stroke received, to
/// check that no input is lost on the device being tested.
class _InputReadout extends StatelessWidget {
  const _InputReadout({required this.stats});

  final ValueListenable<_InputStats?> stats;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_InputStats?>(
    valueListenable: stats,
    builder: (context, s, _) => s == null
        ? const SizedBox.shrink()
        : DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                s.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
  );
}

/// Select/type plus the modules' tools, and the active tool's options.
class _ToolBar extends StatelessWidget {
  const _ToolBar({
    required this.tools,
    required this.active,
    required this.onSelect,
  });

  final List<CanvasTool> tools;
  final CanvasTool? active;
  final ValueChanged<CanvasTool?> onSelect;

  @override
  Widget build(BuildContext context) {
    final options = active?.buildOptions(context);
    Widget button(CanvasTool? tool, IconData icon, String label) {
      final key = tool?.shortcut?.keyLabel ?? 'V';
      return IconButton(
        isSelected: identical(active, tool),
        tooltip: '$label ($key)',
        icon: Icon(icon),
        onPressed: () => onSelect(tool),
      );
    }

    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(null, Icons.text_fields, 'Select and type'),
            for (final t in tools) button(t, t.icon, t.label),
            if (options != null) ...[
              const SizedBox(height: 32, child: VerticalDivider(width: 12)),
              options,
            ],
          ],
        ),
      ),
    );
  }
}
