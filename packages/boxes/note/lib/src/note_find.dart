// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:noted_core/noted_core.dart';

import 'note_codec.dart';

/// Find on page inside a note (Box API 0.6): where the matches are in the
/// blocks of the note's document.
///
/// The matches are found in the note's own text snapshot with the query the
/// canvas passes in ([BoxFind]); [snapshotParts] says which block each piece
/// of the snapshot came from, so a match maps to a block and an offset in
/// it. Nothing here touches the saved data.
final class NoteFind {
  NoteFind._(this._hits, this._partText);

  /// Builds the model for [data], or returns null if the note doesn't match
  /// (a note matches when it holds every term of the query).
  static NoteFind? build(NoteData data, BoxFind find, String boxId) {
    final parts = snapshotParts(data);
    final snapshot = parts.map((p) => p.text).join();
    final ranges = find.query.rangesIn(snapshot);
    if (ranges == null) return null;
    final current = find.currentBoxId == boxId ? find.currentOccurrence : -1;
    final hits = <String, List<NoteFindHit>>{};
    final partText = <String, String>{};
    var offset = 0;
    var next = 0;
    for (final part in parts) {
      final start = offset;
      final end = offset + part.text.length;
      offset = end;
      final path = part.path;
      if (path == null) continue;
      final key = path.join('.');
      partText[key] = part.text;
      while (next < ranges.length && ranges[next].start < end) {
        final r = ranges[next];
        if (r.start >= start) {
          (hits[key] ??= []).add(
            NoteFindHit(
              r.start - start,
              (r.end > end ? end : r.end) - start,
              current: next == current,
            ),
          );
        }
        next++;
      }
    }
    return NoteFind._(hits, partText);
  }

  final Map<String, List<NoteFindHit>> _hits;
  final Map<String, String> _partText;

  /// The matches in the block [node], in the snapshot text of that block;
  /// null if there are none.
  List<NoteFindHit>? hitsFor(Node node) => _hits[node.path.join('.')];

  /// The block's text as it appears in the snapshot.
  String? snapshotTextOf(Node node) => _partText[node.path.join('.')];

  /// Whether any block has a match.
  bool get isEmpty => _hits.isEmpty;
}

/// A match inside one block's snapshot text.
final class NoteFindHit {
  const NoteFindHit(this.start, this.end, {required this.current});

  final int start;
  final int end;

  /// This is the match Find on page is on.
  final bool current;
}

/// Gives the blocks of one note its [NoteFind]. Blocks that read it are
/// rebuilt when it changes.
class NoteFindScope extends InheritedWidget {
  const NoteFindScope({super.key, required this.find, required super.child});

  final NoteFind? find;

  /// The model in effect at [context] (which then depends on it), or null.
  static NoteFind? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteFindScope>()?.find;

  @override
  bool updateShouldNotify(NoteFindScope oldWidget) => oldWidget.find != find;
}

/// The colors of a find highlight: the current match, and the others.
/// They come from the theme's color scheme (the tertiary roles), so they
/// follow light and dark.
({Color background, Color foreground}) findColors(
  BuildContext context, {
  required bool current,
}) {
  final scheme = Theme.of(context).colorScheme;
  return current
      ? (background: scheme.tertiary, foreground: scheme.onTertiary)
      : (
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
        );
}

/// The highlight behind an equation (inline or block) whose source matches:
/// the container color, with an outline on the current match. The math keeps
/// its own text color, so the fill is the light one in both cases.
BoxDecoration equationFindDecoration(
  BuildContext context, {
  required bool current,
  double radius = 3,
}) {
  final scheme = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: scheme.tertiaryContainer,
    borderRadius: BorderRadius.circular(radius),
    border: current ? Border.all(color: scheme.tertiary, width: 2) : null,
  );
}

/// Where the text op that starts at delta offset [deltaOffset] starts in the
/// snapshot text of the block: a plain op is as long as its text; an
/// equation op is its formula between dollar signs.
int snapshotOffsetOf(Delta delta, int deltaOffset) {
  var d = 0;
  var s = 0;
  for (final op in delta) {
    if (d >= deltaOffset) break;
    if (op is TextInsert) {
      final f = op.attributes?[NoteFormat.formulaKey];
      s += f is String ? f.length + 2 : op.text.length;
    }
    d += op.length;
  }
  return s;
}

/// Marks the matches of the note's find in text: splits a plain run into
/// pieces with the match highlighted, and puts a highlight behind an inline
/// equation whose source matches. [inner] makes the run's span first
/// (equations, links, formula values).
TextSpanDecoratorForAttribute findSpanDecorator(
  TextSpanDecoratorForAttribute inner,
) => (context, node, index, text, before, after) {
  final span = inner(context, node, index, text, before, after);
  if (!context.mounted) return span;
  final model = NoteFindScope.of(context);
  final hits = model?.hitsFor(node);
  final delta = node.delta;
  if (model == null || hits == null || delta == null) return span;

  final runStart = snapshotOffsetOf(delta, index);
  final formula = text.attributes?[NoteFormat.formulaKey];
  if (formula is String) {
    // An inline equation: its source is `$formula$` in the snapshot.
    final runEnd = runStart + formula.length + 2;
    final hit = hits.where((h) => h.start < runEnd && h.end > runStart);
    if (hit.isEmpty || span is! TextSpan || span.children == null) return span;
    final current = hit.any((h) => h.current);
    return TextSpan(
      children: [
        for (final child in span.children!)
          if (child is WidgetSpan)
            WidgetSpan(
              alignment: child.alignment,
              baseline: child.baseline,
              child: DecoratedBox(
                key: ValueKey(
                  current ? 'find-math-current' : 'find-math-match',
                ),
                decoration: equationFindDecoration(context, current: current),
                child: child.child,
              ),
            )
          else
            child,
      ],
    );
  }

  // Plain text. The span must be the text itself; and the block's snapshot
  // must show these characters at this place (it doesn't for a formula cell,
  // which shows its value).
  if (span is! TextSpan || span.children != null || span.text != text.text) {
    return span;
  }
  final runEnd = runStart + text.text.length;
  final shown = model.snapshotTextOf(node);
  if (shown == null ||
      runEnd > shown.length ||
      shown.substring(runStart, runEnd) != text.text) {
    return span;
  }
  final inRun = [
    for (final h in hits)
      if (h.end > runStart && h.start < runEnd) h,
  ];
  if (inRun.isEmpty) return span;

  final pieces = <InlineSpan>[];
  var at = runStart;
  TextSpan piece(String s, {NoteFindHit? hit}) {
    final colors = hit == null
        ? null
        : findColors(context, current: hit.current);
    return TextSpan(
      text: s,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      style: colors == null
          ? span.style
          : (span.style ?? const TextStyle()).copyWith(
              backgroundColor: colors.background,
              color: colors.foreground,
            ),
    );
  }

  String slice(int from, int to) =>
      text.text.substring(from - runStart, to - runStart);
  for (final h in inRun) {
    final s = h.start < runStart ? runStart : h.start;
    final e = h.end > runEnd ? runEnd : h.end;
    if (s > at) pieces.add(piece(slice(at, s)));
    pieces.add(piece(slice(s, e), hit: h));
    at = e;
  }
  if (at < runEnd) pieces.add(piece(slice(at, runEnd)));
  return TextSpan(children: pieces, style: null);
};
