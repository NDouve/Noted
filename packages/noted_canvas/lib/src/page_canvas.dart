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
import 'canvas_commands.dart';
import 'canvas_controller.dart';
import 'canvas_tool.dart';
import 'canvas_view.dart';
import 'command_toolbar.dart';
import 'find_bar.dart';
import 'commands.dart';
import 'geometry.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';
import 'page_background.dart';
import 'page_find.dart';
import 'toolbar_layout.dart';

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
  const PageCanvas({
    super.key,
    required this.controller,
    this.tools,
    this.readOnly = false,
    this.toolbarLayout = defaultToolbarLayout,
    this.findRequests,
    this.extraCommands,
  });

  final CanvasController controller;

  /// Asks this canvas to open Find on page (for example from the results of
  /// a search of all pages). A request for another page is left alone; one
  /// for this page is taken (the notifier is set back to null).
  final ValueNotifier<FindRequest?>? findRequests;

  /// Commands the app adds to this canvas's registry, so they have shortcuts
  /// and can be placed on the toolbar (for example "Search all pages"). Called
  /// each time the registry is made; the registry owns and disposes them.
  final List<Command> Function()? extraCommands;

  /// Which commands the toolbar along the top shows, and in what order. It
  /// is built only from this canvas's [PageCanvasState.commands].
  final ToolbarLayout toolbarLayout;

  /// Show the page without any way to change it: boxes use their module's
  /// read-only view, with no grip, handles or editing; there is no toolbar
  /// and no tool, no box creation on click and no delete or undo keys. Panning
  /// and zooming still work. A controller that is itself read-only
  /// ([CanvasController.readOnly]) gets the same canvas.
  final bool readOnly;

  /// The clipped overlay that shows a tool session's live feedback.
  static const Key overlayKey = ValueKey('PageCanvas.toolOverlay');

  /// The active tool, shared across pages. If null the canvas keeps its own.
  final CanvasToolSelection? tools;

  @override
  State<PageCanvas> createState() => PageCanvasState();
}

