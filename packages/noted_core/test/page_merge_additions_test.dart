// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A codec whose merge accepts "only added on both sides" (as the note and AI
// boxes do, run 2026-11-01-04): the 3-way page merge must raise no conflict
// when the codec merges, and must when it doesn't. The real note and AI
// codecs are tested in their own packages.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

/// A box holding a list of lines. Merging: each side must be the base lines
/// with lines only inserted (in order); both insertions are kept, mine
/// first. Anything else is a conflict.
class _Lines extends BoxCodec<List<String>> {
  const _Lines();

  @override
  String get typeId => 'test.lines';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  List<String> create() => [];
  @override
  List<String> decode(Object? json, int storedVersion) =>
      (json! as List).cast<String>();
  @override
  Object? encode(List<String> data) => data;
  @override
  String snapshotText(List<String> data) => data.join('\n');
  @override
  AiExposure aiExposure(List<String> data) => AiText(snapshotText(data));

  @override
  MergeResult<List<String>> merge(
    List<String> base,
    List<String> mine,
    List<String> theirs,
  ) {
    bool onlyAdded(List<String> side) {
      var i = 0;
      for (final line in side) {
        if (i < base.length && line == base[i]) i++;
      }
      return i == base.length;
    }

    if (!onlyAdded(mine) || !onlyAdded(theirs)) return const Conflicted();
    final out = [...base];
    for (final line in [...mine, ...theirs]) {
      if (!out.contains(line)) out.add(line);
    }
    return Merged(out);
  }
}

const _codec = _Lines();

CodecRegistry registry() => CodecRegistry()..register(_codec);

BoxRecord box(List<String> lines) => BoxRecord.create(
  id: 'n',
  typeId: _codec.typeId,
  dataVersion: 1,
  bounds: const Bounds(0, 0, 100, 50),
  data: RawJson.encode(lines),
  snapshotText: _codec.snapshotText(lines),
  rev: 'r0',
);

NotedPage pageOf(BoxRecord b) =>
    NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0)).insertNode(b);

List<String> linesOf(PageMerge r) =>
    (jsonDecode(jsonEncode((r.page.node('n')! as BoxRecord).data!.decode()))
            as List)
        .cast<String>();

void main() {
  final baseBox = box(['a', 'b']);
  final base = pageOf(baseBox);
  NotedPage edited(List<String> lines) =>
      pageOf(commitBox(baseBox, _codec, lines));

  PageMerge merge(NotedPage mine, NotedPage theirs) =>
      mergePage(base, mine, theirs, registry(), theirsTime: 7);

  test('both sides added: merged, no conflict, nothing recorded', () {
    final r = merge(edited(['a', 'b', 'mine']), edited(['a', 'x', 'b']));
    expect(r.conflictedIds, isEmpty);
    expect(linesOf(r), ['a', 'b', 'mine', 'x']);
    final n = r.page.node('n')! as BoxRecord;
    expect(n.conflicts, isEmpty);
    expect(n.isConflicted, isFalse);
    expect(n.snapshotText, 'a\nb\nmine\nx');
  });

  test('the merge is a new revision, so the next sync sees a change', () {
    final mine = edited(['a', 'b', 'm']);
    final theirs = edited(['a', 'b', 't']);
    final r = merge(mine, theirs);
    final rev = (r.page.node('n')! as BoxRecord).rev;
    expect(rev, isNot((mine.node('n')! as BoxRecord).rev));
    expect(rev, isNot((theirs.node('n')! as BoxRecord).rev));
  });

  test('both sides added and the merge is stable when repeated', () {
    final r = merge(edited(['a', 'b', 'm']), edited(['a', 'b', 't']));
    // Merging the result again with the same theirs adds nothing new.
    final again = mergePage(
      base,
      r.page,
      edited(['a', 'b', 't']),
      registry(),
      theirsTime: 8,
    );
    expect(again.conflictedIds, isEmpty);
    expect(linesOf(again), ['a', 'b', 'm', 't']);
  });

  test('an edit on one side and an addition on the other is a conflict', () {
    final r = merge(edited(['a', 'B']), edited(['a', 'b', 'x']));
    expect(r.conflictedIds, {'n'});
    final n = r.page.node('n')! as BoxRecord;
    expect(n.isConflicted, isTrue);
    expect(n.conflicts, hasLength(1));
    expect(linesOf(r), ['a', 'B']); // mine kept
  });

  test('a deletion on one side and an addition on the other is a conflict',
      () {
    final r = merge(edited(['a']), edited(['a', 'b', 'x']));
    expect(r.conflictedIds, {'n'});
  });

  test('an addition on one side and the box removed on the other is a '
      'delete conflict', () {
    final r = merge(
      edited(['a', 'b', 'm']),
      NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0)),
    );
    expect(r.conflictedIds, {'n'});
  });
}
