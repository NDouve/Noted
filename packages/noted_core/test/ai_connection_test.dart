// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  const id = '0123456789abcdef';
  final key = 'A' * 43;

  test('a token splits into id and key; malformed ones are null', () {
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

  test('connections are read from settings, tolerating bad entries', () {
    expect(readAiConnections(null), isEmpty);
    expect(readAiConnections({'aiConnections': 3}), isEmpty);
    expect(
      readAiConnections({
        'aiConnections': [
          {'id': id, 'name': 'Claude', 'hash': 'zz', 'created': 1700000000000},
          {'id': 'short', 'name': 'bad'},
          {'id': id, 'name': 'duplicate'},
          'junk',
          {'id': 'fedcba9876543210'},
        ],
      }),
      [
        const AiConnectionInfo(id: id, name: 'Claude', createdAt: 1700000000000),
        const AiConnectionInfo(id: 'fedcba9876543210', name: '', createdAt: 0),
      ],
    );
  });
}