class PageCanvasState extends State<PageCanvas>
    with SingleTickerProviderStateMixin
    implements ToolContext, CanvasCommandTarget {
  final TransformationController _transform = TransformationController();
  CommandRegistry _commands = CommandRegistry();

  /// The zoom the toolbar was last built with.
  double? _toolbarScale;
  final FocusNode _focus = FocusNode(debugLabel: 'PageCanvas');
  final CanvasToolSelection _ownTools = CanvasToolSelection();
  final _OverlayRepaint _overlay = _OverlayRepaint();

  /// Pointer events per tool session, for the debug readout.
  final ValueNotifier<_InputStats?> _stats = ValueNotifier(null);

  CanvasView? _view;
  CanvasGeometry? _geometry;
  Rect? _content;
  int? _middlePointer;
  // A touchpad pinch: the zoom the view had when it started, and the
  // two-finger pan applied so far (to move only by what is new).
  double _pinchStartScale = 1;
  Offset _pinchPan = Offset.zero;

  /// Where the mouse last was over the canvas, null when it is elsewhere.
  Offset? _hover;
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
  bool get _readOnly => widget.readOnly || _c.readOnly;
  CanvasToolSelection get _tools => widget.tools ?? _ownTools;

  @override
  CanvasToolSelection get tools => _tools;

  @override
  bool get isReadOnly => _readOnly;

  @override
  void focusCanvas() => _focus.requestFocus();

  /// Find on page for the open page (the find bar's model), for tests and
  /// the app shell.
  PageFind get find => _find;

  late PageFind _find;
  final FocusNode _findFocus = FocusNode(debugLabel: 'FindBar');

  @override
  bool get isFindOpen => _find.isOpen;

  @override
  void openFind() => _find.open();

  @override
  void closeFind() {
    final hadFocus = _findFocus.hasFocus;
    _find.close();
    if (hadFocus) _focus.requestFocus();
  }

  @override
  void stepFind(int delta) => _find.step(delta);

  PageFind _makeFind() =>
      PageFind(page: () => _c.page, onReveal: _revealBox);

  void _takeFindRequest() {
    final r = widget.findRequests?.value;
    if (r == null || r.pageId != _c.page.id) return;
    widget.findRequests!.value = null;
    // After the first layout, so the view can be moved.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _find.open(text: r.text, boxId: r.boxId, occurrence: r.occurrence);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// Brings the box [id] into view: scrolls to it, and zooms out only if it
  /// doesn't fit at the current zoom (never in, so never past where the
  /// user already is). Does nothing if it is already fully in view.
  void _revealBox(String id) {
    final g = _geometry;
    final v = _view;
    final rect = _c.page.node(id)?.bounds?.rect;
    if (rect == null) return;
    if (g == null || v == null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealBox(id);
      });
      return;
    }
    final target = rect.inflate(canvasChromePadding);
    final fit = math.min(
      g.viewport.width / target.width,
      g.viewport.height / target.height,
    );
    final scale = math.min(v.scale, fit).clamp(g.minScale, g.maxScale).toDouble();
    if (scale == v.scale && v.visible(g.viewport).contains(target.topLeft) &&
        v.visible(g.viewport).contains(target.bottomRight)) {
      return;
    }
    final center = g.viewport.center(Offset.zero) - target.center * scale;
    // A box taller than the view (at the zoom floor) shows its top.
    final dy = target.height * scale > g.viewport.height
        ? -target.top * scale
        : center.dy;
    final dx = target.width * scale > g.viewport.width
        ? -target.left * scale
        : center.dx;
    setState(() => _view = g.clamp(CanvasView(scale, Offset(dx, dy))));
  }

  /// This canvas's commands: its own, its modules' tools and the modules'
  /// commands (Box API 0.4). Key presses and the toolbar go through it.
  /// Made again when the page or the tool selection changes.
  CommandRegistry get commands => _commands;

  void _buildCommands() {
    final old = _commands;
    _commands = CommandRegistry()
      ..registerAll(buildCanvasCommands(this))
      ..registerAll(_c.modules.commandsFor(this))
      ..registerAll(widget.extraCommands?.call() ?? const []);
    old.dispose();
  }

  /// The current view, for tests and the app shell.
  CanvasView? get view => _view;

  /// The running tool session, for tests.
  ToolSession? get toolSession => _session;

  @override
  CanvasController get controller => _c;

  @override
  double get scale => _view?.scale ?? 1;

  @override
  Brightness get brightness => _brightness;

  @override
  NotedColors get colors => _colors;

  NotedColors _colors = NotedColors.light;

  Brightness _brightness = Brightness.light;

  @override
  void repaintOverlay() => _overlay.repaint();

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _tools.addListener(_toolChanged);
    _find = _makeFind();
    _buildCommands();
    widget.findRequests?.addListener(_takeFindRequest);
    _takeFindRequest();
  }

  @override
  void didUpdateWidget(PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _cancelSession();
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _view = null;
      _find.dispose();
      _find = _makeFind();
    }
    if (oldWidget.findRequests != widget.findRequests) {
      oldWidget.findRequests?.removeListener(_takeFindRequest);
      widget.findRequests?.addListener(_takeFindRequest);
      _takeFindRequest();
    }
    if (oldWidget.tools != widget.tools) {
      (oldWidget.tools ?? _ownTools).removeListener(_toolChanged);
      _tools.addListener(_toolChanged);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.tools != widget.tools) {
      _buildCommands();
    }
  }

  @override
  void dispose() {
    widget.findRequests?.removeListener(_takeFindRequest);
    _find.dispose();
    _findFocus.dispose();
    _commands.dispose();
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
    if (_readOnly || tool == null || _session != null || _view == null) return;
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

  void _changed() {
    // The page turned read-only under a running tool: end it.
    if (_readOnly) _cancelSession();
    _find.refresh();
    _hostsRevision++;
    setState(() {});
  }

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

  @override
  void fitAll() => _setView((g, _) => g.fitAll(_content));

  /// Zooms around the mouse if it is over the canvas, else around the
  /// centre of the view.
  @override
  void zoomBy(double factor) => _setView(
    (g, v) => g.zoomAt(
      v,
      _hover ?? g.viewport.center(Offset.zero),
      factor,
    ),
  );

  /// Zooms to [scale] around the centre of the view.
  @override
  void zoomTo(double scale) => _setView(
    (g, v) =>
        g.zoomAt(v, g.viewport.center(Offset.zero), scale / v.scale),
  );

  void _onSignal(PointerSignalEvent event) {
    if (event.kind == PointerDeviceKind.mouse) _hover = event.localPosition;
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
    if (v == null || _readOnly || _tools.active != null) return;
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

  /// Keys are looked up in the command registry. Keys bubble up from a
  /// focused editor: only the commands that work while editing (zoom,
  /// Escape) answer them, the rest is left to the editor. A read-only page
  /// answers only to the commands that work there (zoom).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final command = _commands.resolve(
      event,
      // The find bar's text field owns the keys like a box's editor does.
      editing: _c.editingId != null || _findFocus.hasFocus,
      readOnly: _readOnly,
    );
    if (command == null) return KeyEventResult.ignored;
    command.run();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _brightness = Theme.of(context).brightness;
    _colors = NotedColors.of(context);
    _toolbarScale = _view?.scale;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommandToolbar(
            registry: _commands,
            layout: widget.toolbarLayout,
            readOnly: _readOnly,
          ),
          Expanded(child: _canvasArea(scheme)),
        ],
      ),
    );
  }

  // The boxes' widgets, kept while nothing they show has changed. Panning and
  // zooming rebuild this widget on every frame, but a BoxHost reads the zoom
  // when it needs it (BoxHost.scaleOf), so the same widget instances can be
  // handed to the Stack again and Flutter then skips every box (editors
  // included). The list is made again whenever the controller notifies (the
  // page, the selection, editing, read-only), and when the canvas child's
  // origin, the read-only state, the find model or the controller change.
  //
  // Each box's widget is also kept on its own while what that box shows is
  // unchanged: its node (the page replaces the node object of a box that
  // changes and keeps the others; compared by identity), whether it is
  // selected or being edited, and the read-only state. So when one note grows
  // with its text, only that box rebuilds, not every box on the page.
  List<Widget>? _hostWidgets;
  int _hostsRevision = 0;
  (int, CanvasController, Offset, bool, PageFind)? _hostsKey;
  final Map<String, ((CanvasNode, bool, bool, bool), BoxHost)> _hostPerBox = {};

  List<Widget> _boxHosts(Offset childOrigin, bool readOnly) {
    final key = (_hostsRevision, _c, childOrigin, readOnly, _find);
    final cached = _hostWidgets;
    if (cached != null && _hostsKey == key) return cached;
    final previous = _hostsKey;
    // Something every box uses changed: make every widget again.
    if (previous == null || (previous.$2, previous.$3, previous.$4, previous.$5) != (key.$2, key.$3, key.$4, key.$5)) {
      _hostPerBox.clear();
    }
    _hostsKey = key;
    final kept = <String, ((CanvasNode, bool, bool, bool), BoxHost)>{};
    final hosts = <Widget>[];
    for (final node in _c.page.nodes) {
      final boxKey = (node, _c.selectedId == node.id, _c.editingId == node.id, _c.readOnly);
      final old = _hostPerBox[node.id];
      final host = old != null && old.$1 == boxKey
          ? old.$2
          : BoxHost(
              key: ValueKey(node.id),
              node: node,
              controller: _c,
              childOrigin: childOrigin,
              scaleOf: () => scale,
              onGripTap: _focus.requestFocus,
              readOnly: readOnly,
              find: _find,
            );
      kept[node.id] = (boxKey, host);
      hosts.add(host);
    }
    _hostPerBox
      ..clear()
      ..addAll(kept);
    return _hostWidgets = hosts;
  }

  Widget _canvasArea(ColorScheme scheme) {
    return LayoutBuilder(
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
          // The toolbar is built before this runs: if the view settled on a
          // zoom it doesn't show, rebuild once so its percentage is right.
          if (view.scale != _toolbarScale) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          }
          final matrix = g.matrixFor(view);
          if (_transform.value != matrix) _transform.value = matrix;

          final readOnly = _readOnly;
          // A tool picked on another page does nothing on a read-only one.
          final tool = readOnly ? null : _tools.active;
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
                  onPointerHover: (e) {
                    if (e.kind == PointerDeviceKind.mouse) {
                      _hover = e.localPosition;
                    }
                  },
                  onPointerPanZoomStart: (_) {
                    _pinchStartScale = _view?.scale ?? 1;
                    _pinchPan = Offset.zero;
                  },
                  onPointerPanZoomUpdate: (e) {
                    // A box that scrolls has claimed this gesture's panning
                    // (BoxScrollScope); a pinch still zooms the canvas.
                    final claimed = TrackpadClaims.isClaimed(e.pointer);
                    // The focal point is where the fingers are now: the
                    // gesture's start plus its pan so far. The scale is
                    // the start scale times the gesture's cumulative scale,
                    // so it never drifts; the content under the fingers
                    // stays under them at every step.
                    // (e.pan, not e.localPan: Flutter transforms that as a
                    // position, so it would include the canvas's offset.)
                    final pan = claimed ? Offset.zero : e.pan;
                    final step = pan - _pinchPan;
                    _pinchPan = pan;
                    _setView(
                      (g, v) => g.zoomAt(
                        v,
                        e.localPosition + pan,
                        _pinchStartScale * e.scale / v.scale,
                        pan: step,
                      ),
                    );
                  },
                  onPointerPanZoomEnd: (e) => TrackpadClaims.release(e.pointer),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _onBackgroundTap,
                    child: MouseRegion(
                      onExit: (_) => _hover = null,
                      cursor: tool?.cursor ?? MouseCursor.defer,
                      child: ColoredBox(
                        color: scheme.surfaceContainerLowest,
                        child: CustomPaint(
                          painter: PageBackgroundPainter(
                            background: _c.page.meta.background,
                            view: view,
                            pitch: NotedMetrics.of(context).paperPitch,
                            lineColor: _colors.paperLine,
                            dotColor: _colors.paperDot,
                            marginColor: _colors.paperMargin,
                            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                          ),
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
                                children: _boxHosts(g.child.topLeft, readOnly),
                              ),
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
              // The find bar, top right under the toolbar.
              Positioned(
                top: NotedMetrics.of(context).space2,
                right: NotedMetrics.of(context).space4,
                child: ListenableBuilder(
                  listenable: _find,
                  builder: (context, _) => _find.isOpen
                      ? FindBar(
                          find: _find,
                          focusNode: _findFocus,
                          onClose: closeFind,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              if (kDebugMode)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _InputReadout(stats: _stats),
                ),
            ],
          );
        },
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
  Widget build(BuildContext context) {
    final metrics = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    return ValueListenableBuilder<_InputStats?>(
      valueListenable: stats,
      builder: (context, s, _) => s == null
          ? const SizedBox.shrink()
          : DecoratedBox(
              decoration: BoxDecoration(
                color: colors.readoutBackground,
                borderRadius: metrics.borderSm,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: metrics.space2,
                  vertical: metrics.space1,
                ),
                child: Text(
                  s.toString(),
                  style: NotedTypography.of(context).small.copyWith(
                    color: colors.onReadout,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
    );
  }
}
