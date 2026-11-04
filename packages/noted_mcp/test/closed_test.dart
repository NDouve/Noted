// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart' show conflictCopyOriginalNames;
import 'package:noted_core/noted_core_read.dart';
import 'package:noted_mcp/noted_mcp.dart';

import 'ai_test.dart' show FakeNoted;
import 'fixture.dart';
import 'running_lock.dart';

// Code-based reads and writes while Noted is not running: the server checks
// the code against the saved ai-access.json, logs every request, and writes an
// AI box straight into its page file only when the box allows it.

const _key = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ'; // 43 characters
String token(String id) => 'noted_${id}_$_key';

const idWriter = '3000000000000001';
const idReader = '3000000000000002';
const idPageCode = '3000000000000003';
const idBinderCode = '3000000000000004';
const idGuardedBox = '3000000000000005';

const approveText = 'Approve this code in Noted first. Open Noted: it will ask you.';

AiCode codeOf(
  String id,
  AiCodeTarget target, {
  String role = 'reader',
  bool approved = true,
  DateTime? expires,
  String label = 'Test chat',
  DateTime? revoked,
}) => AiCode(
  revoked: revoked,
  id: id,
  target: target,
  roleName: role,
  label: label,
  hash: aiKeyHash(_key),
  created: DateTime.utc(2026, 1, 1),
  approved: approved ? DateTime.utc(2026, 1, 2) : null,
  expires: expires,
);

void writeStore(Directory data, List<AiCode> codes, [Map<String, Object?> boxes = const {}]) {
  File('${data.path}/ai-access.json').writeAsStringSync(
    jsonEncode({
      'format': 1,
      'codes': [for (final c in codes) c.toJson()],
      'boxes': boxes,
    }),
  );
}

List<AiMcpLogEntry> readLog(Directory data) {
  final f = File('${data.path}/$aiMcpLogFileName');
  return f.existsSync() ? parseAiMcpLog(f.readAsStringSync()) : [];
}

