// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/ai/ai_access_service.dart';
import 'package:noted/src/ai/ai_merge_service.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_core/noted_core.dart';

Map<String, Object?> _para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

Map<String, Object?> _doc(List<Map<String, Object?>> blocks, {String? owner}) => {
  'document': {'type': 'page', 'children': blocks},
  'owner': ?owner,
};

BoxRecord _box(String id, Map<String, Object?> data, {String type = 'noted.note', int at = 1000, String device = 'PC-A'}) =>
    BoxRecord.create(
      id: id,
      typeId: type,
      dataVersion: 1,
      bounds: const Bounds(40, 40, 300, 100),
      data: RawJson.encode(data),
      snapshotText: noteToMarkdown(data),
      rev: 'r-$id-$at',
      device: device,
      at: at,
    );

void main() {
  late Directory root;
  late Directory data;
  late AiAccessService service;
  late Notebook nb;
  late String pageId;
  late String pageCode;

  Future<String> issueReader(AiCodeTarget target, {bool approve = true, bool use = true}) async {
    final code = await service.issue(target, role: AiCodeRole.reader, label: 'Review chat');
    final id = parseAiToken(code)!.id;
    if (approve) service.store.approveCode(id);
    if (use) service.store.recordUse(id);
    return code;
  }

  // Puts a note (or AI) box with a recorded other version on the open page and
  // saves it.
  Future<void> conflicted(
    String id, {
    String type = 'noted.note',
    List<String> mine = const ['Shared line', 'Mine only'],
    List<String> theirs = const ['Shared line', 'Theirs only'],
    BoxConflict? override,
  }) async {
    final m = _box(id, _doc([for (final t in mine) _para(t)]), type: type);
    final o = _box(id, _doc([for (final t in theirs) _para(t)]), type: type, at: 2000, device: 'PC-B');
    final withConflict = m.withConflict(override ?? BoxConflict.other(node: o.toRaw(), at: 2000, device: 'PC-B'));
    nb.current!.insertBox(withConflict);
    await nb.flush();
  }

  Future<AiLinkResponse> link(AiLinkRequest r) => nb.handleAiLink(r);

  AiLinkMergeRequests list(String code) => AiLinkMergeRequests(code: code, session: 's', app: 'Claude Code');

  AiLinkProposeMerge propose(String code, String request, String content) =>
      AiLinkProposeMerge(code: code, session: 's', app: 'Claude Code', request: request, content: content);

  Future<AiLinkMergeItem> theItem(String code) async {
    final r = await link(list(code));
    expect(r, isA<AiLinkMerges>(), reason: r is AiLinkError ? r.wireCode : '');
    return (r as AiLinkMerges).items.single;
  }

  Future<AiLinkCode?> refused(AiLinkRequest r) async {
    final response = await link(r);
    return response is AiLinkError ? response.code : null;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_aimerge');
    data = await Directory('${root.path}/data').create();
    service = AiAccessService(dataFolder: data);
    nb = Notebook(
      PageStore(Directory('${data.path}/pages')),
      buildModules(aiAccess: service),
      saveDelay: Duration.zero,
      bindersFile: File('${data.path}/binders.json'),
      deviceName: 'PC-A',
      aiAccess: service,
    );
    await nb.load();
    pageId = nb.currentId!;
    await nb.setAiAccess(pageId, AiAccess.privileged);
    pageCode = await issueReader(AiCodeTarget.page(pageId));
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    service.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  group('availability', () {
    test('a note box with a connected page Reader code on a Privileged page: yes', () async {
      await conflicted('n1');
      expect(nb.aiMerge!.available(pageId, 'n1'), isTrue);
    });

    test('an Open page works the same, an AI box too', () async {
      await nb.setAiAccess(pageId, AiAccess.open);
      await conflicted('a1', type: aiBoxTypeId);
      expect(nb.aiMerge!.available(pageId, 'a1'), isTrue);
    });

    test('a Guarded page: no', () async {
      await conflicted('n1');
      await nb.setAiAccess(pageId, AiAccess.guarded);
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse);
    });

    test('only note and AI boxes', () async {
      final d = _box('d1', {'strokes': <Object?>[]}, type: 'noted.drawing');
      nb.current!.insertBox(d);
      expect(nb.aiMerge!.available(pageId, 'd1'), isFalse);
      expect(nb.aiMerge!.available(pageId, 'nope'), isFalse);
    });

    test('no code, an unapproved one, an expired one, one not used lately: no', () async {
      await conflicted('n1');
      final id = parseAiToken(pageCode)!.id;
      // Not used lately: the service's clock is 16 minutes on.
      final later = AiMergeService(
        access: service,
        host: nb,
        now: () => DateTime.now().add(const Duration(minutes: 16)),
      );
      expect(later.available(pageId, 'n1'), isFalse);
      final soon = AiMergeService(
        access: service,
        host: nb,
        now: () => DateTime.now().add(const Duration(minutes: 14)),
      );
      expect(soon.available(pageId, 'n1'), isTrue);

      // Expired.
      await service.setExpires(id, DateTime.now().subtract(const Duration(seconds: 1)));
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse);
      await service.setExpires(id, null);
      expect(nb.aiMerge!.available(pageId, 'n1'), isTrue);

      // Revoked (removed, or kept and marked revoked).
      service.store.update((d) {
        final c = d.code(id)!;
        d.put(
          AiCode(
            id: c.id,
            target: c.target,
            roleName: c.roleName,
            label: c.label,
            hash: c.hash,
            created: c.created,
            lastUsed: c.lastUsed,
            approved: c.approved,
            revoked: DateTime.now().toUtc(),
            extra: c.extra,
          ),
        );
      });
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse);
      service.store.revoke(id);
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse);

      // Unapproved, never used.
      await issueReader(AiCodeTarget.page(pageId), approve: false);
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse);
      await issueReader(AiCodeTarget.page(pageId), use: false);
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse, reason: 'approved but never used');
    });

    test('a code for another page or a box code does not count', () async {
      await conflicted('n1');
      service.store.revoke(parseAiToken(pageCode)!.id);
      final other = await nb.createPage();
      await issueReader(AiCodeTarget.page(other));
      await issueReader(AiCodeTarget.box('n1'));
      await nb.open(pageId);
      expect(nb.aiMerge!.available(pageId, 'n1'), isFalse);
    });

    test('a page code covers the subpages below it', () async {
      final child = await nb.createPage(parentId: pageId);
      await nb.open(child);
      await nb.setAiAccess(child, AiAccess.privileged);
      await conflicted('n2');
      expect(nb.aiMerge!.available(child, 'n2'), isTrue);
    });
  });

  group('the request', () {
    test('ask, list, propose: the dialog gets the proposal in the shape of the box', () async {
      await conflicted('n1');
      final pending = nb.aiMerge!.ask(pageId, 'n1');
      final done = expectLater(pending, completes);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final item = await theItem(pageCode);
      expect(item.page, pageId);
      expect(item.box, 'n1');
      expect(item.type, 'noted.note');
      expect(item.mine.markdown, 'Shared line\n\nMine only');
      expect(item.mine.device, 'PC-A');
      expect(item.mine.at, 1000);
      expect(item.theirs.markdown, 'Shared line\n\nTheirs only');
      expect(item.theirs.device, 'PC-B');
      expect(item.theirs.at, 2000);

      final r = await link(propose(pageCode, item.id, 'Shared line\n\nMine only\n\nTheirs only'));
      expect(r, isA<AiLinkProposed>());
      await done;
      final p = await pending;
      expect(p.markdown, 'Shared line\n\nMine only\n\nTheirs only');
      expect(p.dataVersion, 1);
      expect(p.data, isA<NoteData>());
      final doc = (p.data! as NoteData).document['document']! as Map;
      expect(doc['type'], 'page');
      expect([for (final b in doc['children'] as List) aiBlockText(b as Map)], ['Shared line', 'Mine only', 'Theirs only']);
      // It encodes through the box's own codec.
      expect(const NoteCodec().encode(p.data! as NoteData), {'document': doc});

      // Answered: gone from the list, and a second proposal finds nothing.
      expect((await link(list(pageCode)) as AiLinkMerges).items, isEmpty);
      expect(await refused(propose(pageCode, item.id, 'again')), AiLinkCode.noRequest);
    });

    test('an AI box keeps its <ai-written> parts marked and the user parts unmarked, and its owner', () async {
      final aiBlock = markAiWritten(_para('From the AI'));
      final m = _box('a1', _doc([_para('User line'), aiBlock], owner: 'conn1'), type: aiBoxTypeId);
      final o = _box('a1', _doc([_para('User line'), markAiWritten(_para('Other AI text'))], owner: 'conn1'),
          type: aiBoxTypeId, at: 2000, device: 'PC-B');
      nb.current!.insertBox(m.withConflict(BoxConflict.other(node: o.toRaw(), at: 2000, device: 'PC-B')));
      await nb.flush();

      final pending = nb.aiMerge!.ask(pageId, 'a1');
      unawaited(pending.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final item = await theItem(pageCode);
      expect(item.type, aiBoxTypeId);
      expect(item.mine.markdown, 'User line\n\n<ai-written>\n\nFrom the AI\n\n</ai-written>');
      expect(item.theirs.markdown, contains('<ai-written>'));

      final merged = 'User line\n\n<ai-written>\nFrom the AI\n\nOther AI text\n</ai-written>\n\nA user note';
      expect(await link(propose(pageCode, item.id, merged)), isA<AiLinkProposed>());
      final p = await pending;
      final box = p.data! as AiBoxData;
      expect(box.owner, 'conn1');
      final blocks = [for (final b in (box.json['document']! as Map)['children'] as List) b as Map<Object?, Object?>];
      expect([for (final b in blocks) aiBlockText(b)], ['User line', 'From the AI', 'Other AI text', 'A user note']);
      expect([for (final b in blocks) isAiWritten(b)], [false, true, true, false]);
    });

    test('an AI box merge without markers is the AI\'s whole text (replace semantics)', () async {
      await conflicted('a1', type: aiBoxTypeId);
      final pending = nb.aiMerge!.ask(pageId, 'a1');
      unawaited(pending.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final item = await theItem(pageCode);
      await link(propose(pageCode, item.id, 'All merged'));
      final blocks = [for (final b in (((await pending).data! as AiBoxData).json['document']! as Map)['children'] as List) b as Map];
      expect([for (final b in blocks) isAiWritten(b)], [true]);
    });

    test('one request per box: asking again joins the first', () async {
      await conflicted('n1');
      final a = nb.aiMerge!.ask(pageId, 'n1');
      final b = nb.aiMerge!.ask(pageId, 'n1');
      unawaited(a.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await link(list(pageCode)) as AiLinkMerges).items, hasLength(1));
      nb.aiMerge!.cancel(pageId, 'n1');
      await expectLater(a, throwsA(isA<AiMergeException>()));
      await expectLater(b, throwsA(isA<AiMergeException>()));
    });

    test('cancel withdraws it: gone from the list, a proposal finds nothing', () async {
      await conflicted('n1');
      final pending = nb.aiMerge!.ask(pageId, 'n1');
      final failed = expectLater(pending, throwsA(isA<AiMergeException>()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final item = await theItem(pageCode);
      nb.aiMerge!.cancel(pageId, 'n1');
      await failed;
      expect((await link(list(pageCode)) as AiLinkMerges).items, isEmpty);
      expect(await refused(propose(pageCode, item.id, 'late')), AiLinkCode.noRequest);
      // Cancelling nothing is fine, and the box can be asked about again.
      nb.aiMerge!.cancel(pageId, 'n1');
      final again = nb.aiMerge!.ask(pageId, 'n1');
      unawaited(again.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await link(list(pageCode)) as AiLinkMerges).items, hasLength(1));
      nb.aiMerge!.cancel(pageId, 'n1');
    });

    test('a request expires', () async {
      await conflicted('n1');
      final short = AiMergeService(access: service, host: nb, expiry: const Duration(milliseconds: 80));
      final pending = short.ask(pageId, 'n1');
      final failed = expectLater(pending, throwsA(isA<AiMergeException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final code = service.store.codes().single;
      expect(short.pendingFor(code), hasLength(1));
      await failed;
      expect(short.pendingFor(code), isEmpty);
      expect(short.propose(code, 'x', 'text'), isA<AiLinkError>());
    });

    test('the default expiry is 10 minutes', () {
      expect(aiMergeExpiry, const Duration(minutes: 10));
      expect(aiMergeConnectedWithin, const Duration(minutes: 15));
      expect(nb.aiMerge, isA<AiMergeService>());
      expect((nb.aiMerge! as AiMergeService).expiry, aiMergeExpiry);
    });

    test('asking when not available, about a deleted conflict, or a huge box fails clearly', () async {
      await conflicted('n1');
      await nb.setAiAccess(pageId, AiAccess.guarded);
      await expectLater(nb.aiMerge!.ask(pageId, 'n1'), throwsA(isA<AiMergeException>()));
      await nb.setAiAccess(pageId, AiAccess.privileged);

      final m = _box('n2', _doc([_para('mine')])).withConflict(BoxConflict.deleted(at: 5));
      nb.current!.insertBox(m);
      await nb.flush();
      await expectLater(nb.aiMerge!.ask(pageId, 'n2'), throwsA(isA<AiMergeException>()));

      final big = 'x' * (aiMergeMaxVersionBytes + 1);
      await conflicted('n3', mine: [big], theirs: ['small']);
      await expectLater(nb.aiMerge!.ask(pageId, 'n3'), throwsA(isA<AiMergeException>()));
    });

    test('an empty or unreadable merge is refused and the request stays', () async {
      await conflicted('n1');
      final pending = nb.aiMerge!.ask(pageId, 'n1');
      unawaited(pending.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final item = await theItem(pageCode);
      expect(await refused(propose(pageCode, item.id, '  \n ')), AiLinkCode.badRequest);
      expect((await link(list(pageCode)) as AiLinkMerges).items, hasLength(1));
      nb.aiMerge!.cancel(pageId, 'n1');
    });
  });

  group('the code', () {
    Future<String> pendingRequest() async {
      await conflicted('n1');
      final pending = nb.aiMerge!.ask(pageId, 'n1');
      unawaited(pending.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return (await theItem(pageCode)).id;
    }

    test('a code for another page sees nothing and cannot answer', () async {
      final id = await pendingRequest();
      final other = await nb.createPage();
      await nb.open(pageId);
      final elsewhere = await issueReader(AiCodeTarget.page(other));
      expect((await link(list(elsewhere)) as AiLinkMerges).items, isEmpty);
      expect(await refused(propose(elsewhere, id, 'merged')), AiLinkCode.noRequest);
      expect((await link(list(pageCode)) as AiLinkMerges).items, hasLength(1), reason: 'still waiting');
    });

    test('a box code (Reader or Writer) is refused with wrong_role', () async {
      final id = await pendingRequest();
      final reader = await issueReader(AiCodeTarget.box('n1'));
      final writer = await service.issue(AiCodeTarget.box('n1'), role: AiCodeRole.writer, label: 'w');
      service.store.approveCode(parseAiToken(writer)!.id);
      for (final c in [reader, writer]) {
        expect(await refused(list(c)), AiLinkCode.wrongRole);
        expect(await refused(propose(c, id, 'merged')), AiLinkCode.wrongRole);
      }
    });

    test('an unapproved code is not approved by asking for merges (nobody can be asked)', () async {
      final id = await pendingRequest();
      final fresh = await issueReader(AiCodeTarget.page(pageId), approve: false, use: false);
      expect(await refused(list(fresh)), AiLinkCode.notApproved);
      expect(await refused(propose(fresh, id, 'merged')), AiLinkCode.notApproved);
    });

    test('a revoked code is bad_code, an expired one is expired, junk is bad_code', () async {
      final id = await pendingRequest();
      final revoked = await issueReader(AiCodeTarget.page(pageId));
      service.store.revoke(parseAiToken(revoked)!.id);
      expect(await refused(list(revoked)), AiLinkCode.badCode);
      expect(await refused(propose(revoked, id, 'merged')), AiLinkCode.badCode);

      final expired = await issueReader(AiCodeTarget.page(pageId));
      await service.setExpires(parseAiToken(expired)!.id, DateTime.now().subtract(const Duration(minutes: 1)));
      expect(await refused(list(expired)), AiLinkCode.expired);
      expect(await refused(propose(expired, id, 'merged')), AiLinkCode.expired);

      expect(await refused(list('noted_${'0' * 16}_${'A' * 43}')), AiLinkCode.badCode);
      expect((await link(list(pageCode)) as AiLinkMerges).items, hasLength(1), reason: 'untouched');
    });

    test('a Reader is enough, and the use is logged to the code\'s activity', () async {
      final id = await pendingRequest();
      expect(await refused(propose(pageCode, id, 'Merged')), isNull);
      final ops = [for (final e in service.activityFor(AiCodeTargetKind.page, pageId)) '${e.op}:${e.result}'];
      expect(ops, containsAll(['merge_requests:ok', 'propose_merge:ok']));
      expect(await refused(propose(pageCode, id, 'Merged')), AiLinkCode.noRequest);
      expect(service.activityFor(AiCodeTargetKind.page, pageId).last.result, 'no_request');
    });

    test('a locked-out page (Guarded after the ask) hides the request from the code', () async {
      final id = await pendingRequest();
      await nb.setAiAccess(pageId, AiAccess.guarded);
      expect((await link(list(pageCode)) as AiLinkMerges).items, isEmpty);
      expect(await refused(propose(pageCode, id, 'merged')), AiLinkCode.noRequest);
    });
  });

  group('saved data only', () {
    test('the versions are the saved ones: a later edit on screen is not what the AI gets', () async {
      await conflicted('n1');
      final pending = nb.aiMerge!.ask(pageId, 'n1');
      unawaited(pending.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The user types on screen, unsaved (the autosave has not run).
      nb.current!.replaceBoxData({
        'n1': NoteData({
          'document': {
            'type': 'page',
            'children': [_para('LIVE TEXT NOT SAVED')],
          },
        }),
      });
      final item = await theItem(pageCode);
      expect(item.mine.markdown, isNot(contains('LIVE')));
      expect(item.mine.markdown, contains('Mine only'));
      expect(jsonOfItem(item), isNot(contains('LIVE')));
      nb.aiMerge!.cancel(pageId, 'n1');
    });

    test('the service reads the page file (not the open page) for the versions', () async {
      await conflicted('n1');
      var reads = 0;
      final spy = _Spy(nb, () => reads++);
      final s = AiMergeService(access: service, host: spy);
      final pending = s.ask(pageId, 'n1');
      unawaited(pending.then((_) {}, onError: (_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(reads, 1);
      expect(s.pendingFor(service.store.codes().single).single.mine.markdown, contains('Mine only'));
      s.cancel(pageId, 'n1');
    });
  });
}

String jsonOfItem(AiLinkMergeItem i) => i.toJson().toString();

/// A host that counts reads of the saved page.
class _Spy implements AiMergeHost {
  _Spy(this.inner, this.onRead);

  final Notebook inner;
  final void Function() onRead;

  @override
  List<String> aiReadablePages(AiCodeTarget target) => inner.aiReadablePages(target);

  @override
  Future<NotedPage?> aiSavedPage(String pageId) {
    onRead();
    return inner.aiSavedPage(pageId);
  }

  @override
  String? aiOpenBoxType(String pageId, String boxId) => inner.aiOpenBoxType(pageId, boxId);

  @override
  BoxCodec<Object?>? aiMergeCodec(String typeId) => inner.aiMergeCodec(typeId);
}
