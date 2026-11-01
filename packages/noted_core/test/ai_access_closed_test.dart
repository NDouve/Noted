// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory dir;
  late File file;
  late AiAccessStore store;
  final now = DateTime.utc(2026, 11, 1, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noted_ai_closed_');
    file = File('${dir.path}/$aiAccessFileName');
    store = AiAccessStore(file);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> onDisk() => jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  group('approved on the code', () {
    test('a new code is not approved; approving sets the time once and it is kept', () {
      final c = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.writer, label: 'x', now: now);
      expect(c.record.isApproved, isFalse);
      expect(store.codes().single.approved, isNull);
      store.approveCode(c.record.id, now: now);
      expect(store.codes().single.approved, now);
      expect(store.codes().single.isApproved, isTrue);
      // A second approval keeps the first time.
      store.approveCode(c.record.id, now: now.add(const Duration(days: 1)));
      expect(store.codes().single.approved, now);
      // Using the code later doesn't lose it.
      store.recordUse(c.record.id, now: now.add(const Duration(days: 2)));
      expect(store.codes().single.approved, now);
      expect((onDisk()['codes'] as List).single['approved'], '2026-11-01T12:00:00.000Z');
      // Verifying still gives the code, approved.
      expect(store.verify(c.code, now: now).code!.isApproved, isTrue);
    });

    test('approving an unknown code does nothing', () {
      store.approveCode('0123456789abcdef');
      expect(store.codes(), isEmpty);
    });

    test('old sessions are kept as written and decide nothing', () {
      final c = store.issue(target: const AiCodeTarget.box('b'), role: AiCodeRole.writer, label: 'x', now: now);
      store.addSession(c.record.id, AiCodeSession(id: 's1', app: 'Claude Code', approved: now));
      expect(store.codes().single.isApproved, isFalse);
      store.approveCode(c.record.id, now: now);
      expect((onDisk()['codes'] as List).single['sessions'], hasLength(1));
    });

    test('a stored approved parses, rewrites, and a bad one counts as not approved but is kept', () {
      const base = {
        'id': '0123456789abcdef',
        'target': {'kind': 'box', 'id': 'b'},
        'role': 'writer',
        'label': 'L',
        'hash': 'h',
        'created': '2026-01-01T00:00:00.000Z',
      };
      final good = AiCode.fromJson({...base, 'approved': '2026-02-03T04:05:06Z'})!;
      expect(good.approved, DateTime.utc(2026, 2, 3, 4, 5, 6));
      expect(good.toJson()['approved'], '2026-02-03T04:05:06.000Z');
      final bad = AiCode.fromJson({...base, 'approved': 'yesterday'})!;
      expect(bad.isApproved, isFalse);
      expect(bad.toJson()['approved'], 'yesterday');
      expect(bad.copyWith(lastUsed: now).toJson()['approved'], 'yesterday');
      expect(bad.copyWith(approved: now).toJson()['approved'], '2026-11-01T12:00:00.000Z');
      expect(AiCode.fromJson(base)!.toJson()['approved'], isNull);
      expect(good.withExpires(now).approved, good.approved);
    });
  });

  group('Writer permission', () {
    test('append is the default and an unknown value reads as append', () {
      expect(AiWriterPermission.fromWire(null), AiWriterPermission.append);
      expect(AiWriterPermission.fromWire('root'), AiWriterPermission.append);
      expect(AiWriterPermission.fromWire(5), AiWriterPermission.append);
      expect(AiWriterPermission.fromWire('edit'), AiWriterPermission.edit);
      expect(AiWriterPermission.fromWire('full'), AiWriterPermission.full);
      expect(store.writerPermission('b'), AiWriterPermission.append);
    });

    test('append allows append; edit adds replace_ai; full adds replace', () {
      const modes = AiLinkMode.values;
      Set<AiLinkMode> allowed(AiWriterPermission p) => {for (final m in modes) if (p.allows(m)) m};
      expect(allowed(AiWriterPermission.append), {AiLinkMode.append});
      expect(allowed(AiWriterPermission.edit), {AiLinkMode.append, AiLinkMode.replaceAi});
      expect(allowed(AiWriterPermission.full), {AiLinkMode.append, AiLinkMode.replaceAi, AiLinkMode.replace});
    });

    test('set and read per box; append removes the key; other settings stay', () {
      store.setAskBeforeWrite('b', true);
      store.setWriterPermission('b', AiWriterPermission.edit);
      store.setWriterPermission('c', AiWriterPermission.full);
      expect(store.writerPermission('b'), AiWriterPermission.edit);
      expect(store.writerPermission('c'), AiWriterPermission.full);
      expect(store.writerPermission('other'), AiWriterPermission.append);
      expect((onDisk()['boxes'] as Map)['b'], {'askBeforeWrite': true, 'writerPermission': 'edit'});
      store.setWriterPermission('b', AiWriterPermission.append);
      expect((onDisk()['boxes'] as Map)['b'], {'askBeforeWrite': true});
      store.setWriterPermission('c', AiWriterPermission.append);
      expect((onDisk()['boxes'] as Map).containsKey('c'), isFalse);
    });

    test('an unknown stored value and an unreadable file read as append', () {
      file.writeAsStringSync(jsonEncode({
        'format': 1,
        'boxes': {
          'b': {'writerPermission': 'superuser'},
        },
      }));
      expect(store.writerPermission('b'), AiWriterPermission.append);
      file.writeAsStringSync('nope');
      expect(store.writerPermission('b'), AiWriterPermission.append);
    });
  });

  group('closed-app writes', () {
    test('off by default, set per box, and off is removed', () {
      expect(store.closedWrites('b'), isFalse);
      store.setClosedWrites('b', true);
      expect(store.closedWrites('b'), isTrue);
      expect(store.closedWrites('other'), isFalse);
      expect((onDisk()['boxes'] as Map)['b'], {'closedWrites': true});
      store.setClosedWrites('b', false);
      expect(onDisk().containsKey('boxes'), isFalse);
    });

    test('never effective while the box asks before each write, but the switch is kept', () {
      store.setClosedWrites('b', true);
      store.setAskBeforeWrite('b', true);
      expect(store.closedWrites('b'), isFalse);
      expect((onDisk()['boxes'] as Map)['b'], {'closedWrites': true, 'askBeforeWrite': true});
      store.setAskBeforeWrite('b', false);
      expect(store.closedWrites('b'), isTrue);
    });

    test('a stored closedWrites true with askBeforeWrite true reads as false, through the view and the store', () {
      file.writeAsStringSync(jsonEncode({
        'format': 1,
        'boxes': {
          'b': {'closedWrites': true, 'askBeforeWrite': true},
        },
      }));
      expect(AiAccessView.parse(file.readAsStringSync()).closedWrites('b'), isFalse);
      expect(store.closedWrites('b'), isFalse);
      expect(store.read().closedWrites('b'), isFalse);
    });

    test('only a true value counts; an unreadable file reads as false', () {
      file.writeAsStringSync(jsonEncode({
        'format': 1,
        'boxes': {
          'b': {'closedWrites': 'yes'},
          'c': {'closedWrites': 1},
        },
      }));
      expect(store.closedWrites('b'), isFalse);
      expect(store.closedWrites('c'), isFalse);
      file.writeAsStringSync('nope');
      expect(store.closedWrites('b'), isFalse);
    });
  });

  group('the read-only view', () {
    test('parses the file text, verifies a code by hash and reports approval', () {
      final c = store.issue(
        target: const AiCodeTarget.box('b'),
        role: AiCodeRole.writer,
        label: 'x',
        expires: now.add(const Duration(days: 1)),
        now: now,
      );
      store.approveCode(c.record.id, now: now);
      store.setWriterPermission('b', AiWriterPermission.edit);
      store.setClosedWrites('b', true);
      final view = AiAccessView.parse(file.readAsStringSync());
      final verdict = view.verify(c.code, now);
      expect(verdict.ok, isTrue);
      expect(verdict.code!.isApproved, isTrue);
      expect(verdict.code!.canWriteBox, isTrue);
      expect(view.verify(c.code, now.add(const Duration(days: 2))).failure, AiCodeFailure.expired);
      expect(view.verify('${c.code}x', now).failure, AiCodeFailure.badCode);
      final wrongKey = 'noted_${c.record.id}_${'A' * 43}';
      expect(view.verify(wrongKey, now).failure, AiCodeFailure.badCode);
      expect(view.writerPermission('b'), AiWriterPermission.edit);
      expect(view.closedWrites('b'), isTrue);
      expect(view.askBeforeWrite('b'), isFalse);
      expect(view.code(c.record.id)!.label, 'x');
      expect(view.codes, hasLength(1));
    });

    test('an empty view has no codes; bad text is unreadable', () {
      final view = AiAccessView.empty();
      expect(view.codes, isEmpty);
      expect(view.closedWrites('b'), isFalse);
      expect(view.writerPermission('b'), AiWriterPermission.append);
      expect(() => AiAccessView.parse('nope'), throwsA(isA<AiAccessUnreadable>()));
      expect(() => AiAccessView.parse('{"format":2}'), throwsA(isA<AiAccessUnreadable>()));
      expect(() => AiAccessView.parse('{"format":1,"boxes":[]}'), throwsA(isA<AiAccessUnreadable>()));
    });

    test('the hash helpers are the SHA-256 of the key, compared in constant time', () {
      // sha256('abc')
      const abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
      expect(aiKeyHash('abc'), abc);
      expect(aiKeyMatches('abc', abc), isTrue);
      expect(aiKeyMatches('abc', abc.toUpperCase()), isTrue);
      expect(aiKeyMatches('abd', abc), isFalse);
      expect(aiKeyMatches('abc', ''), isFalse);
    });
  });
}
