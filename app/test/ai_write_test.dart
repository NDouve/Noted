// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_access_service.dart';
import 'package:noted/src/ai/ai_link_authority.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/binder_seams.dart';

/// A box type that takes AI writes: `{"by": code id|null, "text": text}`.
class _Codec extends BoxCodec<Map<String, Object?>> {
  const _Codec(this.typeId, {this.writes = true});

  @override
  final String typeId;
  final bool writes;

  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  Map<String, Object?> create() => {'by': null, 'text': ''};
  @override
  Map<String, Object?> decode(Object? json, int storedVersion) => Map<String, Object?>.from(json! as Map);
  @override
  Object? encode(Map<String, Object?> data) => data;
  @override
  String snapshotText(Map<String, Object?> data) => data['text']! as String;
  @override
  AiExposure aiExposure(Map<String, Object?> data) => AiText(data['text']! as String);
  @override
  Map<String, Object?>? aiWrite(Map<String, Object?> data, AiWrite write) {
    if (!writes) return null;
    final old = data['text']! as String;
    return {
      ...data,
      'by': write.connectionId,
      'mode': write.mode.name,
      'text': write.mode == AiWriteMode.replace ? write.content : '$old${write.content}',
    };
  }
}

class _Module extends BoxModule<Map<String, Object?>> {
  const _Module(this.codec);

  @override
  final BoxCodec<Map<String, Object?>> codec;
  @override
  Widget buildEditor(BuildContext context, BoxContext<Map<String, Object?>> box) => Text('${box.data['text']}');
  @override
  Widget buildView(BuildContext context, BoxContext<Map<String, Object?>> box) => Text('${box.data['text']}');
}

/// A store that deletes its folder right after it has loaded a page for the
/// [vanishOnLoad]th time.
class _VanishingStore extends PageStore {
  _VanishingStore(super.directory);

  int loads = 0;
  int? vanishOnLoad;

  @override
  Future<NotedPage> load(String pageId) async {
    final page = await super.load(pageId);
    loads++;
    if (loads == vanishOnLoad) directory.deleteSync(recursive: true);
    return page;
  }
}

/// A store that runs [beforeWrite] once, right before the next compare-and-swap
/// replace: a sync client landing a newer version of the file at that moment.
class _SyncingStore extends PageStore {
  _SyncingStore(super.directory);

