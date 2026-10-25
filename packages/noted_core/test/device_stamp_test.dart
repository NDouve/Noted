// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec();
  @override
  String get typeId => 'test.text';
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

const _codec = _Codec();

NotedPage _page(List<CanvasNode> nodes) {
  var p = NotedPage.create(PageMeta.create(id: 'p', title: 'T', order: 0));
  for (final n in nodes) {
    p = p.insertNode(n);
  }
  return p;
}

void main() {
  test('createBox and commitBox stamp device and time', () {
    final b = createBox(_codec, const Bounds(0, 0, 100, 40), device: 'PC-1', at: 1000);
    expect(b.device, 'PC-1');
    expect(b.editedAt, 1000);
    final c = commitBox(b, _codec, 'x', device: 'PC-2', at: 2000);
    expect(c.device, 'PC-2');
    expect(c.editedAt, 2000);
    expect(c.baseRev, b.rev);
  });

  test('without a stamp the header has no device or time', () {
    final b = createBox(_codec, const Bounds(0, 0, 100, 40));
    expect(b.device, isNull);
    expect(b.editedAt, isNull);
    final stamped = commitBox(b, _codec, 'x', device: 'PC', at: 5);
    final plain = commitBox(stamped, _codec, 'y');
    expect(plain.device, isNull);
    expect(plain.editedAt, isNull);
  });

  test('the stamp survives a write and read, and nothing else changes', () {
    final b = commitBox(
      createBox(_codec, const Bounds(0, 0, 100, 40), device: 'Ünï "PC"', at: 7),
      _codec,
      'hello',
      device: 'Ünï "PC"',
      at: 8,
    );
    final text = writePage(_page([b]));
    final back = readPage(text).node(b.id)! as BoxRecord;
    expect(back.device, 'Ünï "PC"');
    expect(back.editedAt, 8);
    expect(writePage(readPage(text)), text);
    expect(
      back.noted.entries.map((e) => e.$1),
      containsAll(['type', 'v', 'rev', 'data', 'device', 'at']),
    );
  });

  test('a box without a stamp reads as unknown and round-trips', () {
    final b = createBox(_codec, const Bounds(0, 0, 100, 40));
    final text = writePage(_page([b]));
    final back = readPage(text).node(b.id)! as BoxRecord;
    expect(back.device, isNull);
    expect(back.editedAt, isNull);
    expect(writePage(readPage(text)), text);
  });

  test('a conflict entry records the device and reads back', () {
    final c = BoxConflict.other(
      node: const RawJson.trusted('{"id":"a"}'),
      at: 5,
      device: 'PC-2',
    );
    expect(c.raw.text, '{"node":{"id":"a"},"at":5,"device":"PC-2"}');
    final back = BoxConflict.tryRead(c.raw)!;
    expect(back.device, 'PC-2');
    expect(back.at, 5);
  });

  test('an old conflict entry without a device still reads', () {
    final c = BoxConflict.tryRead(
      const RawJson.trusted('{"node":{"id":"a"},"at":5}'),
    )!;
    expect(c.device, isNull);
    expect(c.at, 5);
    expect(c.raw.text, '{"node":{"id":"a"},"at":5}');
    expect(
      BoxConflict.other(node: const RawJson.trusted('{"id":"a"}'), at: 5).raw.text,
      '{"node":{"id":"a"},"at":5}',
    );
    expect(BoxConflict.deleted(at: 3).device, isNull);
  });

  test("mergePage stores the other version's device with the conflict", () {
    final codecs = CodecRegistry()..register(_codec);
    final a = createBox(_codec, const Bounds(0, 0, 100, 40), device: 'PC-1', at: 1);
    final base = _page([a]);
    final mine = base.replaceNode(commitBox(a, _codec, 'mine', device: 'PC-1', at: 2));
    final theirs = base.replaceNode(commitBox(a, _codec, 'theirs', device: 'PC-2', at: 3));
    final r = mergePage(base, mine, theirs, codecs, theirsTime: 99);
    final m = r.page.node(a.id)! as BoxRecord;
    expect(m.conflicts.single.device, 'PC-2');
    expect(m.conflicts.single.at, 99);
    expect(m.device, 'PC-1');

    final theirs2 = base.replaceNode(commitBox(a, _codec, 'theirs'));
    final m2 = mergePage(base, mine, theirs2, codecs, theirsTime: 99)
        .page
        .node(a.id)! as BoxRecord;
    expect(m2.conflicts.single.device, isNull);
    expect(m2.conflicts.single.raw.text.contains('device'), isFalse);
  });
}
