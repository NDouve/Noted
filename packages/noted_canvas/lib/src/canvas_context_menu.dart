// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'canvas_commands.dart';
import 'commands.dart';
import 'noted_colors.dart';
import 'noted_menu.dart' show notedMenuMinWidth;
import 'noted_theme.dart';
import 'radial_menu.dart';

/// How the canvas's context menus are drawn (host only). The same entries,
/// target, revalidation and focus rules apply to both.
enum ContextMenuStyle {
  /// A conventional menu: a column of rows at the pointer.
  list,

  /// A ring of six slots around the pointer, opened by the mouse only.
  radial,
}

/// One entry of a context menu: a command, with the text to show for it. The
/// command is a registry command or a point command made for one open menu.
class ContextEntry {
  const ContextEntry(
    this.command, {
    this.label,
    this.destructive = false,
    this.point = false,
    this.more = false,
  });

  final Command command;

  /// Replaces the command's label in the menu.
  final String? label;
  final bool destructive;

  /// A command made for this menu (never registered): the menu disposes it.
  final bool point;

  /// The ring's More slot: it swaps the ring for the full conventional menu.
  final bool more;

  String get text => label ?? command.label;
  bool get enabled => more || command.enabled;
}

/// What one context menu shows.
class ContextMenuSpec {
  ContextMenuSpec({
    required this.groups,
    required this.ring,
    this.heading,
    this.points = const [],
  });

  /// The conventional menu: groups of entries, a divider between groups.
  final List<List<ContextEntry>> groups;

  /// The ring's six slots clockwise from the top; null is an empty slot.
  final List<ContextEntry?> ring;

  /// A line above the entries ("Not allowed on this page").
  final String? heading;

  /// The commands made for this menu, disposed when it is done with.
  final List<Command> points;

  Iterable<ContextEntry> get entries => groups.expand((g) => g);

  late final Listenable listenable = Listenable.merge([
    for (final e in entries) e.command,
    for (final e in ring) ?e?.command,
  ]);
}

/// The id of a command made for one context menu.
String contextPointId(String name) => 'canvas.context.$name';

/// The entries for a box target. [boxesHere] is the point command that opens
/// the pick list; the layering and Delete come from [registry]. A disallowed
/// box (0166) gets its heading; its layering is off by the registry.
ContextMenuSpec boxContextSpec({
  required CommandRegistry registry,
  required Command boxesHere,
  required bool disallowed,
}) {
  ContextEntry? reg(String id, {String? label, bool destructive = false}) {
    final c = registry[id];
    return c == null ? null : ContextEntry(c, label: label, destructive: destructive);
  }

  final front = reg(CanvasCommands.bringToFront);
  final forward = reg(CanvasCommands.bringForward);
  final backward = reg(CanvasCommands.sendBackward);
  final back = reg(CanvasCommands.sendToBack);
  final delete = reg(CanvasCommands.delete, label: 'Delete box', destructive: true);
  final here = ContextEntry(boxesHere, point: true);
  final more = ContextEntry(_moreCommand(), point: true, more: true);
  return ContextMenuSpec(
    heading: disallowed ? 'Not allowed on this page' : null,
    groups: [
      [?front, ?forward, ?backward, ?back],
      [here],
      [?delete],
    ],
    ring: [front, delete, back, here, more, null],
    points: [boxesHere, more.command],
  );
}

/// The entries for the empty canvas. [newNote] and [paste] are point
/// commands; the inserts come from [registry] and are left out when their
/// module is off. A placeholder ("coming later") is never shown.
ContextMenuSpec canvasContextSpec({
  required CommandRegistry registry,
  required Command newNote,
  required Command paste,
  Set<String> hidden = const {},
  Set<String> notAllowed = const {},
}) {
  ContextEntry? reg(String id, {String? label}) {
    final c = registry[id];
    // A placeholder is never shown; a command made unavailable for a disallowed
    // type keeps the text that says so.
    if (c == null || hidden.contains(id)) return null;
    return ContextEntry(c, label: label != null && !notAllowed.contains(id) ? label : null);
  }

  final image = reg('noted.image.insert', label: 'Insert image');
  final file = reg('noted.file.insert', label: 'Insert file');
  final ai = reg('noted.ai.insert', label: 'AI box');
  final note = ContextEntry(newNote, point: true);
  final pasteEntry = ContextEntry(paste, point: true);
  final more = ContextEntry(_moreCommand(), point: true, more: true);
  return ContextMenuSpec(
    groups: [
      [note, pasteEntry],
      [?image, ?file, ?ai],
    ],
    ring: [note, pasteEntry, image, file, more, null],
    points: [newNote, paste, more.command],
  );
}

