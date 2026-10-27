// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_template/noted_box_template.dart';
import 'package:noted_core/noted_core.dart';

import 'fixtures.dart';


void main() {
  const codec = StickyLabelCodec();

  group('codec', () {
    test('describes the type', () {
      expect(codec.typeId, 'noted.template.sticky-label');
      expect(codec.dataVersion, 1);
      expect(codec.apiVersion, boxApiVersion);
      expect(boxApiVersion.canHost(codec.apiVersion), isTrue);
      expect(codec.sizing, BoxSizing.fixed);
      expect(codec.permissions, isEmpty);
    });

    test('creates an empty label', () {
      final d = codec.create();
      expect(d.text, '');
      expect(d.color, defaultStickyLabelColor);
      expect(codec.isEmpty(d), isTrue);
      expect(codec.snapshotText(d), '');
    });

    test('encodes and decodes', () {
      const d = StickyLabelData(text: 'Call Sam', color: 'purple');
      final json = codec.encode(d);
      expect(json, {'text': 'Call Sam', 'color': 'purple'});
      final back = codec.decode(jsonDecode(jsonEncode(json)), 1);
      expect(back.text, 'Call Sam');
      expect(back.color, 'purple');
      expect(codec.snapshotText(back), 'Call Sam');
      expect(codec.isEmpty(back), isFalse);
      expect(codec.isEmpty(const StickyLabelData(text: '  \n')), isTrue);
    });

    test('exposes the text to an AI', () {
      final e = codec.aiExposure(const StickyLabelData(text: 'hi'));
      expect(e, isA<AiText>());
      expect((e as AiText).text, 'hi');
    });

    test('bad data decodes to safe values instead of throwing', () {
      for (final bad in [null, 5, 'x', <Object?>[], true]) {
        final d = codec.decode(bad, 1);
        expect(d.text, '');
        expect(d.color, defaultStickyLabelColor);
      }
      final d = codec.decode({'text': 7, 'color': null, 'k': 1}, 1);
      expect(d.text, '');
      expect(d.color, defaultStickyLabelColor);
      expect(d.extra, {'k': 1});
    });

    test('unknown keys and an unknown colour survive decode and encode', () {
      final json = jsonDecode(futureData);
      final d = codec.decode(json, 1);
      expect(d.extra.keys, containsAll(['pin', 'z']));
      expect(jsonEncode(codec.encode(d)), jsonEncode(codec.encode(d)));
      expect(codec.encode(d), json);

      final odd = codec.decode({'text': 'a', 'color': 'chartreuse'}, 1);
      expect(codec.encode(odd), {'text': 'a', 'color': 'chartreuse'});
      // An edit keeps what it doesn't touch.
      final edited = d.copyWith(text: 'Buy oat milk');
      expect((codec.encode(edited) as Map)['pin'], {
        'x': [1, 2.5],
      });
    });
  });

  group('merge', () {
    const base = StickyLabelData(text: 'a', color: 'blue');

    test('takes the side that changed a field', () {
      final r = codec.merge(
        base,
        base.copyWith(text: 'b'),
        base.copyWith(color: 'green'),
      );
      final merged = (r as Merged<StickyLabelData>).data;
      expect(merged.text, 'b');
      expect(merged.color, 'green');
    });

    test('conflicts when both sides changed a field differently', () {
      final r = codec.merge(
        base,
        base.copyWith(text: 'b'),
        base.copyWith(text: 'c'),
      );
      expect(r, isA<Conflicted<StickyLabelData>>());
    });

    test('keeps unknown keys added on the other side', () {
      final theirs = codec.decode({'text': 'a', 'color': 'blue', 'n': 1}, 1);
      final r = codec.merge(base, base, theirs);
      expect((r as Merged<StickyLabelData>).data.extra, {'n': 1});
    });
  });

  group('page format', () {
    BoxRecord boxOf(NotedPage p) => p.nodes.first as BoxRecord;

    test('a new box survives save and load', () {
      var box = createBox(codec, const Bounds(10, 20, 260, 120));
      box = commitBox(
        box,
        codec,
        const StickyLabelData(text: 'Remember', color: 'orange'),
      );
      final page = NotedPage.create(
        PageMeta.create(id: 'p', title: 'T', order: 0),
      ).insertNode(box);

      final loaded = readPage(writePage(page));
      final record = boxOf(loaded);
      expect(record.typeId, StickyLabelCodec.id);
      expect(record.snapshotText, 'Remember');
      final live = CodecRegistry()..register(codec);
      final resolved = live.resolve(record) as LiveBox;
      final data = resolved.data! as StickyLabelData;
      expect(data.text, 'Remember');
      expect(data.color, 'orange');
    });

    test('unknown data is written back byte-for-byte when untouched', () {
      final source = pageSource();
      expect(writePage(readPage(source)), contains(futureData));
    });

    test('unknown keys survive a commit through the codec', () {
      final page = readPage(pageSource());
      final registry = CodecRegistry()..register(codec);
      final live = registry.resolve(boxOf(page)) as LiveBox;
      final data = (live.data! as StickyLabelData).copyWith(text: 'Edited');
      final next = page.replaceNode(commitBox(boxOf(page), codec, data));
      final out = readPage(writePage(next));
      final stored = jsonDecode(boxOf(out).data!.text) as Map;
      expect(stored['text'], 'Edited');
      expect(stored['color'], 'green');
      expect(stored['pin'], {
        'x': [1, 2.5],
      });
      expect(stored['z'], true);
      expect(boxOf(out).snapshotText, 'Edited');
    });

    test('a newer data version is not opened and not rewritten', () {
      final source = pageSource(version: 2);
      final registry = CodecRegistry()..register(codec);
      final page = readPage(source);
      final r = registry.resolve(boxOf(page));
      expect(r, isA<UnsupportedBox>());
      expect(
        (r as UnsupportedBox).reason,
        UnsupportedReason.newerDataVersion,
      );
      expect(writePage(page), contains(futureData));
    });
  });
}
