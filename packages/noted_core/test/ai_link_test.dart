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

  test('the greeting carries the nonce and the new protocol', () {
    expect(aiLinkProtocol, 'ai-link/2');
    final line = aiLinkGreeting('n0nce');
    expect(line, isNot(contains('\n')));
    expect(line, '{"noted":"ai-link/2","nonce":"n0nce"}');
    expect(readAiLinkGreeting('$line\n'), 'n0nce');
    for (final bad in ['', 'x', '[]', '{}', '{"noted":"ai-link/1","nonce":"a"}', '{"noted":"ai-link/2"}', '{"noted":"ai-link/2","nonce":""}']) {
      expect(readAiLinkGreeting(bad), isNull, reason: bad);
    }
    expect(aiLinkReadTimeout, const Duration(seconds: 5));
    expect(aiLinkApprovalTimeout, const Duration(seconds: 45));
    expect(aiLinkMaxConnections, 8);
    expect(aiLinkMaxRequestBytes, 1048576);
  });

  test('a write_box request round-trips on a single line, with newlines and unicode in the content', () {
    const r = AiLinkWriteBox(
      code: 'noted_x',
      session: 'sess',
      app: 'Claude Code',
      box: 'b1',
      mode: AiLinkMode.append,
      content: 'line 1\nline 2 é 😀',
    );
    final line = r.encode();
    expect(line, isNot(contains('\n')));
    expect(line, contains('"noted":"ai-link/2"'));
    expect(line, contains('"op":"write_box"'));
    final back = AiLinkRequest.parse('$line\n') as AiLinkWriteBox;
    expect(back.code, 'noted_x');
    expect(back.session, 'sess');
    expect(back.app, 'Claude Code');
    expect(back.box, 'b1');
    expect(back.mode, AiLinkMode.append);
    expect(back.content, 'line 1\nline 2 é 😀');
  });

  test('write_box modes are append, replace_ai and replace on the wire', () {
    expect(AiLinkMode.values.map((m) => m.wire), ['append', 'replace_ai', 'replace']);
    for (final mode in AiLinkMode.values) {
      final r = AiLinkWriteBox(code: 'c', session: 's', box: 'b', mode: mode, content: 'x');
      expect(r.encode(), contains('"mode":"${mode.wire}"'));
      expect((AiLinkRequest.parse(r.encode()) as AiLinkWriteBox).mode, mode);
    }
    final line = jsonEncode({
      'noted': 'ai-link/2', 'op': 'write_box', 'code': 'c', 'session': 's', 'box': 'b', 'content': 'x',
      'mode': 'replaceAi',
    });
    expect(AiLinkRequest.parse(line), isA<AiLinkMalformed>());
  });

  test('not_permitted is an error code with its message', () {
    expect(AiLinkCode.fromWire('not_permitted'), AiLinkCode.notPermitted);
    final e = AiLinkResponse.decode(AiLinkResponse.error(AiLinkCode.notPermitted).encode()) as AiLinkError;
    expect(e.code, AiLinkCode.notPermitted);
    expect(
      e.message,
      "This box's Writer permission doesn't allow that. Ask the user to change it in the box.",
    );
  });

  test('app is optional', () {
    const r = AiLinkDescribeCode(code: 'c', session: 's');
    expect(r.encode(), isNot(contains('"app"')));
    final back = AiLinkRequest.parse(r.encode()) as AiLinkDescribeCode;
    expect(back.app, isNull);
    expect(back.session, 's');
  });

  test('access requests carry an action and an optional target', () {
    for (final action in AiLinkAction.values) {
      final r = AiLinkAccess(code: 'c', session: 's', action: action, target: 'x');
      final back = AiLinkRequest.parse(r.encode()) as AiLinkAccess;
      expect(back.action, action);
      expect(back.target, 'x');
    }
    expect(AiLinkAction.values.map((a) => a.wire), ['read_box', 'read_page', 'list_pages', 'search']);
    final none = AiLinkRequest.parse(const AiLinkAccess(code: 'c', session: 's', action: AiLinkAction.listPages).encode()) as AiLinkAccess;
    expect(none.target, isNull);
    expect(const AiLinkAccess(code: 'c', session: 's', action: AiLinkAction.listPages).encode(), isNot(contains('target')));
  });

  test('describe_code requests round-trip', () {
    final back = AiLinkRequest.parse(const AiLinkDescribeCode(code: 'c', session: 's', app: 'a').encode());
    expect(back, isA<AiLinkDescribeCode>());
    expect(back!.op, 'describe_code');
  });

  test('anything that is not a JSON object with noted=ai-link/2 parses to null', () {
    for (final bad in [
      '',
      'nope',
      '[]',
      '"x"',
      '{"noted":',
      'GET / HTTP/1.1',
      'POST /mcp HTTP/1.1\r\nHost: localhost',
      '{}',
      '{"noted":"ai-link/1","op":"write_box"}',
      '{"noted":"other","op":"describe_code","code":"c","session":"s"}',
      '{"noted":2}',
    ]) {
      expect(AiLinkRequest.parse(bad), isNull, reason: bad);
    }
  });

  test('this protocol with a bad shape is malformed, to be answered bad_request', () {
    Map<String, Object?> ok() => {
      'noted': 'ai-link/2',
      'op': 'write_box',
      'code': 'c',
      'session': 's',
      'box': 'b',
      'mode': 'replace',
      'content': 'x',
    };
    expect(AiLinkRequest.parse(jsonEncode(ok())), isA<AiLinkWriteBox>());
    final changes = <String, Object?>{
      'op': 'delete_box',
      'mode': 'prepend',
      'code': 5,
      'session': '',
      'box': null,
      'content': ['x'],
      'app': 3,
    };
    for (final change in changes.entries) {
      expect(AiLinkRequest.parse(jsonEncode({...ok(), change.key: change.value})), isA<AiLinkMalformed>(), reason: change.key);
    }
    for (final key in ['op', 'code', 'session', 'box', 'mode', 'content']) {
      expect(AiLinkRequest.parse(jsonEncode({...ok()}..remove(key))), isA<AiLinkMalformed>(), reason: 'no $key');
    }
    final badAction = jsonEncode({'noted': 'ai-link/2', 'op': 'access', 'code': 'c', 'session': 's', 'action': 'delete'});
    expect(AiLinkRequest.parse(badAction), isA<AiLinkMalformed>());
    final badTarget = jsonEncode({'noted': 'ai-link/2', 'op': 'access', 'code': 'c', 'session': 's', 'action': 'search', 'target': 1});
    expect(AiLinkRequest.parse(badTarget), isA<AiLinkMalformed>());
    expect((AiLinkRequest.parse('{"noted":"ai-link/2"}') as AiLinkMalformed).message, isNotEmpty);
  });

  test('the error codes', () {
    expect(AiLinkCode.values.map((c) => c.wire), [
      'bad_request',
      'bad_code',
      'expired',
      'not_approved',
      'wrong_role',
      'no_box',
      'conflict',
      'locked',
      'not_writable',
      'no_request',
      'not_permitted',
      'save_failed',
      'busy',
      'not_running',
      'unknown',
    ]);
    expect(AiLinkCode.fromWire('bad_token'), isNull);
    expect(AiLinkCode.fromWire('not_owner'), isNull);
    expect(AiLinkCode.notRunning.defaultMessage, contains('This needs Noted running'));
  });

  test('responses round-trip, with a default message per code', () {
    const written = AiLinkResponse.written(box: 'b');
    expect(written.encode(), '{"ok":true,"box":"b"}');
    final w = AiLinkResponse.decode(written.encode()) as AiLinkWritten;
    expect(w.ok, isTrue);
    expect(w.box, 'b');

    for (final code in AiLinkCode.values) {
      expect(code.defaultMessage, isNotEmpty);
      final line = AiLinkResponse.error(code).encode();
      expect(line, isNot(contains('\n')));
      final back = AiLinkResponse.decode(line) as AiLinkError;
      expect(back.ok, isFalse);
      expect(back.code, code);
      expect(back.message, code.defaultMessage);
    }
    final custom = AiLinkResponse.error(AiLinkCode.locked, 'Read only.');
    expect((AiLinkResponse.decode(custom.encode()) as AiLinkError).message, 'Read only.');
  });

  test('grants round-trip in both shapes', () {
    const box = AiLinkResponse.granted(AiLinkBoxGrant(box: 'b', page: 'p'));
    expect(box.encode(), '{"ok":true,"grant":{"kind":"box","box":"b","page":"p"}}');
    final b = (AiLinkResponse.decode(box.encode()) as AiLinkGranted).grant as AiLinkBoxGrant;
    expect((b.box, b.page), ('b', 'p'));

    const pages = AiLinkResponse.granted(AiLinkPagesGrant(pages: ['p1', 'p2']));
    expect(pages.encode(), '{"ok":true,"grant":{"kind":"pages","pages":["p1","p2"]}}');
    final p = (AiLinkResponse.decode(pages.encode()) as AiLinkGranted).grant as AiLinkPagesGrant;
    expect(p.pages, ['p1', 'p2']);
    const none = AiLinkResponse.granted(AiLinkPagesGrant(pages: []));
    expect(((AiLinkResponse.decode(none.encode()) as AiLinkGranted).grant as AiLinkPagesGrant).pages, isEmpty);
  });

  test('describe_code answers round-trip', () {
    const d = AiLinkResponse.described(kind: 'box', id: 'b', role: 'writer', expires: '2026-12-01T00:00:00.000Z');
    final back = AiLinkResponse.decode(d.encode()) as AiLinkDescribed;
    expect((back.kind, back.id, back.role, back.expires), ('box', 'b', 'writer', '2026-12-01T00:00:00.000Z'));
    const never = AiLinkResponse.described(kind: 'page', id: 'p', role: 'reader');
    expect(never.encode(), contains('"expires":null'));
    expect((AiLinkResponse.decode(never.encode()) as AiLinkDescribed).expires, isNull);
  });

  test('malformed responses are null', () {
    for (final bad in [
      '',
      'x',
      '[]',
      '{}',
      '{"ok":true}',
      '{"ok":true,"page":"p"}',
      '{"ok":true,"grant":{"kind":"pages","pages":[1]}}',
      '{"ok":true,"grant":{"kind":"box","box":"b"}}',
      '{"ok":true,"grant":{"kind":"cloud"}}',
      '{"ok":true,"kind":"box","id":"b"}',
      '{"ok":false}',
      '{"ok":false,"code":"mystery"}',
      '{"ok":"yes"}',
    ]) {
      expect(AiLinkResponse.decode(bad), isNull, reason: bad);
    }
  });

  test('a code from a newer app keeps its message', () {
    final r = AiLinkResponse.decode('{"ok":false,"code":"mystery","message":"Try later."}') as AiLinkError;
    expect(r.ok, isFalse);
    expect(r.code, AiLinkCode.unknown);
    expect(r.wireCode, 'mystery');
    expect(r.message, 'Try later.');
    expect(r.encode(), '{"ok":false,"code":"mystery","message":"Try later."}');
    expect(AiLinkCode.fromWire('unknown'), isNull);
    expect(AiLinkResponse.decode('{"ok":false,"code":"busy"}') as AiLinkError, isA<AiLinkError>().having((e) => e.wireCode, 'wireCode', 'busy'));
  });

  test('session and app lengths are limited', () {
    String line({String session = 's', Object? app}) =>
        jsonEncode({'noted': 'ai-link/2', 'op': 'describe_code', 'code': 'c', 'session': session, 'app': ?app});
    expect(AiLinkRequest.parse(line(session: 's' * 128, app: 'a' * 200)), isA<AiLinkDescribeCode>());
    expect(AiLinkRequest.parse(line(session: 's' * 129)), isA<AiLinkMalformed>());
    expect(AiLinkRequest.parse(line(app: 'a' * 201)), isA<AiLinkMalformed>());
  });

  test('read_box and read_page need a target; list_pages and search do not', () {
    String line(String action, [Object? target]) =>
        jsonEncode({'noted': 'ai-link/2', 'op': 'access', 'code': 'c', 'session': 's', 'action': action, 'target': ?target});
    for (final a in ['read_box', 'read_page']) {
      expect(AiLinkRequest.parse(line(a)), isA<AiLinkMalformed>(), reason: a);
      expect(AiLinkRequest.parse(line(a, '')), isA<AiLinkMalformed>(), reason: a);
      expect(AiLinkRequest.parse(line(a, 'x')), isA<AiLinkAccess>(), reason: a);
    }
    expect(AiLinkRequest.parse(line('list_pages')), isA<AiLinkAccess>());
    expect(AiLinkRequest.parse(line('search')), isA<AiLinkAccess>());
  });

  group('merge requests', () {
    test('merge_requests and propose_merge round-trip', () {
      const list = AiLinkMergeRequests(code: 'c', session: 's', app: 'a');
      expect(list.op, 'merge_requests');
      final back = AiLinkRequest.parse(list.encode()) as AiLinkMergeRequests;
      expect(back.code, 'c');
      expect(back.app, 'a');

      const propose = AiLinkProposeMerge(code: 'c', session: 's', request: 'r1', content: '# Merged\n\n"text"');
      expect(propose.op, 'propose_merge');
      final p = AiLinkRequest.parse(propose.encode()) as AiLinkProposeMerge;
      expect(p.request, 'r1');
      expect(p.content, '# Merged\n\n"text"');
      expect(propose.encode(), isNot(contains('\n')));
    });

    test('a propose_merge without a request or content is malformed', () {
      String line(Map<String, Object?> extra) =>
          jsonEncode({'noted': 'ai-link/2', 'op': 'propose_merge', 'code': 'c', 'session': 's', ...extra});
      expect(AiLinkRequest.parse(line({'request': 'r', 'content': 'x'})), isA<AiLinkProposeMerge>());
      expect(AiLinkRequest.parse(line({'request': 'r', 'content': ''})), isA<AiLinkProposeMerge>(), reason: 'empty is a valid string');
      expect(AiLinkRequest.parse(line({'content': 'x'})), isA<AiLinkMalformed>());
      expect(AiLinkRequest.parse(line({'request': '', 'content': 'x'})), isA<AiLinkMalformed>());
      expect(AiLinkRequest.parse(line({'request': 'r'})), isA<AiLinkMalformed>());
      expect(AiLinkRequest.parse(line({'request': 'r', 'content': 3})), isA<AiLinkMalformed>());
    });

    test('the answers round-trip', () {
      const item = AiLinkMergeItem(
        id: 'r1',
        page: 'p',
        box: 'b',
        type: 'noted.note',
        mine: AiLinkMergeVersion(markdown: 'mine\ntext', at: 5, device: 'PC'),
        theirs: AiLinkMergeVersion(markdown: 'theirs', at: 9),
      );
      final line = const AiLinkResponse.merges([item]).encode();
      expect(line, isNot(contains('\n')));
      final back = AiLinkResponse.decode(line) as AiLinkMerges;
      expect(back.items.single.id, 'r1');
      expect(back.items.single.mine.markdown, 'mine\ntext');
      expect(back.items.single.mine.device, 'PC');
      expect(back.items.single.theirs.device, isNull);
      expect(back.items.single.theirs.at, 9);
      expect(AiLinkResponse.decode(const AiLinkResponse.merges([]).encode()), isA<AiLinkMerges>());
      expect(AiLinkResponse.decode('{"ok":true,"merges":[{"id":"x"}]}'), isNull);

      final proposed = AiLinkResponse.decode(const AiLinkResponse.proposed(request: 'r1').encode()) as AiLinkProposed;
      expect(proposed.request, 'r1');
      expect(proposed.ok, isTrue);
      expect(AiLinkResponse.decode('{"ok":true,"proposed":3}'), isNull);

      final gone = AiLinkResponse.decode(AiLinkResponse.error(AiLinkCode.noRequest).encode()) as AiLinkError;
      expect(gone.code, AiLinkCode.noRequest);
    });
  });
}
