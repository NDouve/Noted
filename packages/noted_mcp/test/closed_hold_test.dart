// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core_read.dart';
import 'package:noted_mcp/noted_mcp.dart';

import 'ai_test.dart' show FakeNoted;
import 'closed_test.dart' show idWriter, readLog, token, writeStore, codeOf;
import 'fixture.dart';
import 'running_lock.dart';

// A closed write holds the shared running lock across the page write (run
// 2026-11-06-02, task 1). Lock contention needs a second process, because
// locks don't conflict inside one process on Linux: RunningLock holds the
// app's exclusive lock from a helper process.
//
// "Fails on 61cd4a8" below names the behaviour that the earlier code lacked.

void main() {
  late Directory root;
  late Directory data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_mcp_hold');
    data = writeFixture(root);
  });
  tearDown(() {
    LockGate.beforeLockForTest = null;
    root.deleteSync(recursive: true);
  });

  // Every test sets the limit to 60 s, except the tests of the limit itself.
  NotedToolbox toolbox({
    Future<void> Function(int attempt)? beforeReplace,
    Future<void> Function(int attempt)? beforeRead,
    Future<void> Function(int attempt)? beforeHold,
    Future<void> Function(int attempt)? beforeRecheck,
    Duration limit = const Duration(seconds: 60),
    Duration greeting = const Duration(milliseconds: 500),
    void Function(int n)? onLinkSend,
    Duration retryDelay = const Duration(milliseconds: 60),
  }) => NotedToolbox(
    data,
    session: 's',
    app: 'Test App 1.2',
    greetingTimeout: greeting,
    responseTimeout: const Duration(seconds: 5),
    beforeClosedReplace: beforeReplace,
    beforeClosedRead: beforeRead,
    beforeClosedHold: beforeHold,
    beforeClosedRecheck: beforeRecheck,
    closedHoldLimit: limit,
    onLinkSend: onLinkSend,
    linkRetryDelay: retryDelay,
  );

  String aiOpenPath() => '${data.path}/pages/${Ids.aiOpen}.canvas';
  AiCode writer({String box = 'aiA', String page = Ids.aiOpen}) =>
      codeOf(idWriter, AiCodeTarget.box(box, page: page), role: 'writer');
  Map<String, Object?> allowClosed([String permission = 'append', String box = 'aiA']) => {
    box: {'closedWrites': true, 'writerPermission': permission},
  };

  // Whether the app's exclusive lock can be taken now (it can't while a server
  // holds its shared lock).
  Future<bool> canHold() async {
    try {
      final l = await RunningLock.hold(data);
      await l.release();
      return true;
    } on Object {
      return false;
    }
  }

  Future<ToolOutput> append(NotedToolbox t, [String text = 'new words']) =>
      t.writeBox(boxId: 'aiA', code: token(idWriter), mode: 'append', content: text);

  void expectNoStrays(String path) {
    final stray = [
      for (final f in File(path).parent.listSync())
        if (f.path.endsWith('.tmp') || f.path.contains('-NOTED-MCP-')) f.path,
    ];
    expect(stray, isEmpty);
  }

  group('the hold', () {
    test('1. Noted starting during a write is kept out until the write has landed', () async {
      writeStore(data, [writer()], allowClosed());
      var fired = false;
      bool? during;
      final out = await append(
        toolbox(
          beforeReplace: (_) async {
            fired = true;
            during = await canHold();
          },
        ),
      );
      expect(fired, isTrue);
      expect(during, isFalse, reason: 'the exclusive lock is refused while the write is paused');
      expect(out.isError, isFalse, reason: out.text);
      expect(File(aiOpenPath()).readAsStringSync(), contains('new words'));
      expect(await canHold(), isTrue, reason: 'the hold is gone once the write ended');
    });

    test('2. a queued write takes its own hold at its turn: if Noted is there by then it goes to the link', () async {
      writeStore(data, [writer()], allowClosed('full'));
      final path = aiOpenPath();
      final firstAtReplace = Completer<void>();
      final go = Completer<void>();
      final w1 = append(
        toolbox(
          beforeReplace: (_) async {
            firstAtReplace.complete();
            await go.future;
          },
        ),
        'first change',
      );
      await firstAtReplace.future;
      FakeNoted? fake;
      RunningLock? app;
      var holdSeam = 0;
      final w2 = append(
        toolbox(
          beforeHold: (_) async {
            // Between W1's release and W2's take, Noted starts: it takes its
            // lock, then its link answers.
            holdSeam++;
            app = await RunningLock.hold(data);
            fake = await FakeNoted.start(data, holdLock: false);
            fake!.answer = (_) => const AiLinkResponse.written(box: 'aiA').encode();
          },
        ),
        'second change',
      );
      addTearDown(() async {
        await fake?.close();
        await app?.release();
      });
      go.complete();
      final r1 = await w1;
      final r2 = await w2;
      expect(holdSeam, 1);
      expect(r1.isError, isFalse, reason: r1.text);
      expect(r2.text, 'Written to box aiA.');
      expect(fake!.requests.whereType<AiLinkWriteBox>(), hasLength(1));
      final text = File(path).readAsStringSync();
      expect(text, contains('first change'));
      expect(text, isNot(contains('second change')), reason: 'W2 went to the app, not the file');
    });

    test('3. the retry after a changed page holds again', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      bool? second;
      final out = await append(
        toolbox(
          beforeReplace: (attempt) async {
            if (attempt == 0) File(path).writeAsStringSync('${File(path).readAsStringSync()}\n');
            if (attempt == 1) second = await canHold();
          },
        ),
      );
      expect(second, isFalse, reason: 'the second attempt holds the lock');
      expect(out.isError, isFalse, reason: out.text);
      expect(File(path).readAsStringSync(), contains('new words'));
    });
  });

  group('the limit', () {
    const limit = Duration(milliseconds: 300);

    test('4a. a read that outlasts the limit ends busy and writes nothing; a slow load before the hold does not count', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      var fired = false;
      final out = await append(
        toolbox(
          limit: limit,
          beforeRead: (_) async {
            fired = true;
            await Future<void>.delayed(const Duration(milliseconds: 900));
          },
        ),
      );
      expect(fired, isTrue);
      expect(out.isError, isTrue);
      expect(out.text, contains('busy'));
      expect(File(path).readAsStringSync(), before);
      expectNoStrays(path);
      expect(readLog(data).single.result, 'busy');

      // The second case: the time before take() isn't counted. (The limit is longer here
      // because the exclusive attempt, which starts a process, runs under the hold.)
      var slow = false;
      bool? during;
      final ok = await append(
        toolbox(
          limit: const Duration(seconds: 3),
          beforeHold: (_) async {
            slow = true;
            await Future<void>.delayed(const Duration(milliseconds: 3500));
          },
          beforeReplace: (_) async => during = await canHold(),
        ),
      );
      expect(slow, isTrue);
      expect(ok.isError, isFalse, reason: ok.text);
      expect(during, isFalse);
      expect(File(path).readAsStringSync(), contains('new words'));
    });

    test('4b. the timer lets go of a hold stuck in a read: Noted can start, and the late write is busy', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final pending = Completer<void>();
      final reached = Completer<void>();
      final w = append(
        toolbox(
          limit: limit,
          beforeRead: (_) async {
            reached.complete();
            await pending.future;
          },
        ),
      );
      await reached.future;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(await canHold(), isTrue, reason: 'the limit passed while the read is still pending');
      pending.complete();
      final out = await w;
      expect(out.isError, isTrue);
      expect(out.text, contains('busy'));
      expect(File(path).readAsStringSync(), before);
      expectNoStrays(path);
    });

    test('4c. greets() counts against the limit', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      // A listener that accepts and never greets.
      final mute = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      mute.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await mute.close();
      });
      final sw = Stopwatch();
      int? exclusiveAt;
      var fired = false;
      Future<void>? attempt;
      final out = await append(
        toolbox(
          limit: limit,
          greeting: const Duration(seconds: 4),
          beforeHold: (_) async {
            fired = true;
            // The link file appears only now, so the first probe didn't wait on it.
            File('${data.path}/$aiLinkFileName').writeAsStringSync(
              jsonEncode({'format': 1, 'port': mute.port, 'pid': 1, 'nonce': 'n'}),
            );
            sw.start();
            // An exclusive attempt after the limit, while greets() is still waiting.
            attempt = Future<void>.delayed(const Duration(milliseconds: 500), () async {
              if (await canHold()) exclusiveAt = sw.elapsedMilliseconds;
            });
          },
        ),
      );
      final end = sw.elapsedMilliseconds;
      await attempt;
      expect(fired, isTrue);
      expect(exclusiveAt, isNotNull, reason: 'the exclusive lock was free at about the limit');
      expect(exclusiveAt!, lessThan(end), reason: 'before greets() returned');
      expect(out.isError, isTrue);
      expect(out.text, contains('busy'));
      expect(File(path).readAsStringSync(), before);
    });

    test('4d. an expired attempt stops early: no temp file is created and replace is never reached', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      var reachedReplace = false;
      var fired = false;
      final out = await append(
        toolbox(
          limit: limit,
          beforeRecheck: (_) async {
            fired = true;
            await Future<void>.delayed(const Duration(milliseconds: 700));
          },
          beforeReplace: (_) async => reachedReplace = true,
        ),
      );
      expect(fired, isTrue);
      expect(reachedReplace, isFalse);
      expect(out.isError, isTrue);
      expect(out.text, contains('busy'));
      expect(File(path).readAsStringSync(), before);
      expectNoStrays(path);
    });
  });

  group('the gate', () {
    test('5. a probe paused in the gate does not let go of a write\'s hold', () async {
      writeStore(data, [writer()], allowClosed());
      final paused = Completer<void>();
      final reached = Completer<void>();
      var first = true;
      LockGate.beforeLockForTest = () async {
        if (!first) return;
        first = false;
        reached.complete();
        await paused.future;
      };
      final probe = isNotedRunning(data);
      await reached.future;
      bool? during;
      var fired = false;
      final w = append(
        toolbox(
          beforeReplace: (_) async {
            fired = true;
            during = await canHold();
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      paused.complete();
      expect(await probe, isFalse);
      final out = await w;
      expect(fired, isTrue);
      expect(during, isFalse, reason: 'the probe\'s close (on Linux a drop of every lock) did not free the write\'s hold');
      expect(out.isError, isFalse, reason: out.text);
    }, skip: false);

    test('two holds share one descriptor: the lock stays until the last release, and a release counts once', () async {
      final a = await LockGate.instance.take(data);
      final b = await LockGate.instance.take(data);
      expect(a.lockClass, LockClass.held);
      expect(b.lockClass, LockClass.held);
      expect(await canHold(), isFalse);
      await a.release();
      await a.release(); // again: harmless, and it takes nothing from b
      expect(await canHold(), isFalse, reason: 'b still holds');
      await b.release();
      expect(await canHold(), isTrue);
    });

    test('a hold taken while the app holds the lock says running, and nothing is left held', () async {
      final app = await RunningLock.hold(data);
      final h = await LockGate.instance.take(data);
      expect(h.lockClass, LockClass.running);
      await h.release();
      await app.release();
      final again = await LockGate.instance.take(data);
      expect(again.lockClass, LockClass.held);
      await again.release();
    });
  });

  group('Noted turns out to be running', () {
    test('6. a link that greets under the hold gets the write; the file is untouched', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      FakeNoted? fake;
      var fired = false;
      final out = await append(
        toolbox(
          beforeHold: (_) async {
            fired = true;
            fake = await FakeNoted.start(data, holdLock: false);
            fake!.answer = (_) => const AiLinkResponse.written(box: 'aiA').encode();
          },
        ),
      );
      addTearDown(() async => fake?.close());
      expect(fired, isTrue);
      expect(out.text, 'Written to box aiA.');
      expect(fake!.requests.whereType<AiLinkWriteBox>(), hasLength(1));
      expect(File(path).readAsStringSync(), before);
      expect(await canHold(), isTrue, reason: 'the hold was let go');
    });

    test('7. the app holds the lock but its link is not up: one retry, then busy, nothing written', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      RunningLock? app;
      var fired = false;
      final sends = <int>[];
      final times = Stopwatch()..start();
      final stamps = <int>[];
      final out = await append(
        toolbox(
          retryDelay: const Duration(seconds: 1),
          onLinkSend: (n) {
            sends.add(n);
            stamps.add(times.elapsedMilliseconds);
          },
          beforeHold: (_) async {
            fired = true;
            app = await RunningLock.hold(data); // no link
          },
        ),
      );
      addTearDown(() async => app?.release());
      expect(fired, isTrue);
      expect(sends, [1, 2]);
      expect(stamps[1] - stamps[0], greaterThanOrEqualTo(900), reason: 'about a second apart');
      expect(out.isError, isTrue);
      expect(out.text, notedBusyText);
      expect(File(path).readAsStringSync(), before);
      expect(readLog(data), isEmpty);
    });

    test('8. a missing lock file refuses the write: open Noted once', () async {
      writeStore(data, [writer()], allowClosed());
      File('${data.path}/$aiRunningLockFileName').deleteSync();
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final out = await append(toolbox());
      expect(out.isError, isTrue);
      expect(out.text, openNotedOnceText);
      expect(File(path).readAsStringSync(), before);
      expect(readLog(data).single.result, 'busy');
      expect(File('${data.path}/$aiRunningLockFileName').existsSync(), isFalse, reason: 'the server never creates it');
    });

    test('15. an unusable lock file (a folder) is running: busy with its own text, nothing written', () async {
      writeStore(data, [writer(), codeOf('3000000000000009', const AiCodeTarget.box('aiA', page: Ids.aiOpen))], allowClosed());
      File('${data.path}/$aiRunningLockFileName').deleteSync();
      Directory('${data.path}/$aiRunningLockFileName').createSync();
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      final out = await append(toolbox());
      expect(out.isError, isTrue);
      expect(out.text, lockUnusableText);
      expect(File(path).readAsStringSync(), before);
      final read = await toolbox().readBox('aiA', code: token('3000000000000009'));
      expect(read.isError, isTrue);
      expect(read.text, notedBusyText);
    });
  });

  group('the re-check', () {
    Future<void> rewriteStore(List<AiCode> codes, Map<String, Object?> boxes) async => writeStore(data, codes, boxes);

    test('12a. closed writes turned off before the hold are refused', () async {
      writeStore(data, [writer()], allowClosed('full'));
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      var fired = false;
      final out = await append(
        toolbox(
          beforeHold: (_) async {
            fired = true;
            await rewriteStore([writer()], const {});
          },
        ),
      );
      expect(fired, isTrue);
      expect(out.text, closedWritesOffText);
      expect(File(path).readAsStringSync(), before);
      expect(readLog(data).single.result, 'not_writable');
    });

    test('12b. a Writer permission reduced before the hold is refused for replace', () async {
      writeStore(data, [writer()], allowClosed('full'));
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      var fired = false;
      final out = await toolbox(
        beforeHold: (_) async {
          fired = true;
          await rewriteStore([writer()], allowClosed('append'));
        },
      ).writeBox(boxId: 'aiA', code: token(idWriter), mode: 'replace', content: 'x');
      expect(fired, isTrue);
      expect(out.isError, isTrue);
      expect(out.text, AiLinkCode.notPermitted.defaultMessage);
      expect(File(path).readAsStringSync(), before);
      expect(readLog(data).single.result, 'not_permitted');
    });

    test('12c. a code revoked before the hold is refused as the pre-check refuses it', () async {
      writeStore(data, [writer()], allowClosed());
      final path = aiOpenPath();
      final before = File(path).readAsStringSync();
      var fired = false;
      final out = await append(
        toolbox(
          beforeHold: (_) async {
            fired = true;
            await rewriteStore([codeOf(idWriter, const AiCodeTarget.box('aiA', page: Ids.aiOpen), role: 'writer', revoked: DateTime.utc(2026, 2, 1))], allowClosed());
          },
        ),
      );
      expect(fired, isTrue);
      expect(out.isError, isTrue);
      expect(out.text, contains('not valid'));
      expect(File(path).readAsStringSync(), before);
      expect(readLog(data), isEmpty, reason: 'a revoked code is not logged, by the pre-check either');
    });

    // A page in the Bare binder (nothing set), with its AI box.
    String bare(String id) => '${root.path}/Bare/$id.canvas';
    String bareBinderFile() => '${root.path}/Bare/$binderFileName';
    NotedPage aiPage(String id, {String? parent, String ai = 'open'}) =>
        page(id, 'P $id', parent: parent, ai: ai, nodes: [box('aiN', aiBoxTypeId, aiBoxData('kid'), const Bounds(0, 0, 100, 40))]);

    Future<ToolOutput> writeN(NotedToolbox t) =>
        t.writeBox(boxId: 'aiN', code: token(idWriter), mode: 'append', content: 'words');

    void storeN(String page) => writeStore(data, [writer(box: 'aiN', page: page)], allowClosed('full', 'aiN'));

    test('14a. a binder file that now disallows AI boxes refuses the write (second attempt)', () async {
      final p = aiPage('f000000000000030');
      File(bare(p.id)).writeAsStringSync(writePage(p));
      storeN(p.id);
      final before = File(bare(p.id)).readAsStringSync();
      var holds = 0;
      var reads = 0;
      final out = await writeN(
        toolbox(
          beforeRead: (_) async => reads++,
          beforeHold: (_) async {
            holds++;
            final b = Binder.parse(File(bareBinderFile()).readAsStringSync()).withBoxType(aiBoxTypeId, false);
            File(bareBinderFile()).writeAsStringSync(b.write());
          },
        ),
      );
      expect(holds, 1);
      expect(reads, 0);
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      expect(File(bare(p.id)).readAsStringSync(), before);
      expect(readLog(data).single.result, 'not_writable');
    });

    test('14b. a parent page that now disallows AI boxes refuses the write (binder, two levels down)', () async {
      final g = page('f000000000000040', 'Grand', ai: 'open');
      final par = page('f000000000000041', 'Parent', parent: g.id, ai: 'open');
      final c = aiPage('f000000000000042', parent: par.id);
      for (final p in [g, par, c]) {
        File(bare(p.id)).writeAsStringSync(writePage(p));
      }
      storeN(c.id);
      final before = File(bare(c.id)).readAsStringSync();
      var holds = 0;
      final out = await writeN(
        toolbox(
          beforeHold: (_) async {
            holds++;
            File(bare(g.id)).writeAsStringSync(writePage(g.withMeta(g.meta.withBoxType(aiBoxTypeId, false))));
          },
        ),
      );
      expect(holds, 1);
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      expect(File(bare(c.id)).readAsStringSync(), before);
      expect(readLog(data).single.result, 'not_writable');
    });

    test('14b. a standalone parent in another standalone folder that now disallows AI boxes refuses the write', () async {
      final other = Directory('${root.path}/Second')..createSync();
      final parent = page('f000000000000050', 'Parent', ai: 'privileged');
      final child = aiPage('f000000000000051', parent: parent.id);
      File('${data.path}/pages/${parent.id}.canvas').writeAsStringSync(writePage(parent));
      File('${other.path}/${child.id}.canvas').writeAsStringSync(writePage(child));
      File('${data.path}/binders.json').writeAsStringSync(
        jsonEncode({
          'format': 1,
          'binders': ['${root.path}/Trips', '${root.path}/Taxes', '${root.path}/Bare', '${root.path}/Vault'],
          'standaloneFolders': [other.path],
        }),
      );
      storeN(child.id);
      final before = File('${other.path}/${child.id}.canvas').readAsStringSync();
      var holds = 0;
      final out = await writeN(
        toolbox(
          beforeHold: (_) async {
            holds++;
            File('${data.path}/pages/${parent.id}.canvas').writeAsStringSync(
              writePage(parent.withMeta(parent.meta.withBoxType(aiBoxTypeId, false))),
            );
          },
        ),
      );
      expect(holds, 1);
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      expect(File('${other.path}/${child.id}.canvas').readAsStringSync(), before);
    });

    test('14c. a binder file now locked refuses the write', () async {
      final p = aiPage('f000000000000031');
      File(bare(p.id)).writeAsStringSync(writePage(p));
      storeN(p.id);
      final before = File(bare(p.id)).readAsStringSync();
      var holds = 0;
      final out = await writeN(
        toolbox(
          beforeHold: (_) async {
            holds++;
            final j = jsonDecode(File(bareBinderFile()).readAsStringSync()) as Map<String, Object?>;
            j['locked'] = true;
            File(bareBinderFile()).writeAsStringSync(jsonEncode(j));
          },
        ),
      );
      expect(holds, 1);
      expect(out.isError, isTrue);
      expect(out.text, contains('cannot be edited'));
      expect(File(bare(p.id)).readAsStringSync(), before);
      expect(readLog(data).single.result, 'locked');
    });

    test('14d. a parent that was absent at the load and appears under the hold refuses the write', () async {
      const parentId = 'f000000000000060';
      final child = aiPage('f000000000000061', parent: parentId);
      File('${data.path}/pages/${child.id}.canvas').writeAsStringSync(writePage(child));
      storeN(child.id);
      final path = '${data.path}/pages/${child.id}.canvas';
      final before = File(path).readAsStringSync();
      var holds = 0;
      final out = await writeN(
        toolbox(
          beforeHold: (_) async {
            holds++;
            final parent = page(parentId, 'Late parent', ai: 'open');
            File('${data.path}/pages/$parentId.canvas').writeAsStringSync(
              writePage(parent.withMeta(parent.meta.withBoxType(aiBoxTypeId, false))),
            );
          },
        ),
      );
      expect(holds, 1);
      expect(out.isError, isTrue);
      expect(out.text, contains('does not take writes'));
      expect(File(path).readAsStringSync(), before);
    });

    test('14e. identical bytes with a new mtime are no difference: the write lands on the first attempt, under the hold', () async {
      final g = page('f000000000000070', 'Parent', ai: 'open');
      final c = aiPage('f000000000000071', parent: g.id);
      for (final p in [g, c]) {
        File(bare(p.id)).writeAsStringSync(writePage(p));
      }
      storeN(c.id);
      var reads = 0;
      bool? during;
      final out = await writeN(
        toolbox(
          beforeRead: (_) async => reads++,
          beforeHold: (_) async {
            for (final path in ['${data.path}/binders.json', bareBinderFile(), bare(g.id)]) {
              final f = File(path);
              f.writeAsBytesSync(f.readAsBytesSync());
              f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 30)));
            }
          },
          beforeReplace: (_) async => during = await canHold(),
        ),
      );
      expect(out.isError, isFalse, reason: out.text);
      expect(reads, 1, reason: 'first attempt');
      expect(during, isFalse);
      expect(File(bare(c.id)).readAsStringSync(), contains('words'));
    });

    test('a folder that keeps failing to list is no difference', () async {
      // The page's own folder is fine; a standalone folder that is a file fails both times.
      final blocker = File('${root.path}/not-a-folder')..writeAsStringSync('x');
      File('${data.path}/binders.json').writeAsStringSync(
        jsonEncode({
          'format': 1,
          'binders': ['${root.path}/Trips', '${root.path}/Taxes', '${root.path}/Bare', '${root.path}/Vault'],
          'standaloneFolders': [blocker.path],
        }),
      );
      writeStore(data, [writer()], allowClosed());
      final out = await append(toolbox());
      expect(out.isError, isFalse, reason: out.text);
    });
  });

  test('16. a synced link to the lock file is never opened by a read (Linux and macOS)', () async {
    writeStore(data, [writer()], allowClosed());
    final folder = '${data.path}/pages';
    var fired = false;
    bool? during;
    List<String>? listed;
    final t = toolbox();
    final out = await append(
      toolbox(
        beforeHold: (_) async {
          fired = true;
          Link('$folder/x.canvas').createSync('${data.path}/$aiRunningLockFileName');
        },
        beforeReplace: (_) async {
          // A library load through the same toolbox reads every *.canvas.
          listed = (jsonDecode((await t.listPages()).text)['pages'] as List).cast<Map<String, Object?>>().map((p) => '${p['id']}').toList();
          during = await canHold();
        },
      ),
    );
    expect(fired, isTrue);
    expect(listed, isNotNull);
    expect(during, isFalse, reason: 'the read did not close the descriptor that holds the lock');
    expect(out.isError, isFalse, reason: out.text);
  }, skip: Platform.isWindows ? 'POSIX locks are per process; a link to the lock file matters only there' : false);

}
