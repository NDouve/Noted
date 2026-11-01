// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// A box type that takes AI writes: `{"owner": id|null, "text": text}`.
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
  Map<String, Object?> create() => {'owner': null, 'text': ''};
  @override
  Map<String, Object?> decode(Object? json, int storedVersion) => Map<String, Object?>.from(json! as Map);
  @override
  Object? encode(Map<String, Object?> data) => data;
  @override
  String snapshotText(Map<String, Object?> data) => data['text']! as String;
  @override
  AiExposure aiExposure(Map<String, Object?> data) => AiText(data['text']! as String);
  @override
  String? aiOwner(Map<String, Object?> data) => data['owner'] as String?;
  @override
  Map<String, Object?>? aiWrite(Map<String, Object?> data, AiWrite write) {
    if (!writes) return null;
    final old = data['text']! as String;
    return {...data, 'text': write.mode == AiWriteMode.replace ? write.content : '$old${write.content}'};
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

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late AppSettings settings;
  late ModuleRegistry modules;
  late List<Notebook> opened;
  late String token;
  late String connId;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_aiwrite');
    pages = await Directory('${root.path}/pages').create();
    folder = await Directory('${root.path}/Work').create();
    opened = [];
    settings = AppSettings(File('${root.path}/settings.json'));
    token = await settings.addAiConnection('Claude Code');
    connId = parseAiToken(token)!.id;
    modules = _modules();
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook make({PageStore? store, Directory? recovery}) {
    final nb = Notebook(
      store ?? PageStore(pages),
      modules,
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      deviceName: 'TestPC',
      settings: settings,
      recoveryDirectory: recovery,
    );
    opened.add(nb);
    return nb;
  }

  BoxRecord box(String id, {String? owner, String text = '', String type = 'test.ai'}) => BoxRecord.create(
    id: id,
    typeId: type,
    dataVersion: 1,
    bounds: const Bounds(40, 40, 200, 80),
    data: RawJson.encode({'owner': owner, 'text': text}),
    snapshotText: text,
    rev: 'r-$id',
  );

  // The data of box [id] on the open page.
  Map<String, Object?> dataOf(Notebook nb, String id) =>
      ((nb.current!.page.node(id)! as BoxRecord).data!.decode()! as Map).cast<String, Object?>();

  AiLinkRequest req(
    String boxId, {
    String? tok,
    String content = 'hello',
    AiLinkMode mode = AiLinkMode.replace,
  }) => AiLinkRequest(token: tok ?? token, box: boxId, mode: mode, content: content);

  Future<AiLinkCode?> codeOf(Notebook nb, AiLinkRequest r) async => (await nb.aiWrite(r)).code;

  // A notebook with page `a` (Whole page, box `ba` owned by the connection)
  // and, optionally, the open page.
  Future<({Notebook nb, String a})> withBox({AiSetting? setting = AiSetting.wholePage, String? owner}) async {
    final nb = make();
    await nb.load();
    final a = nb.currentId!;
    await nb.setAiSetting(a, setting);
    nb.current!.insertBox(box('ba', owner: owner ?? connId, text: 'old'));
    await nb.flush();
    return (nb: nb, a: a);
  }

  test('AiLinkMode and AiWriteMode have the same names', () {
    expect(AiLinkMode.values.map((m) => m.name), AiWriteMode.values.map((m) => m.name));
  });

  group('accepted', () {
    test('a write to the open page shows at once and is one undo step', () async {
      final t = await withBox();
      final c = t.nb.current!;
      var notified = 0;
      c.addListener(() => notified++);
      final before = (c.page.node('ba')! as BoxRecord);

      final r = await t.nb.aiWrite(req('ba', content: 'new text'));
      expect(r.ok, isTrue);
      expect(r.page, t.a);
      expect(r.box, 'ba');
      expect(notified, greaterThan(0), reason: 'the canvas is told');
      expect(dataOf(t.nb, 'ba')['text'], 'new text');
      expect(dataOf(t.nb, 'ba')['owner'], connId);
      final after = c.page.node('ba')! as BoxRecord;
      expect(after.snapshotText, 'new text');
      expect(after.rev, isNot(before.rev));
      expect(after.device, 'TestPC');
      // Saved by the normal path.
      expect(readPage(File('${pages.path}/${t.a}.canvas').readAsStringSync()).node('ba'), isA<BoxRecord>());
      expect(File('${pages.path}/${t.a}.canvas').readAsStringSync(), contains('new text'));

      // One undo step, then the box is back and still there.
      c.undo();
      expect(dataOf(t.nb, 'ba')['text'], 'old');
      expect(c.page.node('ba'), isNotNull);
      c.redo();
      expect(dataOf(t.nb, 'ba')['text'], 'new text');
    });

    test('append adds to the text', () async {
      final t = await withBox();
      await t.nb.aiWrite(req('ba', content: ' more', mode: AiLinkMode.append));
      expect(dataOf(t.nb, 'ba')['text'], 'old more');
    });

    test('Box only allows writing too', () async {
      final t = await withBox(setting: AiSetting.boxOnly);
      expect((await t.nb.aiWrite(req('ba'))).ok, isTrue);
    });

    test('an inherited setting allows it', () async {
      final t = await withBox();
      final sub = await t.nb.createPage(parentId: t.a);
      t.nb.current!.insertBox(box('bs', owner: connId));
      expect(t.nb.ownAiSetting(sub), isNull);
      expect((await t.nb.aiWrite(req('bs'))).ok, isTrue);
    });

    test('a write to a closed page is on disk and survives a restart', () async {
      final t = await withBox();
      final other = await t.nb.createPage();
      expect(t.nb.currentId, other);

      final r = await t.nb.aiWrite(req('ba', content: 'closed write'));
      expect(r.ok, isTrue);
      expect(r.page, t.a);
      final file = File('${pages.path}/${t.a}.canvas');
      expect(file.readAsStringSync(), contains('closed write'));

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

    test('a page in a binder is found', () async {
      final nb = make();
      await nb.load();
      final s = await nb.addBinder(folder.path);
      final p = await nb.createPage(binderPath: s.path);
      await nb.setAiSetting(p, AiSetting.wholePage);
      nb.current!.insertBox(box('bb', owner: connId));
      await nb.open(nb.tree.roots.first.id);
      expect(nb.currentId, isNot(p));
      final r = await nb.aiWrite(req('bb', content: 'in binder'));
      expect(r.ok, isTrue);
      expect(r.page, p);
      expect(File('${folder.path}/$p.canvas').readAsStringSync(), contains('in binder'));
    });
  });

  group('ordering and races', () {
    test('queued writes are applied in the order they came', () async {
      final t = await withBox();
      final all = await Future.wait([
        t.nb.aiWrite(req('ba', content: 'one', mode: AiLinkMode.replace)),
        t.nb.aiWrite(req('ba', content: ' two', mode: AiLinkMode.append)),
        t.nb.aiWrite(req('ba', content: ' three', mode: AiLinkMode.append)),
      ]);
      expect(all.every((r) => r.ok), isTrue);
      expect(dataOf(t.nb, 'ba')['text'], 'one two three');

      // The same for a closed page.
      await t.nb.createPage();
      await Future.wait([
        t.nb.aiWrite(req('ba', content: 'A', mode: AiLinkMode.replace)),
        t.nb.aiWrite(req('ba', content: 'B', mode: AiLinkMode.append)),
      ]);
      await t.nb.open(t.a);
      expect(dataOf(t.nb, 'ba')['text'], 'AB');
    });

    for (final writeFirst in [true, false]) {
      test('a write to a closed page racing open() is not lost (${writeFirst ? 'write' : 'open'} first)', () async {
        final t = await withBox();
        await t.nb.createPage(); // t.a is closed now
        final Future<AiLinkResponse> w;
        final Future<void> o;
        if (writeFirst) {
          w = t.nb.aiWrite(req('ba', content: 'raced'));
          o = t.nb.open(t.a);
        } else {
          o = t.nb.open(t.a);
          w = t.nb.aiWrite(req('ba', content: 'raced'));
        }
        expect((await w).ok, isTrue);
        await o;
        expect(t.nb.currentId, t.a);
        expect(dataOf(t.nb, 'ba')['text'], 'raced', reason: 'the open page shows it');

        // The user's next save keeps it.
        t.nb.current!.insertBox(box('user', owner: null, text: 'mine'));
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
      final r = nb.aiWrite(req('ba', content: 'early'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await nb.load();
      expect((await r).ok, isTrue);
      await nb.open(first.a);
      expect(dataOf(nb, 'ba')['text'], 'early');
    });

    test('a bad token is refused without waiting for the load', () async {
      final nb = make();
      expect(await codeOf(nb, req('ba', tok: 'garbage')), AiLinkCode.badToken);
    });

    test('the closed page\'s own file decides the AI setting', () async {
      final t = await withBox();
      await t.nb.createPage();
      final f = File('${pages.path}/${t.a}.canvas');
      f.writeAsStringSync(f.readAsStringSync().replaceAll('"ai":"page"', '"ai":"off"'));
      expect(f.readAsStringSync(), contains('"ai":"off"'));
      expect(t.nb.aiSettingFor(t.a), AiSetting.wholePage, reason: 'the notebook has not looked yet');
      expect(await codeOf(t.nb, req('ba')), AiLinkCode.noBox);
    });
  });

  group('save failures', () {
    test('an open page that can not be saved answers save_failed and keeps the change for recovery', () async {
      final rec = Directory('${root.path}/rec');
      final nb = make(recovery: rec);
      await nb.load();
      final a = nb.currentId!;
      await nb.setAiSetting(a, AiSetting.wholePage);
      nb.current!.insertBox(box('ba', owner: connId, text: 'old'));
      await nb.flush();
      pages.deleteSync(recursive: true); // the folder goes away

      final r = await nb.aiWrite(req('ba', content: 'new'));
      expect(r.code, AiLinkCode.saveFailed);
      expect(r.message, contains("don't retry an append"));
      expect(dataOf(nb, 'ba')['text'], 'new', reason: 'still on screen');
      expect(rec.existsSync() && rec.listSync().isNotEmpty, isTrue, reason: 'kept for recovery');
    });

    test('a closed page that can not be saved is kept for recovery', () async {
      final rec = Directory('${root.path}/rec');
      final store = _VanishingStore(pages);
      final nb = make(store: store, recovery: rec);
      await nb.load();
      final a = nb.currentId!;
      await nb.setAiSetting(a, AiSetting.wholePage);
      nb.current!.insertBox(box('ba', owner: connId, text: 'old'));
      await nb.flush();
      await nb.createPage();
      // The folder disappears after the write has read the page.
      store.vanishOnLoad = store.loads + 2;

      final r = await nb.aiWrite(req('ba', content: 'new'));
      expect(r.code, AiLinkCode.saveFailed);
      expect(r.message, contains("don't retry an append"));
      expect(rec.existsSync() && rec.listSync().isNotEmpty, isTrue, reason: 'kept for recovery');
    });

    test('one page failing to save does not fail a write to another', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await nb.setAiSetting(a, AiSetting.wholePage);
      nb.current!.insertBox(box('ba', owner: connId, text: 'old'));
      await nb.flush();
      final b = await nb.createPage();
      await nb.setAiSetting(b, AiSetting.wholePage);
      nb.current!.insertBox(box('bb', owner: connId, text: 'old'));
      await nb.flush();
      // Page b can't be saved (its file is a folder); page a still can.
      File('${pages.path}/$b.canvas').deleteSync();
      Directory('${pages.path}/$b.canvas').createSync();
      expect((await nb.aiWrite(req('bb'))).code, AiLinkCode.saveFailed);
      await nb.open(a);
      expect((await nb.aiWrite(req('ba', content: 'fine'))).ok, isTrue);
    });
  });

  group('rejected', () {
    test('a malformed, wrong or unknown token', () async {
      final t = await withBox();
      final good = parseAiToken(token)!;
      final wrongKey = 'noted_${good.id}_${'A' * 43}';
      final unknownId = 'noted_${'0' * 16}_${good.key}';
      for (final bad in ['', 'garbage', 'noted_', wrongKey, unknownId, '$token-x']) {
        expect(await codeOf(t.nb, req('ba', tok: bad)), AiLinkCode.badToken, reason: bad);
      }
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });

    test('the token is checked before the box is looked up', () async {
      final t = await withBox();
      expect(await codeOf(t.nb, req('no-such-box', tok: 'garbage')), AiLinkCode.badToken);
      expect(await codeOf(t.nb, req('no-such-box')), AiLinkCode.noBox);
    });

    test('a revoked token fails at once', () async {
      final t = await withBox();
      expect((await t.nb.aiWrite(req('ba', content: 'one'))).ok, isTrue);
      settings.revokeAiConnection(connId);
      expect(await codeOf(t.nb, req('ba', content: 'two')), AiLinkCode.badToken);
      expect(dataOf(t.nb, 'ba')['text'], 'one');
    });

    test('an unknown box', () async {
      final t = await withBox();
      expect(await codeOf(t.nb, req('nope')), AiLinkCode.noBox);
    });

    test('a page that is Off gives the same answer as no box', () async {
      final t = await withBox(setting: AiSetting.off);
      expect(await codeOf(t.nb, req('ba')), AiLinkCode.noBox);
      expect(await codeOf(t.nb, req('nope')), AiLinkCode.noBox);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });

    test('Off with nothing chosen (the default) and Off inherited', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      nb.current!.insertBox(box('ba', owner: connId));
      expect(await codeOf(nb, req('ba')), AiLinkCode.noBox, reason: 'Off by default');

      await nb.setAiSetting(a, AiSetting.off);
      final sub = await nb.createPage(parentId: a);
      await nb.setAiSetting(sub, null);
      nb.current!.insertBox(box('bs', owner: connId));
      expect(nb.aiSettingFor(sub), AiSetting.off);
      expect(await codeOf(nb, req('bs')), AiLinkCode.noBox);
      await nb.open(a); // sub is closed now
      expect(await codeOf(nb, req('bs')), AiLinkCode.noBox);
    });

    test('a box of another connection, or of nobody', () async {
      final t = await withBox();
      final other = await settings.addAiConnection('Other');
      expect(await codeOf(t.nb, req('ba', tok: other)), AiLinkCode.notOwner);
      t.nb.current!.insertBox(box('free'));
      expect(await codeOf(t.nb, req('free')), AiLinkCode.notOwner);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });

    test('a conflicted box', () async {
      final t = await withBox();
      final other = box('ba', owner: connId, text: 'theirs');
      t.nb.current!.insertBox(
        box('bc', owner: connId, text: 'mine').withConflict(BoxConflict.other(node: other.toRaw(), at: 5)),
      );
      expect(await codeOf(t.nb, req('bc')), AiLinkCode.conflict);
      expect(dataOf(t.nb, 'bc')['text'], 'mine');
    });

    test('a box type that takes no AI writes', () async {
      final t = await withBox();
      t.nb.current!.insertBox(box('bn', owner: connId, type: 'test.noai'));
      expect(await codeOf(t.nb, req('bn')), AiLinkCode.notWritable);
    });

    test('a box whose module is switched off, or not installed', () async {
      final t = await withBox();
      modules.codecs.setEnabled('test.ai', false);
      expect(await codeOf(t.nb, req('ba')), AiLinkCode.notWritable);
      modules.codecs.setEnabled('test.ai', true);
      expect((await t.nb.aiWrite(req('ba'))).ok, isTrue);

      // Saved by a module this build doesn't have: passes through untouched.
      final foreign = BoxRecord.create(
        id: 'bf',
        typeId: 'other.thing',
        dataVersion: 1,
        bounds: const Bounds(0, 0, 10, 10),
        data: RawJson.encode({'owner': connId}),
        snapshotText: 'x',
        rev: 'r',
      );
      t.nb.current!.insertBox(foreign);
      expect(await codeOf(t.nb, req('bf')), AiLinkCode.notWritable);
    });

    Future<({Notebook nb, String page})> lockedBinder() async {
      final first = make();
      await first.load();
      final s = await first.addBinder(folder.path);
      final p = await first.createPage(binderPath: s.path);
      await first.setAiSetting(p, AiSetting.wholePage);
      first.current!.insertBox(box('bl', owner: connId, text: 'old'));
      await first.flush();
      first.dispose();
      opened.clear();
      File('${folder.path}/$binderFileName').writeAsStringSync('{ not json');
      final nb = make();
      await nb.load();
      expect(nb.isReadOnlyPage(p), isTrue);
      return (nb: nb, page: p);
    }

    test('a page of a binder that can not be read, closed or open', () async {
      final t = await lockedBinder();
      expect(t.nb.currentId, isNot(t.page));
      expect(await codeOf(t.nb, req('bl')), AiLinkCode.locked);
      await t.nb.open(t.page);
      expect(await codeOf(t.nb, req('bl')), AiLinkCode.locked);
      expect(dataOf(t.nb, 'bl')['text'], 'old');
      expect(File('${folder.path}/${t.page}.canvas').readAsStringSync(), isNot(contains('hello')));
    });

    test('a read-only open page', () async {
      final t = await withBox();
      t.nb.current!.readOnly = true;
      expect(await codeOf(t.nb, req('ba')), AiLinkCode.locked);
      expect(dataOf(t.nb, 'ba')['text'], 'old');
    });
  });
}

ModuleRegistry _modules() => buildModules()
  ..register(const _Module(_Codec('test.ai')))
  ..register(const _Module(_Codec('test.noai', writes: false)));