void main() {
  late Directory root;
  late Directory data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_mcp_closed');
    data = writeFixture(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  NotedToolbox toolbox({
    String? app = 'Test App 1.2',
    Future<void> Function(int attempt)? beforeReplace,
    Future<void> Function(int attempt)? beforeRead,
  }) => NotedToolbox(
    data,
    session: 's',
    app: app,
    greetingTimeout: const Duration(milliseconds: 500),
    responseTimeout: const Duration(seconds: 5),
    beforeClosedReplace: beforeReplace,
    beforeClosedRead: beforeRead,
  );

  String aiOpenPath() => '${data.path}/pages/${Ids.aiOpen}.canvas';

  // The page file text with box [id]'s record cut out: what a write must leave
  // exactly as it was.
  String outside(String text, String id) {
    final nodes = JsonSpanReader.objectEntrySpans(text).firstWhere((e) => e.$1 == 'nodes');
    final array = text.substring(nodes.$2, nodes.$3);
    for (final (s, e) in JsonSpanReader.arrayItemSpans(array)) {
      if (array.substring(s, e).contains('"id":"$id"')) {
        return text.replaceRange(nodes.$2 + s, nodes.$2 + e, '');
      }
    }
    fail('box $id not in the file');
  }

  BoxRecord boxIn(String path, String id) =>
      readPage(File(path).readAsStringSync()).node(id)! as BoxRecord;

  AiCode writer({String box = 'aiA', String page = Ids.aiOpen, bool approved = true, DateTime? expires}) =>
      codeOf(idWriter, AiCodeTarget.box(box, page: page), role: 'writer', approved: approved, expires: expires);

  Map<String, Object?> allowClosed([String permission = 'append', String box = 'aiA']) => {
    box: {'closedWrites': true, 'writerPermission': permission},
  };

  Future<void> expectNothingChanged(String path, String before) async {
    expect(File(path).readAsStringSync(), before);
    final stray = [
      for (final f in File(path).parent.listSync())
        if (f.path.endsWith('.tmp')) f.path,
    ];
    expect(stray, isEmpty);
  }

  group('closed reads', () {
    test('a Reader box code reads that box only, with nothing about its page, and the read is logged', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiG', page: Ids.aiGuarded))]);
      final out = await toolbox().readBox('aiG', code: token(idReader));
      expect(out.isError, isFalse);
      expect(out.text, startsWith('**ai** · box `aiG`'));
      expect(out.text, contains('okapi guarded box'));
      expect(out.text, contains('<ai-written>'));
      expect(out.text, isNot(contains('Guarded AI')));
      expect(out.text, isNot(contains(Ids.aiGuarded)));
      expect(out.text, isNot(contains(secret)));
      final log = readLog(data);
      expect(log, hasLength(1));
      expect(log.single.result, 'ok');
      expect(log.single.op, 'read_box');
      expect(log.single.code, idReader);
      expect(log.single.target.kind, AiCodeTargetKind.box);
      expect(log.single.target.id, 'aiG');
      expect(log.single.target.page, Ids.aiGuarded);
      expect(log.single.app, 'Test App 1.2');
      expect(log.single.label, 'Test chat');
    });

    test('a box code finds the box when it moved to another page, and is refused for other boxes and tools', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.public))]);
      final t = toolbox();
      expect((await t.readBox('aiA', code: token(idReader))).text, contains('okapi from A'));
      expect((await t.readBox('aiB', code: token(idReader))).text, startsWith('No such box'));
      for (final out in [
        await t.listPages(code: token(idReader)),
        await t.readPage(Ids.aiOpen, code: token(idReader)),
        await t.search('okapi', code: token(idReader)),
      ]) {
        expect(out.isError, isTrue);
        expect(out.text, contains('box code'));
        expect(out.text, isNot(contains('Open AI')));
      }
      expect([for (final e in readLog(data)) e.result], ['ok', 'wrong_role', 'wrong_role', 'wrong_role'], reason: 'another box id is no_box and not logged');
    });

    test('a box in a locked binder is reachable by its box code', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiV', page: Ids.aiLocked))]);
      expect((await toolbox().readBox('aiV', code: token(idReader))).text, contains('okapi vault box'));
    });

    test('a page code reads the Privileged pages it covers, minus Guarded ones; Open pages stay readable', () async {
      writeStore(data, [codeOf(idPageCode, const AiCodeTarget.page(Ids.priv))]);
      final t = toolbox();
      final list = await t.listPages(code: token(idPageCode));
      final ids = {for (final p in (jsonDecode(list.text)['pages'] as List).cast<Map<String, Object?>>()) p['id']};
      expect(ids, {...openIds, Ids.priv, Ids.privChild, Ids.privLoose});
      expect((await t.readPage(Ids.priv, code: token(idPageCode))).text, contains('giraffe privileged text'));
      expect((await t.readPage(Ids.privTight, code: token(idPageCode))).text, noSuchPage(Ids.privTight));
      expect((await t.readPage(Ids.privBinderPage, code: token(idPageCode))).text, noSuchPage(Ids.privBinderPage));
      expect((await t.readPage(Ids.priv)).text, noSuchPage(Ids.priv), reason: 'no code, no Privileged page');
      expect((await t.readBox('n8', code: token(idPageCode))).text, contains('giraffe'));
      final hits = jsonDecode((await t.search('giraffe', code: token(idPageCode))).text)['results'] as List;
      expect(hits.map((r) => (r as Map)['id']), [Ids.priv]);
      expect(readLog(data).every((e) => e.result == 'ok' && e.code == idPageCode), isTrue);
      expect({for (final e in readLog(data)) e.op}, {'list_pages', 'read_page', 'read_box', 'search'});
    });

    test('a binder code reads the binder\'s Privileged pages, not another binder or a locked one', () async {
      final taxes = Binder.parse(File('${root.path}/Taxes/$binderFileName').readAsStringSync());
      writeStore(data, [codeOf(idBinderCode, AiCodeTarget.binder(taxes.id))]);
      final t = toolbox();
      expect((await t.readPage(Ids.privBinderPage, code: token(idBinderCode))).text, contains('zebra taxes'));
      expect((await t.readPage(Ids.priv, code: token(idBinderCode))).text, noSuchPage(Ids.priv));
      expect((await t.readPage(Ids.locked, code: token(idBinderCode))).text, noSuchPage(Ids.locked));
      // A code for the locked binder reads nothing of it.
      final vault = jsonDecode(File('${root.path}/Vault/$binderFileName').readAsStringSync()) as Map<String, Object?>;
      writeStore(data, [codeOf(idBinderCode, AiCodeTarget.binder('${vault['id']}'))]);
      expect((await t.readPage(Ids.locked, code: token(idBinderCode))).text, noSuchPage(Ids.locked));
      expect((await t.readPage(Ids.aiLocked, code: token(idBinderCode))).text, noSuchPage(Ids.aiLocked));
    });

    test('an unapproved code is refused with the approval message and a pending_approval entry', () async {
      writeStore(data, [
        codeOf(idPageCode, const AiCodeTarget.page(Ids.priv), approved: false),
        codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen), approved: false),
      ]);
      final t = toolbox();
      for (final out in [
        await t.readPage(Ids.priv, code: token(idPageCode)),
        await t.listPages(code: token(idPageCode)),
        await t.readBox('aiA', code: token(idReader)),
      ]) {
        expect(out.isError, isTrue);
        expect(out.text, approveText);
        expect(out.text, isNot(contains('giraffe')));
      }
      final log = readLog(data);
      expect(log, hasLength(3));
      expect(log.every((e) => e.isPendingApproval), isTrue);
      expect([for (final e in log) e.code], [idPageCode, idPageCode, idReader]);
    });

    test('an expired code is refused and logged; a revoked, wrong or malformed one is bad_code and not logged', () async {
      writeStore(data, [
        codeOf(idPageCode, const AiCodeTarget.page(Ids.priv), expires: DateTime.utc(2020, 1, 1)),
        codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen)),
      ]);
      final t = toolbox();
      final expired = await t.readPage(Ids.priv, code: token(idPageCode));
      expect(expired.text, contains('expired'));
      expect(readLog(data).single.result, 'expired');
      final before = File('${data.path}/$aiMcpLogFileName').readAsStringSync();
      // Not in the store (revoked), a wrong key, and a malformed code.
      for (final c in [token('3999999999999999'), 'noted_${idReader}_${'Z' * 43}', 'noted_junk']) {
        final out = await t.readBox('aiA', code: c);
        expect(out.isError, isTrue);
        expect(out.text, startsWith('The code is not valid'));
        expect(out.text, isNot(contains(c)));
      }
      expect(File('${data.path}/$aiMcpLogFileName').readAsStringSync(), before);
    });

    test('a revoked code that is still in the file is bad_code for reads and writes, and not logged', () async {
      writeStore(
        data,
        [
          codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen), revoked: DateTime.utc(2026, 2, 1)),
          codeOf(idPageCode, const AiCodeTarget.page(Ids.priv), revoked: DateTime.utc(2026, 2, 1)),
        ],
        allowClosed(),
      );
      final t = toolbox();
      final box = await t.readBox('aiA', code: token(idReader));
      expect(box.isError, isTrue);
      expect(box.text, startsWith('The code is not valid'));
      final page = await t.readPage(Ids.priv, code: token(idPageCode));
      expect(page.isError, isTrue);
      expect(page.text, startsWith('The code is not valid'));
      expect(File('${data.path}/$aiMcpLogFileName').existsSync(), isFalse);
    });

    test('a store that cannot be read accepts no code and says so', () async {
      File('${data.path}/ai-access.json').writeAsStringSync('{"format": 99');
      final out = await toolbox().readBox('aiA', code: token(idReader));
      expect(out.isError, isTrue);
      expect(out.text, "Noted can't read its codes. Open Noted to fix it.");
    });

    test('a link that greets without the lock is still Noted running: the app decides, nothing is read closed', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen), approved: false)]);
      final f = await FakeNoted.start(data, holdLock: false);
      addTearDown(() async {
        await f.close();
        File('${data.path}/$aiLinkFileName').deleteSync();
      });
      f.answer = (_) => AiLinkResponse.granted(const AiLinkBoxGrant(box: 'aiA', page: Ids.aiOpen)).encode();
      final out = await toolbox().readBox('aiA', code: token(idReader));
      expect(out.isError, isFalse, reason: 'the unapproved store was not consulted');
      expect(f.requests, hasLength(1), reason: 'the greeting probe sent no code; only the real request did');
      expect(readLog(data), isEmpty);
    });

    test('a role this build does not know grants nothing', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen), role: 'organize')]);
      final out = await toolbox().readBox('aiA', code: token(idReader));
      expect(out.isError, isTrue);
      expect(readLog(data).single.result, 'wrong_role');
    });

    test('the log holds the code id, never the key, and a clean app name on one line', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen), label: 'Line\none')]);
      await toolbox(app: 'Evil\nApp\r\n${'x' * 500}').readBox('aiA', code: token(idReader));
      final text = File('${data.path}/$aiMcpLogFileName').readAsStringSync();
      expect(text, isNot(contains(_key)));
      expect(text.trimRight().split('\n'), hasLength(1));
      final e = readLog(data).single;
      expect(e.app, isNot(contains('\n')));
      expect(e.app.length, lessThanOrEqualTo(aiLinkMaxAppLength));
      expect(e.label, isNot(contains('\n')));
    });

    test('log lines are appended: what was there stays byte for byte', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen))]);
      final log = File('${data.path}/$aiMcpLogFileName');
      const old = '{"not":"an entry"}\nhalf a li\n';
      log.writeAsStringSync(old);
      final t = toolbox();
      await t.readBox('aiA', code: token(idReader));
      final one = log.readAsStringSync();
      expect(one.startsWith(old), isTrue);
      await t.readBox('aiA', code: token(idReader));
      final two = log.readAsStringSync();
      expect(two.startsWith(one), isTrue);
      expect(two.length, greaterThan(one.length));
    });

    test('with Noted running a code read goes to the app, not the saved store', () async {
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen), approved: false)]);
      final f = await FakeNoted.start(data);
      addTearDown(() async {
        await f.close();
        File('${data.path}/$aiLinkFileName').deleteSync();
      });
      f.answer = (_) => AiLinkResponse.granted(const AiLinkBoxGrant(box: 'aiA', page: Ids.aiOpen)).encode();
      final out = await toolbox().readBox('aiA', code: token(idReader));
      expect(out.isError, isFalse, reason: 'the app decides: the unapproved store is not consulted');
      expect(f.requests, hasLength(1));
      expect(readLog(data), isEmpty, reason: 'the app logs it');
    });

    test('a stale link file and a lock file nobody holds count as closed', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      File('${data.path}/$aiLinkFileName').writeAsStringSync(jsonEncode({'format': 1, 'port': port, 'pid': 1, 'nonce': 'n'}));
      File('${data.path}/$aiRunningLockFileName').writeAsStringSync('');
      writeStore(data, [codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen))]);
      expect((await toolbox().readBox('aiA', code: token(idReader))).text, contains('okapi from A'));
      expect(File('${data.path}/$aiRunningLockFileName').readAsStringSync(), '', reason: 'the probe never writes it');
    });

    test('with the lock held and the link down, reads and writes answer busy and nothing is written', () async {
      writeStore(data, [
        codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen)),
        writer(),
      ], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final lock = await RunningLock.hold(data); // no link file at all
      addTearDown(lock.release);
      final t = toolbox();
      for (final out in [
        await t.readBox('aiA', code: token(idReader)),
        await t.listPages(code: token(idReader)),
        await t.writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x'),
      ]) {
        expect(out.isError, isTrue);
        expect(out.text, notedBusyText);
      }
      await expectNothingChanged(path, before);
      expect(readLog(data), isEmpty);
      expect((await t.readPage(Ids.public)).isError, isFalse, reason: 'Open pages need no code');
    });

    test('a refusing listener while the lock is held is busy too', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      File('${data.path}/$aiLinkFileName').writeAsStringSync(jsonEncode({'format': 1, 'port': port, 'pid': 1, 'nonce': 'n'}));
      writeStore(data, [writer()], allowClosed());
      final before = File(aiOpenPath()).readAsStringSync();
      final lock = await RunningLock.hold(data);
      addTearDown(lock.release);
      final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x');
      expect(out.text, notedBusyText);
      expect(File(aiOpenPath()).readAsStringSync(), before);
    });
  });

  group('closed writes', () {
    test('append goes into the page file: only the box changes, rev and baseRev move, the log records it', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final old = boxIn(path, 'aiA');
      final out = await toolbox().writeBox(
        boxId: 'aiA',
        code: token(idWriter),
        mode: 'append',
        content: 'Hello **there**',
      );
      expect(out.isError, isFalse, reason: out.text);
      expect(out.text, 'Written to box aiA.');
      final after = File(path).readAsStringSync();
      expect(after, isNot(before));
      expect(outside(after, 'aiA'), outside(before, 'aiA'), reason: 'every other byte is as it was');
      final box = boxIn(path, 'aiA');
      expect(box.rev, isNotNull);
      expect(box.rev, isNot(old.rev));
      expect(box.baseRev, old.rev);
      expect(box.dataVersion, 1);
      expect(box.snapshotText, contains('okapi from A'));
      expect(box.snapshotText, contains('Hello **there**'));
      expect(box.bounds, old.bounds);
      // The new text reads back, marked as AI-written.
      final read = await toolbox().readBox('aiA');
      expect(read.text, contains('okapi from A'));
      expect(read.text, contains('Hello'));
      expect(read.text, contains('<ai-written>'));
      final log = readLog(data);
      expect(log.single.op, 'write_box');
      expect(log.single.result, 'ok');
      expect(log.single.code, idWriter);
      expect(log.single.target.id, 'aiA');
      expect(log.single.target.page, Ids.aiOpen);
      await expectNothingChanged(path, after);
    });

    test('the owner and the box\'s other pages are kept; a page with a BOM keeps it', () async {
      writeStore(data, [writer(box: 'aiB')], allowClosed('append', 'aiB'));
      final path = aiOpenPath();
      final bytes = [0xEF, 0xBB, 0xBF, ...File(path).readAsBytesSync()];
      File(path).writeAsBytesSync(bytes);
      final out = await toolbox().writeBox(boxId: 'aiB', code: token(idWriter), mode: 'append', content: 'more');
      expect(out.isError, isFalse, reason: out.text);
      final after = File(path).readAsBytesSync();
      expect(after.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(after.sublist(3, 6), isNot([0xEF, 0xBB, 0xBF]));
      final data0 = boxIn(path, 'aiB').data!.decode() as Map;
      expect(data0['owner'], '9999999999999999');
      expect(boxIn(path, 'aiA').rev, 'r', reason: 'the other box is untouched');
    });

    test('append mode with a Writer permission of append refuses replace_ai and replace', () async {
      writeStore(data, [writer()], allowClosed('append'));
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      for (final mode in ['replace_ai', 'replace']) {
        final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: mode, content: 'x');
        expect(out.isError, isTrue);
        expect(out.text, contains("Writer permission doesn't allow that"));
      }
      await expectNothingChanged(path, before);
      expect([for (final e in readLog(data)) e.result], ['not_permitted', 'not_permitted']);
    });

    test('an unknown or missing permission is append', () async {
      writeStore(data, [writer()], {
        'aiA': {'closedWrites': true, 'writerPermission': 'admin'},
      });
      final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace_ai', content: 'x');
      expect(out.isError, isTrue);
      expect(out.text, contains('Writer permission'));
    });

    test('edit permission allows replace_ai (the user\'s text stays) and refuses replace', () async {
      writeStore(data, [writer()], allowClosed('edit'));
      final path = aiOpenPath();
      // A user block next to the AI block.
      final user = {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': 'my own words'},
          ],
        },
      };
      final p = readPage(File(path).readAsStringSync());
      final a = p.node('aiA')! as BoxRecord;
      final doc = a.data!.decode() as Map<String, Object?>;
      final kids = [...((doc['document']! as Map)['children']! as List), user];
      final seeded = a.withContent(
        data: RawJson.encode({
          ...doc,
          'document': {...(doc['document']! as Map).cast<String, Object?>(), 'children': kids},
        }),
        dataVersion: 1,
        snapshotText: '',
        newRev: 'seeded',
      );
      File(path).writeAsStringSync(writePage(p.replaceNode(seeded)));
      final ok = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace_ai', content: 'fresh news');
      expect(ok.isError, isFalse, reason: ok.text);
      final text = (await toolbox().readBox('aiA')).text;
      expect(text, contains('my own words'));
      expect(text, contains('fresh news'));
      expect(text, isNot(contains('okapi from A')), reason: 'the earlier AI text was replaced');
      final refused = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace', content: 'x');
      expect(refused.isError, isTrue);
      expect(refused.text, contains('Writer permission'));
    });

    test('full permission allows replace, and empty content empties the box', () async {
      writeStore(data, [writer()], allowClosed('full'));
      final path = aiOpenPath();
      final r = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace', content: 'only this');
      expect(r.isError, isFalse, reason: r.text);
      var text = (await toolbox().readBox('aiA')).text;
      expect(text, contains('only this'));
      expect(text, isNot(contains('okapi from A')));
      final e = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace', content: '');
      expect(e.isError, isFalse, reason: e.text);
      text = (await toolbox().readBox('aiA')).text;
      expect(text, isNot(contains('only this')));
      expect(boxIn(path, 'aiA').snapshotText, isNot(contains('only this')));
      expect(readPage(File(path).readAsStringSync()).node('aiA'), isA<BoxRecord>());
    });

    test('a box without closedWrites is refused (the closed-app message), by default and when off', () async {
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      for (final boxes in <Map<String, Object?>>[
        const {},
        {
          'aiA': {'closedWrites': false},
        },
        {
          'aiA': {'writerPermission': 'full'},
        },
      ]) {
        writeStore(data, [writer()], boxes);
        final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x');
        expect(out.isError, isTrue);
        expect(out.text, equals(closedWritesOffText));
      }
      await expectNothingChanged(path, before);
      expect(readLog(data).map((e) => e.result), everyElement('not_writable'));
    });

    test('ask before each write turns closed writes off, whatever the switch says', () async {
      writeStore(data, [writer()], {
        'aiA': {'closedWrites': true, 'askBeforeWrite': true, 'writerPermission': 'full'},
      });
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x');
      expect(out.isError, isTrue);
      expect(out.text, equals(closedWritesOffText));
      await expectNothingChanged(path, before);
    });

    test('an unapproved Writer code is refused and logged pending; an expired one is refused', () async {
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      writeStore(data, [writer(approved: false)], allowClosed());
      final a = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x');
      expect(a.text, approveText);
      expect(readLog(data).single.isPendingApproval, isTrue);
      writeStore(data, [writer(expires: DateTime.utc(2020, 1, 1))], allowClosed());
      final b = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x');
      expect(b.text, contains('expired'));
      await expectNothingChanged(path, before);
    });

    test('a Reader code, a code for another box and a missing box write nothing', () async {
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      writeStore(data, [
        codeOf(idReader, const AiCodeTarget.box('aiA', page: Ids.aiOpen)),
        writer(box: 'aiB'),
      ], {...allowClosed(), ...allowClosed('append', 'aiB')});
      final t = toolbox();
      final r = await t.writeBox(boxId: 'aiA', code: token(idReader), mode: 'append', content: 'x');
      expect(r.text, contains('does not allow that'));
      final other = await t.writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'x');
      expect(other.text, contains('No such box'));
      writeStore(data, [writer(box: 'gone')], allowClosed('append', 'gone'));
      final gone = await t.writeBox(boxId: 'gone', code: token(idWriter), mode: 'append', content: 'x');
      expect(gone.text, contains('No such box'));
      await expectNothingChanged(path, before);
    });

    test('a box type the page disallows, a conflicted box and a locked binder refuse; nothing changes', () async {
      final blocked = page(
        'f000000000000010',
        'No AI boxes',
        ai: 'open',
        nodes: [box('aiT', aiBoxTypeId, aiBoxData('old'), const Bounds(0, 0, 100, 40))],
      );
      final noAi = blocked.withMeta(blocked.meta.withBoxType(aiBoxTypeId, false));
      final conflicted = page(
        'f000000000000011',
        'Conflicted',
        ai: 'open',
        nodes: [
          (box('aiC', aiBoxTypeId, aiBoxData('old'), const Bounds(0, 0, 100, 40)))
              .withConflict(BoxConflict.deleted(at: 1)),
        ],
      );
      File('${data.path}/pages/${noAi.id}.canvas').writeAsStringSync(writePage(noAi));
      File('${data.path}/pages/${conflicted.id}.canvas').writeAsStringSync(writePage(conflicted));
      writeStore(
        data,
        [writer(box: 'aiT', page: noAi.id)],
        {...allowClosed('full', 'aiT'), ...allowClosed('full', 'aiC'), ...allowClosed('full', 'aiV')},
      );
      final t = toolbox();
      final before = {
        for (final p in [noAi.id, conflicted.id]) p: File('${data.path}/pages/$p.canvas').readAsStringSync(),
      };
      final vaultPath = '${root.path}/Vault/${Ids.aiLocked}.canvas';
      final vaultBefore = File(vaultPath).readAsStringSync();

      final type = await t.writeBox(boxId: 'aiT', code: token(idWriter), mode: 'append', content: 'x');
      expect(type.text, contains('does not take writes'));

      writeStore(
        data,
        [writer(box: 'aiC', page: conflicted.id)],
        allowClosed('full', 'aiC'),
      );
      final conflict = await t.writeBox(boxId: 'aiC', code: token(idWriter), mode: 'append', content: 'x');
      expect(conflict.text, contains('sync conflict'));

      writeStore(data, [writer(box: 'aiV', page: Ids.aiLocked)], allowClosed('full', 'aiV'));
      final locked = await t.writeBox(boxId: 'aiV', code: token(idWriter), mode: 'append', content: 'x');
      expect(locked.text, contains('cannot be edited'));

      for (final p in before.keys) {
        expect(File('${data.path}/pages/$p.canvas').readAsStringSync(), before[p]);
      }
      expect(File(vaultPath).readAsStringSync(), vaultBefore);
      expect([for (final e in readLog(data)) e.result], ['not_writable', 'conflict', 'locked']);
    });

    test('a note box is not written even by a Writer code that names it', () async {
      writeStore(data, [writer(box: 'note1')], allowClosed('full', 'note1'));
      final before = File(aiOpenPath()).readAsStringSync();
      final out = await toolbox().writeBox(boxId: 'note1', code: token(idWriter), mode: 'append', content: 'x');
      expect(out.isError, isTrue);
      expect(File(aiOpenPath()).readAsStringSync(), before);
    });

    test('a page file that changed between reading and renaming is read again, once', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      var calls = 0;
      final out = await toolbox(
        beforeReplace: (attempt) async {
          calls++;
          // Another process saves the page (the same content, trailing newline).
          if (attempt == 0) File(path).writeAsStringSync('${File(path).readAsStringSync()}\n');
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'after the change');
      expect(out.isError, isFalse, reason: out.text);
      expect(calls, 2);
      final text = File(path).readAsStringSync();
      expect(text, contains('after the change'));
      expect(text.trimRight().endsWith('}'), isTrue);
      expect(readLog(data).single.result, 'ok');
    });

    test('a page file that keeps changing is busy: nothing of ours is written and no temp file is left', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      var last = '';
      final out = await toolbox(
        beforeReplace: (attempt) async {
          last = '${File(path).readAsStringSync()}\n';
          File(path).writeAsStringSync(last);
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'never lands');
      expect(out.isError, isTrue);
      expect(out.text, contains('busy'));
      await expectNothingChanged(path, last);
      expect(last, isNot(contains('never lands')));
      expect(readLog(data).single.result, 'busy');
    });

    test('with Noted running a write goes to the app and the page file is not touched', () async {
      writeStore(data, [writer()], allowClosed());
      final f = await FakeNoted.start(data);
      addTearDown(() async {
        await f.close();
        File('${data.path}/$aiLinkFileName').deleteSync();
      });
      f.answer = (_) => const AiLinkResponse.written(box: 'aiA').encode();
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace_ai', content: 'x');
      expect(out.text, 'Written to box aiA.');
      final req = f.requests.single as AiLinkWriteBox;
      expect(req.mode, AiLinkMode.replaceAi);
      expect(File(path).readAsStringSync(), before);
      expect(readLog(data), isEmpty);
    });

    test('parallel closed writes to one page are serialized: every one lands, none is lost', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final results = await Future.wait([
        for (var i = 0; i < 6; i++)
          toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'parallel-$i'),
      ]);
      expect(results.every((r) => !r.isError), isTrue, reason: results.map((r) => r.text).join('|'));
      final text = (await toolbox().readBox('aiA')).text;
      for (var i = 0; i < 6; i++) {
        expect(text, contains('parallel-$i'));
      }
      expect([for (final e in readLog(data)) e.result], everyElement('ok'));
      expect(readLog(data), hasLength(6));
      await expectNothingChanged(path, File(path).readAsStringSync());
    });

    test('the checks run again before the retry: a box that became conflicted is not written', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final out = await toolbox(
        beforeReplace: (attempt) async {
          if (attempt != 0) return;
          final p = readPage(File(path).readAsStringSync());
          final b = p.node('aiA')! as BoxRecord;
          File(path).writeAsStringSync(writePage(p.replaceNode(b.withConflict(BoxConflict.deleted(at: 1)))));
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'must not land');
      expect(out.isError, isTrue);
      expect(out.text, contains('sync conflict'));
      expect(File(path).readAsStringSync(), isNot(contains('must not land')));
      expect(readLog(data).single.result, 'conflict');
    });

    test('a page that disallows AI boxes between the library load and the byte read is not written', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      String? after;
      final out = await toolbox(
        beforeRead: (attempt) async {
          if (attempt != 0) return;
          final p = readPage(File(path).readAsStringSync());
          File(path).writeAsStringSync(writePage(p.withMeta(p.meta.withBoxType(aiBoxTypeId, false))));
          after = File(path).readAsStringSync();
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'must not land');
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      expect(after, isNotNull);
      await expectNothingChanged(path, after!);
      expect(File(path).readAsStringSync(), isNot(contains('must not land')));
      expect(readLog(data).single.result, 'not_writable');
    });

    test('a page moved under a parent that disallows AI boxes between the load and the read is looked at again and refused', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final parent = page('f000000000000040', 'No AI parent', ai: 'open');
      final noAi = parent.withMeta(parent.meta.withBoxType(aiBoxTypeId, false));
      File('${data.path}/pages/${noAi.id}.canvas').writeAsStringSync(writePage(noAi));
      String? after;
      final out = await toolbox(
        beforeRead: (attempt) async {
          if (attempt != 0) return;
          final p = readPage(File(path).readAsStringSync());
          File(path).writeAsStringSync(writePage(p.withMeta(p.meta.withParent(noAi.id))));
          after = File(path).readAsStringSync();
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'must not land');
      // The first try sees the new parent and starts over; the second try's
      // chain includes the parent, which refuses.
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      await expectNothingChanged(path, after!);
      expect(File(path).readAsStringSync(), isNot(contains('must not land')));
      expect(readLog(data).single.result, 'not_writable');
    });

    test('a file that now holds another page is not written: no such box', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final other = page(
        'f000000000000041',
        'Other',
        ai: 'open',
        nodes: [box('aiA', aiBoxTypeId, aiBoxData('old'), const Bounds(0, 0, 100, 40))],
      );
      String? after;
      final out = await toolbox(
        beforeRead: (attempt) async {
          File(path).writeAsStringSync(writePage(other));
          after = File(path).readAsStringSync();
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'must not land');
      expect(out.isError, isTrue);
      expect(out.text, contains('No such box'));
      await expectNothingChanged(path, after!);
      expect(readLog(data).single.result, 'no_box');
    });

    test('a code revoked before the retry is not honoured', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final out = await toolbox(
        beforeReplace: (attempt) async {
          if (attempt != 0) return;
          writeStore(data, const [], allowClosed());
          File(path).writeAsStringSync('${File(path).readAsStringSync()}\n');
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: 'must not land');
      expect(out.isError, isTrue);
      expect(File(path).readAsStringSync(), isNot(contains('must not land')));
    });

    test('page trees span all standalone folders: a subpage in another folder inherits the parent\'s disallowed type', () async {
      final other = Directory('${root.path}/Second')..createSync();
      final parent = page('f000000000000020', 'Parent', ai: 'privileged');
      final noAi = parent.withMeta(parent.meta.withBoxType(aiBoxTypeId, false));
      final child = page(
        'f000000000000021',
        'Child',
        parent: parent.id,
        nodes: [box('aiK', aiBoxTypeId, aiBoxData('kid'), const Bounds(0, 0, 100, 40))],
      );
      File('${data.path}/pages/${noAi.id}.canvas').writeAsStringSync(writePage(noAi));
      File('${other.path}/${child.id}.canvas').writeAsStringSync(writePage(child));
      File('${data.path}/binders.json').writeAsStringSync(
        jsonEncode({
          'format': 1,
          'binders': [
            '${root.path}/Trips',
            '${root.path}/Taxes',
            '${root.path}/Bare',
            '${root.path}/Vault',
          ],
          'standaloneFolders': [other.path],
        }),
      );
      final before = File('${other.path}/${child.id}.canvas').readAsStringSync();
      writeStore(
        data,
        [writer(box: 'aiK', page: child.id), codeOf(idPageCode, AiCodeTarget.page(parent.id))],
        allowClosed('full', 'aiK'),
      );
      final out = await toolbox().writeBox(boxId: 'aiK', code: token(idWriter), mode: 'append', content: 'x');
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      expect(File('${other.path}/${child.id}.canvas').readAsStringSync(), before);
      // The page code reaches the subpage in the other folder.
      expect((await toolbox().readPage(child.id, code: token(idPageCode))).text, contains('kid'));
      expect((await toolbox().readPage(parent.id, code: token(idPageCode))).isError, isFalse);
    });

    test('write_box takes append, replace_ai and replace, and nothing else', () async {
      final out = await toolbox().writeBox(boxId: 'aiA', code: token(idWriter), mode: 'delete', content: 'x');
      expect(out.isError, isTrue);
      expect(out.text, contains('replace_ai'));
      final modes = NotedMcpServer.writeBoxTool.inputSchema;
      expect(jsonEncode(modes), contains('replace_ai'));
      expect(jsonEncode(modes), contains('Full'));
    });
  });

  group('the narrow writer', () {
    late Directory folder;
    late ClosedWriter w;

    setUp(() {
      folder = Directory('${root.path}/Writer')..createSync();
      w = ClosedWriter(dataDir: data, folders: [folder.path]);
    });

    test('replaces a page file in a listed folder atomically and leaves no temp file', () async {
      final f = File('${folder.path}/p.canvas')..writeAsStringSync('old');
      expect(await w.replacePage(f.path, expected: utf8.encode('old'), text: utf8.encode('new')), PageReplace.done);
      expect(f.readAsStringSync(), 'new');
      expect(folder.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last), ['p.canvas']);
    });

    List<String> names() => folder.listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toList()..sort();

    test('a sync replacement between the final comparison and publishing is not destroyed; the old bytes are kept as a conflict copy', () async {
      final f = File('${folder.path}/3f2a-b1.canvas')..writeAsStringSync('old');
      w.beforePublish = () async => f.writeAsStringSync('from sync');
      expect(await w.replacePage(f.path, expected: utf8.encode('old'), text: utf8.encode('new')), PageReplace.busy);
      expect(f.readAsStringSync(), 'from sync');
      final copies = names().where((n) => n != '3f2a-b1.canvas').toList();
      expect(copies, hasLength(1));
      expect(File('${folder.path}/${copies.single}').readAsStringSync(), 'old');
      // noted_core's scanner reads the kept copy as a copy of the page.
      expect(conflictCopyOriginalNames(copies.single), contains('3f2a-b1.canvas'));
    });

    test('a page changed after the first look is put back as it was', () async {
      final f = File('${folder.path}/p.canvas')..writeAsStringSync('old');
      // Changed between the first comparison and the move aside.
      w.beforeAside = () async => f.writeAsStringSync('edited');
      expect(await w.replacePage(f.path, expected: utf8.encode('old'), text: utf8.encode('new')), PageReplace.changed);
      expect(f.readAsStringSync(), 'edited');
      expect(names(), ['p.canvas']);
    });

    test('changed bytes: nothing is written', () async {
      final f = File('${folder.path}/p.canvas')..writeAsStringSync('someone else');
      expect(await w.replacePage(f.path, expected: utf8.encode('old'), text: utf8.encode('new')), PageReplace.changed);
      expect(f.readAsStringSync(), 'someone else');
      expect(folder.listSync(), hasLength(1));
    });

    test('refuses a folder it was not given, a file that is not a page, a missing file and a subfolder', () async {
      final other = Directory('${root.path}/Other')..createSync();
      final elsewhere = File('${other.path}/p.canvas')..writeAsStringSync('old');
      final notPage = File('${folder.path}/p.json')..writeAsStringSync('old');
      Directory('${folder.path}/sub').createSync();
      final nested = File('${folder.path}/sub/p.canvas')..writeAsStringSync('old');
      for (final f in [elsewhere, notPage, nested, File('${folder.path}/missing.canvas')]) {
        expect(await w.replacePage(f.path, expected: utf8.encode('old'), text: utf8.encode('new')), PageReplace.refused, reason: f.path);
      }
      expect(elsewhere.readAsStringSync(), 'old');
      expect(notPage.readAsStringSync(), 'old');
      expect(nested.readAsStringSync(), 'old');
      // A path that climbs out of the folder resolves outside it.
      expect(
        await w.replacePage('${folder.path}/../Other/p.canvas', expected: utf8.encode('old'), text: utf8.encode('new')),
        PageReplace.refused,
      );
      expect(elsewhere.readAsStringSync(), 'old');
    });

    test('refuses a link, whether it points inside or outside', () async {
      final target = File('${root.path}/Other.canvas')..writeAsStringSync('old');
      final link = Link('${folder.path}/l.canvas');
      try {
        link.createSync(target.path);
      } on FileSystemException {
        return; // Links need a privilege on this machine: nothing to test.
      }
      expect(await w.replacePage(link.path, expected: utf8.encode('old'), text: utf8.encode('new')), PageReplace.refused);
      expect(target.readAsStringSync(), 'old');
    });

    test('a folder that is a link out of the listed ones is not a listed folder', () async {
      final real = Directory('${root.path}/Real')..createSync();
      final f = File('${real.path}/p.canvas')..writeAsStringSync('old');
      final dirLink = Link('${folder.path}/viaLink');
      try {
        dirLink.createSync(real.path);
      } on FileSystemException {
        return;
      }
      expect(
        await w.replacePage('${dirLink.path}/p.canvas', expected: utf8.encode('old'), text: utf8.encode('new')),
        PageReplace.refused,
      );
      expect(f.readAsStringSync(), 'old');
    });

    test('appendLog tries again while a trim holds the log, and never throws', () async {
      final log = File('${data.path}/$aiMcpLogFileName')..writeAsStringSync('first\n');
      // Another process holds the log's lock, as the app's trim does.
      final lock = await RunningLock.holdLog(data);
      final started = DateTime.now();
      var finished = false;
      final append = w.appendLog('{"late":1}').whenComplete(() => finished = true);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(finished, isFalse, reason: 'nothing lands while the lock is held');
      await lock.release();
      expect(await append, isTrue);
      expect(DateTime.now().difference(started).inMilliseconds, greaterThanOrEqualTo(550));
      expect(log.readAsStringSync(), 'first\n{"late":1}\n');
    });

    test('appendLog after a torn last line starts a new line, and only appends', () async {
      final log = File('${data.path}/$aiMcpLogFileName');
      // A multi-byte character cut in half, no newline.
      log.writeAsBytesSync([...utf8.encode('{"a":1}\n{"t":"'), 0xE2, 0x82]);
      final before = log.readAsBytesSync();
      expect(await w.appendLog('{"b":2}'), isTrue);
      final after = log.readAsBytesSync();
      expect(after.sublist(0, before.length), before);
      expect(utf8.decode(after.sublist(before.length)), '\n{"b":2}\n');
      expect(await w.appendLog('{"c":3}'), isTrue);
      expect(utf8.decode(log.readAsBytesSync(), allowMalformed: true).split('\n').where((l) => l.isNotEmpty).last, '{"c":3}');
    });

    test('appendLog refuses a log that is a link', () async {
      final target = File('${root.path}/elsewhere.txt')..writeAsStringSync('keep');
      final link = Link('${data.path}/$aiMcpLogFileName');
      try {
        link.createSync(target.path);
      } on FileSystemException {
        return;
      }
      expect(await w.appendLog('{"x":1}'), isFalse);
      expect(target.readAsStringSync(), 'keep');
    });

    test('appendLog appends lines, refuses a line with a newline, and does not create the data folder', () async {
      expect(await w.appendLog('{"a":1}'), isTrue);
      expect(await w.appendLog('{"b":2}'), isTrue);
      expect(await w.appendLog('{"c":\n3}'), isFalse);
      expect(File('${data.path}/$aiMcpLogFileName').readAsStringSync(), '{"a":1}\n{"b":2}\n');
      final gone = ClosedWriter(dataDir: Directory('${root.path}/nope'), folders: const []);
      expect(await gone.appendLog('{}'), isFalse);
      expect(Directory('${root.path}/nope').existsSync(), isFalse);
    });
  });
}
