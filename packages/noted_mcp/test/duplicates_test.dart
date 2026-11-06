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
import 'closed_test.dart'
    show
        idReader,
        idWriter,
        idPageCode,
        idBinderCode,
        token,
        writeStore,
        codeOf,
        readLog;
import 'fixture.dart';
import 'running_lock.dart';

// Run 2026-11-06-04, task 3: the MCP server never reads an unchosen copy. A page
// id with more than one file (in a folder, across folders and binders; a file the
// server can't use counts for the id it may carry) is Guarded, so are the pages
// under it, and its boxes answer `ambiguousPageText` to box codes.

const _small = Bounds(0, 0, 100, 40);

void main() {
  late Directory root;
  late Directory data;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_mcp_dup');
    // Registered first, so it runs last: after every lock and permission is undone.
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort for a temp folder.
      }
    });
    data = writeFixture(root);
  });

  // ---- helpers --------------------------------------------------------------

  Directory mk(String name) =>
      Directory('${root.path}/$name')..createSync(recursive: true);
  String pagesDir() => '${data.path}/pages';
  String pagePath(String id, [String? dir]) =>
      '${dir ?? pagesDir()}/$id.canvas';

  void save(String dir, NotedPage p, [String? name]) =>
      File('$dir/${name ?? p.id}.canvas').writeAsStringSync(writePage(p));

  // A copy of the saved page file [id] (from the default pages folder, or [from])
  // in [dir] under [name].
  void copyTo(String dir, String id, {String? name, String? from}) =>
      File(pagePath(id, from)).copySync('$dir/${name ?? id}.canvas');

  Map<String, Object?> listsJson() =>
      jsonDecode(File('${data.path}/binders.json').readAsStringSync())
          as Map<String, Object?>;

  void setLists({
    List<String> standalone = const [],
    List<String> binders = const [],
  }) {
    final j = listsJson();
    File('${data.path}/binders.json').writeAsStringSync(
      jsonEncode({
        ...j,
        'standaloneFolders': [
          ...(j['standaloneFolders'] as List? ?? const []),
          ...standalone,
        ],
        'binders': [...(j['binders'] as List? ?? const []), ...binders],
      }),
    );
  }

  Future<NotedLibrary> load() => NotedLibrary.load(data);

  NotedToolbox toolbox({Future<void> Function(int attempt)? beforeHold}) =>
      NotedToolbox(
        data,
        session: 's',
        app: 'Test App 1.2',
        greetingTimeout: const Duration(milliseconds: 500),
        responseTimeout: const Duration(seconds: 5),
        closedHoldLimit: const Duration(seconds: 60),
        beforeClosedHold: beforeHold,
      );

  Set<String> listedIds(String text) => {
    for (final p
        in (jsonDecode(text)['pages'] as List).cast<Map<String, Object?>>())
      p['id']! as String,
  };

  // What an AI without a code gets for the page: true if it reads it.
  Future<bool> reads(String id, {String? code}) async =>
      !(await toolbox().readPage(id, code: code)).isError;

  // Makes [path] (a file) unreadable. Returns false (and the test should end) if
  // this platform or user can't.
  Future<bool> makeUnreadable(String path) async {
    if (Platform.isWindows) {
      await RunningLock.holdFile(path);
    } else {
      Process.runSync('chmod', ['000', path]);
      addTearDown(() => Process.runSync('chmod', ['644', path]));
    }
    try {
      File(path).readAsBytesSync();
      markTestSkipped('this platform cannot make $path unreadable');
      return false;
    } on FileSystemException {
      return true;
    }
  }

  // Makes the folder [path] fail to list.
  bool makeUnlistable(String path) {
    if (Platform.isWindows) {
      Process.runSync('icacls', [path, '/deny', '*S-1-1-0:(RD)']);
      addTearDown(
        () => Process.runSync('icacls', [path, '/remove:d', '*S-1-1-0']),
      );
    } else {
      Process.runSync('chmod', ['000', path]);
      addTearDown(() => Process.runSync('chmod', ['755', path]));
    }
    try {
      Directory(path).listSync();
      markTestSkipped('this platform cannot make $path fail to list');
      return false;
    } on FileSystemException {
      return true;
    }
  }

  AiCode readerBox(String box, String page, {String id = idReader}) =>
      codeOf(id, AiCodeTarget.box(box, page: page));
  AiCode writerBox(String box, String page) =>
      codeOf(idWriter, AiCodeTarget.box(box, page: page), role: 'writer');
  Map<String, Object?> allowClosed(String box) => {
    box: {'closedWrites': true, 'writerPermission': 'append'},
  };
  Future<ToolOutput> append(NotedToolbox t, String box) => t.writeBox(
    boxId: box,
    code: token(idWriter),
    mode: 'append',
    content: 'new words',
  );

  // A page with an AI box, in [dir].
  NotedPage aiPage(
    String id,
    String boxId, {
    String? parent,
    String? ai = 'open',
    String text = 'okapi',
  }) => page(
    id,
    'AI $id',
    parent: parent,
    ai: ai,
    nodes: [
      box(boxId, aiBoxTypeId, aiBoxData(text), const Bounds(0, 100, 100, 40)),
    ],
  );

  // ---- 1 to 3: the page tools -------------------------------------------------

  group('the page tools never serve an id with more than one file', () {
    test('1. two files with one id in one folder, both Open: hidden from list_pages, search and read_page', () async {
      // A sync copy beside the page: same header, Open.
      copyTo(pagesDir(), Ids.public, name: '${Ids.public}-DESKTOP-ABC');
      final lib = await load();
      expect(lib.ambiguous, contains(Ids.public));
      expect(lib.page(Ids.public)!.access, AiAccess.guarded);
      final t = toolbox();
      expect(
        listedIds((await t.listPages()).text),
        isNot(contains(Ids.public)),
      );
      expect((await t.readPage(Ids.public)).text, noSuchPage(Ids.public));
      final hits = jsonDecode((await t.search('Trip')).text)['results'] as List;
      expect(hits.map((r) => (r as Map)['id']), isNot(contains(Ids.public)));
      expect((await t.readBox('note')).text, noSuchBox('note'));
    });

    test(
      '1. a page code on the parent does not cover an ambiguous child',
      () async {
        writeStore(data, [
          codeOf(idPageCode, const AiCodeTarget.page(Ids.priv)),
        ]);
        final t = toolbox();
        expect(
          (await t.readPage(Ids.privChild, code: token(idPageCode))).isError,
          isFalse,
          reason: 'one copy: covered',
        );
        copyTo(pagesDir(), Ids.privChild, name: '${Ids.privChild}-LAPTOP');
        expect(
          (await t.readPage(Ids.privChild, code: token(idPageCode))).text,
          noSuchPage(Ids.privChild),
        );
        final ids = listedIds(
          (await t.listPages(code: token(idPageCode))).text,
        );
        expect(ids, contains(Ids.priv));
        expect(ids, isNot(contains(Ids.privChild)));
      },
    );

    test('2. across two standalone folders', () async {
      final other = mk('Other');
      copyTo(other.path, Ids.public);
      setLists(standalone: [other.path]);
      expect((await load()).ambiguous, {Ids.public});
      expect(
        (await toolbox().readPage(Ids.public)).text,
        noSuchPage(Ids.public),
      );
    });

    test('2. across a standalone folder and a binder', () async {
      copyTo('${root.path}/Trips', Ids.public);
      expect((await load()).ambiguous, {Ids.public});
      expect(
        (await toolbox().readPage(Ids.public)).text,
        noSuchPage(Ids.public),
      );
      expect((await toolbox().readPage(Ids.binderPage)).isError, isFalse);
    });

    test('2. across two binders; a binder code does not cover the page', () async {
      final taxes = Binder.parse(
        File('${root.path}/Taxes/$binderFileName').readAsStringSync(),
      );
      writeStore(data, [codeOf(idBinderCode, AiCodeTarget.binder(taxes.id))]);
      expect(
        (await toolbox().readPage(
          Ids.privBinderPage,
          code: token(idBinderCode),
        )).isError,
        isFalse,
      );
      copyTo(
        '${root.path}/Taxes',
        Ids.binderPage,
        from: '${root.path}/Trips',
      ); // an Open page of Trips, also in Taxes
      expect((await load()).ambiguous, {Ids.binderPage});
      expect(
        (await toolbox().readPage(Ids.binderPage)).text,
        noSuchPage(Ids.binderPage),
      );
      // A copy of the Taxes page in Trips: the binder code no longer covers it.
      copyTo(
        '${root.path}/Trips',
        Ids.privBinderPage,
        from: '${root.path}/Taxes',
      );
      expect(
        (await toolbox().readPage(
          Ids.privBinderPage,
          code: token(idBinderCode),
        )).text,
        noSuchPage(Ids.privBinderPage),
      );
      expect(
        listedIds((await toolbox().listPages(code: token(idBinderCode))).text),
        isNot(contains(Ids.privBinderPage)),
      );
    });

    test('3. a child (header Open) of an ambiguous page is hidden', () async {
      expect((await toolbox().readPage(Ids.publicChild)).isError, isFalse);
      copyTo(mk('Other').path, Ids.public);
      setLists(standalone: ['${root.path}/Other']);
      final lib = await load();
      expect(lib.page(Ids.publicChild)!.access, AiAccess.guarded);
      expect(
        (await toolbox().readPage(Ids.publicChild)).text,
        noSuchPage(Ids.publicChild),
      );
      expect(
        listedIds((await toolbox().listPages()).text),
        isNot(contains(Ids.publicChild)),
      );
    });

    test('3. a binder page whose parent is ambiguous only through a copy in another tree is hidden', () async {
      final trips = '${root.path}/Trips';
      save(trips, page('a100000000000001', 'Parent', ai: 'open'));
      save(
        trips,
        page(
          'a100000000000002',
          'Child',
          parent: 'a100000000000001',
          ai: 'open',
        ),
      );
      expect(
        await reads('a100000000000002'),
        isTrue,
        reason: 'one copy: served',
      );
      // A copy of the parent in a standalone folder (another tree).
      final other = mk('Other');
      save(other.path, page('a100000000000001', 'Parent copy', ai: 'open'));
      setLists(standalone: [other.path]);
      expect(await reads('a100000000000002'), isFalse);
      expect(await reads('a100000000000001'), isFalse);
    });

    test('5. a second file that does not read as a page does not make the id ambiguous', () async {
      File('${pagesDir()}/old-copy.canvas').writeAsStringSync('{ not json');
      File('${pagesDir()}/notes.canvas')
          .writeAsStringSync('{"nodes":[],"edges":[]}');
      final lib = await load();
      expect(lib.ambiguous, isEmpty);
      expect(lib.allAmbiguous, isFalse);
      expect(await reads(Ids.public), isTrue);
    });

    test('6. removing the second copy: the next request serves the page under its own access', () async {
      copyTo(pagesDir(), Ids.public, name: '${Ids.public}-PC');
      expect(await reads(Ids.public), isFalse);
      File('${pagesDir()}/${Ids.public}-PC.canvas').deleteSync();
      expect(await reads(Ids.public), isTrue);
      final out = await toolbox().listPages();
      expect(listedIds(out.text), openIds);
    });
  });

  // ---- 4: box codes -----------------------------------------------------------

  group('box codes on an ambiguous page', () {
    test('4. the read answers ambiguousPageText and a closed write refuses; both files are unchanged', () async {
      writeStore(data, [
        readerBox('aiA', Ids.aiOpen),
        writerBox('aiA', Ids.aiOpen),
      ], allowClosed('aiA'));
      final other = mk('Other');
      copyTo(other.path, Ids.aiOpen);
      setLists(standalone: [other.path]);
      final a = File(pagePath(Ids.aiOpen)).readAsBytesSync();
      final b = File(pagePath(Ids.aiOpen, other.path)).readAsBytesSync();
      final read = await toolbox().readBox('aiA', code: token(idReader));
      expect(read.isError, isTrue);
      expect(read.text, ambiguousPageText);
      final out = await append(toolbox(), 'aiA');
      expect(out.isError, isTrue);
      expect(out.text, ambiguousPageText);
      expect(File(pagePath(Ids.aiOpen)).readAsBytesSync(), a);
      expect(File(pagePath(Ids.aiOpen, other.path)).readAsBytesSync(), b);
      expect(readLog(data).map((e) => e.result), ['ambiguous', 'ambiguous']);
      // One copy left: the box reads and writes as before.
      File(pagePath(Ids.aiOpen, other.path)).deleteSync();
      expect(
        (await toolbox().readBox('aiA', code: token(idReader))).text,
        contains('okapi from A'),
      );
      expect((await append(toolbox(), 'aiA')).isError, isFalse);
    });

    test('4. while Noted runs, the grant the app gives is not read from an ambiguous page', () async {
      copyTo(mk('Other').path, Ids.aiOpen);
      setLists(standalone: ['${root.path}/Other']);
      final f = await FakeNoted.start(data);
      addTearDown(f.close);
      f.answer = (_) =>
          AiLinkResponse.granted(AiLinkBoxGrant(box: 'aiA', page: Ids.aiOpen))
              .encode();
      final out = await toolbox().readBox('aiA', code: token(idReader));
      expect(out.isError, isTrue);
      expect(out.text, ambiguousPageText);
    });

    test('N1. the hint page is checked first: a hint with copies never falls back to another page with the same box id', () async {
      // The hint page has two copies and no box aiA; the Open AI page has aiA.
      const hint = 'f000000000000009';
      final other = mk('Other');
      save(pagesDir(), page(hint, 'Hint page', ai: 'open'));
      save(other.path, page(hint, 'Hint copy', ai: 'open'));
      setLists(standalone: [other.path]);
      writeStore(data, [
        readerBox('aiA', hint),
        writerBox('aiA', hint),
      ], allowClosed('aiA'));
      final read = await toolbox().readBox('aiA', code: token(idReader));
      expect(
        read.text,
        ambiguousPageText,
        reason: 'not the aiA of another page',
      );
      expect(read.text, isNot(contains('okapi')));
      final before = File(pagePath(Ids.aiOpen)).readAsBytesSync();
      final out = await append(toolbox(), 'aiA');
      expect(out.text, ambiguousPageText);
      expect(File(pagePath(Ids.aiOpen)).readAsBytesSync(), before);
      // The tools too: a grant for the hint page reads nothing else.
      final lib = await load();
      final granted = NotedTools(
        lib,
        openPages: false,
      ).readGrantedBox(AiLinkBoxGrant(box: 'aiA', page: hint));
      expect(granted.text, ambiguousPageText);
    });

    test('B2. a closed write is refused through an ambiguous ancestor, page bytes unchanged; the box code still reads', () async {
      save(
        pagesDir(),
        aiPage('f000000000000010', 'aiC', parent: Ids.public, ai: null),
      );
      writeStore(data, [
        readerBox('aiC', 'f000000000000010'),
        writerBox('aiC', 'f000000000000010'),
      ], allowClosed('aiC'));
      copyTo(mk('Other').path, Ids.public);
      setLists(standalone: ['${root.path}/Other']);
      final path = pagePath('f000000000000010');
      final before = File(path).readAsBytesSync();
      final out = await append(toolbox(), 'aiC');
      expect(out.isError, isTrue);
      expect(out.text, ambiguousPageText);
      expect(File(path).readAsBytesSync(), before);
      // Box-code reads do not depend on ancestors (0111).
      expect(
        (await toolbox().readBox('aiC', code: token(idReader))).text,
        contains('okapi'),
      );
    });

    test('B2. a closed write is refused when its chain ends at an id that has copies', () async {
      // The parent file is gone from the tree, but copies of it sit in two other folders... of another tree.
      final trips = '${root.path}/Trips';
      save(
        trips,
        aiPage('f000000000000011', 'aiE', parent: 'f000000000000012', ai: null),
      );
      final x = mk('X');
      final y = mk('Y');
      save(x.path, page('f000000000000012', 'Elsewhere', ai: 'open'));
      save(y.path, page('f000000000000012', 'Elsewhere copy', ai: 'open'));
      setLists(standalone: [x.path, y.path]);
      writeStore(data, [
        writerBox('aiE', 'f000000000000011'),
      ], allowClosed('aiE'));
      final path = pagePath('f000000000000011', trips);
      final before = File(path).readAsBytesSync();
      final out = await append(toolbox(), 'aiE');
      expect(out.text, ambiguousPageText);
      expect(File(path).readAsBytesSync(), before);
    });

    test(
      'merge_requests answers "unavailable" for an ambiguous page',
      () async {
        final note = box('nb', 'noted.note', simpleNote('mine text'), _small)
            .withConflict(
              BoxConflict.other(
                node: box(
                  'nb',
                  'noted.note',
                  simpleNote('their text'),
                  _small,
                ).toRaw(),
                at: 5,
              ),
            );
        const id = 'f000000000000020';
        save(pagesDir(), page(id, 'Merge page', ai: 'open', nodes: [note]));
        final f = await FakeNoted.start(data);
        addTearDown(f.close);
        const item = AiLinkMergeItem(
          id: 'req1',
          page: id,
          box: 'nb',
          type: 'noted.note',
          mine: AiLinkMergeVersion(at: 1000, device: 'A'),
          theirs: AiLinkMergeVersion(at: 2000, device: 'B'),
        );
        f.answer = (_) => const AiLinkResponse.merges([item]).encode();
        final code = token(idPageCode);
        final shown =
            jsonDecode((await toolbox().mergeRequests(code)).text)['requests']
                as List;
        expect(
          (shown.single as Map)['unavailable'],
          isNull,
          reason: 'one copy: both versions are shown',
        );
        expect(jsonEncode(shown), contains('their text'));
        copyTo(mk('Other').path, id);
        setLists(standalone: ['${root.path}/Other']);
        final out = await toolbox().mergeRequests(code);
        expect(out.isError, isFalse);
        final hidden = (jsonDecode(out.text)['requests'] as List).single as Map;
        expect(hidden['unavailable'], isNotNull);
        expect(out.text, isNot(contains('their text')));
      },
    );
  });

  // ---- N6 and revision 2: what can't be used ------------------------------------

  group('files the server cannot use still count for the id they may carry', () {
    test('N6. a copy in a locked binder makes the id ambiguous', () async {
      copyTo('${root.path}/Vault', Ids.public);
      final lib = await load();
      expect(lib.ambiguous, {Ids.public});
      expect(await reads(Ids.public), isFalse);
    });

    test('R2. a locked <id>-DEVICE.canvas in one binder with the readable copy in another hides the page', () async {
      final trips = '${root.path}/Trips';
      final copy = '$trips/${Ids.binderPage}-DEVICE.canvas';
      File(copy).writeAsStringSync(
        File('$trips/${Ids.binderPage}.canvas').readAsStringSync(),
      );
      // The readable page moves to the Taxes binder's folder; the copy stays in Trips, locked.
      File('$trips/${Ids.binderPage}.canvas')
          .copySync('${root.path}/Taxes/${Ids.binderPage}.canvas');
      File('$trips/${Ids.binderPage}.canvas').deleteSync();
      if (!await makeUnreadable(copy)) return;
      final lib = await load();
      expect(
        lib.ambiguous,
        contains(Ids.binderPage),
        reason: 'the name carries the id',
      );
      expect(lib.allAmbiguous, isFalse);
      expect(lib.page(Ids.binderPage)!.access, AiAccess.guarded);
      expect(await reads(Ids.binderPage), isFalse);
    });

    test('B1. a locked .canvas named <id>.canvas counts for that id', () async {
      final other = mk('Other');
      File('${other.path}/${Ids.public}.canvas').writeAsStringSync('{}');
      setLists(standalone: [other.path]);
      if (!await makeUnreadable('${other.path}/${Ids.public}.canvas')) return;
      final lib = await load();
      expect(lib.ambiguous, {Ids.public});
      expect(await reads(Ids.public), isFalse);
      expect(await reads(Ids.publicChild), isFalse);
      expect(
        await reads(Ids.binderPage),
        isTrue,
        reason: 'other ids are served',
      );
    });

    test('B1. a truncated file with an id in its name counts for that id; with none it counts for nothing', () async {
      File('${pagesDir()}/${Ids.public}-DESKTOP-1.canvas')
          .writeAsStringSync('{"nodes":[{"id":"x"');
      File('${pagesDir()}/notes.canvas')
          .writeAsStringSync('{"nodes":[{"id":"x"');
      final lib = await load();
      expect(lib.ambiguous, {Ids.public});
      expect(lib.allAmbiguous, isFalse);
      expect(await reads(Ids.public), isFalse);
      expect(await reads(Ids.binderPage), isTrue);
    });

    test('R2. a stray non-page .canvas does not hide its folder', () async {
      File(
        '${pagesDir()}/drawing.canvas',
      ).writeAsStringSync('{"nodes":[{"id":"1","type":"text","text":"hi"}]}');
      File('${pagesDir()}/empty.canvas').writeAsStringSync('');
      final lib = await load();
      expect(lib.ambiguous, isEmpty);
      expect(lib.allAmbiguous, isFalse);
      expect(await reads(Ids.public), isTrue);
    });

    // The real text of page [id], cut after its header's page id (the header is
    // written last, after every box).
    String cutAfterId(String id, {bool reachId = true}) {
      final text = writePage(
        page(
          id,
          'cut',
          nodes: [
            box('a0000000000000ff', 'noted.note', simpleNote('x'), _small),
          ],
        ),
      );
      final mark = '"pageId":"$id"';
      final at = text.indexOf(mark);
      return text.substring(0, reachId ? at + mark.length : at);
    }

    test('R2. a truncated file with a box id before the header id counts for the page id', () async {
      final other = mk('Other');
      File('${other.path}/weird.canvas')
          .writeAsStringSync(cutAfterId(Ids.public));
      setLists(standalone: [other.path]);
      final lib = await load();
      expect(lib.ambiguous, {
        Ids.public,
      }, reason: 'the header id, not the box id');
      expect(await reads(Ids.public), isFalse);
    });

    test(
      'R2. a half-written copy named "X - Copy.canvas" makes X ambiguous',
      () async {
        final other = mk('Other');
        File('${other.path}/${Ids.public} - Copy.canvas')
            .writeAsStringSync(cutAfterId(Ids.public));
        setLists(standalone: [other.path]);
        final lib = await load();
        expect(lib.ambiguous, {Ids.public});
        expect(await reads(Ids.public), isFalse);
        expect(await reads(Ids.publicChild), isFalse);
      },
    );

    test('R2. a truncated file that never reaches the header id counts for its name\'s id only', () async {
      final other = mk('Other');
      File('${other.path}/${Ids.public}-DEVICE-1.canvas')
          .writeAsStringSync(cutAfterId(Ids.binderPage, reachId: false));
      File('${other.path}/${Ids.public} - Copy.canvas')
          .writeAsStringSync(cutAfterId(Ids.binderPage, reachId: false));
      setLists(standalone: [other.path]);
      final lib = await load();
      expect(
        lib.ambiguous,
        {Ids.public},
        reason: 'the name\'s id; a box id and a name without an id count for nothing',
      );
      expect(lib.allAmbiguous, isFalse);
    });

    test('a readable file that does not parse counts for its header id and its name\'s id', () async {
      final other = mk('Other');
      File('${other.path}/${Ids.publicChild}-X.canvas')
          .writeAsStringSync(cutAfterId(Ids.public));
      setLists(standalone: [other.path]);
      expect((await load()).ambiguous, {Ids.public, Ids.publicChild});
    });

    test('an uppercase name carries no id: unreadable, it falls under the unknown rule', () async {
      expect(nameIds('/x/A0000000000000A1.canvas'), isEmpty);
      expect(fileIdsOf('/x/A0000000000000A1.canvas', null).unknown, isTrue);
    });

    test('B1. a file that can\'t be read and has no id in its name makes every id ambiguous', () async {
      final other = mk('Other');
      File('${other.path}/notes.canvas').writeAsStringSync('{}');
      setLists(standalone: [other.path]);
      if (!await makeUnreadable('${other.path}/notes.canvas')) return;
      final lib = await load();
      expect(lib.allAmbiguous, isTrue);
      expect(lib.isAmbiguous('anything'), isTrue);
      expect(await reads(Ids.public), isFalse);
      expect(lib.pages.every((p) => p.access == AiAccess.guarded), isTrue);
      writeStore(data, [readerBox('aiA', Ids.aiOpen)]);
      expect(
        (await toolbox().readBox('aiA', code: token(idReader))).text,
        ambiguousPageText,
      );
    });

    test(
      'B1. a listed folder that fails to list makes every id ambiguous',
      () async {
        final other = mk('Other');
        setLists(standalone: [other.path]);
        if (!makeUnlistable(other.path)) return;
        final lib = await load();
        expect(lib.allAmbiguous, isTrue);
        expect(await reads(Ids.public), isFalse);
      },
    );

    for (final name in ['binders.json', 'settings.json']) {
      test(
        'B1. a $name that exists but can\'t be read makes every id ambiguous',
        () async {
          if (!await makeUnreadable('${data.path}/$name')) return;
          final lib = await load();
          expect(lib.allAmbiguous, isTrue);
          expect(await reads(Ids.public), isFalse);
        },
      );
    }

    test('N-a. a damaged binder file still counts its folder\'s copies and does not hide the other binders', () async {
      // Taxes' binder file is damaged; a copy of an Open Trips page sits in Taxes.
      File('${root.path}/Taxes/$binderFileName').writeAsStringSync('{ damaged');
      copyTo('${root.path}/Taxes', Ids.binderPage, from: '${root.path}/Trips');
      final lib = await load();
      expect(lib.ambiguous, {Ids.binderPage});
      expect(lib.allAmbiguous, isFalse);
      expect(
        await reads(Ids.binderPage),
        isFalse,
        reason: 'its copy is counted',
      );
      expect(await reads(Ids.public), isTrue);
      expect(
        await reads(Ids.binderPriv),
        isFalse,
        reason: 'still Privileged, not served without a code',
      );
      expect(
        lib.page(Ids.privBinderPage),
        isNull,
        reason: 'its pages are not served when its binder file can\'t be read',
      );
    });

    test('N-a. an unreadable binder file counts its folder\'s copies, serves none of its pages, and hides nothing else', () async {
      final taxesFile = '${root.path}/Taxes/$binderFileName';
      copyTo('${root.path}/Taxes', Ids.binderPage, from: '${root.path}/Trips');
      if (!await makeUnreadable(taxesFile)) return;
      final lib = await load();
      expect(lib.ambiguous, {Ids.binderPage});
      expect(lib.allAmbiguous, isFalse);
      expect(lib.page(Ids.privBinderPage), isNull);
      expect(await reads(Ids.public), isTrue);
    });
  });

  // ---- file names, header scan, normalised paths -----------------------------------

  group('the rules for a file the server can not use', () {
    test('nameIds follows core\'s conflictCopyOriginalNames', () {
      for (final name in [
        '${Ids.public}.canvas',
        '${Ids.public}-DESKTOP-4QK2N8L.canvas',
        '${Ids.public}-DESKTOP-4QK2N8L-1.canvas',
        '${Ids.public}-NOTED-MCP-9c1d07ab.canvas',
        '${Ids.public}-conflict-9c1d07ab.canvas',
        'notes.canvas',
        'my-notes-2.canvas',
        '-.canvas',
      ]) {
        final stems = {
          name.substring(0, name.length - '.canvas'.length),
          for (final c in conflictCopyOriginalNames(name))
            c.substring(0, c.length - '.canvas'.length),
        };
        final expected = {
          for (final s in stems)
            if (RegExp(r'^[0-9a-f]{16}$').hasMatch(s)) s,
        };
        expect(nameIds('/x/$name'), expected, reason: name);
        expect(nameIds(r'C:\x\' + name), expected, reason: name);
      }
      expect(nameIds('/x/${Ids.public}.txt'), isEmpty);
    });

    test('scanHeaderId reads only the header\'s pageId, on real page text', () {
      // The real layout: nodes, edges, then the header last, with the page id
      // under `pageId`; a box carries its own `noted` object.
      final text = writePage(
        page(
          'a0000000000000a1',
          'Title',
          nodes: [box('b1', 'noted.note', simpleNote('x'), _small)],
        ),
      );
      expect(scanHeaderId(text), 'a0000000000000a1');
      final at =
          text.indexOf('"pageId":"a0000000000000a1"') +
          '"pageId":"a0000000000000a1"'.length;
      expect(
        scanHeaderId(text.substring(0, at)),
        'a0000000000000a1',
        reason: 'cut short right after the id',
      );
      expect(
        scanHeaderId(text.substring(0, at - 5)),
        isNull,
        reason: 'cut inside the id',
      );
      expect(
        scanHeaderId(text.substring(0, text.indexOf('"pageId"'))),
        isNull,
        reason: 'the id was not reached',
      );
      expect(scanHeaderId('﻿$text'), 'a0000000000000a1');
      expect(
        scanHeaderId(text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n')),
        'a0000000000000a1',
      );
      // Not another object's field.
      expect(
        scanHeaderId('{"pageId":"top","nodes":[]}'),
        isNull,
        reason: 'a top-level pageId is not the header\'s',
      );
      expect(
        scanHeaderId('{"nodes":[{"noted":{"pageId":"inner"}}]}'),
        isNull,
        reason: 'a box header is not the page header',
      );
      expect(
        scanHeaderId('{"noted":{"id":"p2"}}'),
        isNull,
        reason: 'the field is pageId, not id',
      );
      expect(
        scanHeaderId(
          '{"noted":{"title":"say \\"pageId\\":\\"fake\\" ok","pageId":"p5"}}',
        ),
        'p5',
      );
      expect(scanHeaderId(''), isNull);
      expect(scanHeaderId('not json at all'), isNull);
    });

    test('R2-1. a file that parses counts only for its parsed id, whatever its name says', () async {
      // The file named for the Open page holds another page (the child).
      final other = mk('Other');
      File(pagePath(Ids.publicChild))
          .copySync('${other.path}/${Ids.public}.canvas');
      setLists(standalone: [other.path]);
      final lib = await load();
      expect(lib.ambiguous, {
        Ids.publicChild,
      }, reason: 'the page id it holds, not the id in its name');
      expect(await reads(Ids.public), isTrue);
      expect(await reads(Ids.publicChild), isFalse);
    });

    // A link to the running-lock file among the page files: a symbolic link
    // where those are allowed, else a hard link (NTFS, through fsutil).
    bool linkToLock(String path) {
      final lock = '${data.path}/$aiRunningLockFileName';
      try {
        if (Platform.isWindows) {
          final r = Process.runSync('fsutil', [
            'hardlink',
            'create',
            path.replaceAll('/', r'\'),
            lock.replaceAll('/', r'\'),
          ]);
          if (r.exitCode != 0) throw const FileSystemException('no hard link');
        } else {
          Link(path).createSync(lock);
        }
        return true;
      } on Object {
        markTestSkipped('this platform cannot link to the lock file');
        return false;
      }
    }

    test(
      'a link to the running-lock file among the page files counts for nothing: no id is ambiguous (Linux and macOS)',
      () async {
        if (!linkToLock('${pagesDir()}/x.canvas')) return;
        final other = mk('Other');
        if (!linkToLock('${other.path}/${Ids.public}.canvas')) return;
        setLists(standalone: [other.path]);
        final lib = await load();
        expect(lib.allAmbiguous, isFalse, reason: 'not an unreadable file');
        expect(
          lib.ambiguous,
          isEmpty,
          reason: 'not a copy, even under a page id\'s name',
        );
        expect(await reads(Ids.public), isTrue);
      },
      skip: Platform.isWindows
          ? 'Windows reads no lock identity: its locks belong to a handle'
          : false,
    );

    test(
      'isLockFile tells the lock file and a link to it from any other file',
      () async {
        final lock = '${data.path}/$aiRunningLockFileName';
        final id = await LockIdentity.forLockFile(lock);
        expect(await id.isLockFile(lock), isTrue);
        if (!linkToLock('${pagesDir()}/x.canvas')) return;
        expect(await id.isLockFile('${pagesDir()}/x.canvas'), isTrue);
        expect(await id.readBytes('${pagesDir()}/x.canvas'), isNull);
        expect(await id.isLockFile(pagePath(Ids.public)), isFalse);
        expect(
          await id.isLockFile('${pagesDir()}/missing.canvas'),
          isFalse,
          reason: 'can\'t be told: false, so it stays fail closed',
        );
        expect(await LockIdentity.none.isLockFile(lock), isFalse);
      },
    );

    test('N4. the same folder listed under two spellings is counted once and serves its pages', () async {
      setLists(
        standalone: [
          '${data.path}/pages/',
          '${data.path}/pages/../pages',
          '${data.path}/./pages',
        ],
        binders: ['${root.path}/Trips/', '${root.path}/Trips/../Trips'],
      );
      final lib = await load();
      expect(lib.ambiguous, isEmpty);
      expect(lib.allAmbiguous, isFalse);
      expect(lib.folders.length, 5, reason: 'pages, plus 4 binders');
      expect(await reads(Ids.public), isTrue);
      expect(await reads(Ids.binderPage), isTrue);
    });

    test('build note R2-2. a folder listed as standalone and as a binder is counted once and served with the stricter access', () async {
      // Trips is an Open binder: its page without an access of its own is Open there, Guarded as a standalone page.
      setLists(standalone: ['${root.path}/Trips']);
      // And a page that says Open in a Privileged binder: Open standalone, Privileged in the binder.
      const loose = 'd100000000000002';
      save('${root.path}/Taxes', page(loose, 'Open in Taxes', ai: 'open'));
      setLists(standalone: ['${root.path}/Taxes']);
      final lib = await load();
      expect(lib.ambiguous, isEmpty, reason: 'each file once');
      expect(
        lib.page(Ids.binderPage)!.access,
        AiAccess.guarded,
        reason: 'standalone default is stricter than the Open binder',
      );
      expect(
        lib.pages
            .where((p) => p.id == Ids.binderPage)
            .every((p) => p.access == AiAccess.guarded),
        isTrue,
      );
      expect(
        lib.pages.where((p) => p.id == loose).map((p) => p.access),
        everyElement(AiAccess.privileged),
      );
      expect(lib.pages.where((p) => p.id == loose), hasLength(2));
      expect(await reads(Ids.binderPage), isFalse);
      expect(await reads(loose), isFalse);
      expect(
        listedIds((await toolbox().listPages()).text),
        isNot(contains(Ids.binderPage)),
      );
      // A binder code reaches the Privileged page; nothing is more open than before.
      final taxes = Binder.parse(
        File('${root.path}/Taxes/$binderFileName').readAsStringSync(),
      );
      writeStore(data, [codeOf(idBinderCode, AiCodeTarget.binder(taxes.id))]);
      expect(await reads(loose, code: token(idBinderCode)), isTrue);
    });
  });

  // ---- under the hold -------------------------------------------------------------

  group('a copy that arrives under the hold', () {
    // A page with an AI box in the Trips binder; the box allows closed writes.
    const id = 'f000000000000030';
    late String path;

    setUp(() {
      path = pagePath(id, '${root.path}/Trips');
      save('${root.path}/Trips', aiPage(id, 'aiT', ai: null));
      writeStore(data, [writerBox('aiT', id)], allowClosed('aiT'));
    });

    test(
      'N6. a copy arriving in another binder is refused, page bytes unchanged',
      () async {
        final before = File(path).readAsBytesSync();
        final out = await append(
          toolbox(
            beforeHold: (a) async {
              if (a == 0) File(path).copySync('${root.path}/Taxes/$id.canvas');
            },
          ),
          'aiT',
        );
        expect(out.isError, isTrue);
        expect(out.text, ambiguousPageText);
        expect(File(path).readAsBytesSync(), before);
      },
    );

    test('N6. a copy arriving in a standalone folder while the page is in a binder is refused, page bytes unchanged', () async {
      final before = File(path).readAsBytesSync();
      final out = await append(
        toolbox(
          beforeHold: (a) async {
            if (a == 0) File(path).copySync('${pagesDir()}/$id-LAPTOP.canvas');
          },
        ),
        'aiT',
      );
      expect(out.isError, isTrue);
      expect(out.text, ambiguousPageText);
      expect(File(path).readAsBytesSync(), before);
    });

    test('N2. a new file that can\'t be read and has no id, arriving under the hold, refuses the write', () async {
      // First: can this platform make a file unreadable at all (a probe outside every listed folder)?
      File('${root.path}/probe.txt').writeAsStringSync('x');
      if (!await makeUnreadable('${root.path}/probe.txt')) return;
      final before = File(path).readAsBytesSync();
      final out = await append(
        toolbox(
          beforeHold: (a) async {
            if (a != 0) return;
            final f = '${root.path}/Taxes/mystery.canvas';
            File(f).writeAsStringSync('{}');
            await makeUnreadable(f);
          },
        ),
        'aiT',
      );
      expect(out.isError, isTrue);
      expect(File(path).readAsBytesSync(), before);
    });

    test(
      'N2. an unrelated new file under the hold does not refuse the write',
      () async {
        final out = await append(
          toolbox(
            beforeHold: (a) async {
              if (a == 0) {
                File('${root.path}/Taxes/${Ids.privBinderPage}-COPY.canvas')
                    .writeAsStringSync('{}');
              }
            },
          ),
          'aiT',
        );
        expect(out.isError, isFalse, reason: out.text);
        expect(File(path).readAsStringSync(), contains('new words'));
      },
    );
  });

  group('a folder listed as standalone and as a binder', () {
    test(
      'R-1. the reconciled access reaches the pages under it in another folder',
      () async {
        // P says Open, in the Privileged Taxes binder that is also listed as standalone:
        // Open as a standalone page, Privileged in the binder, so Privileged.
        const parent = 'd100000000000002';
        const child = 'd100000000000003';
        save('${root.path}/Taxes', page(parent, 'Open in Taxes', ai: 'open'));
        final other = mk('Other');
        save(
          other.path,
          page(child, 'Child elsewhere', parent: parent, ai: 'open'),
        );
        setLists(standalone: [other.path, '${root.path}/Taxes']);
        final lib = await load();
        expect(lib.ambiguous, isEmpty);
        expect(lib.page(parent)!.access, AiAccess.privileged);
        expect(
          lib.page(child)!.access,
          AiAccess.privileged,
          reason: 'never looser than its ancestor',
        );
        expect(await reads(child), isFalse);
      },
    );

    test(
      'item 5. a closed write honours the box type the binder disallows',
      () async {
        const id = 'f000000000000040';
        final trips = '${root.path}/Trips';
        save(trips, aiPage(id, 'aiT', ai: null));
        final binderFile = File('$trips/$binderFileName');
        binderFile.writeAsStringSync(
          Binder.parse(binderFile.readAsStringSync())
              .withBoxType(aiBoxTypeId, false)
              .write(),
        );
        writeStore(data, [writerBox('aiT', id)], allowClosed('aiT'));
        final path = pagePath(id, trips);
        final before = File(path).readAsBytesSync();
        expect(
          (await append(toolbox(), 'aiT')).isError,
          isTrue,
          reason: 'only a binder: AI boxes are off',
        );
        // Listed as standalone too: the first entry has no binder, but the binder's disallow still holds.
        setLists(standalone: [trips]);
        final out = await append(toolbox(), 'aiT');
        expect(out.isError, isTrue);
        expect(File(path).readAsBytesSync(), before);
      },
    );

    test('a binder file changed under the hold (AI boxes now disallowed) refuses a write to a folder listed both ways', () async {
      const id = 'f000000000000041';
      final trips = '${root.path}/Trips';
      save(trips, aiPage(id, 'aiU', ai: null));
      setLists(standalone: [trips]);
      writeStore(data, [writerBox('aiU', id)], allowClosed('aiU'));
      final path = pagePath(id, trips);
      final before = File(path).readAsBytesSync();
      final binderFile = File('$trips/$binderFileName');
      final out = await append(
        toolbox(
          beforeHold: (a) async {
            if (a != 0) return;
            binderFile.writeAsStringSync(
              Binder.parse(binderFile.readAsStringSync())
                  .withBoxType(aiBoxTypeId, false)
                  .write(),
            );
          },
        ),
        'aiU',
      );
      expect(out.isError, isTrue);
      expect(File(path).readAsBytesSync(), before);
    });

    test('a page under a page of a locked binder, in another folder, is locked too', () async {
      const parent = 'e100000000000001';
      const child = 'e100000000000002';
      save('${root.path}/Vault', page(parent, 'Vault parent', ai: 'open'));
      final other = mk('Other');
      save(
        other.path,
        page(child, 'Child elsewhere', parent: parent, ai: 'open'),
      );
      setLists(standalone: ['${root.path}/Vault', other.path]);
      final lib = await load();
      expect(lib.page(child)!.locked, isTrue);
      expect(await reads(child), isFalse);
    });
  });
}