Command _moreCommand() =>
    Command(id: contextPointId('more'), label: 'More', icon: Icons.more_horiz_rounded, invoke: () {});

/// Opens a context menu for [spec] at the screen point [anchor] and completes
/// with the entry chosen, or null if it was closed. [within] is the canvas
/// area (global), which the ring is kept inside. With [radial] the ring shows
/// first, unless it can't fit [within], when the conventional menu shows.
/// [closeSignal] closing it asks the menu to close, choosing nothing.
Future<ContextEntry?> showContextMenu(
  BuildContext context, {
  required ContextMenuSpec spec,
  required Offset anchor,
  required Rect within,
  required bool radial,
  required ValueListenable<bool> closeSignal,
}) {
  return Navigator.of(context).push<ContextEntry>(
    _ContextRoute(
      spec: spec,
      anchor: anchor,
      within: within,
      radial: radial,
      closeSignal: closeSignal,
      animate: radial && !MediaQuery.disableAnimationsOf(context),
    ),
  );
}

class _ContextRoute extends PopupRoute<ContextEntry> {
  _ContextRoute({
    required this.spec,
    required this.anchor,
    required this.within,
    required this.radial,
    required this.closeSignal,
    required this.animate,
  });

  final ContextMenuSpec spec;
  final Offset anchor;
  final Rect within;
  final bool radial;
  final ValueListenable<bool> closeSignal;
  final bool animate;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close the menu';
  @override
  Duration get transitionDuration => animate ? const Duration(milliseconds: 120) : Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> b) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: 'Context menu',
      child: _ContextPanel(
        spec: spec,
        anchor: anchor,
        within: within,
        radial: radial,
        closeSignal: closeSignal,
      ),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> a, Animation<double> b, Widget child) {
    if (!animate) return child;
    final size = MediaQuery.sizeOf(context);
    final origin = Alignment(
      (anchor.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
      (anchor.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
    );
    return FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween<double>(begin: 0.85, end: 1).animate(a), alignment: origin, child: child),
    );
  }
}

class _ContextPanel extends StatefulWidget {
  const _ContextPanel({
    required this.spec,
    required this.anchor,
    required this.within,
    required this.radial,
    required this.closeSignal,
  });

  final ContextMenuSpec spec;
  final Offset anchor;
  final Rect within;
  final bool radial;
  final ValueListenable<bool> closeSignal;

  @override
  State<_ContextPanel> createState() => _ContextPanelState();
}

class _ContextPanelState extends State<_ContextPanel> {
  final FocusNode _focus = FocusNode(debugLabel: 'ContextMenu');
  final Map<int, GlobalKey> _rowKeys = {};
  bool _closing = false;

  /// The canvas asked for the menu to close: its commands may be gone, so
  /// nothing here reads them any more.
  bool _gone = false;
  late bool _ring = widget.radial;

  /// The row or slot the keyboard (or the pointer) is on, and whether the
  /// keyboard put it there (the focus outline shows for the keyboard only).
  int? _at;
  bool _keyboard = true;
  bool _started = false;

  List<ContextEntry> get _flat => widget.spec.entries.toList();

  @override
  void initState() {
    super.initState();
    widget.closeSignal.addListener(_onSignal);
    if (widget.closeSignal.value) _onSignal();
  }

  void _onSignal() {
    if (!widget.closeSignal.value || _gone) return;
    _gone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
      _close();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    widget.closeSignal.removeListener(_onSignal);
    _focus.dispose();
    super.dispose();
  }

  void _close([ContextEntry? entry]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop<ContextEntry>(entry);
  }

  /// The entries the keyboard moves over, in order: the list's rows, or the
  /// ring's slots clockwise (their indexes in the ring).
  List<ContextEntry> get _stops => _ring
      ? [for (final e in widget.spec.ring) ?e]
      : _flat;

  void _run(ContextEntry e) {
    if (_gone || _closing || !e.enabled) return;
    if (e.more) {
      setState(() {
        _ring = false;
        _at = null;
        _keyboard = true;
        _started = false;
      });
      return;
    }
    _close(e);
  }

  void _step(int dir) {
    final stops = _stops;
    final on = [for (final (i, e) in stops.indexed) if (e.enabled) i];
    if (on.isEmpty) return;
    final at = _at;
    int next;
    if (at == null) {
      next = dir > 0 ? on.first : on.last;
    } else {
      final i = on.indexOf(at);
      next = i < 0
          ? (dir > 0 ? on.firstWhere((x) => x > at, orElse: () => on.first) : on.lastWhere((x) => x < at, orElse: () => on.last))
          : on[(i + dir) % on.length];
    }
    setState(() {
      _at = next;
      _keyboard = true;
    });
    _reveal();
  }

