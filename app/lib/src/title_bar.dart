// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'brand_mark.dart';
import 'window_channel.dart';

/// The width of a caption button, in logical pixels (Windows' 46 at 100%).
const double captionButtonWidth = 46;

/// Rounds a logical coordinate to a whole device pixel, half up, so each
/// physical coordinate comes from its own logical origin (spec section 2).
double snapToDevicePixel(double logical, double devicePixelRatio) =>
    (logical * devicePixelRatio + 0.5).floorToDouble() / devicePixelRatio;

/// The custom Windows title bar (spec section 2): the brand, and the minimise,
/// maximise or restore and close buttons. The runner owns the mouse (drag,
/// double-click, the buttons' presses); this only draws, from the state the
/// runner reports, and tells the runner where the buttons are.
///
/// It sits above the Navigator (`MaterialApp.builder`), so routes, dialogs and
/// the drawer lay out below it and never cover the caption.
class TitleBar extends StatefulWidget {
  const TitleBar({super.key, required this.window});

  final WindowChannel window;

  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> {
  final _keys = {
    CaptionButton.minimize: GlobalKey(debugLabel: 'caption minimize'),
    CaptionButton.maximize: GlobalKey(debugLabel: 'caption maximize'),
    CaptionButton.close: GlobalKey(debugLabel: 'caption close'),
  };
  late WindowFrameState _state = widget.window.state;
  List<double>? _sent;
  bool _reportQueued = false;

  @override
  void initState() {
    super.initState();
    widget.window.onState = _onState;
    widget.window.refreshState().then((s) {
      if (mounted && s != _state) setState(() => _state = s);
    });
  }

  void _onState(WindowFrameState s) {
    if (mounted) setState(() => _state = s);
  }

  @override
  void didUpdateWidget(TitleBar old) {
    super.didUpdateWidget(old);
    if (old.window != widget.window) {
      _release(old.window);
      widget.window.onState = _onState;
      _sent = null;
    }
  }

  // Only this State's own callback is cleared.
  void _release(WindowChannel w) {
    if (w.onState == _onState) w.onState = null;
  }

  @override
  void dispose() {
    _release(widget.window);
    super.dispose();
  }

  Rect? _rectOf(CaptionButton b) {
    final box = _keys[b]!.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // After layout: the button rects, sent only when they changed.
  void _queueReport() {
    if (_reportQueued) return;
    _reportQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportQueued = false;
      if (!mounted) return;
      final min = _rectOf(CaptionButton.minimize);
      final max = _rectOf(CaptionButton.maximize);
      final close = _rectOf(CaptionButton.close);
      if (min == null || max == null || close == null) return;
      List<double> flat(Rect r) => [r.left, r.top, r.right, r.bottom];
      final key = [...flat(min), ...flat(max), ...flat(close)];
      if (listEquals(key, _sent)) return;
      _sent = key;
      widget.window.setCaptionRects(minimize: min, maximize: max, close: close);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    MediaQuery.sizeOf(context); // Rebuilds on a resize, to report again.
    final active = _state.active;
    final textColor = active ? scheme.onSurface : scheme.onSurfaceVariant;
    _queueReport();
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: DesignMetrics.titleBarHeight,
        child: DecoratedBox(
          key: const ValueKey('title-bar'),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(bottom: BorderSide(color: scheme.outline)),
          ),
          child: Stack(
            children: [
              Semantics(
                label: 'Noted',
                container: true,
                excludeSemantics: true,
                child: Stack(
                  children: [
                    Positioned(
                      left: snapToDevicePixel(16, dpr),
                      top: snapToDevicePixel(12, dpr),
                      child: Opacity(
                        opacity: active ? 1 : 0.6,
                        child: const BrandMark(showWordmark: false),
                      ),
                    ),
                    Positioned(
                      left: snapToDevicePixel(38, dpr),
                      top: snapToDevicePixel(10, dpr),
                      width: 42,
                      height: 20,
                      child: Text(
                        'Noted',
                        key: const ValueKey('title-bar-wordmark'),
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          fontFamily: 'Segoe UI',
                          fontFamilyFallback: const ['Inter'],
                          fontSize: 14,
                          height: 20 / 14,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _button(
                      CaptionButton.minimize,
                      'Minimise',
                      0xE921,
                      widget.window.minimize,
                    ),
                    _button(
                      CaptionButton.maximize,
                      _state.maximized ? 'Restore' : 'Maximise',
                      _state.maximized ? 0xE923 : 0xE922,
                      widget.window.toggleMaximize,
                    ),
                    _button(
                      CaptionButton.close,
                      'Close',
                      0xE8BB,
                      widget.window.close,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(
    CaptionButton which,
    String name,
    int glyph,
    Future<void> Function() onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isClose = which == CaptionButton.close;
    final pressed = _state.pressed == which;
    final hovered = _state.hovered == which || pressed;
    Color? background;
    var glyphColor = _state.active ? scheme.onSurface : scheme.onSurfaceVariant;
    if (hovered) {
      if (isClose) {
        background = pressed
            ? const Color(0xE6C42B1C)
            : const Color(0xFFC42B1C);
        glyphColor = const Color(0xFFFFFFFF);
      } else {
        background = scheme.onSurface.withValues(alpha: pressed ? 0.12 : 0.08);
      }
    }
    return Semantics(
      button: true,
      label: name,
      excludeSemantics: true,
      onTap: () => onTap(),
      child: GestureDetector(
        key: ValueKey('caption-${which.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(),
        child: SizedBox(
          key: _keys[which],
          width: captionButtonWidth,
          height: DesignMetrics.titleBarHeight,
          child: ColoredBox(
            color: background ?? const Color(0x00000000),
            child: Center(
              child: Text(
                String.fromCharCode(glyph),
                style: TextStyle(
                  fontFamily: 'Segoe Fluent Icons',
                  fontFamilyFallback: const ['Segoe MDL2 Assets'],
                  fontSize: 10,
                  color: glyphColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