  void Function()? beforeWrite;

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) {
    final f = beforeWrite;
    beforeWrite = null;
    f?.call();
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforePublish: beforePublish,
      beforeRestore: beforeRestore,
    );
  }
}

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Directory data;
  late AiAccessService service;
  late ModuleRegistry modules;
  late List<Notebook> opened;
  late List<AiApprovalRequest> asked;
  // How the user answers a question; null: the question stays open.
  late Future<bool> Function(AiApprovalRequest) answer;
  var timings = const AiLinkTimings(approval: Duration(seconds: 5));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_aiwrite');
    pages = await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    data = await Directory('${root.path}/data').create();
    opened = [];
    asked = [];
    answer = (_) async => true;
    timings = const AiLinkTimings(approval: Duration(seconds: 5));
    service = AiAccessService(dataFolder: data);
    modules = _modules();
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    service.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook make({
    PageStore? store,
    Directory? recovery,
    BinderStore Function(Directory)? binderStores,
  }) {
    final nb = Notebook(
      store ?? PageStore(pages),
      modules,
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      deviceName: 'TestPC',
      aiAccess: service,
      aiTimings: timings,
      recoveryDirectory: recovery,
      binderStoreFactory: binderStores ?? BinderStore.new,
    );
    nb.aiApprover = (r) {
      asked.add(r);
      return answer(r);
    };
    opened.add(nb);
    return nb;
  }

  BoxRecord box(String id, {String text = '', String type = 'test.ai'}) => BoxRecord.create(
    id: id,
    typeId: type,
    dataVersion: 1,
    bounds: const Bounds(40, 40, 200, 80),
    data: RawJson.encode({'by': null, 'text': text}),
    snapshotText: text,
    rev: 'r-$id',
  );

  // The data of box [id] on the open page.
  Map<String, Object?> dataOf(Notebook nb, String id) =>
      ((nb.current!.page.node(id)! as BoxRecord).data!.decode()! as Map).cast<String, Object?>();

  Future<String> issue(
    String boxId, {
    AiCodeRole role = AiCodeRole.writer,
    String label = 'Work chat',
  }) async {
    final code = await service.issue(AiCodeTarget.box(boxId), role: role, label: label);
    // Most tests are about something else than the Writer permission.
    if (role == AiCodeRole.writer) await service.setWriterPermission(boxId, AiWriterPermission.full);
    return code;
  }

  AiLinkWriteBox req(
    String boxId,
    String code, {
    String content = 'hello',
    AiLinkMode mode = AiLinkMode.replace,
    String session = 's1',
    String? app = 'Claude Code',
  }) => AiLinkWriteBox(code: code, session: session, app: app, box: boxId, mode: mode, content: content);

  Future<AiLinkCode?> codeOf(Notebook nb, AiLinkRequest r) async {
    final response = await nb.handleAiLink(r);
    return response is AiLinkError ? response.code : null;
  }

  // A notebook with page `a` (Guarded: nothing chosen) and a box `ba` with a
  // Writer code.
  Future<({Notebook nb, String a, String code})> withBox() async {
    final nb = make();
    await nb.load();
    final a = nb.currentId!;
    nb.current!.insertBox(box('ba', text: 'old'));
    await nb.flush();
    return (nb: nb, a: a, code: await issue('ba'));
  }

  AiCode stored(String codeText) => service.store.codes().singleWhere((c) => c.id == parseAiToken(codeText)!.id);

  group('busy', () {
    test('a notebook that is still loading answers busy and changes nothing', () async {
      timings = const AiLinkTimings(deadline: Duration(milliseconds: 800));
      final nb = make();
      final code = await issue('ba');
      // load() is never called.
      expect(await codeOf(nb, req('ba', code)), AiLinkCode.busy);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('an unreadable codes file answers busy until it can be read', () async {
      final t = await withBox();
      final file = service.store.file;
      final good = file.readAsStringSync();
      file.writeAsStringSync('{ damaged');
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.busy);
      expect(await codeOf(t.nb, req('ba', 'nonsense')), AiLinkCode.busy);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(file.readAsStringSync(), '{ damaged', reason: 'the damaged file is left alone');
      file.writeAsStringSync(good);
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);
    });

    test('a codes file another process holds locked answers busy', () async {
      final t = await withBox();
      final lock = File('${service.store.file.path}.lock').openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive);
      try {
        expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.busy);
      } finally {
        lock.unlockSync();
        lock.closeSync();
      }
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    }, skip: !Platform.isWindows ? 'file locks are per process on POSIX' : false);
  });

  test('each wire mode reaches the codec as its own AiWriteMode (replace_ai is replaceAiText)', () async {
    final t = await withBox();
    final expected = {
      AiLinkMode.append: AiWriteMode.append,
      AiLinkMode.replaceAi: AiWriteMode.replaceAiText,
      AiLinkMode.replace: AiWriteMode.replace,
    };
    expect(expected.keys, AiLinkMode.values);
    for (final e in expected.entries) {
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'x', mode: e.key))).ok, isTrue, reason: e.key.name);
      expect(dataOf(t.nb, 'ba')['mode'], e.value.name);
    }
  });

  test('a request that is this protocol but malformed answers bad_request', () async {
    final t = await withBox();
    final r = await t.nb.handleAiLink(const AiLinkMalformed('write_box needs a box.'));
    expect((r as AiLinkError).code, AiLinkCode.badRequest);
    expect(r.message, 'write_box needs a box.');
  });

  test('without codes at all, every code is bad_code', () async {
    final nb = Notebook(PageStore(pages), modules, saveDelay: Duration.zero);
    addTearDown(nb.dispose);
    expect(await codeOf(nb, req('ba', 'noted_${'0' * 16}_${'A' * 43}')), AiLinkCode.badCode);
  });

  group('accepted', () {
    test('a write to the open page shows at once, is one undo step and is saved', () async {
      final t = await withBox();
      final c = t.nb.current!;
      var notified = 0;
      c.addListener(() => notified++);
      final before = (c.page.node('ba')! as BoxRecord);

      final r = await t.nb.handleAiLink(req('ba', t.code, content: 'new text'));
      expect(r, isA<AiLinkWritten>());
      expect((r as AiLinkWritten).box, 'ba');
      expect(r.encode(), isNot(contains(t.a)), reason: 'the answer names no page');
      expect(notified, greaterThan(0), reason: 'the canvas is told');
      expect(dataOf(t.nb, 'ba')['text'], 'new text');
      expect(dataOf(t.nb, 'ba')['by'], stored(t.code).id, reason: 'the code id is the writer');
      final after = c.page.node('ba')! as BoxRecord;
      expect(after.snapshotText, 'new text');
      expect(after.rev, isNot(before.rev));
      expect(after.device, 'TestPC');
      expect(File('${pages.path}/${t.a}.canvas').readAsStringSync(), contains('new text'));

      c.undo();
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(c.page.node('ba'), isNotNull);
      c.redo();
      expect(dataOf(t.nb, 'ba')['text'], 'new text');
    });

    test('append adds to the text', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, content: ' more', mode: AiLinkMode.append));
      expect(dataOf(t.nb, 'ba')['text'], 'old more');
    });

    test('whatever the page access: Open, Privileged and Guarded all take the write', () async {
      final t = await withBox();
      for (final access in AiAccess.values) {
        await t.nb.setAiAccess(t.a, access);
        final r = await t.nb.handleAiLink(req('ba', t.code, content: access.name));
        expect(r.ok, isTrue, reason: access.name);
        expect(dataOf(t.nb, 'ba')['text'], access.name);
      }
    });

    test('a box on a subpage is found', () async {
      final t = await withBox();
      await t.nb.createPage(parentId: t.a);
      t.nb.current!.insertBox(box('bs'));
      final code = await issue('bs');
      expect((await t.nb.handleAiLink(req('bs', code))).ok, isTrue);
    });

    test('a write to a closed page is on disk and survives a restart', () async {
      final t = await withBox();
      final other = await t.nb.createPage();
      expect(t.nb.currentId, other);

      final r = await t.nb.handleAiLink(req('ba', t.code, content: 'closed write'));
      expect(r.ok, isTrue);
      expect(File('${pages.path}/${t.a}.canvas').readAsStringSync(), contains('closed write'));

      t.nb.dispose();
      opened.clear();
      final again = make();
      await again.load();
      await again.open(t.a);
      expect(dataOf(again, 'ba')['text'], 'closed write');
      final rec = again.current!.page.node('ba')! as BoxRecord;
      expect(rec.snapshotText, 'closed write');
      expect(rec.device, 'TestPC');
      expect(rec.rev, isNot('r-ba'));
    });

    test('a page in a binder is found, and a hint of the wrong page does not matter', () async {
      final nb = make();
      await nb.load();
      final s = await nb.addBinder(folder.path);
      final p = await nb.createPage(binderPath: s.path);
      nb.current!.insertBox(box('bb'));
      await nb.open(nb.tree.roots.first.id);
      expect(nb.currentId, isNot(p));
      final code = await service.issue(
        AiCodeTarget.box('bb', page: 'a-page-that-moved-away'),
        role: AiCodeRole.writer,
        label: 'Binder chat',
      );
      await service.setWriterPermission('bb', AiWriterPermission.full);
      final r = await nb.handleAiLink(req('bb', code, content: 'in binder'));
      expect(r.ok, isTrue);
      expect(File('${folder.path}/$p.canvas').readAsStringSync(), contains('in binder'));
    });
  });

  group('approval', () {
    test('the first use of a code asks, once; the code is then approved for every session', () async {
      final t = await withBox();
      expect(stored(t.code).approved, isNull);
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'one'))).ok, isTrue);
      expect(asked, hasLength(1));
      expect(asked.single.message, 'Claude Code wants to read and write the AI box (code "Work chat"). Allow?');
      expect(asked.single.perWrite, isFalse);
      expect(asked.single.closedApp, isFalse);
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'two'))).ok, isTrue);
      expect(asked, hasLength(1), reason: 'same code: not asked again');
      expect(stored(t.code).approved, isNotNull);

      // Another session, another app: the code is approved, so no question.
      expect((await t.nb.handleAiLink(req('ba', t.code, session: 's2', app: 'Cursor'))).ok, isTrue);
      expect(asked, hasLength(1));
    });

    test('a revoked code is gone, and a new code of the box asks again', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code));
      await service.revoke(stored(t.code).id);
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.badCode);
      final fresh = await issue('ba');
      expect((await t.nb.handleAiLink(req('ba', fresh))).ok, isTrue);
      expect(asked, hasLength(2));
    });

    test('a revoked code stays in the file marked, is bad_code, and its use is not logged', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code));
      final id = stored(t.code).id;
      final before = service.activityFor(AiCodeTargetKind.box, 'ba').length;
      await service.revoke(id);
      expect(stored(t.code).isRevoked, isTrue);
      expect(stored(t.code).revoked, isNotNull);
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.badCode);
      expect(asked, hasLength(1), reason: 'no question for a revoked code');
      final activity = service.activityFor(AiCodeTargetKind.box, 'ba');
      expect(activity, hasLength(before), reason: 'an unknown/revoked code is not logged');
      expect(activity.every((e) => e.extra['revoked'] == true), isTrue, reason: 'its history is marked');
    });

    test('a new Writer retires the old one by marking it revoked', () async {
      final t = await withBox();
      final fresh = await issue('ba');
      expect(stored(t.code).isRevoked, isTrue);
      expect(stored(fresh).isRevoked, isFalse);
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.badCode);
    });

    test('the question names what it reaches: the box by its first line, cut short and on one line', () async {
      final nb = make();
      await nb.load();
      nb.current!.insertBox(box('bl', text: '  \n"Quoted"   title ${'x' * 80}\nsecond'));
      await nb.flush();
      final code = await issue('bl', label: 'Chat');
      await nb.handleAiLink(req('bl', code));
      expect(asked.single.message, 'Claude Code wants to read and write the AI box (code "Chat"). Allow?');
      final name = asked.single.reachName!;
      expect(name, startsWith('"Quoted" title xxx'));
      expect(name, endsWith('…'));
      expect(name.characters.length, 61, reason: '60 characters and the ellipsis');
      expect(name, isNot(contains('second')));
    });

    test('combining-mark runs are dropped and the cut is by grapheme, not by code unit', () async {
      final nb = make();
      await nb.load();
      const flag = '\u{1F1EB}\u{1F1F7}'; // one grapheme of two code points
      final zalgo = 'Z${'́' * 40}ok ${flag * 70}';
      nb.current!.insertBox(box('bz', text: zalgo));
      await nb.flush();
      final code = await issue('bz', label: 'Chat');
      await nb.handleAiLink(req('bz', code));
      final name = asked.single.reachName!;
      expect(name, startsWith('Zok '));
      expect(name.characters.length, 61);
      expect(name, endsWith('…'));
      expect(name.characters.skip(4).take(60).every((c) => c == flag || c == '…'), isTrue, reason: 'no flag cut in half');
    });

    test('a slow lookup of what the code reaches does not hold the question: the old wording is used', () async {
      final code = await issue('ba');
      final authority = AiLinkAuthority(
        service: service,
        host: _NeverNamesHost(),
        approver: (r) async {
          asked.add(r);
          return true;
        },
        timings: const AiLinkTimings(reachLookup: Duration(milliseconds: 50)),
      );
      final sw = Stopwatch()..start();
      await authority.handle(AiLinkDescribeCode(code: code, session: 's', app: 'Claude Code'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(asked.single.reach, isNull);
      expect(asked.single.reachName, isNull);
      expect(asked.single.message, 'Claude Code wants to read and write Work chat. Allow?');
    });

    test('old sessions in the file are ignored: an unapproved code with a session still asks', () async {
      final t = await withBox();
      service.store.addSession(
        stored(t.code).id,
        AiCodeSession(id: 's1', app: 'Claude Code', approved: DateTime.now().toUtc()),
      );
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);
      expect(asked, hasLength(1));
    });

    test('a read asks "read"', () async {
      final t = await withBox();
      final reader = await issue('ba', role: AiCodeRole.reader, label: 'Review chat');
      await t.nb.handleAiLink(AiLinkAccess(code: reader, session: 's9', app: 'Cursor', action: AiLinkAction.readBox, target: 'ba'));
      expect(asked.single.message, 'Cursor wants to read the AI box (code "Review chat"). Allow?');
    });

    test('a request without an app name still reads well', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, app: null));
      expect(asked.single.message, 'An AI app wants to read and write the AI box (code "Work chat"). Allow?');
    });

    test('control characters in the app name become spaces', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, app: 'Evil\n\u0007App x'));
      expect(asked.single.message, 'Evil  App x wants to read and write the AI box (code "Work chat"). Allow?');
    });

    test('deny: not_approved, nothing written, nothing remembered', () async {
      timings = const AiLinkTimings(denyCooldown: Duration.zero);
      final t = await withBox();
      answer = (_) async => false;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(stored(t.code).approved, isNull);
      expect(stored(t.code).lastUsed, isNull);
      answer = (_) async => true;
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);
      expect(asked, hasLength(2), reason: 'no pause configured: asked again');
    });

    test('after a Deny, further requests of that code are refused without a question for a while', () async {
      timings = const AiLinkTimings(denyCooldown: Duration(milliseconds: 500));
      final t = await withBox();
      answer = (_) async => false;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      answer = (_) async => true;
      expect(await codeOf(t.nb, req('ba', t.code, session: 'other')), AiLinkCode.notApproved);
      expect(asked, hasLength(1), reason: 'not asked during the pause');
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect((await t.nb.handleAiLink(req('ba', t.code, session: 'other'))).ok, isTrue);
      expect(asked, hasLength(2));
    });

    test('no answer is not a Deny: no pause', () async {
      timings = const AiLinkTimings(approval: Duration(milliseconds: 100));
      final t = await withBox();
      answer = (_) => Completer<bool>().future;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      answer = (_) async => true;
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);
    });

    test('only one question is on screen at a time; the rest wait their turn', () async {
      final t = await withBox();
      final second = await issue('ba', role: AiCodeRole.reader, label: 'Second');
      var open = 0;
      var most = 0;
      answer = (_) async {
        open++;
        if (open > most) most = open;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        open--;
        return true;
      };
      final a = t.nb.handleAiLink(req('ba', t.code));
      final b = t.nb.handleAiLink(
        AiLinkAccess(code: second, session: 's2', app: 'B', action: AiLinkAction.readBox, target: 'ba'),
      );
      expect((await a).ok && (await b).ok, isTrue);
      expect(asked, hasLength(2));
      expect(most, 1);
    });

    test('too many waiting questions get busy, and an approved code is still answered', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, content: 'warm up')); // approved
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      Future<AiLinkResponse> ask(String code, String session) => t.nb.handleAiLink(
        AiLinkAccess(code: code, session: session, app: 'B', action: AiLinkAction.readBox, target: 'ba'),
      );
      final waiting = [
        for (var i = 0; i < aiMaxPendingPrompts; i++) ask(await issue('ba', role: AiCodeRole.reader, label: 'R$i'), 'n$i'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await codeOf(t.nb, AiLinkAccess(code: await issue('ba', role: AiCodeRole.reader, label: 'late'), session: 'n9', action: AiLinkAction.readBox, target: 'ba')), AiLinkCode.busy);
      expect((await t.nb.handleAiLink(AiLinkDescribeCode(code: t.code, session: 's1'))).ok, isTrue);
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'still works'))).ok, isTrue);
      gate.complete(false);
      for (final w in waiting) {
        await w;
      }
    });

    test('a code waiting for a question does not hold up other codes', () async {
      final t = await withBox();
      final other = await issue('ba', role: AiCodeRole.reader, label: 'Other');
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      // The first code's question is open; its next request joins it.
      final first = t.nb.handleAiLink(req('ba', t.code, session: 'h1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final joined = t.nb.handleAiLink(req('ba', t.code, session: 'h2'));
      // Another code still gets its question (queued behind the first).
      final second = t.nb.handleAiLink(
        AiLinkAccess(code: other, session: 'o1', app: 'B', action: AiLinkAction.readBox, target: 'ba'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete(true);
      expect((await first).ok, isTrue);
      expect((await joined).ok, isTrue);
      expect((await second).ok, isTrue);
      expect(asked, hasLength(2));
    });

    test('two requests from one new session share one question and one place', () async {
      final t = await withBox();
      final other = await issue('ba', role: AiCodeRole.reader, label: 'Other');
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      final a = t.nb.handleAiLink(req('ba', t.code, session: 'p1', content: 'a'));
      final b = t.nb.handleAiLink(req('ba', t.code, session: 'p1', content: 'b'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final c = t.nb.handleAiLink(
        AiLinkAccess(code: other, session: 'o1', app: 'B', action: AiLinkAction.readBox, target: 'ba'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete(true);
      expect((await a).ok && (await b).ok, isTrue);
      expect((await c).ok, isTrue, reason: 'the shared question took one place only');
      expect(asked, hasLength(2));
    });

    test('a per-write question with no room to ask answers busy, not a refusal', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, content: 'warm up')); // approves the code
      await service.setAskBeforeWrite('ba', true);
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      // This code's own place is taken by the first write's question.
      final pending = t.nb.handleAiLink(req('ba', t.code, content: 'first'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await codeOf(t.nb, req('ba', t.code, content: 'later')), AiLinkCode.busy);
      gate.complete(false);
      await pending;
    });

    test('one deadline covers the question and the load, below the client\'s', () async {
      timings = const AiLinkTimings(deadline: Duration(milliseconds: 700));
      expect(const AiLinkTimings().deadline, lessThan(const Duration(seconds: 55)));
      final nb = make(); // never loaded
      final code = await issue('ba');
      answer = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return true;
      };
      final watch = Stopwatch()..start();
      expect(await codeOf(nb, req('ba', code)), AiLinkCode.busy);
      expect(watch.elapsedMilliseconds, inInclusiveRange(600, 5000), reason: 'the load only got what the question left');
    });

    test('a question nobody answers ends at the deadline, not at its own longer timeout', () async {
      timings = const AiLinkTimings(approval: Duration(seconds: 30), deadline: Duration(milliseconds: 400));
      final t = await withBox();
      answer = (_) => Completer<bool>().future;
      final watch = Stopwatch()..start();
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      // Far below the question's own 30 s, with room for a slow CI machine.
      expect(watch.elapsedMilliseconds, lessThan(5000));
      await asked.single.expired;
    });

    test('a write is not applied once the client has gone', () async {
      final t = await withBox();
      await service.setAskBeforeWrite('ba', true);
      await t.nb.handleAiLink(req('ba', t.code, content: 'warm up')); // asks session and write
      var open = true;
      answer = (r) async {
        if (r.perWrite) open = false; // the client drops while the question is open
        return true;
      };
      final before = dataOf(t.nb, 'ba')['text'];
      final r = await t.nb.handleAiLink(req('ba', t.code, content: 'too late'), () => open);
      expect((r as AiLinkError).code, AiLinkCode.busy);
      expect(dataOf(t.nb, 'ba')['text'], before);
    });

    test('format characters in an app name are dropped', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, app: 'Cla\u202Eude​ \u2066Code\u2069'));
      expect(asked.single.message, 'Claude Code wants to read and write the AI box (code "Work chat"). Allow?');
    });

    test('no answer in time: not_approved, and the question is told to close', () async {
      timings = const AiLinkTimings(approval: Duration(milliseconds: 200));
      final t = await withBox();
      answer = (_) => Completer<bool>().future;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      await asked.single.expired;
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(stored(t.code).sessions, isEmpty);
    });

    test('nobody to ask: not_approved', () async {
      final t = await withBox();
      t.nb.aiApprover = null;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
    });

    test('revoked while the question is open: refused, nothing written or remembered', () async {
      final t = await withBox();
      final id = stored(t.code).id;
      answer = (_) async {
        await service.revoke(id);
        return true;
      };
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.badCode);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(service.store.codes().single.isRevoked, isTrue, reason: 'kept, marked revoked');
      expect(service.store.codes().single.approved, isNull, reason: 'a revoked code is not approved');
    });

    test('expired while the question is open: refused', () async {
      final t = await withBox();
      final id = stored(t.code).id;
      answer = (_) async {
        service.store.update((d) => d.put(d.code(id)!.withExpires(DateTime.now().subtract(const Duration(hours: 1)))));
        return true;
      };
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.expired);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });

    test('two requests of one new session ask once', () async {
      final t = await withBox();
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      final a = t.nb.handleAiLink(req('ba', t.code, content: 'a'));
      final b = t.nb.handleAiLink(req('ba', t.code, content: 'b', mode: AiLinkMode.append));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(asked, hasLength(1));
      gate.complete(true);
      expect((await a).ok && (await b).ok, isTrue);
      expect(asked, hasLength(1));
    });
  });

  group('ask before each write', () {
    test('asks with a preview; allow writes, deny does not', () async {
      final t = await withBox();
      await service.setAskBeforeWrite('ba', true);
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'first'))).ok, isTrue);
      expect(asked, hasLength(2), reason: 'the session, then the write');
      final write = asked.last;
      expect(write.perWrite, isTrue);
      expect(write.message, 'Claude Code wants to write to the AI box (code "Work chat"). Allow?');
      expect(write.preview, 'Replace with: first');

      answer = (r) async => !r.perWrite;
      expect(await codeOf(t.nb, req('ba', t.code, content: 'second', mode: AiLinkMode.append)), AiLinkCode.notApproved);
      expect(asked.last.preview, 'Add: second');
      expect(dataOf(t.nb, 'ba')['text'], 'first');

      await service.setAskBeforeWrite('ba', false);
      answer = (_) async => true;
      final count = asked.length;
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'third'))).ok, isTrue);
      expect(asked, hasLength(count), reason: 'no longer asked');
    });

    test('a long preview is shortened', () async {
      final t = await withBox();
      await service.setAskBeforeWrite('ba', true);
      await t.nb.handleAiLink(req('ba', t.code, content: 'x ${'word ' * 100}'));
      expect(asked.last.preview!.length, lessThan(230));
      expect(asked.last.preview, endsWith('…'));
    });

    test('is not asked about a write that would be refused', () async {
      final t = await withBox();
      await service.setAskBeforeWrite('ba', true);
      t.nb.current!.readOnly = true;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.locked);
      expect(asked.where((a) => a.perWrite), isEmpty);
    });

    test('revoked while the question is open: refused', () async {
      final t = await withBox();
      await service.setAskBeforeWrite('ba', true);
      final id = stored(t.code).id;
      answer = (r) async {
        if (r.perWrite) await service.revoke(id);
        return true;
      };
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.badCode);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });

    test('no answer in time: not_approved', () async {
      timings = const AiLinkTimings(approval: Duration(milliseconds: 200));
      final t = await withBox();
      await service.setAskBeforeWrite('ba', true);
      answer = (r) => r.perWrite ? Completer<bool>().future : Future.value(true);
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });
  });

  group('activity and use', () {
    test('every request is logged with op, app, label and result, never the content', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, content: 'a secret sentence'));
      answer = (_) async => false;
      final unasked = await issue('ba', role: AiCodeRole.reader, label: 'Other chat');
      await t.nb.handleAiLink(
        AiLinkAccess(code: unasked, session: 'other', app: 'Other app', action: AiLinkAction.readBox, target: 'ba'),
      );
      final reader = await issue('ba', role: AiCodeRole.reader, label: 'Reader');
      answer = (_) async => true;
      await t.nb.handleAiLink(req('ba', reader)); // wrong role
      await t.nb.handleAiLink(
        AiLinkAccess(code: t.code, session: 's1', app: 'Claude Code', action: AiLinkAction.readBox, target: 'ba'),
      );
      await t.nb.handleAiLink(AiLinkDescribeCode(code: t.code, session: 's1', app: 'Claude Code'));

      final entries = service.activity('ba');
      expect(entries.map((e) => (e.op, e.result, e.app, e.label)), [
        ('write_box', 'ok', 'Claude Code', 'Work chat'),
        ('read_box', 'not_approved', 'Other app', 'Other chat'),
        ('write_box', 'wrong_role', 'Claude Code', 'Reader'),
        ('read_box', 'ok', 'Claude Code', 'Work chat'),
        ('describe_code', 'ok', 'Claude Code', 'Work chat'),
      ]);
      expect(entries.first.code, stored(t.code).id);
      expect(entries.first.target, const AiCodeTarget.box('ba'));
      expect(File(service.log.file.path).readAsStringSync(), isNot(contains('secret sentence')));
    });

    test('a refused code is logged only when it is a known code (expired), a bad one not at all', () async {
      final t = await withBox();
      await codeOf(t.nb, req('ba', 'noted_${'0' * 16}_${'A' * 43}'));
      expect(service.log.entries(), isEmpty);
      service.store.update((d) => d.put(d.code(stored(t.code).id)!.withExpires(DateTime.now().subtract(const Duration(hours: 1)))));
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.expired);
      expect(service.log.entries().single.result, 'expired');
    });

    test('a used code records when, and the listeners are told', () async {
      final t = await withBox();
      var told = 0;
      service.addListener(() => told++);
      expect(stored(t.code).lastUsed, isNull);
      await t.nb.handleAiLink(req('ba', t.code));
      expect(stored(t.code).lastUsed, isNotNull);
      expect(told, greaterThan(0));
    });
  });

  group('ordering and races', () {
    test('queued writes are applied in the order they came', () async {
      final t = await withBox();
      await t.nb.handleAiLink(req('ba', t.code, content: 'warm up')); // the session is allowed
      final all = await Future.wait([
        t.nb.handleAiLink(req('ba', t.code, content: 'one', mode: AiLinkMode.replace)),
        t.nb.handleAiLink(req('ba', t.code, content: ' two', mode: AiLinkMode.append)),
        t.nb.handleAiLink(req('ba', t.code, content: ' three', mode: AiLinkMode.append)),
      ]);
      expect(all.every((r) => r.ok), isTrue);
      expect(dataOf(t.nb, 'ba')['text'], 'one two three');

      await t.nb.createPage();
      await Future.wait([
        t.nb.handleAiLink(req('ba', t.code, content: 'A', mode: AiLinkMode.replace)),
        t.nb.handleAiLink(req('ba', t.code, content: 'B', mode: AiLinkMode.append)),
      ]);
      await t.nb.open(t.a);
      expect(dataOf(t.nb, 'ba')['text'], 'AB');
    });

    for (final writeFirst in [true, false]) {
      test('a write to a closed page racing open() is not lost (${writeFirst ? 'write' : 'open'} first)', () async {
        final t = await withBox();
        await t.nb.handleAiLink(req('ba', t.code, content: 'warm up'));
        await t.nb.createPage(); // t.a is closed now
        final Future<AiLinkResponse> w;
        final Future<void> o;
        if (writeFirst) {
          w = t.nb.handleAiLink(req('ba', t.code, content: 'raced'));
          o = t.nb.open(t.a);
        } else {
          o = t.nb.open(t.a);
          w = t.nb.handleAiLink(req('ba', t.code, content: 'raced'));
        }
        expect((await w).ok, isTrue);
        await o;
        expect(t.nb.currentId, t.a);
        expect(dataOf(t.nb, 'ba')['text'], 'raced', reason: 'the open page shows it');

        t.nb.current!.insertBox(box('user', text: 'mine'));
        await t.nb.flush();
        final onDisk = readPage(File('${pages.path}/${t.a}.canvas').readAsStringSync());
        expect(onDisk.node('user'), isNotNull);
        expect(((onDisk.node('ba')! as BoxRecord).data!.decode()! as Map)['text'], 'raced');
      });
    }

    test('a request before the notebook has loaded waits for it', () async {
      final first = await withBox();
      first.nb.dispose();
      opened.clear();
      final nb = make();
      final r = nb.handleAiLink(req('ba', first.code, content: 'early'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await nb.load();
      expect((await r).ok, isTrue);
      await nb.open(first.a);
      expect(dataOf(nb, 'ba')['text'], 'early');
    });

    test('a bad code is refused without waiting for the load', () async {
      final nb = make();
      expect(await codeOf(nb, req('ba', 'garbage')), AiLinkCode.badCode);
    });
  });

  group('save failures', () {
    test('an open page that can not be saved answers save_failed and keeps the change for recovery', () async {
      final rec = Directory('${root.path}/rec');
      final nb = make(recovery: rec);
      await nb.load();
      nb.current!.insertBox(box('ba', text: 'old'));
      await nb.flush();
      final code = await issue('ba');
      pages.deleteSync(recursive: true); // the folder goes away

      final r = await nb.handleAiLink(req('ba', code, content: 'new'));
      expect((r as AiLinkError).code, AiLinkCode.saveFailed);
      expect(r.message, contains("don't retry an append"));
      expect(dataOf(nb, 'ba')['text'], 'new', reason: 'still on screen');
      expect(rec.existsSync() && rec.listSync().isNotEmpty, isTrue, reason: 'kept for recovery');
    });

    test('a closed page that can not be saved is kept for recovery', () async {
      final rec = Directory('${root.path}/rec');
      final store = _VanishingStore(pages);
      final nb = make(store: store, recovery: rec);
      await nb.load();
      nb.current!.insertBox(box('ba', text: 'old'));
      await nb.flush();
      final code = await issue('ba');
      await nb.createPage();
      // The folder disappears after the write has read the page (the lookup
      // loads it once, the write once; naming the box for the approval question
      // takes one more).
      store.vanishOnLoad = store.loads + 3;

      final r = await nb.handleAiLink(req('ba', code, content: 'new'));
      expect((r as AiLinkError).code, AiLinkCode.saveFailed);
      expect(r.message, contains("don't retry an append"));
      expect(rec.existsSync() && rec.listSync().isNotEmpty, isTrue, reason: 'kept for recovery');
    });

    test('R-1: the file replaced at the replace itself is merged, not overwritten', () async {
      final store = _SyncingStore(pages);
      final nb = make(store: store);
      await nb.load();
      final a = nb.currentId!;
      nb.current!.insertBox(box('ba', text: 'old'));
      await nb.flush();
      final code = await issue('ba');
      await nb.createPage(); // a is closed now
      final file = File('${pages.path}/$a.canvas');
      // After the last reread and the rules, right before the file is replaced.
      store.beforeWrite = () {
        final disk = readPage(file.readAsStringSync());
        file.writeAsStringSync(writePage(disk.insertNode(box('bx', text: 'sync'))));
      };

      final r = await nb.handleAiLink(req('ba', code, content: 'ai'));

      expect(r.ok, isTrue);
      final saved = readPage(file.readAsStringSync());
      String text(String id) => ((saved.node(id)! as BoxRecord).data!.decode()! as Map)['text']! as String;
      expect(text('ba'), 'ai');
      expect(text('bx'), 'sync');
    });

    group('a closed page whose file changes while the write is made', () {
      late ({Notebook nb, String a, String code}) t;
      late File file;

      setUp(() async {
        t = await withBox();
        await t.nb.createPage(); // t.a is closed now
        file = File('${pages.path}/${t.a}.canvas');
      });

      NotedPage disk() => readPage(file.readAsStringSync());

      // Runs [change] the first [times] times the write reaches [point].
      void inject(String point, void Function(int n) change, {int times = 1}) {
        var n = 0;
        t.nb.syncHook = (p, _) async {
          if (p == point && n < times) change(n++);
        };
      }

      String textOf(NotedPage p, String id) => ((p.node(id)! as BoxRecord).data!.decode()! as Map)['text']! as String;

      for (final point in ['closed-reread', 'closed-before-write']) {
        test('another box added at $point: both edits are saved', () async {
          inject(point, (_) => file.writeAsStringSync(writePage(disk().insertNode(box('bx', text: 'sync')))));
          final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
          expect(r.ok, isTrue);
          final saved = disk();
          expect(textOf(saved, 'ba'), 'ai');
          expect(textOf(saved, 'bx'), 'sync');
        });
      }

      test('the box becoming conflicted in between: refused, the other writer\'s file stays', () async {
        late String theirs;
        inject('closed-reread', (_) {
          BoxRecord version(String text, String rev) => BoxRecord.create(
            id: 'ba',
            typeId: 'test.ai',
            dataVersion: 1,
            bounds: const Bounds(40, 40, 200, 80),
            data: RawJson.encode({'by': null, 'text': text}),
            snapshotText: text,
            rev: rev,
          );
          theirs = writePage(
            disk().replaceNode(
              version('theirs', 'r-theirs').withConflict(
                BoxConflict.other(node: version('elsewhere', 'r-other').toRaw(), at: 5),
              ),
            ),
          );
          file.writeAsStringSync(theirs);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.conflict);
        expect(file.readAsStringSync(), theirs);
      });

      test('the file becoming unreadable in between: refused, the file is untouched', () async {
        inject('closed-reread', (_) => file.writeAsStringSync('{ not json'));
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.saveFailed);
        expect(r.message, contains("can't be read"));
        expect(file.readAsStringSync(), '{ not json');
      });

      test('a newer format appearing just before the write: refused, the file is untouched', () async {
        late String newer;
        inject('closed-before-write', (_) {
          newer = writePage(disk()).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
          file.writeAsStringSync(newer);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.saveFailed);
        expect(file.readAsStringSync(), newer);
      });

      test('a file that keeps changing is refused after a few rounds, and nothing is lost', () async {
        var last = '';
        inject('closed-before-write', (n) {
          last = writePage(disk().insertNode(box('bx$n', text: 'sync')));
          file.writeAsStringSync(last);
        }, times: 100);
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.busy);
        expect(r.message, contains('keeps changing'));
        expect(file.readAsStringSync(), last);
        expect(textOf(disk(), 'ba'), 'old');
      });

      // Runs [change] once when the write reaches [point] (it may await).
      void injectAsync(String point, Future<void> Function() change) {
        var done = false;
        t.nb.syncHook = (p, _) async {
          if (p == point && !done) {
            done = true;
            await change();
          }
        };
      }

      test('the code revoked just before the write, the file unchanged: refused, nothing written', () async {
        injectAsync('closed-before-write', () => service.revoke(stored(t.code).id));
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect(r.ok, isFalse);
        expect(textOf(disk(), 'ba'), 'old');
      });

      test('the Writer permission lowered just before the write, the file unchanged: refused', () async {
        injectAsync(
          'closed-before-write',
          () => service.setWriterPermission('ba', AiWriterPermission.append),
        );
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.notPermitted);
        expect(textOf(disk(), 'ba'), 'old');
      });

      test('the page deleted while the write waits: refused, the file is not recreated', () async {
        injectAsync('closed-reread', () async {
          await t.nb.delete(t.a);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.noBox);
        expect(file.existsSync(), isFalse);
      });

      test('the page deleted just before the write: refused, the file is not recreated', () async {
        injectAsync('closed-before-write', () async {
          await t.nb.delete(t.a);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.noBox);
        expect(file.existsSync(), isFalse);
      });

      test('the box type disallowed by the other writer: refused, their file stays', () async {
        late String theirs;
        inject('closed-reread', (_) {
          theirs = writePage(disk().withMeta(disk().meta.withBoxType('test.ai', false)));
          file.writeAsStringSync(theirs);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.notWritable);
        expect(file.readAsStringSync(), theirs);
      });

      test('a file holding another page id: refused, the file is untouched', () async {
        late String other;
        inject('closed-reread', (_) {
          other = file.readAsStringSync().replaceAll(RegExp('"pageId"\\s*:\\s*"${t.a}"'), '"pageId":"other"');
          file.writeAsStringSync(other);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.saveFailed);
        expect(r.message, allOf(contains("can't be read"), contains('a different page')));
        expect(file.readAsStringSync(), other);
      });

      test('a newer format appearing at the reread: refused, the file is untouched', () async {
        late String newer;
        inject('closed-reread', (_) {
          newer = writePage(disk()).replaceFirst(RegExp(r'"format"\s*:\s*1'), '"format":99');
          file.writeAsStringSync(newer);
        });
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.saveFailed);
        expect(file.readAsStringSync(), newer);
      });

      test('the folder vanishing at the reread still goes to recovery', () async {
        final rec = Directory('${root.path}/rec');
        final nb = make(recovery: rec);
        await nb.load();
        nb.current!.insertBox(box('bb', text: 'old'));
        await nb.flush();
        final code = await issue('bb');
        await nb.createPage();
        nb.syncHook = (p, _) async {
          if (p == 'closed-reread' && pages.existsSync()) pages.deleteSync(recursive: true);
        };
        final r = await nb.handleAiLink(req('bb', code, content: 'new'));
        expect((r as AiLinkError).code, AiLinkCode.saveFailed);
        expect(r.message, contains("don't retry an append"));
        expect(rec.existsSync() && rec.listSync().isNotEmpty, isTrue, reason: 'kept for recovery');
      });

      test('the folder vanishing at the reread: the entry holds the loaded page as its base', () async {
        final rec = Directory('${root.path}/rec');
        final nb = make(recovery: rec);
        await nb.load();
        nb.current!.insertBox(box('bb', text: 'old'));
        await nb.flush();
        final code = await issue('bb');
        final a = nb.currentId!;
        final before = File('${pages.path}/$a.canvas').readAsStringSync();
        await nb.createPage();
        nb.syncHook = (p, _) async {
          if (p == 'closed-reread' && pages.existsSync()) pages.deleteSync(recursive: true);
        };
        await nb.handleAiLink(req('bb', code, content: 'new'));
        final entry = (await nb.pendingRecovery()).entries.single;
        expect(entry.pageId, a);
        expect(entry.baseText, before);
      });

      test('the page forgotten with its vanishing folder at the reread: recovery, not noBox', () async {
        final rec = Directory('${root.path}/rec');
        final nb = make(recovery: rec);
        await nb.load();
        nb.current!.insertBox(box('bb', text: 'old'));
        await nb.flush();
        final code = await issue('bb');
        final a = nb.currentId!;
        await nb.createPage();
        nb.syncHook = (p, _) async {
          if (p == 'closed-reread' && pages.existsSync()) {
            pages.deleteSync(recursive: true);
            nb.debugRelocate(a, null); // what _folderGone does to the page
          }
        };
        final r = await nb.handleAiLink(req('bb', code, content: 'new'));
        expect((r as AiLinkError).code, AiLinkCode.saveFailed);
        expect((await nb.pendingRecovery()).entries.single.pageId, a);
      });

      test('the page moved while the write waits: refused as noBox, the old file untouched', () async {
        final other = await Directory('${root.path}/Other').create();
        late String before;
        t.nb.syncHook = (p, _) async {
          if (p == 'closed-before-write') {
            before = file.readAsStringSync();
            t.nb.debugRelocate(t.a, other.path);
          }
        };
        final r = await t.nb.handleAiLink(req('ba', t.code, content: 'ai'));
        expect((r as AiLinkError).code, AiLinkCode.noBox);
        expect(file.readAsStringSync(), before);
        expect(textOf(disk(), 'ba'), 'old');
      });
    });

    test('one page failing to save does not fail a write to another', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      nb.current!.insertBox(box('ba', text: 'old'));
      await nb.flush();
      final b = await nb.createPage();
      nb.current!.insertBox(box('bb', text: 'old'));
      await nb.flush();
      final codeA = await issue('ba');
      final codeB = await issue('bb');
      File('${pages.path}/$b.canvas').deleteSync();
      Directory('${pages.path}/$b.canvas').createSync();
      expect(await codeOf(nb, req('bb', codeB)), AiLinkCode.saveFailed);
      await nb.open(a);
      expect((await nb.handleAiLink(req('ba', codeA, content: 'fine'))).ok, isTrue);
    });
  });

  group('rejected', () {
    test('a malformed, wrong or unknown code', () async {
      final t = await withBox();
      final good = parseAiToken(t.code)!;
      final wrongKey = 'noted_${good.id}_${'A' * 43}';
      final unknownId = 'noted_${'0' * 16}_${good.key}';
      for (final bad in ['', 'garbage', 'noted_', wrongKey, unknownId, '${t.code}-x']) {
        expect(await codeOf(t.nb, req('ba', bad)), AiLinkCode.badCode, reason: bad);
      }
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(asked, isEmpty, reason: 'nobody is asked about a bad code');
    });

    test('the code is checked before the box is looked up', () async {
      final t = await withBox();
      expect(await codeOf(t.nb, req('no-such-box', 'garbage')), AiLinkCode.badCode);
      final code = await issue('no-such-box');
      expect(await codeOf(t.nb, req('no-such-box', code)), AiLinkCode.noBox);
    });

    test('a revoked code fails at once', () async {
      final t = await withBox();
      expect((await t.nb.handleAiLink(req('ba', t.code, content: 'one'))).ok, isTrue);
      await service.revoke(stored(t.code).id);
      expect(await codeOf(t.nb, req('ba', t.code, content: 'two')), AiLinkCode.badCode);
      expect(dataOf(t.nb, 'ba')['text'], 'one');
    });

    test('an old Writer code stops working when a new one is issued', () async {
      final t = await withBox();
      final next = await issue('ba');
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.badCode);
      expect((await t.nb.handleAiLink(req('ba', next))).ok, isTrue);
    });

    test('an expired code', () async {
      final t = await withBox();
      await service.setExpires(stored(t.code).id, DateTime.now().subtract(const Duration(minutes: 1)));
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.expired);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      await service.setExpires(stored(t.code).id, DateTime.now().add(const Duration(hours: 1)));
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);
    });

    test('a Reader code, a page code or a code of a role this build does not know cannot write', () async {
      final t = await withBox();
      final reader = await issue('ba', role: AiCodeRole.reader);
      expect(await codeOf(t.nb, req('ba', reader)), AiLinkCode.wrongRole);
      final pageCode = await service.issue(AiCodeTarget.page(t.a), role: AiCodeRole.reader, label: 'Page');
      expect(await codeOf(t.nb, req('ba', pageCode)), AiLinkCode.wrongRole);
      final future = newAiToken();
      service.store.update(
        (d) => d.put(
          AiCode(
            id: future.id,
            target: const AiCodeTarget.box('ba'),
            roleName: 'organize',
            label: 'Newer',
            hash: future.hash,
            created: DateTime.now().toUtc(),
          ),
        ),
      );
      expect(await codeOf(t.nb, req('ba', future.token)), AiLinkCode.wrongRole);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(asked, isEmpty, reason: 'refused before anyone is asked');
    });

    test('a box that is not the code\'s own gives the answer of a box that is not there', () async {
      final t = await withBox();
      t.nb.current!.insertBox(box('bother', text: 'theirs'));
      expect(await codeOf(t.nb, req('bother', t.code)), AiLinkCode.noBox);
      expect(await codeOf(t.nb, req('nope', t.code)), AiLinkCode.noBox);
      expect(dataOf(t.nb, 'bother')['text'], 'theirs');
      expect(asked, isEmpty);
    });

    test('a code for a box that does not exist', () async {
      final t = await withBox();
      final code = await issue('nope');
      expect(await codeOf(t.nb, req('nope', code)), AiLinkCode.noBox);
    });

    test('a conflicted box', () async {
      final t = await withBox();
      final other = box('bc', text: 'theirs');
      t.nb.current!.insertBox(
        box('bc', text: 'mine').withConflict(BoxConflict.other(node: other.toRaw(), at: 5)),
      );
      final code = await issue('bc');
      expect(await codeOf(t.nb, req('bc', code)), AiLinkCode.conflict);
      expect(dataOf(t.nb, 'bc')['text'], 'mine');
    });

    test('a box type that takes no AI writes', () async {
      final t = await withBox();
      t.nb.current!.insertBox(box('bn', type: 'test.noai'));
      expect(await codeOf(t.nb, req('bn', await issue('bn'))), AiLinkCode.notWritable);
    });

    test('a box whose module is switched off, or not installed', () async {
      final t = await withBox();
      modules.codecs.setEnabled('test.ai', false);
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notWritable);
      modules.codecs.setEnabled('test.ai', true);
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);

      final foreign = BoxRecord.create(
        id: 'bf',
        typeId: 'other.thing',
        dataVersion: 1,
        bounds: const Bounds(0, 0, 10, 10),
        data: RawJson.encode({'by': null}),
        snapshotText: 'x',
        rev: 'r',
      );
      t.nb.current!.insertBox(foreign);
      expect(await codeOf(t.nb, req('bf', await issue('bf'))), AiLinkCode.notWritable);
    });

    test('a box type the page does not allow, here or by a parent or the binder', () async {
      final t = await withBox();
      final c = t.nb.current!;
      c.updateMeta(c.page.meta.withBoxType('test.ai', false));
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notWritable);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      c.updateMeta(c.page.meta.withBoxType('test.ai', null));
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);

      // Disallowed by the parent page: the subpage's box can't be written.
      final sub = await t.nb.createPage(parentId: t.a);
      t.nb.current!.insertBox(box('bs'));
      final code = await issue('bs');
      await t.nb.open(t.a);
      t.nb.current!.updateMeta(t.nb.current!.page.meta.withBoxType('test.ai', false));
      expect(t.nb.tree[sub], isNotNull);
      expect(await codeOf(t.nb, req('bs', code)), AiLinkCode.notWritable);
    });

    test('a box type the binder allows again is refused while that change is not saved', () async {
      final seams = Seams();
      final nb = make(binderStores: (d) => SeamStore(d, seams));
      await nb.load();
      final s = await nb.addBinder(folder.path);
      await nb.createPage(binderPath: s.path);
      nb.current!.insertBox(box('bb'));
      await nb.flush();
      await nb.setBinderBoxType(s.path, 'test.ai', false);
      final code = await issue('bb');
      expect(await codeOf(nb, req('bb', code)), AiLinkCode.notWritable);

      // The binder allows the type again, but the write is held.
      final gate = seams.holdNext();
      final allow = nb.setBinderBoxType(s.path, 'test.ai', null);
      expect(nb.binderBoxType(s.path, 'test.ai'), isNull, reason: 'the screen shows it allowed');
      expect(await codeOf(nb, req('bb', code)), AiLinkCode.notWritable);
      expect(dataOf(nb, 'bb')['text'], '');

      gate.complete();
      await allow;
      expect((await nb.handleAiLink(req('bb', code))).ok, isTrue);
    });

    Future<({Notebook nb, String page, String binderId})> lockedBinder() async {
      final first = make();
      await first.load();
      final s = await first.addBinder(folder.path);
      final p = await first.createPage(binderPath: s.path);
      first.current!.insertBox(box('bl', text: 'old'));
      await first.flush();
      final binderId = s.binder!.id;
      first.dispose();
      opened.clear();
      File('${folder.path}/$binderFileName').writeAsStringSync('{ not json');
      final nb = make();
      await nb.load();
      expect(nb.isReadOnlyPage(p), isTrue);
      return (nb: nb, page: p, binderId: binderId);
    }

    test('a page of a binder that can not be read, closed or open', () async {
      final t = await lockedBinder();
      final code = await issue('bl');
      expect(t.nb.currentId, isNot(t.page));
      expect(await codeOf(t.nb, req('bl', code)), AiLinkCode.locked);
      await t.nb.open(t.page);
      expect(await codeOf(t.nb, req('bl', code)), AiLinkCode.locked);
      expect(dataOf(t.nb, 'bl')['text'], 'old');
    });

    test('a read-only open page', () async {
      final t = await withBox();
      t.nb.current!.readOnly = true;
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.locked);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });

    test('a box in a locked binder is still readable by its box code', () async {
      final t = await lockedBinder();
      final code = await issue('bl', role: AiCodeRole.reader);
      final r = await t.nb.handleAiLink(
        AiLinkAccess(code: code, session: 's1', app: 'A', action: AiLinkAction.readBox, target: 'bl'),
      );
      expect((r as AiLinkGranted).grant, isA<AiLinkBoxGrant>());
      expect((r.grant as AiLinkBoxGrant).page, t.page);
    });

    test('a page code in a locked binder reaches no page', () async {
      final t = await lockedBinder();
      final code = await service.issue(AiCodeTarget.page(t.page), role: AiCodeRole.reader, label: 'P');
      final r = await t.nb.handleAiLink(
        AiLinkAccess(code: code, session: 's1', app: 'A', action: AiLinkAction.listPages),
      );
      expect(((r as AiLinkGranted).grant as AiLinkPagesGrant).pages, isEmpty);
    });
  });

  group('access', () {
    Future<AiLinkResponse> access(
      Notebook nb,
      String code,
      AiLinkAction action, {
      String? target,
    }) => nb.handleAiLink(AiLinkAccess(code: code, session: 's1', app: 'A', action: action, target: target));

    List<String> granted(AiLinkResponse r) => ((r as AiLinkGranted).grant as AiLinkPagesGrant).pages.toList()..sort();

    test('a box code grants its own box, whatever the page access, with the page', () async {
      final t = await withBox();
      for (final role in [AiCodeRole.reader, AiCodeRole.writer]) {
        final code = await issue('ba', role: role);
        final r = await access(t.nb, code, AiLinkAction.readBox, target: 'ba');
        expect((r as AiLinkGranted).grant.toJson(), {'kind': 'box', 'box': 'ba', 'page': t.a});
      }
      // Also when the page is closed.
      await t.nb.createPage();
      final code = await issue('ba', role: AiCodeRole.reader);
      final r = await access(t.nb, code, AiLinkAction.readBox, target: 'ba');
      expect((r as AiLinkGranted).grant.toJson(), {'kind': 'box', 'box': 'ba', 'page': t.a});
    });

    test('a box code reaches nothing but its box: other boxes, pages, lists and search are refused', () async {
      final t = await withBox();
      t.nb.current!.insertBox(box('other'));
      final code = await issue('ba', role: AiCodeRole.reader);
      expect(await codeOf(t.nb, AiLinkAccess(code: code, session: 's1', action: AiLinkAction.readBox, target: 'other')), AiLinkCode.noBox);
      for (final action in [AiLinkAction.readPage, AiLinkAction.listPages, AiLinkAction.search]) {
        expect(await codeOf(t.nb, AiLinkAccess(code: code, session: 's1', action: action, target: 'x')), AiLinkCode.wrongRole, reason: action.wire);
      }
    });

    test('a box code for a box that is gone', () async {
      final t = await withBox();
      final code = await issue('gone', role: AiCodeRole.reader);
      expect(await codeOf(t.nb, AiLinkAccess(code: code, session: 's1', action: AiLinkAction.readBox, target: 'gone')), AiLinkCode.noBox);
    });

    test('a page code covers its page and subpages, minus Guarded and tightened ones', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final sub = await nb.createPage(parentId: a);
      final subsub = await nb.createPage(parentId: sub);
      final sub2 = await nb.createPage(parentId: a);
      final elsewhere = await nb.createPage();
      await nb.setAiAccess(elsewhere, AiAccess.open);
      await nb.setAiAccess(a, AiAccess.open);
      await nb.setAiAccess(sub, AiAccess.privileged);
      await nb.setAiAccess(sub2, AiAccess.guarded);
      final code = await service.issue(AiCodeTarget.page(a), role: AiCodeRole.reader, label: 'Pages');

      final r = await access(nb, code, AiLinkAction.listPages);
      expect(granted(r), ([a, sub, subsub]..sort()), reason: 'Open and Privileged, not the Guarded subpage, not other pages');

      // Tightening the page itself takes the whole subtree out.
      await nb.setAiAccess(a, AiAccess.guarded);
      expect(granted(await access(nb, code, AiLinkAction.readPage, target: sub)), isEmpty);
      await nb.setAiAccess(a, AiAccess.privileged);
      await nb.setAiAccess(sub, AiAccess.guarded);
      expect(granted(await access(nb, code, AiLinkAction.search, target: 'q')), [a]);
    });

    test('a page code for a page that does not exist grants nothing', () async {
      final t = await withBox();
      final code = await service.issue(AiCodeTarget.page('nope'), role: AiCodeRole.reader, label: 'P');
      expect(granted(await access(t.nb, code, AiLinkAction.listPages)), isEmpty);
    });

    test('a binder code covers its pages, minus Guarded ones; a standalone page is out', () async {
      final nb = make();
      await nb.load();
      final standalone = nb.currentId!;
      final s = await nb.addBinder(folder.path);
      final p1 = await nb.createPage(binderPath: s.path);
      final p2 = await nb.createPage(binderPath: s.path);
      final p2sub = await nb.createPage(parentId: p2);
      await nb.setAiAccess(standalone, AiAccess.open);
      await nb.setBinderAiAccess(s.path, AiAccess.privileged);
      final code = await service.issue(AiCodeTarget.binder(s.binder!.id), role: AiCodeRole.reader, label: 'Binder');

      expect(granted(await access(nb, code, AiLinkAction.listPages)), ([p1, p2, p2sub]..sort()));
      await nb.setAiAccess(p2, AiAccess.guarded);
      expect(granted(await access(nb, code, AiLinkAction.listPages)), [p1]);
      await nb.setBinderAiAccess(s.path, AiAccess.guarded);
      expect(granted(await access(nb, code, AiLinkAction.listPages)), isEmpty, reason: 'Guarded binder');
      await nb.setBinderAiAccess(s.path, AiAccess.open);
      expect(granted(await access(nb, code, AiLinkAction.listPages)), [p1], reason: 'Open pages are included');
    });

    test('a binder that can not be read grants nothing', () async {
      final first = make();
      await first.load();
      final s = await first.addBinder(folder.path);
      await first.createPage(binderPath: s.path);
      await first.setBinderAiAccess(s.path, AiAccess.privileged);
      final binderId = s.binder!.id;
      await first.flush();
      first.dispose();
      opened.clear();
      File('${folder.path}/$binderFileName').writeAsStringSync('{ not json');
      final nb = make();
      await nb.load();
      final code = await service.issue(AiCodeTarget.binder(binderId), role: AiCodeRole.reader, label: 'Binder');
      expect(granted(await access(nb, code, AiLinkAction.listPages)), isEmpty);
    });

    test('an access is logged and asks the session once', () async {
      final t = await withBox();
      final code = await service.issue(AiCodeTarget.page(t.a), role: AiCodeRole.reader, label: 'Pages');
      await access(t.nb, code, AiLinkAction.listPages);
      await access(t.nb, code, AiLinkAction.search, target: 'budget');
      expect(asked.single.message, 'A wants to read the page and its subpages (code "Pages"). Allow?');
      final entries = service.activityFor(AiCodeTargetKind.page, t.a);
      expect(entries.map((e) => (e.op, e.result)), [('list_pages', 'ok'), ('search', 'ok')]);
    });

    test('describe_code answers what the code is, with no title', () async {
      final t = await withBox();
      final box = await t.nb.handleAiLink(AiLinkDescribeCode(code: t.code, session: 's1', app: 'A'));
      expect(box.encode(), jsonEncode({'ok': true, 'kind': 'box', 'id': 'ba', 'role': 'writer', 'expires': null}));
      final s = await t.nb.addBinder(folder.path);
      final binderCode = await service.issue(
        AiCodeTarget.binder(s.binder!.id),
        role: AiCodeRole.reader,
        label: 'B',
        expires: DateTime.utc(2099, 1, 2),
      );
      final r = await t.nb.handleAiLink(AiLinkDescribeCode(code: binderCode, session: 's1'));
      expect(r, isA<AiLinkDescribed>());
      expect((r as AiLinkDescribed).kind, 'binder');
      expect(r.id, s.binder!.id);
      expect(r.role, 'reader');
      expect(r.expires, '2099-01-02T00:00:00.000Z');
      expect(r.encode(), isNot(contains(s.path)));
    });

    test('a code of a role this build does not know, on a page, grants nothing', () async {
      final t = await withBox();
      final future = newAiToken();
      service.store.update(
        (d) => d.put(
          AiCode(
            id: future.id,
            target: AiCodeTarget.page(t.a),
            roleName: 'organize',
            label: 'Newer',
            hash: future.hash,
            created: DateTime.now().toUtc(),
          ),
        ),
      );
      expect(await codeOf(t.nb, AiLinkAccess(code: future.token, session: 's1', action: AiLinkAction.listPages)), AiLinkCode.wrongRole);
    });
  });

  group('the service', () {
    test('lists and revokes a box\'s connections, and one new Writer replaces the old', () async {
      final t = await withBox();
      final reader = await issue('ba', role: AiCodeRole.reader, label: 'Reader');
      expect(service.connections('ba').map((c) => c.label), ['Work chat', 'Reader']);
      final writer2 = await issue('ba', label: 'Second');
      // The old Writer stays in the list, marked revoked.
      expect(service.connections('ba').map((c) => (c.label, c.isRevoked)), [
        ('Work chat', true),
        ('Reader', false),
        ('Second', false),
      ]);
      expect(service.connections('other'), isEmpty);
      await service.revoke(stored(reader).id);
      expect(service.connections('ba').map((c) => (c.label, c.isRevoked)), [
        ('Work chat', true),
        ('Reader', true),
        ('Second', false),
      ]);
      expect(parseAiToken(writer2), isNotNull);
      expect(t.code, isNot(writer2));
    });

    test('connect records the page the box is on', () async {
      final nb = make();
      await nb.load();
      nb.current!.insertBox(box('ba'));
      final s = AiAccessService(dataFolder: Directory('${root.path}/data2'), pageOfBox: nb.aiPageOfBox);
      addTearDown(s.dispose);
      await s.connect('ba', role: AiCodeRole.writer, label: 'x');
      expect(s.connections('ba').single.target.page, nb.currentId);
    });

    test('settings: ask before write, activity, an unreadable file as a problem', () async {
      var told = 0;
      service.addListener(() => told++);
      expect(service.askBeforeWrite('ba'), isFalse);
      await service.setAskBeforeWrite('ba', true);
      expect(service.askBeforeWrite('ba'), isTrue);
      expect(told, 1);
      expect(service.problem, isNull);
      service.store.file.writeAsStringSync('{ damaged');
      expect(service.problem, isNotNull);
      expect(service.connections('ba'), isEmpty);
      await expectLater(issue('ba'), throwsA(isA<AiAccessException>()));
      expect(service.store.file.readAsStringSync(), '{ damaged');
    });

    test('a page or binder: issue, list, sessions, activity, rename, revoke', () async {
      final code = await service.issue(AiCodeTarget.page('p1'), role: AiCodeRole.reader, label: 'Notes chat');
      final listed = service.codesFor(AiCodeTargetKind.page, 'p1').single;
      expect(listed.label, 'Notes chat');
      expect(service.codesFor(AiCodeTargetKind.binder, 'p1'), isEmpty);
      await service.rename(listed.id, 'Renamed');
      expect(service.codesFor(AiCodeTargetKind.page, 'p1').single.label, 'Renamed');
      service.store.addSession(listed.id, AiCodeSession(id: 's', app: 'App', approved: DateTime.now().toUtc()));
      expect(service.codesFor(AiCodeTargetKind.page, 'p1').single.sessions, hasLength(1));
      await service.revokeSession(listed.id, 's');
      expect(service.codesFor(AiCodeTargetKind.page, 'p1').single.sessions, isEmpty);
      expect(service.activityFor(AiCodeTargetKind.page, 'p1'), isEmpty);
      await service.revoke(listed.id);
      expect(service.codesFor(AiCodeTargetKind.page, 'p1').single.isRevoked, isTrue);
      expect(parseAiToken(code), isNotNull);
      await expectLater(
        service.issue(AiCodeTarget.page('p1'), role: AiCodeRole.writer, label: 'x'),
        throwsA(isA<AiAccessException>()),
        reason: 'a Writer is for a box',
      );
    });

    test('notices a change another instance made to the files', () async {
      final polled = AiAccessService(dataFolder: Directory('${root.path}/data3'), pollInterval: const Duration(milliseconds: 50));
      addTearDown(polled.dispose);
      var told = 0;
      polled.addListener(() => told++);
      final other = AiAccessService(dataFolder: Directory('${root.path}/data3'));
      addTearDown(other.dispose);
      await other.issue(AiCodeTarget.box('b'), role: AiCodeRole.reader, label: 'x');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(told, greaterThan(0));
      expect(polled.connections('b'), hasLength(1));
    });
  });

  group('Writer permission', () {
    test('append allows only append; edit adds replace_ai; full adds replace', () async {
      final t = await withBox();
      await service.setWriterPermission('ba', AiWriterPermission.append);
      await t.nb.handleAiLink(req('ba', t.code, mode: AiLinkMode.append)); // approves
      final asks = asked.length;
      expect(await codeOf(t.nb, req('ba', t.code, mode: AiLinkMode.replaceAi)), AiLinkCode.notPermitted);
      expect(await codeOf(t.nb, req('ba', t.code, mode: AiLinkMode.replace)), AiLinkCode.notPermitted);
      expect(await codeOf(t.nb, req('ba', t.code, content: '', mode: AiLinkMode.replace)), AiLinkCode.notPermitted);
      expect(dataOf(t.nb, 'ba')['text'], 'oldhello');

      await service.setWriterPermission('ba', AiWriterPermission.edit);
      expect(await codeOf(t.nb, req('ba', t.code, mode: AiLinkMode.replaceAi)), isNull);
      expect(dataOf(t.nb, 'ba')['mode'], 'replaceAiText');
      expect(await codeOf(t.nb, req('ba', t.code, mode: AiLinkMode.replace)), AiLinkCode.notPermitted);

      await service.setWriterPermission('ba', AiWriterPermission.full);
      expect(await codeOf(t.nb, req('ba', t.code, content: 'new', mode: AiLinkMode.replace)), isNull);
      expect(dataOf(t.nb, 'ba')['text'], 'new');
      expect(await codeOf(t.nb, req('ba', t.code, content: '', mode: AiLinkMode.replace)), isNull);
      expect(dataOf(t.nb, 'ba')['text'], '');
      expect(asked, hasLength(asks), reason: 'no question for a write that is not permitted');
    });

    test('not_permitted is logged, says what to do, and is refused before anyone is asked', () async {
      final t = await withBox();
      await service.setWriterPermission('ba', AiWriterPermission.append);
      final r = await t.nb.handleAiLink(req('ba', t.code, mode: AiLinkMode.replace));
      expect((r as AiLinkError).code, AiLinkCode.notPermitted);
      expect(r.message, contains('Writer permission'));
      expect(asked, isEmpty);
      expect(service.activity('ba').single.result, 'not_permitted');
      expect(stored(t.code).approved, isNull);
    });

    test('a permission lowered while the question is open is respected', () async {
      final t = await withBox();
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      final pending = t.nb.handleAiLink(req('ba', t.code, mode: AiLinkMode.replace));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.setWriterPermission('ba', AiWriterPermission.append);
      gate.complete(true);
      expect(((await pending) as AiLinkError).code, AiLinkCode.notPermitted);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });
  });

  group('approvals asked while Noted was closed', () {
    void log(
      String code, {
      String result = 'pending_approval',
      DateTime? at,
      String app = 'Claude Code',
      String box = 'ba',
    }) {
      final entry = AiMcpLogEntry(
        time: at ?? DateTime.now().toUtc().add(const Duration(seconds: 1)),
        code: code,
        target: AiCodeTarget.box(box),
        op: 'write_box',
        app: app,
        label: 'Work chat',
        result: result,
      );
      service.mcpLog.writeAsStringSync('${entry.encode()}\n', mode: FileMode.append);
    }

    Future<void> run(Notebook nb) => nb.askPendingAiApprovals();

    test('asks once about an unapproved code with a pending entry; Allow approves it', () async {
      final t = await withBox();
      log(stored(t.code).id);
      log(stored(t.code).id); // a second entry is not a second question
      await run(t.nb);
      expect(asked, hasLength(1));
      expect(asked.single.closedApp, isTrue);
      expect(
        asked.single.message,
        'Claude Code wants to read and write the AI box (code "Work chat"). It asked while Noted was closed. Allow?',
      );
      expect(stored(t.code).approved, isNotNull);
      // Approved: a request needs no further question.
      expect((await t.nb.handleAiLink(req('ba', t.code))).ok, isTrue);
      expect(asked, hasLength(1));
      await run(t.nb);
      expect(asked, hasLength(1));
    });

    test('Deny leaves the code unapproved and is not asked again in this run', () async {
      final t = await withBox();
      log(stored(t.code).id);
      answer = (_) async => false;
      await run(t.nb);
      await run(t.nb);
      expect(asked, hasLength(1));
      expect(stored(t.code).approved, isNull);
    });

    test('ignores other results, unknown, expired and approved codes and entries older than the code', () async {
      final t = await withBox();
      final id = stored(t.code).id;
      log(id, at: DateTime.now().toUtc().subtract(const Duration(days: 1)));
      log(id, result: 'ok');
      log(id, result: 'expired');
      log('0123456789abcdef');
      await run(t.nb);
      expect(asked, isEmpty);

      log(id);
      service.store.update((d) => d.put(d.code(id)!.withExpires(DateTime.now().subtract(const Duration(hours: 1)))));
      await run(t.nb);
      expect(asked, isEmpty, reason: 'expired');
      service.store.update((d) => d.put(d.code(id)!.withExpires(null)));

      service.store.approveCode(id);
      await run(t.nb);
      expect(asked, isEmpty, reason: 'approved');
    });

    test('a Deny is remembered on the code: the next launch does not ask again, a newer entry does', () async {
      final t = await withBox();
      final id = stored(t.code).id;
      log(id, at: DateTime.now().toUtc()); // the attempt, before the answer
      answer = (_) async => false;
      await run(t.nb);
      expect(AiAccessService.pendingAnswered(stored(t.code)), isNotNull);
      // The next launch: a new notebook on the same data.
      final next = make();
      await next.load();
      await run(next);
      expect(asked, hasLength(1), reason: 'the old entry was answered');
      log(id, at: DateTime.now().toUtc().add(const Duration(minutes: 5)));
      final later = make();
      await later.load();
      await run(later);
      expect(asked, hasLength(2), reason: 'a newer attempt is asked about');
      // The field is kept like the other fields of the record.
      expect(service.store.read().code(id)!.extra['pendingAnswered'], isA<String>());
    });

    test('a question nobody answers is not an answer: the next launch asks again', () async {
      timings = const AiLinkTimings(approval: Duration(milliseconds: 150));
      final t = await withBox();
      log(stored(t.code).id);
      answer = (_) => Completer<bool>().future;
      await run(t.nb);
      expect(AiAccessService.pendingAnswered(stored(t.code)), isNull);
      await asked.single.expired;
      final next = make();
      await next.load();
      await run(next);
      expect(asked, hasLength(2));
    });

    test('a live request that joins a startup question waits only for its own deadline', () async {
      timings = const AiLinkTimings(approval: Duration(seconds: 5), deadline: Duration(milliseconds: 500));
      final t = await withBox();
      log(stored(t.code).id);
      answer = (_) => Completer<bool>().future; // nobody answers
      final startup = run(t.nb);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final watch = Stopwatch()..start();
      expect(await codeOf(t.nb, req('ba', t.code)), AiLinkCode.notApproved);
      expect(watch.elapsedMilliseconds, lessThan(1500));
      await startup;
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('the startup question is capped at the approval time, so live questions are not starved', () async {
      timings = const AiLinkTimings(approval: Duration(milliseconds: 300), deadline: Duration(seconds: 20));
      final t = await withBox();
      final other = await issue('ba', role: AiCodeRole.reader, label: 'Other');
      log(stored(t.code).id);
      var first = true;
      answer = (r) {
        if (first) {
          first = false;
          return Completer<bool>().future; // the startup question: never answered
        }
        return Future.value(true);
      };
      final startup = run(t.nb);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final watch = Stopwatch()..start();
      final live = await t.nb.handleAiLink(
        AiLinkAccess(code: other, session: 'o', app: 'B', action: AiLinkAction.readBox, target: 'ba'),
      );
      expect(live.ok, isTrue);
      expect(watch.elapsedMilliseconds, lessThan(3000));
      await startup;
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a code revoked while the question is open is not approved', () async {
      final t = await withBox();
      final id = stored(t.code).id;
      log(id);
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      final done = run(t.nb);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.revoke(id);
      gate.complete(true);
      await done;
      expect(service.store.codes().single.isRevoked, isTrue);
      expect(service.store.codes().single.approved, isNull);
    });

    test('a revoked code that is still in the file is not asked about at startup', () async {
      final t = await withBox();
      final id = stored(t.code).id;
      log(id);
      await service.revoke(id);
      await run(t.nb);
      expect(asked, isEmpty);
      expect(service.store.codes().single.approved, isNull);
    });

    test('with no log, or a log of bad lines, nothing is asked', () async {
      final t = await withBox();
      await run(t.nb);
      service.mcpLog.writeAsStringSync('not json\n{"time":1}\n');
      await run(t.nb);
      expect(asked, isEmpty);
    });

    test('a live request and a pending entry of one code share one question', () async {
      final t = await withBox();
      log(stored(t.code).id);
      final gate = Completer<bool>();
      answer = (_) => gate.future;
      final live = t.nb.handleAiLink(req('ba', t.code));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final startup = run(t.nb);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete(true);
      expect((await live).ok, isTrue);
      await startup;
      expect(asked, hasLength(1));
      expect(stored(t.code).approved, isNotNull);
    });
  });
}

/// A host whose naming lookup never finishes (an offline or slow page load).
class _NeverNamesHost implements AiLinkHost {
  @override
  Future<String?> aiTargetName(AiCodeTarget target) => Completer<String?>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

ModuleRegistry _modules() => buildModules()
  ..register(const _Module(_Codec('test.ai')))
  ..register(const _Module(_Codec('test.noai', writes: false)));