  // Keeps the row the keyboard is on in view in a list that scrolls.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final at = _at;
      final ctx = at == null ? null : _rowKeys[at]?.currentContext;
      if (mounted && !_gone && ctx != null) Scrollable.ensureVisible(ctx);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _jump(int i) {
    if (i < 0) return;
    setState(() {
      _at = i;
      _keyboard = true;
    });
    _reveal();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || _gone) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final stops = _stops;
    if (key == LogicalKeyboardKey.escape) {
      _close();
    } else if (key == LogicalKeyboardKey.tab) {
      _step(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight && _ring) {
      _step(1);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft && _ring) {
      _step(-1);
    } else if (key == LogicalKeyboardKey.home && !_ring) {
      _jump(stops.indexWhere((s) => s.enabled));
    } else if (key == LogicalKeyboardKey.end && !_ring) {
      _jump(stops.lastIndexWhere((s) => s.enabled));
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final at = _at;
      if (at != null && at < stops.length) _run(stops[at]);
    } else {
      // Every other key is taken: nothing on the canvas acts while a menu is
      // open (a letter would switch the tool, Delete would remove the box).
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _Rebuild(
        listenable: widget.spec.listenable,
        builder: (context, _) {
          // Focus starts on the first enabled entry (for the ring: the first
          // enabled slot clockwise from the top).
          if (!_started) {
            _started = true;
            final i = _stops.indexWhere((s) => s.enabled);
            _at = i < 0 ? null : i;
          }
          final at = _at;
          if (at != null && at < _stops.length && !_stops[at].enabled) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _at == at) setState(() => _at = null);
            });
          }
          if (_ring) {
            final ring = RadialMenuView.maybe(
              context,
              slots: widget.spec.ring,
              heading: widget.spec.heading,
              anchor: widget.anchor,
              within: widget.within,
              at: _at == null ? null : _slotOf(_at!),
              keyboard: _keyboard,
              onRun: _run,
              onHover: (slot) => setState(() {
                _at = _stopOf(slot);
                _keyboard = false;
              }),
            );
            if (ring != null) return ring;
            // The ring doesn't fit the viewport: the list opens instead.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _ring) {
                setState(() {
                  _ring = false;
                  _started = false;
                });
              }
            });
            return const SizedBox.shrink();
          }
          return CustomSingleChildLayout(
            delegate: _ListLayout(widget.anchor),
            child: _ListView(
              spec: widget.spec,
              rowKeys: _rowKeys,
              at: _at,
              keyboard: _keyboard,
              onRun: _run,
              onHover: (i) => setState(() {
                _at = i;
                _keyboard = false;
              }),
            ),
          );
        },
      ),
    );
  }

  // Index into the ring's slots of the stop [stop] (stops skip empty slots).
  int _slotOf(int stop) {
    var n = -1;
    for (final (slot, e) in widget.spec.ring.indexed) {
      if (e != null) n++;
      if (n == stop) return slot;
    }
    return 0;
  }

  int? _stopOf(int slot) {
    if (widget.spec.ring[slot] == null) return null;
    return widget.spec.ring.take(slot).where((e) => e != null).length;
  }
}

/// Places the menu at the anchor, flipped left or up to stay inside the window
/// with an 8 px margin.
class _ListLayout extends SingleChildLayoutDelegate {
  const _ListLayout(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(constraints.maxWidth - 16, constraints.maxHeight - 16));

  @override
  Offset getPositionForChild(Size size, Size child) {
    double place(double a, double extent, double room) {
      var v = a + extent + 8 > room ? a - extent : a;
      v = math.min(v, room - extent - 8);
      return math.max(v, 8);
    }

    return Offset(
      place(anchor.dx, child.width, size.width),
      place(anchor.dy, child.height, size.height),
    );
  }

  @override
  bool shouldRelayout(_ListLayout old) => old.anchor != anchor;
}

class _ListView extends StatelessWidget {
  const _ListView({
    required this.spec,
    required this.at,
    required this.keyboard,
    required this.onRun,
    required this.onHover,
    required this.rowKeys,
  });

