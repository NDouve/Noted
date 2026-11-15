// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import 'canvas_context_menu.dart';
import 'noted_colors.dart';
import 'noted_theme.dart';

/// Slots in the ring, 60 degrees apart, clockwise from the top.
const int radialSlots = 6;

/// The smallest ring radius, and the space kept between two pills and between
/// the ring and the viewport edge.
const double radialMinRadius = 88;
const double radialGap = 8;

/// The room the middle of the ring needs for a heading.
const double radialHeadingRoom = 40;

/// Where the ring's pills sit: [radius] from [centre], one rect per slot (null
/// for an empty slot), all in the coordinates of the anchor.
class RadialLayout {
  const RadialLayout(this.centre, this.radius, this.pills, {this.headingAbove = false, this.headingHeight = 0});

  final Offset centre;
  final double radius;
  final List<Rect?> pills;

  /// The heading doesn't fit in the middle: it sits above the ring, and the
  /// ring's box (kept inside the viewport) includes it.
  final bool headingAbove;
  final double headingHeight;

  /// The smallest rect holding every pill.
  Rect get bounds => pills.whereType<Rect>().reduce((a, b) => a.expandToInclude(b));
}

/// The centre of slot [i] on a ring of [radius] round [centre]: 60 degrees
/// apart, slot 0 at the top, clockwise.
Offset radialSlotCentre(Offset centre, double radius, int i) {
  final a = i * math.pi / 3;
  return centre + Offset(math.sin(a), -math.cos(a)) * radius;
}

/// Lays out the ring for pills of the given [sizes] (null: an empty slot),
/// pointed at [anchor] and kept inside [within] with 8 px margins; null if the
/// ring's box is larger than [within] (the caller then shows the list). The
/// radius is at least 88 and grows until no two pills are within 8 px.
RadialLayout? layoutRadial(
  List<Size?> sizes,
  Offset anchor,
  Rect within, {
  double Function(double width)? headingHeight,
}) {
  var r = radialMinRadius;
  List<Rect?> at(Offset c, double r) => [
    for (final (i, s) in sizes.indexed)
      s == null ? null : Rect.fromCenter(center: radialSlotCentre(c, r, i), width: s.width, height: s.height),
  ];
  bool clear(List<Rect?> rects) {
    final live = rects.whereType<Rect>().toList();
    for (var i = 0; i < live.length; i++) {
      for (var j = i + 1; j < live.length; j++) {
        if (live[i].inflate(radialGap / 2).overlaps(live[j].inflate(radialGap / 2))) return false;
      }
    }
    return true;
  }

  while (!clear(at(Offset.zero, r)) && r < 600) {
    r += 2;
  }
  var box = at(Offset.zero, r).whereType<Rect>().reduce((a, b) => a.expandToInclude(b));
  final inner = at(Offset.zero, r).whereType<Rect>().map(_distanceToRect).reduce(math.min);
  final above = headingHeight != null && inner < radialHeadingRoom;
  final hh = above ? headingHeight(box.width) + 4 : 0.0;
  if (above) box = box.expandToInclude(Rect.fromLTWH(box.left, box.top - hh, box.width, hh));
  final room = within.deflate(radialGap);
  if (box.width > room.width || box.height > room.height) return null;
  final cx = anchor.dx.clamp(room.left - box.left, room.right - box.right).toDouble();
  final cy = anchor.dy.clamp(room.top - box.top, room.bottom - box.bottom).toDouble();
  final centre = Offset(cx, cy);
  return RadialLayout(centre, r, at(centre, r), headingAbove: above, headingHeight: hh);
}

/// The ring: a pill for each slot, a dot at the point pressed, and, for a
/// disallowed box, its heading in the middle (or above the ring if that is too
/// tight).
class RadialMenuView extends StatelessWidget {
  const RadialMenuView._({
    required this.layout,
    required this.slots,
    required this.heading,
    required this.anchor,
    required this.at,
    required this.keyboard,
    required this.onRun,
    required this.onHover,
  });

