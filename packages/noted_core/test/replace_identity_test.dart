// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_cas_id'));
  tearDown(() async => dir.delete(recursive: true));

  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';
  List<String> names() =>
      dir.listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last).toList()..sort();

  group('replaceIfUnchanged with an identity', () {
    test('a matching file is replaced, no leftovers', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7, 8]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1, 2, 3]),
      );
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(File(p('a.bin')).readAsBytesSync(), [7, 8]);
      expect(names(), ['a.bin']);
    });

    test('same length, different bytes (the hash): changed, target untouched', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 4]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1, 2, 3]),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 4]);
      expect(names(), ['a.bin', 'a.tmp']);
    });

    test('a different length: changed, target untouched', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3, 4]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1, 2, 3]),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [1, 2, 3, 4]);
    });

    test('an absent file is changed', () async {
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1]),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(names(), ['a.tmp']);
    });

    test('both expected and identity throw ArgumentError', () async {
      File(p('a.bin')).writeAsBytesSync([1]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      await expectLater(
        replaceIfUnchanged(tmp, p('a.bin'), [1], identity: ContentIdentity.ofBytes([1])),
        throwsArgumentError,
      );
      expect(File(p('a.bin')).readAsBytesSync(), [1]);
    });

    test('the file swapped before the move-aside: the aside compare puts it back', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1, 2, 3]),
        beforeMoveAside: () => File(p('a.bin')).writeAsBytesSync([9, 9, 9]),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(File(p('a.bin')).readAsBytesSync(), [9, 9, 9]);
      expect(names(), ['a.bin', 'a.tmp']);
    });

    test('a newer file at publish: supersededKept', () async {
      File(p('a.bin')).writeAsBytesSync([1, 2, 3]);
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(
        tmp,
        p('a.bin'),
        null,
        identity: ContentIdentity.ofBytes([1, 2, 3]),
        beforePublish: () => File(p('a.bin')).writeAsBytesSync([9, 9]),
      );
      expect(r.outcome, ReplaceOutcome.supersededKept);
      expect(File(p('a.bin')).readAsBytesSync(), [9, 9]);
      expect(File(r.keptPath!).readAsBytesSync(), [1, 2, 3]);
    });

    test('no expectation at all still publishes exclusively', () async {
      final tmp = File(p('a.tmp'))..writeAsBytesSync([7]);
      final r = await replaceIfUnchanged(tmp, p('a.bin'), null);
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(File(p('a.bin')).readAsBytesSync(), [7]);
    });
  });
}
