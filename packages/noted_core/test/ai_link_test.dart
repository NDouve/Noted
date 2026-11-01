// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  test('the port comes from the link file', () {
    expect(aiLinkFileName, 'ai-link.json');
    expect(readAiLink('{"format":1,"port":5123,"pid":42,"nonce":"abc"}'), (port: 5123, nonce: 'abc'));
    expect(readAiLink('{"format":1,"port":5123,"pid":42}'), isNull, reason: 'no nonce');
    expect(readAiLink('{"format":1,"port":5123,"nonce":""}'), isNull);
    expect(readAiLink('{"format":2,"port":5123,"nonce":"a"}'), isNull);
    expect(readAiLink('{"format":1,"port":"5123","nonce":"a"}'), isNull);
    expect(readAiLink('{"format":1,"port":0,"nonce":"a"}'), isNull);
    expect(readAiLink('{"format":1,"port":70000,"nonce":"a"}'), isNull);
    expect(readAiLink('not json'), isNull);
    expect(readAiLink(''), isNull);
    expect(readAiLink('[]'), isNull);
  });

  test('the greeting carries the nonce', () {
    final line = aiLinkGreeting('n0nce');
    expect(line, isNot(contains('\n')));
    expect(line, '{"noted":"ai-link/1","nonce":"n0nce"}');
    expect(readAiLinkGreeting('$line\n'), 'n0nce');
    for (final bad in ['', 'x', '[]', '{}', '{"noted":"ai-link/2","nonce":"a"}', '{"noted":"ai-link/1"}', '{"noted":"ai-link/1","nonce":""}']) {
      expect(readAiLinkGreeting(bad), isNull, reason: bad);
    }
    expect(aiLinkReadTimeout, const Duration(seconds: 5));
    expect(aiLinkMaxConnections, 8);
  });

  test('a request round-trips on a single line, with newlines and unicode in the content', () {
    const r = AiLinkRequest(token: 'noted_x', box: 'b1', mode: AiLinkMode.append, content: 'line 1\nline 2 é 😀');
    final line = r.encode();
    expect(line, isNot(contains('\n')));
    expect(line, contains('"noted":"ai-link/1"'));
    expect(line, contains('"op":"write_box"'));
    final back = AiLinkRequest.decode('$line\n')!;
    expect(back.token, 'noted_x');
    expect(back.box, 'b1');
    expect(back.mode, AiLinkMode.append);
    expect(back.content, 'line 1\nline 2 é 😀');
    expect(aiLinkMaxRequestBytes, 1048576);
  });

  test('malformed requests are null', () {
    Map<String, Object?> ok() => {
      'noted': 'ai-link/1',
      'token': 't',
      'op': 'write_box',
      'box': 'b',
      'mode': 'replace',
      'content': 'c',
    };
    expect(AiLinkRequest.decode(jsonEncode(ok())), isNotNull);
    final changes = <String, Object?>{
      'noted': 'ai-link/2',
      'op': 'delete_box',
      'mode': 'prepend',
      'token': 5,
      'box': null,
      'content': ['x'],
    };
    for (final change in changes.entries) {
      expect(AiLinkRequest.decode(jsonEncode({...ok(), change.key: change.value})), isNull, reason: change.key);
    }
    for (final key in ok().keys) {
      expect(AiLinkRequest.decode(jsonEncode({...ok()}..remove(key))), isNull, reason: 'no $key');
    }
    for (final bad in ['', 'nope', '[]', '"x"', '{"noted":']) {
      expect(AiLinkRequest.decode(bad), isNull, reason: bad);
    }
  });

  test('responses round-trip, with a default message per code', () {
    const okResponse = AiLinkResponse.ok(page: 'p', box: 'b');
    final ok = AiLinkResponse.decode(okResponse.encode())!;
    expect(ok.ok, isTrue);
    expect((ok.page, ok.box), ('p', 'b'));
    expect(okResponse.encode(), '{"ok":true,"page":"p","box":"b"}');

    expect(AiLinkCode.values.map((c) => c.wire), [
      'bad_request',
      'bad_token',
      'no_box',
      'not_owner',
      'conflict',
      'locked',
      'not_writable',
      'save_failed',
      'busy',
      'not_running',
    ]);
    for (final code in AiLinkCode.values) {
      expect(code.defaultMessage, isNotEmpty);
      final line = AiLinkResponse.error(code).encode();
      expect(line, isNot(contains('\n')));
      final back = AiLinkResponse.decode(line)!;
      expect(back.ok, isFalse);
      expect(back.code, code);
      expect(back.message, code.defaultMessage);
    }
    final custom = AiLinkResponse.error(AiLinkCode.locked, 'Read only.');
    expect(AiLinkResponse.decode(custom.encode())!.message, 'Read only.');
  });

  test('malformed responses are null', () {
    for (final bad in [
      '',
      'x',
      '[]',
      '{}',
      '{"ok":true}',
      '{"ok":true,"page":"p"}',
      '{"ok":false}',
      '{"ok":false,"code":"mystery"}',
      '{"ok":"yes"}',
    ]) {
      expect(AiLinkResponse.decode(bad), isNull, reason: bad);
    }
  });

  test('a code from a newer app keeps its message', () {
    final r = AiLinkResponse.decode('{"ok":false,"code":"mystery","message":"Try later."}')!;
    expect(r.ok, isFalse);
    expect(r.code, AiLinkCode.saveFailed);
    expect(r.message, 'Try later.');
  });
}
