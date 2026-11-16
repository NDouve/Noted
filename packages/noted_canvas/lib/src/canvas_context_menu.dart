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
    this.onTarget = false,
    this.short,
  });

  final Command command;

  /// Replaces the command's label in the menu.
  final String? label;
  final bool destructive;

  /// A command made for this menu (never registered): the menu disposes it.
  final bool point;

  /// The ring's More slot: it swaps the ring for the full conventional menu.
  final bool more;

  /// A box entry: [command] only reports whether the action is on for the
  /// menu's target. Choosing it selects the target, then runs the registry
  /// command with the same id.
  final bool onTarget;

  /// A shorter text for the ring's slot (its semantics keep the full text).
  final String? short;

  String get text => label ?? command.label;
  bool get enabled => more || command.enabled;
}

/// What one context menu shows.
class ContextMenuSpec {
  ContextMenuSpec({
    required this.groups,
    required this.ring,
    this.points = const [],
  });

  /// The conventional menu: groups of entries, a divider between groups.
  final List<List<ContextEntry>> groups;

  /// The ring's six slots clockwise from the top; null is an empty slot.
  /// Delete is only in the list (the ring's More).
  final List<ContextEntry?> ring;

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

/// The id of the Pick overlapping box command (a point command of the open
/// menu: never registered, no shortcut).
const String contextPickId = 'canvas.pickOverlappingBox';

/// The width of the conventional list.
const double contextMenuWidth = 248;

/// The entries for a box target. [boxesHere] is the point command that opens
/// the pick list. The arrange rows and Delete are wrapper commands whose
/// enablement is [enabledFor] (read for the menu's target, not the selection,
/// and refreshed by [listenable]); choosing one selects the target and runs the
/// registry command (see [ContextEntry.onTarget]). A disallowed box (0166) gets
/// Delete only, with no heading.
ContextMenuSpec boxContextSpec({
  required CommandRegistry registry,
  required Command boxesHere,
  required bool disallowed,
  required Listenable listenable,
  required bool Function(String commandId) enabledFor,
}) {
  final wrappers = <Command>[];
  ContextEntry? reg(String id, {String? label, bool destructive = false}) {
    final c = registry[id];
    if (c == null) return null;
    final wrapper = Command(
      id: id,
      label: c.label,
      icon: c.icon,
      shortcut: c.shortcut,
      alternateShortcuts: c.alternateShortcuts,
      listenable: listenable,
      enabled: () => enabledFor(id),
      invoke: () {},
    );
    wrappers.add(wrapper);
    return ContextEntry(wrapper, label: label, destructive: destructive, onTarget: true);
  }

  final delete = reg(CanvasCommands.delete, label: 'Delete box', destructive: true);
  if (disallowed) {
    return ContextMenuSpec(
      groups: [
        [?delete],
      ],
      ring: [delete, null, null, null, null, null],
      points: [boxesHere, ...wrappers],
    );
  }
  final front = reg(CanvasCommands.bringToFront);
  final forward = reg(CanvasCommands.bringForward);
  final backward = reg(CanvasCommands.sendBackward);
  final back = reg(CanvasCommands.sendToBack);
  final here = ContextEntry(boxesHere, point: true, short: 'Pick overlapping');
  final more = ContextEntry(_moreCommand(), point: true, more: true);
  return ContextMenuSpec(
    groups: [
      [?front, ?forward, ?backward, ?back],
      [here],
      [?delete],
    ],
    ring: [front, forward, backward, back, here, more],
    points: [boxesHere, more.command, ...wrappers],
  );
}

/// The entries for the empty canvas. [paste] is a point command; the rest come
/// from [registry] and are left out when their module is off. A placeholder
/// ("coming later") is never shown. On a [readOnly] page (either target) only
/// Find on page and Fit all are listed.
ContextMenuSpec canvasContextSpec({
  required CommandRegistry registry,
  required Command paste,
  bool readOnly = false,
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

  final find = reg(CanvasCommands.find);
  final fit = reg(CanvasCommands.fitAll);
  if (readOnly) {
    return ContextMenuSpec(
      groups: [
        [?find, ?fit],
      ],
      ring: [find, fit, null, null, null, null],
      points: [paste],
    );
  }
  final select = reg(CanvasCommands.select);
  final pen = reg('noted.drawing.pen');
  final eraser = reg('noted.drawing.eraser');
  final image = reg('noted.image.insert', label: 'Insert image');
  final file = reg('noted.file.insert', label: 'Insert file');
  final pasteEntry = ContextEntry(paste, point: true);
  final more = ContextEntry(_moreCommand(), point: true, more: true);
  return ContextMenuSpec(
    groups: [
      [?select, ?pen, ?eraser],
      [?image, ?file, pasteEntry],
      [?find, ?fit],
    ],
    ring: [select, pen, image, pasteEntry, find, more],
    points: [paste, more.command],
  );
}

Command _moreCommand() =>
    Command(id: contextPointId('more'), label: 'More…', icon: Icons.more_horiz_rounded, invoke: () {});

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

  /// The list was opened by the ring's More: Escape goes back to the ring.
  bool _fromMore = false;

  /// The row (list) or slot (ring, [radialCancel] for Cancel) the keyboard or
  /// the pointer is on, and whether the keyboard put it there (the focus
  /// outline shows for the keyboard only).
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

  /// The entry at [i]: a list row or a ring slot (null: blank or Cancel).
  ContextEntry? _entryAt(int i) {
    if (_ring) {
      return i >= 0 && i < widget.spec.ring.length ? widget.spec.ring[i] : null;
    }
    final flat = _flat;
    return i >= 0 && i < flat.length ? flat[i] : null;
  }

  /// The indexes the keyboard can land on: enabled rows, or enabled slots.
  List<int> get _enabledStops {
    if (_ring) {
      return [for (final (i, e) in widget.spec.ring.indexed) if (e != null && e.enabled) i];
    }
    return [for (final (i, e) in _flat.indexed) if (e.enabled) i];
  }

  void _run(ContextEntry e) {
    if (_gone || _closing || !e.enabled) return;
    if (e.more) {
      setState(() {
        _ring = false;
        _fromMore = true;
        _at = null;
        _keyboard = true;
        _started = false;
      });
      return;
    }
    _close(e);
  }

  /// Escape from the list that More opened goes back to More on the ring.
  void _backToRing() {
    final more = widget.spec.ring.indexWhere((e) => e != null && e.more);
    setState(() {
      _ring = true;
      _fromMore = false;
      _at = more < 0 ? radialCancel : more;
      _keyboard = true;
      _started = true;
    });
  }

  void _step(int dir, {bool tab = false}) {
    final on = _enabledStops;
    // Tab has Cancel in its cycle; the arrows go round the slots only.
    if (_ring && tab) on.insert(0, radialCancel);
    if (on.isEmpty) return;
    final at = _at;
    int next;
    if (_ring && !tab && at == radialCancel) {
      next = dir > 0 ? on.first : on.last;
    } else if (at == null) {
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
    if (key == LogicalKeyboardKey.escape) {
      if (_fromMore && !_ring) {
        _backToRing();
      } else {
        _close();
      }
    } else if (key == LogicalKeyboardKey.tab) {
      _step(HardwareKeyboard.instance.isShiftPressed ? -1 : 1, tab: true);
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight && _ring) {
      _step(1);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft && _ring) {
      _step(-1);
    } else if (key == LogicalKeyboardKey.home && !_ring) {
      final on = _enabledStops;
      _jump(on.isEmpty ? -1 : on.first);
    } else if (key == LogicalKeyboardKey.end && !_ring) {
      final on = _enabledStops;
      _jump(on.isEmpty ? -1 : on.last);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      final at = _at;
      if (at == radialCancel && _ring) {
        _close();
      } else if (at != null && _entryAt(at) != null) {
        _run(_entryAt(at)!);
      }
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
          // Focus starts on the first enabled row; on the ring, on Cancel.
          if (!_started) {
            _started = true;
            final on = _enabledStops;
            _at = _ring
                ? radialCancel
                : on.isEmpty
                ? null
                : on.first;
          }
          final at = _at;
          final atEntry = at == null ? null : _entryAt(at);
          if (atEntry != null && !atEntry.enabled) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _at == at) setState(() => _at = null);
            });
          }
          if (_ring) {
            final ring = RadialMenuView.maybe(
              context,
              slots: widget.spec.ring,
              anchor: widget.anchor,
              within: widget.within,
              at: _at,
              keyboard: _keyboard,
              onRun: _run,
              onCancel: _close,
              onHover: (slot) => setState(() {
                _at = slot;
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
            delegate: _ListLayout(widget.anchor, widget.within),
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
}

/// Places the menu at the anchor, flipped left or up to stay inside the canvas
/// rect [within] (global) with an 8 px margin.
class _ListLayout extends SingleChildLayoutDelegate {
  const _ListLayout(this.anchor, this.within);

  final Offset anchor;
  final Rect within;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(Size(math.max(0, within.width - 16), math.max(0, within.height - 16)));

  @override
  Offset getPositionForChild(Size size, Size child) {
    double place(double a, double extent, double lo, double hi) {
      var v = a + extent + 8 > hi ? a - extent : a;
      v = math.min(v, hi - extent - 8);
      return math.max(v, lo + 8);
    }

    return Offset(
      place(anchor.dx, child.width, within.left, within.right),
      place(anchor.dy, child.height, within.top, within.bottom),
    );
  }

  @override
  bool shouldRelayout(_ListLayout old) => old.anchor != anchor || old.within != within;
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
    var index = 0;
    final children = <Widget>[
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
    return SizedBox(
      width: contextMenuWidth,
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
    final active = lit && on;
    final fg = !on
        ? colors.textDisabled
        : active
        ? scheme.primary
        : entry.destructive
        ? scheme.error
        : scheme.onSurface;
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
                color: active ? scheme.primaryContainer : Colors.transparent,
                borderRadius: m.borderMd,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: m.rowSize),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: m.space1),
                  child: Text(
                    entry.text,
                    style: type.body.copyWith(
                      color: fg,
                      fontWeight: active ? FontWeight.w700 : null,
                    ),
                    overflow: TextOverflow.ellipsis,
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