  final ContextMenuSpec spec;
  final int? at;
  final bool keyboard;
  final void Function(ContextEntry e) onRun;
  final void Function(int index) onHover;
  final Map<int, GlobalKey> rowKeys;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    var index = 0;
    final children = <Widget>[
      if (spec.heading != null)
        Padding(
          key: const ValueKey('context-heading'),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: m.space1),
          child: Text(
            spec.heading!,
            style: type.small.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
    ];
    var first = true;
    for (final group in spec.groups) {
      if (group.isEmpty) continue;
      if (!first) {
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(vertical: m.space1),
            child: Divider(height: 1, thickness: 1, color: scheme.outline),
          ),
        );
      }
      first = false;
      for (final e in group) {
        final i = index++;
        children.add(
          KeyedSubtree(
            key: rowKeys.putIfAbsent(i, GlobalKey.new),
            child: _Row(
              entry: e,
              lit: at == i,
              outlined: at == i && keyboard,
              onRun: () => onRun(e),
              onHover: () => onHover(i),
            ),
          ),
        );
      }
    }
    // The width the widest row needs (the list scrolls, so it can't be
    // measured by the layout).
    final scaler = MediaQuery.textScalerOf(context);
    double text(String s, TextStyle st) {
      final p = TextPainter(
        text: TextSpan(text: s, style: st),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    var need = notedMenuMinWidth;
    for (final e in spec.entries) {
      final sc = e.point ? null : menuShortcutFor(e.command);
      need = math.max(
        need,
        2 * m.space1 + 20 + m.icon + m.space3 + text(e.text, type.body) +
            (sc == null ? 0 : m.space4 + text(sc, type.small)) + 2,
      );
    }
    if (spec.heading != null) {
      need = math.max(need, 2 * m.space1 + 20 + text(spec.heading!, type.small) + 2);
    }
    return SizedBox(
      width: math.min(need, MediaQuery.sizeOf(context).width - 16),
      child: DecoratedBox(
        key: const ValueKey('context-menu'),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.outline),
          borderRadius: m.borderLg,
          boxShadow: m.shadowPopover,
        ),
        child: Semantics(
          role: SemanticsRole.menu,
          label: 'Context menu',
          container: true,
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.all(m.space1),
              // Scrolls when the window is too short for every row.
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.lit,
    required this.outlined,
    required this.onRun,
    required this.onHover,
  });

  final ContextEntry entry;
  final bool lit;
  final bool outlined;
  final VoidCallback onRun;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final colors = NotedColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final type = NotedTypography.of(context);
    final on = entry.enabled;
    final fg = !on
        ? colors.textDisabled
        : entry.destructive
        ? scheme.error
        : scheme.onSurface;
    final shortcut = entry.point ? null : menuShortcutFor(entry.command);
    return Semantics(
      button: true,
      role: SemanticsRole.menuItem,
      selected: lit,
      enabled: on,
      label: entry.text,
      excludeSemantics: true,
      onTap: on ? onRun : null,
      child: MouseRegion(
        onEnter: (_) => onHover(),
        child: GestureDetector(
          key: ValueKey('context-${entry.command.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: on ? onRun : null,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: m.borderMd,
              border: outlined
                  ? Border.fromBorderSide(BorderSide(color: scheme.primary, width: 2))
                  : null,
            ),
            child: DecoratedBox(
              key: outlined ? const ValueKey('context-focus') : null,
              decoration: BoxDecoration(
                color: lit && on ? colors.surfaceHover : Colors.transparent,
                borderRadius: m.borderMd,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: m.rowSize),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: m.space1),
                  child: Row(
                    children: [
                      Icon(entry.command.icon, size: m.icon, color: fg),
                      SizedBox(width: m.space3),
                      Expanded(
                        child: Text(
                          entry.text,
                          style: type.body.copyWith(color: fg),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (shortcut != null) ...[
                        SizedBox(width: m.space4),
                        Text(
                          shortcut,
                          key: const ValueKey('menu-shortcut'),
                          style: type.small.copyWith(color: on ? scheme.onSurfaceVariant : fg),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Builds with [builder] and again whenever [listenable] notifies. A command
/// can notify while the canvas is being built (a page turning read-only), when
/// a widget elsewhere can't be marked dirty: then it rebuilds after the frame.
class _Rebuild extends StatefulWidget {
  const _Rebuild({required this.listenable, required this.builder});

  final Listenable listenable;
  final Widget Function(BuildContext context, Widget? child) builder;

  @override
  State<_Rebuild> createState() => _RebuildState();
}

class _RebuildState extends State<_Rebuild> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(_Rebuild old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.transientCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      SchedulerBinding.instance.scheduleFrame();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, null);
}
