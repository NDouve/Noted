// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A folder that holds another binder than `binders.json` records is unusable
// (R-2, M): its pages are left out, or Guarded and locked when the folder is
// also listed as standalone, and a closed write there is refused. The same
// rule holds at the hold-time recheck, so a closed write elsewhere is not
// turned busy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core_read.dart';
import 'package:noted_mcp/noted_mcp.dart';

import 'closed_test.dart' show idBinderCode, idWriter, token, writeStore, codeOf;
import 'fixture.dart';

void main() {
  late Directory root;
  late Directory data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_mcp_ident');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort for a temp folder.
      }
    });
    data = writeFixture(root);
  });

  Map<String, Object?> lists() =>
      jsonDecode(File('${data.path}/binders.json').readAsStringSync()) as Map<String, Object?>;
  void setLists(Map<String, Object?> extra) =>
      File('${data.path}/binders.json').writeAsStringSync(jsonEncode({...lists(), ...extra}));

  NotedToolbox toolbox() => NotedToolbox(
    data,
    session: 's',
    app: 'Test App 1.2',
    greetingTimeout: const Duration(milliseconds: 500),
    responseTimeout: const Duration(seconds: 5),
    closedHoldLimit: const Duration(seconds: 60),
  );

  Set<String> listed(String text) => {
    for (final p in (jsonDecode(text)['pages'] as List).cast<Map<String, Object?>>()) p['id']! as String,
  };

  String idOf(String folder) => Binder.parse(File('$folder/$binderFileName').readAsStringSync()).id;

  // A page with an AI box in [dir], and a Writer code that may write it closed.
  void aiBoxPage(String dir, String pageId, String boxId) {
    File('$dir/$pageId.canvas').writeAsStringSync(
      writePage(
        page(
          pageId,
          'AI $pageId',
          ai: 'open',
          nodes: [box(boxId, aiBoxTypeId, aiBoxData('okapi'), const Bounds(0, 100, 100, 40))],
        ),
      ),
    );
    writeStore(
      data,
      [codeOf(idWriter, AiCodeTarget.box(boxId, page: pageId), role: 'writer')],
      {
        boxId: {'closedWrites': true, 'writerPermission': 'append'},
      },
    );
  }

  Future<ToolOutput> append(NotedToolbox t, String boxId) =>
      t.writeBox(boxId: boxId, code: token(idWriter), mode: 'append', content: 'new words');

  String trips() => '${root.path}/Trips';

  group('21. binderIds records A while the folder holds B', () {
    test('no entry: as today (guard)', () async {
      final t = toolbox();
      expect(listed((await t.listPages()).text), contains(Ids.binderPage));
    });

    test('code-less list_pages and search leave the folder pages out', () async {
      setLists({
        'binderIds': {trips(): 'aaaaaaaaaaaaaaaa'},
      });
      final t = toolbox();
      expect(listed((await t.listPages()).text), isNot(contains(Ids.binderPage)));
      final hits = jsonDecode((await t.search('zebra binder')).text)['results'] as List;
      expect(hits.map((r) => (r as Map)['id']), isNot(contains(Ids.binderPage)));
      // The other binders are as before.
      expect(listed((await t.listPages()).text), contains(Ids.public));
    });

    test('a record that matches the file changes nothing', () async {
      setLists({
        'binderIds': {trips(): idOf(trips())},
      });
      expect(listed((await toolbox().listPages()).text), contains(Ids.binderPage));
    });

    test('binder codes for A and for B read nothing of it', () async {
      final taxes = '${root.path}/Taxes';
      final b = idOf(taxes);
      setLists({
        'binderIds': {taxes: 'aaaaaaaaaaaaaaaa'},
      });
      for (final id in ['aaaaaaaaaaaaaaaa', b]) {
        writeStore(data, [codeOf(idBinderCode, AiCodeTarget.binder(id))]);
        final r = await toolbox().readPage(Ids.privBinderPage, code: token(idBinderCode));
        expect(r.isError, isTrue, reason: 'code for $id');
        expect(r.text, noSuchPage(Ids.privBinderPage));
      }
    });

    test('a binder-only folder: a closed write to its page is refused (left out)', () async {
      final f = Directory('${root.path}/Solo')..createSync();
      File('${f.path}/$binderFileName').writeAsStringSync(
        Binder.create(title: 'Solo', color: binderPalette.first).withAiAccess(AiAccess.open).write(),
      );
      aiBoxPage(f.path, 'f000000000000071', 'aiS');
      setLists({
        'binders': [...(lists()['binders'] as List), f.path],
        'binderIds': {f.path: idOf(f.path)},
      });
      final p = File('${f.path}/f000000000000071.canvas');
      final before = p.readAsBytesSync();
      // With the right id it writes (guard for the setup).
      expect((await append(toolbox(), 'aiS')).isError, isFalse);
      p.writeAsBytesSync(before);
      setLists({
        'binderIds': {f.path: 'aaaaaaaaaaaaaaaa'},
      });
      final out = await append(toolbox(), 'aiS');
      expect(out.isError, isTrue);
      expect(out.text, isNot(binderUnusableText));
      expect(p.readAsBytesSync(), before);
    });

    test('a folder also listed as standalone: Guarded and locked, a write gets binder_unusable', () async {
      final f = Directory('${root.path}/Both')..createSync();
      File('${f.path}/$binderFileName').writeAsStringSync(
        Binder.create(title: 'Both', color: binderPalette.first).withAiAccess(AiAccess.open).write(),
      );
      aiBoxPage(f.path, 'f000000000000072', 'aiB2');
      setLists({
        'binders': [...(lists()['binders'] as List), f.path],
        'standaloneFolders': [f.path],
        'binderIds': {f.path: 'aaaaaaaaaaaaaaaa'},
      });
      final p = File('${f.path}/f000000000000072.canvas');
      final before = p.readAsBytesSync();
      final t = toolbox();
      expect((await t.readPage('f000000000000072')).isError, isTrue);
      final out = await append(t, 'aiB2');
      expect(out.isError, isTrue);
      expect(out.text, binderUnusableText);
      expect(p.readAsBytesSync(), before);
    });
  });

  test('21b. F holds B: a closed write to a page in another folder is done, not busy', () async {
    final other = Directory('${root.path}/Elsewhere')..createSync();
    aiBoxPage(other.path, 'f000000000000073', 'aiE2');
    setLists({
      'standaloneFolders': [other.path],
      'binderIds': {trips(): 'aaaaaaaaaaaaaaaa'},
    });
    final p = File('${other.path}/f000000000000073.canvas');
    final before = p.readAsBytesSync();
    final out = await append(toolbox(), 'aiE2');
    expect(out.isError, isFalse, reason: out.text);
    expect(p.readAsBytesSync(), isNot(before));
  });
}
