// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'commands.dart';
import 'noted_menu.dart';
import 'noted_theme.dart';

/// One command of a toolbar row that may move into the More menu: the
/// [widget] that shows it (with the spacing or separator before it), the
/// [command], and the [group] it belongs to (the menu separates groups).
class ToolbarUnit {
  const ToolbarUnit({
    required this.widget,
    required this.command,
    required this.group,
  });

  final Widget widget;
  final Command command;
  final int group;
}

/// The key of the More button at the end of a toolbar row.
const Key toolbarMoreKey = ValueKey('toolbar-more');

/// A row of toolbar [units] that shows as many as fit the width it is given,
/// in order, and puts the rest in a trailing More menu (a button with the
/// tooltip "More"). With room for all of them there is no More button, and
/// nothing is ever clipped. The row is as wide as what it shows.
class ToolbarOverflowRow extends StatefulWidget {
  const ToolbarOverflowRow({
    super.key,
    required this.units,
    required this.registry,
    this.onOpened,
    this.onClosed,
  });

  final List<ToolbarUnit> units;

  /// Called when the More menu opens, and when it closes (a command chosen
  /// and run, or dismissed).
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  /// Runs the command chosen in the More menu, and its dropdown's commands.
  final CommandRegistry registry;

  @override
  State<ToolbarOverflowRow> createState() => _ToolbarOverflowRowState();
}

class _ToolbarOverflowRowState extends State<ToolbarOverflowRow> {
  /// How many units the last layout showed (the rest are in the menu).
  int _shown = 1 << 30;

  final GlobalKey _moreKey = GlobalKey();

  /// How far below the More button the bar ends, so the menu opens under the
  /// bar and not over its lower part (the Contextual strip is shorter than
  /// the bar it sits in).
  double _drop = 0;

  static const _buttonPadding = EdgeInsets.all(8);

  /// Measures [_drop]: the bar is the nearest ancestor at least as tall as
  /// the toolbar height.
  void _measureDrop() {
    if (!mounted) return;
    final button = _moreKey.currentContext?.findRenderObject();
    if (button is! RenderBox || !button.attached || !button.hasSize) return;
    final barHeight = NotedMetrics.of(context).toolbarHeight;
    RenderBox? bar;
    context.visitAncestorElements((e) {
      final r = e.renderObject;
      if (r is RenderBox && r.hasSize && r.size.height >= barHeight - 0.5) {
        bar = r;
        return false;
      }
      return true;
    });
    final b = bar;
    if (b == null) return;
    final barBottom = b.localToGlobal(Offset(0, b.size.height)).dy;
    final buttonBottom = button.localToGlobal(Offset(0, button.size.height)).dy;
    final drop = math.max(0.0, barBottom - buttonBottom);
    if ((drop - _drop).abs() > 0.5) setState(() => _drop = drop);
  }

  List<PopupMenuEntry<String>> _items() {
    final units = widget.units;
    final r = widget.registry;
    final entries = <PopupMenuEntry<String>>[];
    int? group;
    for (final u in units.skip(math.min(_shown, units.length))) {
      if (group != null && u.group != group) {
        entries.add(const NotedMenuDivider());
      }
      group = u.group;
      final c = u.command;
      if (c.menu.isNotEmpty) {
        // A dropdown command: its own commands, the checked one marked, all
        // disabled while the dropdown itself is.
        for (final id in c.menu) {
          final item = r[id];
          if (item == null) continue;
          final entry = NotedMenuItem.forCommand(item, showCheck: true);
          entries.add(
            c.enabled
                ? entry
                : NotedMenuItem<String>(
                    key: entry.key,
                    value: entry.value,
                    label: entry.label,
                    leading: entry.leading,
                    shortcut: entry.shortcut,
                    enabled: false,
                  ),
          );
        }
      } else {
        entries.add(NotedMenuItem.forCommand(c, showCheck: true));
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureDrop());
    return _OverflowLayout(
      onShown: (n) => _shown = n,
      more: KeyedSubtree(
        key: _moreKey,
        child: PopupMenuButton<String>(
          key: toolbarMoreKey,
          tooltip: 'More',
          iconSize: m.icon,
          icon: const Icon(Icons.more_horiz_rounded),
          // Below the bar, so the menu never covers the strip it belongs to.
          position: PopupMenuPosition.under,
          padding: _buttonPadding,
          // PopupMenuButton takes half its vertical padding off the offset.
          offset: Offset(0, _drop + _buttonPadding.vertical / 2),
          // The menu must not take focus: the note commands are enabled only
          // while a note editor has it (0097).
          requestFocus: false,
          onOpened: widget.onOpened,
          onCanceled: widget.onClosed,
          onSelected: (id) async {
            await widget.registry.invoke(id);
            widget.onClosed?.call();
          },
          itemBuilder: (_) => _items(),
        ),
      ),
      children: [for (final u in widget.units) u.widget],
    );
  }
}

class _OverflowLayout extends MultiChildRenderObjectWidget {
  _OverflowLayout({
    required this.onShown,
    required Widget more,
    required List<Widget> children,
  }) : super(children: [...children, more]);