  /// The ring for [slots] (six, null for an empty one), or null if it doesn't
  /// fit [within]. [at] is the slot the keyboard is on.
  static Widget? maybe(
    BuildContext context, {
    required List<ContextEntry?> slots,
    required String? heading,
    required Offset anchor,
    required Rect within,
    required int? at,
    required bool keyboard,
    required void Function(ContextEntry e) onRun,
    required void Function(int slot) onHover,
  }) {
    final m = NotedMetrics.of(context);
    final style = NotedTypography.of(context).label;
    final scaler = MediaQuery.textScalerOf(context);
    final sizes = <Size?>[
      for (final e in slots)
        e == null
            ? null
            : () {
                final p = TextPainter(
                  text: TextSpan(text: e.text, style: style),
                  textDirection: TextDirection.ltr,
                  textScaler: scaler,
                  maxLines: 1,
                )..layout();
                final s = Size(
                  10 + m.icon + m.space2 + p.width + 12,
                  math.max(m.rowSize, p.height + 2 * m.space1),
                );
                p.dispose();
                return s;
              }(),
    ];
    double headingHeight(double width) {
      final p = TextPainter(
        text: TextSpan(text: heading, style: NotedTypography.of(context).small),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width);
      final h = p.height;
      p.dispose();
      return h;
    }

    final layout = layoutRadial(
      sizes,
      anchor,
      within,
      headingHeight: heading == null ? null : headingHeight,
    );
    if (layout == null) return null;
    return RadialMenuView._(
      layout: layout,
      slots: slots,
      heading: heading,
      anchor: anchor,
      at: at,
      keyboard: keyboard,
      onRun: onRun,
      onHover: onHover,
    );
  }

  final RadialLayout layout;
  final List<ContextEntry?> slots;
  final String? heading;
  final Offset anchor;
  final int? at;
  final bool keyboard;
  final void Function(ContextEntry e) onRun;
  final void Function(int slot) onHover;

  @override
  Widget build(BuildContext context) {
    final m = NotedMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final colors = NotedColors.of(context);
    final type = NotedTypography.of(context);
    // The space left in the middle: the nearest pill's distance.
    final inner = layout.pills
        .whereType<Rect>()
        .map((r) => _distance(layout.centre, r))
        .reduce(math.min);
    final fits = !layout.headingAbove;
    return Semantics(
      container: true,
      role: SemanticsRole.menu,
      label: 'Context menu',
      child: Stack(
        key: const ValueKey('radial-menu'),
        children: [
          // A 6 px dot at the true point.
          Positioned(
            left: anchor.dx - 3,
            top: anchor.dy - 3,
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('radial-dot'),
                decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                child: const SizedBox(width: 6, height: 6),
              ),
            ),
          ),
          if (heading != null)
            Positioned.fromRect(
              rect: fits
                  ? Rect.fromCenter(center: layout.centre, width: inner * 1.7, height: inner * 1.4)
                  : Rect.fromLTWH(layout.bounds.left, layout.bounds.top - layout.headingHeight, layout.bounds.width, layout.headingHeight - 4),
              child: Center(child: _heading(context, type, scheme)),
            ),
          for (final (i, e) in slots.indexed)
            if (e != null)
              Positioned.fromRect(
                rect: layout.pills[i]!,
                child: _Pill(
                  entry: e,
                  lit: at == i,
                  outlined: at == i && keyboard,
                  onRun: () => onRun(e),
                  onHover: () => onHover(i),
                  fg: !e.enabled
                      ? colors.textDisabled
                      : e.destructive
                      ? scheme.error
                      : scheme.onSurface,
                  metrics: m,
                ),
              ),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, NotedTypography type, ColorScheme scheme) => Text(
    heading!,
    key: const ValueKey('context-heading'),
    textAlign: TextAlign.center,
    style: type.small.copyWith(color: scheme.onSurfaceVariant),
  );

  static double _distance(Offset p, Rect r) {
    final dx = math.max(math.max(r.left - p.dx, 0.0), p.dx - r.right);
    final dy = math.max(math.max(r.top - p.dy, 0.0), p.dy - r.bottom);
    return math.sqrt(dx * dx + dy * dy);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.entry,
    required this.lit,
    required this.outlined,
    required this.onRun,
    required this.onHover,
    required this.fg,
    required this.metrics,
  });

  final ContextEntry entry;
  final bool lit;
  final bool outlined;
  final VoidCallback onRun;
  final VoidCallback onHover;
  final Color fg;
  final NotedMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = NotedColors.of(context);
    final on = entry.enabled;
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
          key: ValueKey('radial-${entry.command.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: on ? onRun : null,
          child: DecoratedBox(
            key: outlined ? const ValueKey('context-focus') : null,
            decoration: BoxDecoration(
              color: lit && on ? colors.surfaceHover : scheme.surface,
              borderRadius: metrics.borderLg,
              border: Border.all(
                color: outlined ? scheme.primary : scheme.outline,
                width: outlined ? 2 : 1,
              ),
              boxShadow: metrics.shadowPopover,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: metrics.space1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.command.icon, size: metrics.icon, color: fg),
                  SizedBox(width: metrics.space2),
                  Text(
                    entry.text,
                    maxLines: 1,
                    softWrap: false,
                    style: NotedTypography.of(context).label.copyWith(color: fg),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _distanceToRect(Rect r) {
  final dx = math.max(math.max(r.left, 0.0), -r.right);
  final dy = math.max(math.max(r.top, 0.0), -r.bottom);
  return math.sqrt(dx * dx + dy * dy);
}
