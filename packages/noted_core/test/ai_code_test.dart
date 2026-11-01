// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  const id = '0123456789abcdef';
  final key = 'A' * 43;
  final now = DateTime.utc(2026, 11, 1, 12);

  test('a code splits into id and key; malformed ones are null', () {
    expect(parseAiToken('noted_${id}_$key'), (id: id, key: key));
    expect(parseAiToken('  noted_${id}_$key\r\n'), (id: id, key: key));
    expect(parseAiToken('noted_${id}_${'a-_Z0' * 8}abc'), isNotNull);
    for (final bad in [
      '',
      'noted_',
      'noted_${id}_',
      'noted_${id}_${'A' * 42}',
      'noted_${id}_${'A' * 44}',
      'noted_${id}_${'A' * 42}=',
      'noted_${id.toUpperCase()}_$key',
      'noted_${id.substring(1)}_$key',
      'noted_${id}x$key',
      'token_${id}_$key',
      'noted_${id}_$key extra',
    ]) {
      expect(parseAiToken(bad), isNull, reason: bad);
    }
    expect(isAiCodeId(id), isTrue);
    expect(isAiCodeId('short'), isFalse);
  });

  test('new tokens parse, are unique, and match their hash only', () {
    final a = newAiToken();
    final b = newAiToken();
    final parsed = parseAiToken(a.token)!;
    expect(parsed.id, a.id);
    expect(a.token, isNot(b.token));
    expect(a.hash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(aiKeyMatches(parsed.key, a.hash), isTrue);
    expect(aiKeyMatches(parsed.key, b.hash), isFalse);
    expect(aiKeyMatches(parsed.key, ''), isFalse);
    expect(aiKeyMatches(parsed.key, a.hash.substring(1)), isFalse);
    expect(aiKeyHash(parsed.key), a.hash);
    expect(aiKeyHash('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('issuing returns the one-time code and a record that keeps only the hash', () {
    final codes = <AiCode>[];
    final issued = issueAiCode(
      codes,
      target: const AiCodeTarget.box('b1', page: 'p1'),
      role: AiCodeRole.writer,
      label: 'Feedback',
      now: now,
    );
    final parsed = parseAiToken(issued.code)!;
    expect(issued.record.id, parsed.id);
    expect(issued.record.hash, aiKeyHash(parsed.key));
    expect(issued.record.toJson().toString(), isNot(contains(parsed.key)));
    expect(issued.record.created, now);
    expect(issued.record.label, 'Feedback');
    expect(issued.record.target.page, 'p1');
    expect(issued.record.role, AiCodeRole.writer);
    expect(issued.record.canWriteBox, isTrue);
    expect(issued.record.canRead, isTrue);
    expect(codes, [issued.record]);
  });

  test('a Writer is for a box only; Readers can target a box, a page or a binder', () {
    final codes = <AiCode>[];
    for (final t in [const AiCodeTarget.page('p'), const AiCodeTarget.binder('bd')]) {
      expect(
        () => issueAiCode(codes, target: t, role: AiCodeRole.writer, label: 'x'),
        throwsArgumentError,
      );
      final r = issueAiCode(codes, target: t, role: AiCodeRole.reader, label: 'r');
      expect(r.record.canRead, isTrue);
      expect(r.record.canWriteBox, isFalse);
    }
    final box = issueAiCode(codes, target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'r');
    expect(box.record.canWriteBox, isFalse);
    expect(
      () => issueAiCode(codes, target: const AiCodeTarget(kindName: 'folder', id: 'f'), role: AiCodeRole.reader, label: 'x'),
      throwsArgumentError,
    );
  });

  test('a new Writer for a box retires the old one; Readers and other boxes stay', () {
    final codes = <AiCode>[];
    const box = AiCodeTarget.box('b1');
    final w1 = issueAiCode(codes, target: box, role: AiCodeRole.writer, label: 'one');
    final reader = issueAiCode(codes, target: box, role: AiCodeRole.reader, label: 'reader');
    final other = issueAiCode(codes, target: const AiCodeTarget.box('b2'), role: AiCodeRole.writer, label: 'other');
    expect(w1.retired, isEmpty);
    final w2 = issueAiCode(codes, target: box, role: AiCodeRole.writer, label: 'two');
    expect(w2.retired, [w1.record.id]);
    // The old one stays, marked revoked, so its history is kept.
    expect(codes.map((c) => c.id), [w1.record.id, reader.record.id, other.record.id, w2.record.id]);
    expect(codes.first.isRevoked, isTrue);
    expect(codes.where((c) => c.isRevoked), hasLength(1));
    // The old code no longer verifies.
    expect(verifyAiCode(w1.code, codes, now).failure, AiCodeFailure.badCode);
    expect(verifyAiCode(w2.code, codes, now).ok, isTrue);
    // A third Writer retires only the live one.
    final w3 = issueAiCode(codes, target: box, role: AiCodeRole.writer, label: 'three');
    expect(w3.retired, [w2.record.id]);
    expect(codes.where((c) => c.isRevoked), hasLength(2));
  });

  test('verification: shape, unknown id, wrong key, expiry', () {
    final codes = <AiCode>[];
    final live = issueAiCode(codes, target: const AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'a');
    final timed = issueAiCode(
      codes,
      target: const AiCodeTarget.box('c'),
      role: AiCodeRole.reader,
      label: 'b',
      expires: now.add(const Duration(hours: 1)),
      now: now,
    );
    expect(verifyAiCode(live.code, codes, now).code, live.record);
    expect(verifyAiCode('  ${live.code}\n', codes, now).ok, isTrue);
    expect(verifyAiCode('garbage', codes, now).failure, AiCodeFailure.badCode);
    expect(verifyAiCode('noted_${id}_$key', codes, now).failure, AiCodeFailure.badCode);
    final wrongKey = 'noted_${live.record.id}_$key';
    expect(verifyAiCode(wrongKey, codes, now).failure, AiCodeFailure.badCode);
    expect(verifyAiCode(timed.code, codes, now).ok, isTrue);
    expect(verifyAiCode(timed.code, codes, now.add(const Duration(minutes: 59))).ok, isTrue);
    expect(verifyAiCode(timed.code, codes, now.add(const Duration(hours: 1))).failure, AiCodeFailure.expired);
    expect(verifyAiCode(timed.code, codes, now.add(const Duration(days: 2))).failure, AiCodeFailure.expired);
    // Expiry is only reported to a holder of the key.
    expect(verifyAiCode('noted_${timed.record.id}_$key', codes, now.add(const Duration(days: 2))).failure, AiCodeFailure.badCode);
    expect(live.record.isExpired(now.add(const Duration(days: 9999))), isFalse);
  });

  test('an unknown role is kept, verifies as a code, and grants nothing', () {
    final json = {
      'id': id,
      'target': {'kind': 'page', 'id': 'p'},
      'role': 'organize',
      'label': 'Future',
      'hash': aiKeyHash(key),
      'created': now.toIso8601String(),
      'newField': [1, 2],
    };
    final c = AiCode.fromJson(json)!;
    expect(c.role, isNull);
    expect(c.roleName, 'organize');
    expect(c.canRead, isFalse);
    expect(c.canWriteBox, isFalse);
    expect(verifyAiCode('noted_${id}_$key', [c], now).ok, isTrue);
    expect(c.toJson()['role'], 'organize');
    expect(c.toJson()['newField'], [1, 2]);
  });

  test('unparseable times are kept as written; a bad expires counts as expired', () {
    final c = AiCode.fromJson({
      'id': id,
      'target': {'kind': 'box', 'id': 'b'},
      'role': 'reader',
      'hash': aiKeyHash(key),
      'created': 'yesterday-ish',
      'lastUsed': 12345,
      'expires': 'next week',
    })!;
    expect(c.isExpired(now), isTrue);
    expect(verifyAiCode('noted_${id}_$key', [c], now).failure, AiCodeFailure.expired);
    var json = c.toJson();
    expect(json['created'], 'yesterday-ish');
    expect(json['lastUsed'], 12345);
    expect(json['expires'], 'next week');
    // Using the code replaces only lastUsed; the rest stays as written.
    json = c.copyWith(lastUsed: now).toJson();
    expect(json['lastUsed'], now.toIso8601String());
    expect(json['created'], 'yesterday-ish');
    expect(json['expires'], 'next week');
    // Setting an expiry replaces the bad one.
    final fixed = c.withExpires(now.add(const Duration(days: 1)));
    expect(fixed.isExpired(now), isFalse);
    expect(fixed.toJson()['expires'], now.add(const Duration(days: 1)).toIso8601String());
    // Null times stay null and are not "present".
    final plain = AiCode.fromJson({
      'id': id,
      'target': {'kind': 'box', 'id': 'b'},
      'hash': 'h',
      'created': now.toIso8601String(),
      'expires': null,
    })!;
    expect(plain.isExpired(now), isFalse);
    expect(plain.toJson()['expires'], isNull);
  });

  test('a revoked code is kept, rewritten as written and rejected as bad_code', () {
    Map<String, Object?> stored(Object? revoked) => {
      'id': id,
      'target': {'kind': 'box', 'id': 'b'},
      'role': 'reader',
      'hash': aiKeyHash(key),
      'created': now.toIso8601String(),
      'revoked': ?revoked,
    };
    final live = AiCode.fromJson(stored(null))!;
    expect(live.isRevoked, isFalse);
    expect(live.toJson().containsKey('revoked'), isFalse);
    final at = DateTime.utc(2026, 3, 4, 5);
    final c = AiCode.fromJson(stored(at.toIso8601String()))!;
    expect(c.isRevoked, isTrue);
    expect(c.revoked, at);
    expect(c.toJson()['revoked'], at.toIso8601String());
    expect(c.copyWith(lastUsed: now).revoked, at);
    expect(c.withExpires(null).revoked, at);
    expect(verifyAiCode('noted_${id}_$key', [c], now).failure, AiCodeFailure.badCode);
    expect(verifyAiCode('noted_${id}_$key', [live], now).ok, isTrue);
    // A revoked code with a time that does not parse is still revoked, as written.
    final odd = AiCode.fromJson(stored('last tuesday'))!;
    expect(odd.isRevoked, isTrue);
    expect(odd.toJson()['revoked'], 'last tuesday');
    expect(verifyAiCode('noted_${id}_$key', [odd], now).failure, AiCodeFailure.badCode);
    // Revoked beats expired: the holder learns nothing beyond bad_code.
    final both = AiCode.fromJson({...stored(at.toIso8601String()), 'expires': '2000-01-01T00:00:00Z'})!;
    expect(verifyAiCode('noted_${id}_$key', [both], now).failure, AiCodeFailure.badCode);
  });

  test('a code with an unknown target kind grants nothing', () {
    final c = AiCode.fromJson({
      'id': id,
      'target': {'kind': 'folder', 'id': 'f'},
      'role': 'reader',
      'hash': 'h',
      'created': now.toIso8601String(),
    })!;
    expect(c.target.kind, isNull);
    expect(c.canRead, isFalse);
  });

  test('entries without an id, a hash or a target are not codes', () {
    expect(AiCode.fromJson('x'), isNull);
    expect(AiCode.fromJson({'id': id, 'hash': 'h'}), isNull);
    expect(AiCode.fromJson({'id': 'bad', 'hash': 'h', 'target': {'kind': 'box', 'id': 'b'}}), isNull);
    expect(AiCode.fromJson({'id': id, 'target': {'kind': 'box', 'id': 'b'}}), isNull);
  });
}