  final ValueChanged<int> onShown;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOverflow(onShown);

  @override
  void updateRenderObject(BuildContext context, _RenderOverflow renderObject) {
    renderObject.onShown = onShown;
  }
}

class _OverflowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderOverflow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _OverflowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _OverflowParentData> {
  _RenderOverflow(this.onShown);

  ValueChanged<int> onShown;

  /// Units shown; the More button (the last child) is shown when fewer than
  /// all of them are.
  int _shown = 0;
  bool _moreShown = false;
  int _count = 0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _OverflowParentData) {
      child.parentData = _OverflowParentData();
    }
  }

  /// How many of [widths] (the units) fit in [room] along with a More button
  /// [moreWidth] wide, whether More is shown (some are hidden and it fits),
  /// and the width used.
  (int, bool, double) _plan(List<double> widths, double moreWidth, double room) {
    final total = widths.fold<double>(0, (a, b) => a + b);
    if (total <= room) return (widths.length, false, total);
    // Too narrow even for More: show nothing rather than paint past the bar.
    if (moreWidth > room) return (0, false, 0);
    var shown = 0;
    var used = moreWidth;
    for (final w in widths) {
      if (used + w > room) break;
      used += w;
      shown++;
    }
    return (shown, true, used);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final loose = BoxConstraints(maxHeight: constraints.maxHeight);
    var height = 0.0;
    final widths = <double>[];
    for (var c = firstChild; c != null; c = childAfter(c)) {
      final s = c.getDryLayout(loose);
      widths.add(s.width);
      height = math.max(height, s.height);
    }
    final moreWidth = widths.removeLast();
    final (_, _, used) = _plan(widths, moreWidth, constraints.maxWidth);
    return constraints.constrain(Size(used, constraints.constrainHeight(height)));
  }

  @override
  void performLayout() {
    final children = <RenderBox>[];
    for (var c = firstChild; c != null; c = childAfter(c)) {
      children.add(c);
    }
    final more = children.removeLast();
    _count = children.length;
    final loose = BoxConstraints(maxHeight: constraints.maxHeight);
    var height = 0.0;
    final widths = <double>[];
    for (final c in [...children, more]) {
      c.layout(loose, parentUsesSize: true);
      widths.add(c.size.width);
      height = math.max(height, c.size.height);
    }
    final moreWidth = widths.removeLast();
    final (shown, moreShown, used) = _plan(
      widths,
      moreWidth,
      constraints.maxWidth,
    );
    _shown = shown;
    _moreShown = moreShown;
    onShown(shown);
    height = constraints.constrainHeight(height);
    var x = 0.0;
    for (var i = 0; i < children.length; i++) {
      final data = children[i].parentData! as _OverflowParentData;
      data.offset = Offset(x, (height - children[i].size.height) / 2);
      if (i < shown) x += widths[i];
    }
    final moreData = more.parentData! as _OverflowParentData;
    moreData.offset = Offset(x, (height - more.size.height) / 2);
    size = constraints.constrain(Size(used, height));
  }

  /// The children that take part: the shown units, and More when some are
  /// hidden and it fits.
  Iterable<(int, RenderBox)> get _visible sync* {
    var i = 0;
    for (var c = firstChild; c != null; c = childAfter(c)) {
      final isMore = i == _count;
      if (isMore ? _moreShown : i < _shown) yield (i, c);
      i++;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final (_, c) in _visible) {
      final data = c.parentData! as _OverflowParentData;
      context.paintChild(c, data.offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final (_, c) in _visible.toList().reversed) {
      final data = c.parentData! as _OverflowParentData;
      final hit = result.addWithPaintOffset(
        offset: data.offset,
        position: position,
        hitTest: (result, transformed) =>
            c.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (final (_, c) in _visible) {
      visitor(c);
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) {
    var w = 0.0;
    for (var c = firstChild; c != null; c = childAfter(c)) {
      w += c.getMaxIntrinsicWidth(height);
    }
    return w;
  }

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) {
    var h = 0.0;
    for (var c = firstChild; c != null; c = childAfter(c)) {
      h = math.max(h, c.getMaxIntrinsicHeight(width));
    }
    return h;
  }
}
