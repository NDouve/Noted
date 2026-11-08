// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A pull-only location (OneDrive stage 3, the notebook side, rules G1 to G3 and
// G6 of `2026-11-08-01-sync-stage3`): the notebook reads a working copy that the
// pull writes, and writes nothing there itself. The files are written directly,
// under the shared folder lock, as the pull would.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

Map<String, Object?> _doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

BoxRecord _box(ModuleRegistry modules, String id, String text) {
  final codec = modules.codecs.codecFor('noted.note')!;
  return commitBox(
    createBox(codec, const Bounds(10, 10, 200, 40)).withId(id),
    codec,
    codec.decode(_doc(text), 1),
  );
}

String _textOf(BoxRecord b) {
  final out = StringBuffer();
  void walk(Object? o) {
    if (o is Map) {
      o.forEach((k, v) {
        if (k == 'insert' && v is String) {
          out.write(v);
        } else {
          walk(v);
        }
      });
    } else if (o is List) {
      o.forEach(walk);
    }
  }

  walk(b.data?.decode());
  return out.toString();
}

/// The box texts of [page], by box id.
Map<String, String> boxTexts(NotedPage page) => {
  for (final n in page.nodes)
    if (n is BoxRecord) n.id: _textOf(n),
};

String _name(String path) => path.split(RegExp(r'[\\/]')).last;

/// A digest of every file under [dir] (relative path and bytes) and every
/// folder: any write, rename, delete or new folder changes it.
String hashTree(Directory dir) {
  final entries = dir.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  final out = StringBuffer();
  for (final e in entries) {
    final rel = e.path.substring(dir.path.length).replaceAll(r'\', '/');
    if (e is File) {
      out.writeln('F $rel ${contentHash(e.readAsBytesSync())}');
    } else {
      out.writeln('D $rel');
    }
  }
  return contentHash(utf8.encode(out.toString()));
}

class _World {
  late final Directory top;
  late final Directory ro; // the read-only root
  late final Directory acct; // a standalone folder in it
  late final Directory work; // a binder in it
  late final Directory pages; // the default folder (not pull-only)
  late final Directory other; // a writable standalone folder
  late final File settings;
  late final Directory rec;
  late final String pS; // a standalone page in acct
  late final String pB; // a page of the binder
  late final String pB2; // its subpage
  final modules = buildModules();
  final List<Notebook> _opened = [];

  // A hash-named attachment of pB, a damaged one, and a kept copy of a missing one.
  static final Uint8List good = Uint8List.fromList(List.generate(300, (i) => i % 251));
  static final Uint8List bad = Uint8List.fromList(good)..[10] ^= 0xff;
  static final String goodName = '${contentHash(good)}.bin';
  static final Uint8List missingBytes = Uint8List.fromList(List.generate(200, (i) => (i * 7) % 251));
  static final String missingName = '${contentHash(missingBytes)}.bin';

  String path(Directory d, String id) => '${d.path}/$id.canvas';

  Future<void> seed() async {
    top = await Directory.systemTemp.createTemp('noted_pull_only');
    ro = await Directory('${top.path}/onedrive').create();
    acct = await Directory('${ro.path}/acct').create();
    work = await Directory('${acct.path}/Work').create();
    pages = await Directory('${top.path}/pages').create();
    other = await Directory('${top.path}/other').create();
    rec = Directory('${top.path}/rec');
    settings = File('${top.path}/app/binders.json');
    final nb = Notebook(
      PageStore(pages),
      modules,
      saveDelay: Duration.zero,
      bindersFile: settings,
      recoveryDirectory: rec,
    );
    await nb.load();
    final s = await nb.addBinder(work.path);
    await nb.addStandaloneFolder(acct.path);
    pS = await nb.createPage(folderPath: acct.path);
    pB = await nb.createPage(binderPath: s.path);
    pB2 = await nb.createPage(parentId: pB);
    for (final id in [pS, pB, pB2]) {
      await nb.open(id);
      nb.current!.insertBox(_box(modules, 'b${id.substring(0, 6)}', 'text of ${id.substring(0, 6)}'));
      await nb.flush();
    }
    await nb.savePageAsTemplate(pB, name: 'T', inBinder: true);
    await nb.flush();
    nb.dispose();
    final assets = await Directory('${work.path}/${assetsFolderName(pB)}').create();
    File('${assets.path}/$goodName').writeAsBytesSync(good);
    // A damaged file under a hash name, and a missing one with a good kept copy.
    final damaged = '${contentHash(good).replaceFirst(RegExp('^.'), 'f')}.bin';
    File('${assets.path}/$damaged').writeAsBytesSync(bad);
    File('${assets.path}/$missingName.kept-1').writeAsBytesSync(missingBytes);
  }

  String get damagedName => '${contentHash(good).replaceFirst(RegExp('^.'), 'f')}.bin';

  /// A notebook that treats [ro] as read-only (a pull-only location).
  Notebook pull({
    bool watch = false,
    Duration leaveSave = const Duration(seconds: 5),
    List<String>? roots,
    AppSettings? appSettings,
    Future<String?> Function()? pick,
  }) {
    final nb = Notebook(
      settings: appSettings,
      pickFolder: pick,
      PageStore(pages),
      modules,
      saveDelay: Duration.zero,
      bindersFile: settings,
      recoveryDirectory: rec,
      watchFiles: watch,
      folderCheckInterval: Duration.zero,
      leaveSaveLimit: leaveSave,
      readOnlyRoots: roots ?? [ro.path],
    );
    _opened.add(nb);
    return nb;
  }

  /// What the pull does: writes [text] to [path] under the folder's lock,
  /// atomically.
  Future<void> engineWrite(Notebook nb, String path, String text) => busyRetry(
    () => nb.folderLocks.run(Directory(File(path).parent.path), () async {
      final tmp = File('$path.engine.tmp');
      await tmp.writeAsString(text);
      await tmp.rename(path);
    }),
  );

  Future<void> engineDelete(Notebook nb, String path) => busyRetry(
    () => nb.folderLocks.run(Directory(File(path).parent.path), () async {
      File(path).deleteSync();
    }),
  );

  NotedPage read(String path) => readPage(File(path).readAsStringSync());

  Future<void> close() async {
    for (final nb in _opened) {
      nb.dispose();
    }
    if (top.existsSync()) await busyRetry(() => top.delete(recursive: true));
  }
}

const _message = 'This OneDrive folder is read-only on this device for now.';

Matcher get _refused =>
    throwsA(isA<NotebookException>().having((e) => e.message, 'message', _message));

void main() {
  late _World w;
  setUp(() async {
    w = _World();
    await w.seed();
  });
  tearDown(() => w.close());

  group('G1: every write path is refused', () {
    test('page and folder writes throw the read-only message and write nothing', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final before = hashTree(w.ro);
      expect(nb.isReadOnlyPage(w.pB), isTrue);
      expect(nb.isPullOnlyPage(w.pS), isTrue);
      expect(nb.readOnlyReason, _message);
      expect(nb.current!.readOnly, isTrue);

      await expectLater(nb.createPage(binderPath: w.work.path), _refused);
      await expectLater(nb.createPage(parentId: w.pB), _refused);
      await expectLater(nb.createPage(folderPath: w.acct.path), _refused);
      await expectLater(nb.rename(w.pB2, 'x'), _refused);
      await expectLater(nb.rename(w.pS, 'x'), _refused);
      await expectLater(nb.setBackground(w.pB, PageBackground.dots), _refused);
      await expectLater(nb.setBackground(w.pB2, PageBackground.dots), _refused);
      await expectLater(nb.delete(w.pB2), _refused);
      await expectLater(nb.delete(w.pS), _refused);
      await expectLater(nb.moveToLocation(w.pB2), _refused);
      await expectLater(nb.moveToLocation(w.pS, binderPath: w.work.path), _refused);
      await expectLater(nb.moveToFolder(w.pS, w.other.path), _refused);
      await expectLater(nb.move(w.pB2, parentId: null), _refused);
      await expectLater(nb.setAiAccess(w.pB, AiAccess.open), _refused);
      await expectLater(nb.setAiAccess(w.pB2, AiAccess.open), _refused);
      await expectLater(nb.setBoxType(w.pB, nb.switchableBoxTypes.first, false), _refused);
      await expectLater(nb.setAttachmentStorage(w.pB, AttachmentStorage.embedded), _refused);
      await expectLater(nb.convertAttachments(w.pB, AttachmentStorage.embedded), _refused);
      await expectLater(nb.savePageAsTemplate(w.pB, name: 'x', inBinder: true), _refused);
      // No binder file is made in a pull-only folder, and no binder in it.
      final fresh = Directory('${w.acct.path}/Fresh')..createSync();
      await expectLater(nb.addBinder(fresh.path), _refused);
      final template = (await nb.listTemplates(TemplateKind.page, binderPath: w.work.path)).items;
      expect(template, hasLength(1));
      await nb.flush();

      fresh.deleteSync();
      expect(hashTree(w.ro), before);
      expect((await nb.pendingRecovery()).entries, isEmpty);
    });

    test('the five binder and template methods refuse and write nothing', () async {
      final nb = w.pull();
      await nb.load();
      final path = w.work.path;
      final bfile = File('$path/$binderFileName');
      final bytes = bfile.readAsBytesSync();
      final before = hashTree(w.ro);
      final b0 = nb.binders.firstWhere((b) => b.path == path).binder!;

      await nb.setBinderAiAccess(path, AiAccess.open);
      expect(nb.binderAiAccess(path), b0.aiAccess, reason: 'setBinderAiAccess');
      final type = nb.switchableBoxTypes.first;
      await nb.setBinderBoxType(path, type, false);
      expect(nb.binderBoxType(path, type), b0.boxTypeChoice(type), reason: 'setBinderBoxType');
      await nb.setBinderAttachmentStorage(path, AttachmentStorage.embedded);
      expect(nb.binders.firstWhere((b) => b.path == path).binder!.attachmentStorage, b0.attachmentStorage,
          reason: 'setBinderAttachmentStorage');
      await nb.updateBinder(path, title: 'Renamed', description: 'd', owner: 'o', color: binderPalette.last);
      final b1 = nb.binders.firstWhere((b) => b.path == path).binder!;
      expect((b1.title, b1.description, b1.owner, b1.color), (b0.title, b0.description, b0.owner, b0.color),
          reason: 'updateBinder');

      final items = (await nb.listTemplates(TemplateKind.page, binderPath: path)).items;
      await expectLater(nb.deleteTemplate(items.single), _refused);
      expect(File(items.single.path).existsSync(), isTrue);

      await nb.flush();
      expect(bfile.readAsBytesSync(), bytes);
      expect(hashTree(w.ro), before);
    });

    test('a writable location is untouched by the rule: the same calls work with no read-only roots', () async {
      final nb = w.pull(roots: const []);
      await nb.load();
      await nb.setBinderAiAccess(w.work.path, AiAccess.open);
      expect(nb.binderAiAccess(w.work.path), AiAccess.open);
      await nb.rename(w.pB2, 'fine');
      expect(nb.isPullOnlyPage(w.pB2), isFalse);
    });

    test('the pull-only message is what the open of a page in a gone pull-only binder says', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pS);
      File('${w.work.path}/$binderFileName').deleteSync();
      await nb.filesChanged(['${w.work.path}/$binderFileName']);
      await expectLater(nb.open(w.pB), _refused);
    });
  });

  group('G1: callers that took locked to mean gone', () {
    test('search keeps pull-only pages, and the tree row is not greyed', () async {
      final nb = w.pull();
      await nb.load();
      final ids = {for (final p in nb.searchScope().pages) p.id};
      expect(ids, containsAll([w.pS, w.pB, w.pB2]));
    });

    test('a blocked pull-only page is looked at again by a folder check, and keeps no recovery entry', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final path = w.path(w.work, w.pB);
      // A readable file in another format than the app writes: what the page
      // shows is not its text, which once made a block keep "edits".
      final page = w.read(path);
      await w.engineWrite(nb, path, const JsonEncoder.withIndent('  ').convert(jsonDecode(writePage(page))));
      await nb.filesChanged([path]);
      await w.engineWrite(nb, path, '{ not a page');
      await nb.filesChanged([path]);
      expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'a pull-only page has no edits to keep');
      // The pull replaces it with a readable one: the folder check lets go.
      final back = page.insertNode(_box(w.modules, 'bback0000000001', 'readable again'));
      await w.engineWrite(nb, path, writePage(back));
      await nb.checkFolders();
      expect(nb.readOnlyReason, _message);
      expect(boxTexts(nb.current!.page)['bback0000000001'], 'readable again');
    });

    test('leaving a pull-only page with a busy save chain keeps no recovery entry', () async {
      final nb = w.pull(leaveSave: const Duration(milliseconds: 200));
      await nb.load();
      await nb.open(w.pB);
      final gate = Completer<void>();
      unawaited(nb.runOnChainForTest(() => gate.future));
      await nb.open(w.pB2);
      expect(nb.currentId, w.pB2);
      expect((await nb.pendingRecovery()).entries, isEmpty);
      expect(nb.trouble.isTrouble, isFalse);
      gate.complete();
      await nb.flush();
    });
  });

  group('G2: reading writes nothing', () {
    test('the hash of the working copy is unchanged by listing, discovery, open, leave and a folder check', () async {
      final before = hashTree(w.ro);
      final nb = w.pull();
      await nb.load();
      expect(hashTree(w.ro), before, reason: 'listing the folders');
      await nb.discoverBinders();
      expect(hashTree(w.ro), before, reason: 'discovery');
      await nb.open(w.pB);
      // Attachments: a damaged file is shown as damaged, a kept copy of a
      // missing one is not put back.
      final a = nb.attachments!;
      expect((await a.verify(w.damagedName, size: _World.bad.length)).state, AttachmentState.damaged);
      expect((await a.verify(_World.missingName, size: _World.missingBytes.length)).state, AttachmentState.syncing);
      expect((await a.readVerified(_World.goodName, size: _World.good.length)).state, AttachmentState.ok);
      expect(hashTree(w.ro), before, reason: 'opening a page and reading its attachments');
      await nb.open(w.pB2);
      await nb.open(w.pS);
      expect(hashTree(w.ro), before, reason: 'leaving a page');
      await nb.checkFolders();
      await nb.filesChanged(['${w.work.path}/$binderFileName', w.path(w.work, w.pB)]);
      await nb.discoverBinders();
      nb.searchScope().pages.forEach((p) => p.load());
      await nb.flush();
      expect(hashTree(w.ro), before, reason: 'a folder check');
    });

    test('a pull-only attachment folder: no set-aside, no kept copy put back, no sweep of a copy source', () async {
      final assets = Directory('${w.work.path}/${assetsFolderName(w.pB)}');
      final store = PageAttachments(
        pageFolder: w.work,
        pageId: w.pB,
        storage: () => AttachmentStorage.folder,
        cacheDirectory: Directory('${w.top.path}/cache'),
        watch: false,
        readOnly: true,
      );
      addTearDown(store.dispose);
      final before = hashTree(assets);
      expect((await store.verify(w.damagedName, size: _World.bad.length)).state, AttachmentState.damaged);
      expect((await store.readVerified(w.damagedName, size: _World.bad.length)).keptAs, isNull);
      expect((await store.verify(_World.missingName, size: _World.missingBytes.length)).state, isNot(AttachmentState.ok));
      expect(hashTree(assets), before);
      await expectLater(store.put(good2, extension: 'bin'), throwsA(isA<FileSystemException>()));
      // The same calls on a store that may write do set the damaged one aside.
      final writable = PageAttachments(
        pageFolder: w.work,
        pageId: w.pB,
        storage: () => AttachmentStorage.folder,
        cacheDirectory: Directory('${w.top.path}/cache'),
        watch: false,
      );
      addTearDown(writable.dispose);
      await writable.verify(w.damagedName, size: _World.bad.length);
      expect(hashTree(assets), isNot(before));
    });

    test('a copy of a pull-only attachments folder leaves the source as it was', () async {
      final assets = Directory('${w.work.path}/${assetsFolderName(w.pB)}');
      // A leftover unique temp name the sweep would put back.
      File('${assets.path}/${_World.goodName}.123-4.tmp').writeAsBytesSync(_World.good);
      final before = hashTree(assets);
      final to = Directory('${w.top.path}/copy');
      await copyAttachmentTree(assets, to, AttachmentCopy(), sweepSource: false);
      expect(hashTree(assets), before);
      await busyRetry(() => to.delete(recursive: true));
      await copyAttachmentTree(assets, to, AttachmentCopy());
      expect(hashTree(assets), isNot(before), reason: 'the default sweeps the source');
    });
  });

  group('G3: filesChanged on a notebook without watchers', () {
    test('a pulled change shows in the open page', () async {
      final nb = w.pull(); // watchFiles false
      await nb.load();
      await nb.open(w.pB);
      final path = w.path(w.work, w.pB);
      var told = 0;
      nb.attachments!.addListener(() => told++);
      final page = w.read(path).insertNode(_box(w.modules, 'bpulled0000001', 'pulled'));
      await w.engineWrite(nb, path, writePage(page));
      await nb.filesChanged([path, '${w.work.path}/${assetsFolderName(w.pB)}/x']);
      expect(boxTexts(nb.current!.page)['bpulled0000001'], 'pulled');
      expect(nb.current!.readOnly, isTrue);
      expect(told, greaterThan(0), reason: 'the attachments are told');
      expect(File(path).readAsStringSync(), writePage(page), reason: 'the notebook wrote nothing');
    });

    test('a new page file arrives and a removed one leaves the tree', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pS);
      final id = 'cccc000000000001';
      final page = NotedPage.create(PageMeta.create(id: id, title: 'Arrived', order: 5));
      final path = w.path(w.work, id);
      await w.engineWrite(nb, path, writePage(page));
      await nb.filesChanged([path]);
      expect(nb.binderOfPage(id), w.work.path);
      await w.engineDelete(nb, path);
      await nb.filesChanged([path]);
      expect(nb.binderOfPage(id), isNull);
      expect(nb.pageTitleOf(id), isNull);
    });

    test('a conflict copy of a page with its id is listed as a duplicate, never merged, also for the open page', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final section = nb.binders.single;
      final orig = w.path(w.work, w.pB);
      final copyPath = '${w.work.path}/${w.pB}-DESKTOP-9.canvas';
      final copy = w.read(orig).insertNode(_box(w.modules, 'bcopybox000001', 'from the copy'));
      await w.engineWrite(nb, copyPath, writePage(copy));
      await nb.filesChanged([copyPath]);
      expect(boxTexts(nb.current!.page).containsKey('bcopybox000001'), isFalse, reason: 'not merged into the open page');
      expect(section.unreadable.map((u) => (_name(u.path), u.reason)), [(_name(copyPath), 'duplicate page id ${w.pB}')]);
      expect(File(copyPath).existsSync(), isTrue);
      expect(File(copyPath).readAsStringSync(), writePage(copy));
      expect(boxTexts(w.read(orig)).containsKey('bcopybox000001'), isFalse, reason: 'the original is as it was');

      // The same for a closed page.
      final orig2 = w.path(w.work, w.pB2);
      final copy2Path = '${w.work.path}/${w.pB2}-DESKTOP-9.canvas';
      await w.engineWrite(nb, copy2Path, writePage(w.read(orig2).insertNode(_box(w.modules, 'bcopybox000002', 'x'))));
      await nb.filesChanged([copy2Path]);
      expect(section.unreadable.map((u) => _name(u.path)), containsAll([_name(copyPath), _name(copy2Path)]));
      expect(boxTexts(w.read(orig2)).containsKey('bcopybox000002'), isFalse);

      // A scan lists the same (a conflict copy is never merged by a pull-only notebook).
      final again = w.pull();
      await again.load();
      expect(
        again.binders.single.unreadable.map((u) => (_name(u.path), u.reason)).toSet(),
        section.unreadable.map((u) => (_name(u.path), u.reason)).toSet(),
      );
      expect(again.binders.single.tree.roots.map((p) => p.id), [w.pB]);
    });

    test('after the original is removed, the page moves to the surviving file', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final copyPath = '${w.work.path}/${w.pB}-DESKTOP-9.canvas';
      final copy = w.read(orig).insertNode(_box(w.modules, 'bcopybox000001', 'from the copy'));
      await w.engineWrite(nb, copyPath, writePage(copy));
      await nb.filesChanged([copyPath]);
      final orig2 = w.path(w.work, w.pB2);
      final copy2Path = '${w.work.path}/${w.pB2}-DESKTOP-9.canvas';
      await w.engineWrite(nb, copy2Path, writePage(w.read(orig2)));
      await nb.filesChanged([copy2Path]);

      await w.engineDelete(nb, orig);
      await w.engineDelete(nb, orig2);
      await nb.filesChanged([orig, orig2]);
      expect(nb.binders.single.unreadable, isEmpty);
      expect(nb.treeOfPage(w.pB)[w.pB], isNotNull);
      expect(nb.treeOfPage(w.pB2)[w.pB2], isNotNull);
      expect(nb.currentId, w.pB);
      expect(boxTexts(nb.current!.page)['bcopybox000001'], 'from the copy');
      // The page can be left and opened again from the surviving file.
      await nb.open(w.pB2);
      await nb.open(w.pB);
      expect(boxTexts(nb.current!.page)['bcopybox000001'], 'from the copy');
      // What a restart shows.
      final fresh = w.pull();
      await fresh.load();
      await fresh.open(w.pB);
      expect(boxTexts(fresh.current!.page), boxTexts(nb.current!.page));
      expect({for (final p in fresh.binders.single.tree.roots) p.id}, {for (final p in nb.binders.single.tree.roots) p.id});
      expect(fresh.binders.single.unreadable, isEmpty);
    });

    test('a file named like a copy with no original of its id is a page, handled as usual', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pS);
      // `<x>-b.canvas` where `<x>.canvas` doesn't exist.
      final a = NotedPage.create(PageMeta.create(id: 'dddd000000000001', title: 'A', order: 6));
      final pa = '${w.work.path}/dddd-b.canvas';
      await w.engineWrite(nb, pa, writePage(a));
      // And one whose `<id>.canvas` exists but holds another page.
      final b = NotedPage.create(PageMeta.create(id: 'dddd000000000002', title: 'B', order: 7));
      final pb = '${w.work.path}/${w.pB2}-b.canvas';
      await w.engineWrite(nb, pb, writePage(b));
      await nb.filesChanged([pa, pb]);
      expect(nb.binderOfPage('dddd000000000001'), w.work.path);
      expect(nb.binderOfPage('dddd000000000002'), w.work.path);
      expect(nb.binders.single.unreadable, isEmpty);
      final fresh = w.pull();
      await fresh.load();
      expect({for (final p in nb.binders.single.tree.roots) p.id}, {for (final p in fresh.binders.single.tree.roots) p.id});
    });

    test('a removed binder file takes the gone path with its pages and open page kept; it is back when the file is', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final section = nb.binders.single;
      final bfile = '${w.work.path}/$binderFileName';
      final text = File(bfile).readAsStringSync();
      await w.engineDelete(nb, bfile);
      await nb.filesChanged([bfile]);
      expect(section.missing, isTrue);
      expect(section.status, BinderStatus.unavailable);
      expect(nb.currentId, w.pB, reason: 'the open page is not closed');
      expect(nb.current!.readOnly, isTrue);
      expect(nb.treeOfPage(w.pB2)[w.pB2], isNotNull, reason: 'its pages stay listed');
      // A folder check doesn't open it again, or take it apart, while the file is missing.
      await nb.checkFolders();
      expect(nb.currentId, w.pB);
      expect(section.missing, isTrue);
      await w.engineWrite(nb, bfile, text);
      await nb.checkFolders();
      expect(nb.binders.single.missing, isFalse);
      expect(nb.binders.single.available, isTrue);
      expect(nb.currentId, w.pB);
    });
  });

  group('G6: a pull-only binder that moved', () {
    Future<Directory> rename(String from, String to) async {
      await busyRetry(() async => Directory(from).renameSync(to));
      return Directory(to);
    }

    test('its listing and its open page move to the new folder, without a removal record', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final id = nb.binders.single.binder!.id;
      final moved = await rename(w.work.path, '${w.acct.path}/Work moved');
      final newPath = moved.absolute.path;
      await nb.discoverBinders();
      expect(nb.binders.map((b) => b.path.replaceAll(r'\', '/').toLowerCase()), [moved.absolute.path.replaceAll(r'\', '/').toLowerCase()]);
      expect(nb.currentId, w.pB);
      expect(nb.current!.readOnly, isTrue);
      expect(nb.binderOfPage(w.pB), nb.binders.single.path);
      expect(nb.binderOfPage(w.pB2), nb.binders.single.path);
      expect(nb.binders.single.available, isTrue);
      final file = jsonDecode(w.settings.readAsStringSync()) as Map<String, Object?>;
      expect((file['removedBinders'] as List?) ?? const [], isEmpty);
      expect((file['binderIds']! as Map).values, [id]);
      expect(newPath, isNotEmpty);
    });

    test('an open page left at the old path is closed, with a note', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      // The binder file and one page move; the open page's file stays.
      final moved = Directory('${w.acct.path}/Work moved')..createSync();
      File('${w.work.path}/$binderFileName').renameSync('${moved.path}/$binderFileName');
      File(w.path(w.work, w.pB2)).renameSync(w.path(moved, w.pB2));
      await nb.discoverBinders();
      expect(nb.binders.single.path.endsWith('Work moved'), isTrue);
      expect(nb.currentId, isNot(w.pB));
      expect(nb.discoveryNotes.map((n) => n.reason), contains(contains('stayed in the old folder')));
    });

    test('two new places with the id, or a read that failed, re-home nothing', () async {
      final nb = w.pull();
      await nb.load();
      final oldPath = w.work.path;
      Directory('${w.acct.path}/Copy 1').createSync();
      Directory('${w.acct.path}/Copy 2').createSync();
      final text = File('$oldPath/$binderFileName').readAsStringSync();
      File('${w.acct.path}/Copy 1/$binderFileName').writeAsStringSync(text);
      File('${w.acct.path}/Copy 2/$binderFileName').writeAsStringSync(text);
      File('$oldPath/$binderFileName').deleteSync();
      await nb.discoverBinders();
      expect(nb.binders.single.path, oldPath, reason: 'two places hold the id');
      File('${w.acct.path}/Copy 2/$binderFileName').deleteSync();
      Directory('${w.acct.path}/Copy 2').deleteSync();
      // A place no earlier pass read (reads are reused while the file is unchanged).
      await rename('${w.acct.path}/Copy 1', '${w.acct.path}/Copy 3');
      nb.binderHook = (point, path) async {
        if (point == 'candidate-read') throw FileSystemException('locked', path);
      };
      await nb.discoverBinders();
      expect(nb.binders.single.path, oldPath, reason: 'a candidate could not be read');
      nb.binderHook = null;
      await nb.discoverBinders();
      expect(nb.binders.single.path.endsWith('Copy 3'), isTrue, reason: 'exactly one, every file read');
    });

    test('a binder outside any read-only root is never re-homed', () async {
      final nb = w.pull(roots: const []);
      await nb.load();
      final oldPath = w.work.path;
      await rename(oldPath, '${w.acct.path}/Work moved');
      await nb.checkFolders();
      await nb.discoverBinders();
      expect(nb.binders.single.path, oldPath, reason: 'as before: listed where it was, with a note of where it went');
      expect(nb.binderMovedTo(oldPath), isNotEmpty);
    });
  });

  group('review follow-ups', () {
    Future<Directory> rename(String from, String to) async {
      await busyRetry(() async => Directory(from).renameSync(to));
      return Directory(to);
    }

    Set<String> listed(Notebook n) => {
      for (final b in n.binders)
        for (final r in b.tree.roots) ...[r.id, ...b.tree.descendantsOf(r.id)],
    };
    Set<String> dupes(Notebook n) => {
      for (final b in n.binders)
        for (final u in b.unreadable) '${_name(u.path)} ${u.reason}',
    };

    for (final copyFirst in [false, true]) {
      test('a page listed from its copy is handed to the original, reported ${copyFirst ? 'copy first' : 'original first'}', () async {
        // Only the copy holds the page when the notebook loads.
        final orig = w.path(w.work, w.pB2);
        final copyPath = '${w.work.path}/${w.pB2}-DESKTOP-9.canvas';
        File(orig).renameSync(copyPath);
        final nb = w.pull();
        await nb.load();
        expect(nb.binderOfPage(w.pB2), w.work.path);
        final page = w.read(copyPath);
        await w.engineWrite(nb, orig, writePage(page));
        await w.engineWrite(nb, copyPath, writePage(page.insertNode(_box(w.modules, 'bchanged000001', 'changed'))));
        await nb.filesChanged(copyFirst ? [copyPath, orig] : [orig, copyPath]);
        expect(nb.binderOfPage(w.pB2), w.work.path, reason: 'the page stays listed');
        final fresh = w.pull();
        await fresh.load();
        expect(listed(nb), listed(fresh));
        expect(dupes(nb), dupes(fresh));
        expect(fresh.binderOfPage(w.pB2), w.work.path);
      });
    }

    test('a promoted open page can be opened again, and stays on moved.canvas when moved-PC.canvas arrives', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final moved = '${w.work.path}/moved.canvas';
      await w.engineWrite(nb, moved, File(orig).readAsStringSync());
      await w.engineDelete(nb, orig);
      await nb.filesChanged([orig, moved]);
      await nb.open(w.pB2);
      await nb.open(w.pB);
      expect(nb.currentId, w.pB);
      final box = _box(w.modules, 'bpc000000000001', 'from the PC');
      final pc = '${w.work.path}/moved-PC.canvas';
      await w.engineWrite(nb, pc, writePage(w.read(moved).insertNode(box)));
      await nb.filesChanged([pc]);
      expect(boxTexts(nb.current!.page).containsKey('bpc000000000001'), isFalse);
      expect(dupes(nb), {'moved-PC.canvas duplicate page id ${w.pB}'});
      await nb.open(w.pB2);
      await nb.open(w.pB);
      expect(boxTexts(nb.current!.page).containsKey('bpc000000000001'), isFalse, reason: 'reopened from moved.canvas');
    });

    test('an open page moved to a writable folder only gets a duplicate; to another pull-only folder it is opened afresh', () async {
      final nb = w.pull();
      await nb.load();
      await nb.addStandaloneFolder(w.other.path);
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final text = File(orig).readAsStringSync();
      // Into a writable folder: a duplicate; the page stays as it is.
      final away = '${w.other.path}/away.canvas';
      await w.engineWrite(nb, away, writePage(w.read(orig).insertNode(_box(w.modules, 'bwritable00001', 'w'))));
      await w.engineDelete(nb, orig);
      await nb.filesChanged([away, orig]);
      expect(nb.isPullOnlyPage(w.pB), isTrue);
      expect(boxTexts(nb.current!.page).containsKey('bwritable00001'), isFalse);
      File(away).deleteSync();
      await nb.filesChanged([away]);
      // Into another pull-only folder, with new content and attachments beside it.
      final src = Directory('${w.work.path}/${assetsFolderName(w.pB)}');
      final dst = Directory('${w.acct.path}/${assetsFolderName(w.pB)}')..createSync();
      for (final f in src.listSync().whereType<File>()) {
        f.copySync('${dst.path}/${_name(f.path)}');
      }
      final crossed = readPage(text).insertNode(_box(w.modules, 'bxfer000000001', 'crossed over'));
      final to = '${w.acct.path}/crossed.canvas';
      await w.engineWrite(nb, to, writePage(crossed));
      await nb.filesChanged([to, orig]);
      expect(nb.currentId, w.pB);
      expect(boxTexts(nb.current!.page)['bxfer000000001'], 'crossed over');
      expect(nb.isPullOnlyPage(w.pB), isTrue);
      expect(nb.attachments!.folder.path.replaceAll(r'\', '/'), dst.path.replaceAll(r'\', '/'), reason: 'attachments are read beside the new file');
      final fresh = w.pull();
      await fresh.load();
      await fresh.open(w.pB);
      expect(boxTexts(fresh.current!.page), boxTexts(nb.current!.page));
      expect(fresh.attachments!.folder.path, nb.attachments!.folder.path);
      final read = await nb.attachments!.readVerified(_World.goodName, size: _World.good.length);
      expect(read.state, AttachmentState.ok);
    });

    test('a pass that read one candidate and failed on another re-homes nothing', () async {
      final nb = w.pull();
      await nb.load();
      final oldPath = w.work.path;
      await rename(oldPath, '${w.acct.path}/Work moved');
      Directory('${w.acct.path}/Bad').createSync();
      File('${w.acct.path}/Bad/$binderFileName').writeAsStringSync('{}');
      nb.binderHook = (point, path) async {
        if (point == 'candidate-read' && path.contains('Bad')) throw FileSystemException('locked', path);
      };
      await nb.discoverBinders();
      expect(nb.binders.single.path, oldPath);
      nb.binderHook = null;
      await nb.discoverBinders();
      expect(nb.binders.single.path.endsWith('Work moved'), isTrue);
    });

    test('an aside of the binder file counts as the binder file', () async {
      final nb = w.pull();
      await nb.load();
      final oldPath = w.work.path;
      final text = File('$oldPath/$binderFileName').readAsStringSync();
      await rename(oldPath, '${w.acct.path}/Work moved');
      Directory(oldPath).createSync();
      File('$oldPath/$binderFileName.1a2b.cas-old').writeAsStringSync(text);
      await nb.checkFolders();
      expect(nb.binders.single.missing, isFalse, reason: 'a replace under way is not "gone"');
      await nb.discoverBinders();
      expect(nb.binders.single.path, oldPath);
    });

    test('a failed open of the new place puts the old listing back, and the cover follows a re-home', () async {
      final nb = w.pull();
      await nb.load();
      nb.showCover(w.work.path);
      final oldPath = w.work.path;
      await rename(oldPath, '${w.acct.path}/Work moved');
      nb.binderHook = (point, path) async {
        if (point == 'parsed') throw FileSystemException('locked', path);
      };
      await nb.discoverBinders();
      nb.binderHook = null;
      expect(nb.binders.single.path, oldPath);
      expect(nb.binderOfPage(w.pB), oldPath, reason: 'its pages are listed as before');
      expect(nb.coverPath, oldPath);
      await nb.discoverBinders();
      expect(nb.binders.single.path.endsWith('Work moved'), isTrue);
      expect(nb.coverPath, nb.binders.single.path);
      expect(nb.binderOfPage(w.pB), nb.binders.single.path);
    });

    test('the job checks again: a binder file that is back stops the re-home', () async {
      final nb = w.pull();
      await nb.load();
      final oldPath = w.work.path;
      final text = File('$oldPath/$binderFileName').readAsStringSync();
      await rename(oldPath, '${w.acct.path}/Work moved');
      final hold = Completer<void>();
      final reached = Completer<void>();
      nb.syncHook = (point, _) async {
        if (point != 'check-start') return;
        reached.complete();
        await hold.future;
      };
      final busy = nb.checkFile(w.path(w.work, w.pB));
      await reached.future;
      final d = nb.discoverBinders();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      Directory(oldPath).createSync();
      File('$oldPath/$binderFileName').writeAsStringSync(text);
      nb.syncHook = null;
      hold.complete();
      await busy;
      await d;
      expect(nb.binders.single.path, oldPath);
    });

    test('a pass cut by the folder cap re-homes nothing', () async {
      final nb = w.pull();
      await nb.load();
      await nb.discoveryIdle;
      await rename(w.work.path, '${w.acct.path}/A moved');
      Directory('${w.acct.path}/Z other').createSync();
      nb.setDiscoveryLimitsForTest(folders: 1);
      await nb.discoverBinders();
      expect(nb.binders.single.path, w.work.path);
      nb.setDiscoveryLimitsForTest(folders: 1000);
      await nb.discoverBinders();
      expect(nb.binders.single.path.endsWith('A moved'), isTrue);
    });

    test('with two roots, a place under the other root is not the same root', () async {
      final ro2 = Directory('${w.top.path}/onedrive_b')..createSync();
      final nb = w.pull(roots: [w.ro.path, ro2.path]);
      await nb.load();
      await nb.discoveryIdle;
      await nb.addStandaloneFolder(ro2.path);
      await rename(w.work.path, '${ro2.path}/Moved');
      await nb.checkFolders();
      await nb.discoverBinders();
      expect(nb.binders.single.path, w.work.path);
      expect(nb.binderMovedTo(w.work.path), isNotEmpty, reason: 'it was found there, and not taken for the same place');
    });

    test('a sibling folder that only shares the prefix is not under the root', () async {
      final nb = w.pull();
      final sibling = Directory('${w.top.path}/onedrive2/B')..createSync(recursive: true);
      await nb.load();
      final s = await nb.addBinder(sibling.path);
      expect(nb.isPullOnlyLocation(s.path), isFalse);
      await nb.setBinderAiAccess(s.path, AiAccess.open);
      expect(nb.binderAiAccess(s.path), AiAccess.open);
    });

    test('the list position of a re-homed binder is kept', () async {
      final nb = w.pull();
      await nb.load();
      final other = Directory('${w.acct.path}/Other')..createSync();
      await BinderStore(other).create(Binder.create(title: 'Other', color: binderPalette.first));
      await nb.addBinder(other.path);
      expect(nb.binders.map((b) => _name(b.path)), ['Work', 'Other']);
      await rename(w.work.path, '${w.acct.path}/Work moved');
      await nb.discoverBinders();
      expect(nb.binders.map((b) => _name(b.path)), ['Work moved', 'Other']);
    });

    test('the note for a page left behind goes with the old folder', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final moved = Directory('${w.acct.path}/Work moved')..createSync();
      File('${w.work.path}/$binderFileName').renameSync('${moved.path}/$binderFileName');
      File(w.path(w.work, w.pB2)).renameSync(w.path(moved, w.pB2));
      await nb.discoverBinders();
      expect(nb.discoveryNotes.map((n) => n.reason), contains(contains('stayed in the old folder')));
      await busyRetry(() async => w.work.deleteSync(recursive: true));
      expect(nb.discoveryNotes.map((n) => n.reason), isNot(contains(contains('stayed in the old folder'))));
    });

    test('a folder check alone takes a binder with no binder file to "gone", keeps its pages and does not open it again', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      File('${w.work.path}/$binderFileName').deleteSync();
      await nb.checkFolders();
      expect(nb.binders.single.missing, isTrue);
      expect(nb.currentId, w.pB);
      await nb.checkFolders();
      expect(nb.binderOfPage(w.pB2), w.work.path, reason: 'its rows stay listed');
      expect(nb.currentId, w.pB);
    });

    test('a scan never makes a missing pull-only folder', () async {
      final nb = w.pull();
      await nb.load();
      await busyRetry(() async => w.work.deleteSync(recursive: true));
      await expectLater(nb.scanLocationForTest(w.work.path), throwsA(isA<FileSystemException>()));
      expect(w.work.existsSync(), isFalse);
    });

    test('a copy out of a pull-only folder (template, a copy elsewhere) does not sweep its source', () async {
      final assets = Directory('${w.work.path}/${assetsFolderName(w.pB)}');
      File('${assets.path}/${_World.goodName}.123-4.tmp').writeAsBytesSync(_World.good);
      final before = hashTree(assets);
      final out = Directory('${w.top.path}/out')..createSync();
      final nb = w.pull(pick: () async => out.path);
      await nb.load();
      await nb.open(w.pB);
      await nb.savePageAsTemplate(w.pB, name: 'App-wide');
      expect(hashTree(assets), before, reason: 'a template made from it');
      await nb.saveCopyElsewhere();
      expect(hashTree(assets), before, reason: 'a copy elsewhere');
      // And a copy into a pull-only folder is refused.
      final nb2 = w.pull(pick: () async => '${w.acct.path}/Copy');
      await nb2.load();
      await nb2.open(w.pB);
      await expectLater(nb2.saveCopyElsewhere(), _refused);
      expect(Directory('${w.acct.path}/Copy').existsSync(), isFalse);
    });

    test('a binder made in a pull-only folder is refused, by hand and by template', () async {
      final settings = AppSettings(File('${w.top.path}/app/settings.json'));
      settings.defaultBinderFolder = w.acct.path;
      final nb = w.pull(appSettings: settings);
      await nb.load();
      await expectLater(nb.createBinder(), _refused);
      final template = NotedTemplate.forBinder(
        name: 'T',
        binder: Binder.create(title: 'T', color: binderPalette.first),
        pages: const [],
      );
      await expectLater(nb.createBinderFromTemplate(template, '${w.acct.path}/NewB'), _refused);
      expect(Directory('${w.acct.path}/NewB').existsSync(), isFalse);
      expect(Directory('${w.acct.path}/New binder').existsSync(), isFalse, reason: 'no folder made for it');
    });

    test('filesChanged with no paths, or none under an assets folder, does not tell the attachments', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      var told = 0;
      nb.attachments!.addListener(() => told++);
      await nb.filesChanged(const []);
      await nb.filesChanged([w.path(w.work, w.pB)]);
      expect(told, 0);
      await nb.filesChanged(['${w.work.path}/${assetsFolderName(w.pB)}/${_World.goodName}']);
      expect(told, 1);
    });
  });

  group('left-over fixes', () {
    test('an open page removed remotely leaves no row once it is left', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      await w.engineDelete(nb, orig);
      await nb.filesChanged([orig]);
      expect(nb.currentId, w.pB, reason: 'it stays open while it is shown');
      await nb.open(w.pB2);
      expect(nb.pageTitleOf(w.pB), isNull, reason: 'the row is gone');
      expect(nb.treeOfPage(w.pB)[w.pB], isNull);
      final fresh = w.pull();
      await fresh.load();
      expect(fresh.pageTitleOf(w.pB), isNull);
    });

    test('a page that fails to open at its new place leaves another page open', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final to = '${w.acct.path}/crossed.canvas';
      await w.engineWrite(nb, to, File(orig).readAsStringSync());
      await w.engineDelete(nb, orig);
      final calls = <(String, String)>[];
      nb.onPageContent = (loc, page) => calls.add((loc, page.id));
      var thrown = false;
      nb.syncHook = (point, _) async {
        if (point == 'open-read' && !thrown) {
          thrown = true;
          throw const FileSystemException('locked');
        }
      };
      await nb.filesChanged([orig, to]);
      nb.syncHook = null;
      expect(thrown, isTrue);
      expect(nb.current, isNotNull, reason: 'a fallback page is open');
      expect(calls.map((c) => c.$2), contains(w.pB), reason: 'the move is told to the search index');
    });

    test('the page\'s own name returning while it is shown from a copy: it goes back to its own file', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final moved = '${w.work.path}/moved.canvas';
      await w.engineWrite(nb, moved, File(orig).readAsStringSync());
      await w.engineDelete(nb, orig);
      await nb.filesChanged([orig, moved]);
      final base = w.read(moved);
      await w.engineWrite(nb, orig, writePage(base.insertNode(_box(w.modules, 'bown000000000001', 'own'))));
      await nb.filesChanged([orig]);
      expect(boxTexts(nb.current!.page)['bown000000000001'], 'own');
      expect(nb.binders.single.unreadable.map((u) => _name(u.path)), ['moved.canvas']);
      await w.engineWrite(nb, orig, writePage(w.read(orig).insertNode(_box(w.modules, 'bown000000000002', 'later'))));
      await nb.filesChanged([orig]);
      expect(boxTexts(nb.current!.page)['bown000000000002'], 'later', reason: 'a later change shows too');
      await nb.open(w.pB2);
      await nb.open(w.pB);
      expect(boxTexts(nb.current!.page)['bown000000000002'], 'later');
    });

    test('a block of a pull-only page keeps nothing for recovery even when the file text differs', () async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final path = w.path(w.work, w.pB);
      nb.setKnownTextForTest(path, 'not what the page writes');
      await w.engineWrite(nb, path, '{ not a page');
      await nb.filesChanged([path]);
      await nb.refreshRecoveryIndexForTest();
      expect((await nb.pendingRecovery()).entries, isEmpty);
      expect(Directory(w.rec.path).existsSync() ? Directory(w.rec.path).listSync() : const [], isEmpty);
    });
  });

  group('ghost row guards', () {
    Future<Notebook> openRemoved(_World w, {void Function(String orig)? beforeLeave}) async {
      final nb = w.pull();
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final text = File(orig).readAsStringSync();
      await w.engineDelete(nb, orig);
      await nb.filesChanged([orig]);
      // The file is published again, unreported.
      if (beforeLeave != null) {
        File(orig).writeAsStringSync(text);
        beforeLeave(orig);
      }
      return nb;
    }

    test('a file that is back on disk keeps the row, and the page opens again', () async {
      final nb = await openRemoved(w, beforeLeave: (_) {});
      await nb.open(w.pB2);
      expect(nb.pageTitleOf(w.pB), isNotNull);
      await nb.open(w.pB);
      expect(nb.currentId, w.pB);
    });

    test('an aside of the page file counts as the file', () async {
      final nb = await openRemoved(w);
      final orig = w.path(w.work, w.pB);
      File('$orig.123-4.cas-old').writeAsStringSync('x');
      await nb.open(w.pB2);
      expect(nb.pageTitleOf(w.pB), isNotNull);
    });

    test('a duplicate in a writable folder takes the page over when the row would go', () async {
      final nb = w.pull();
      await nb.load();
      await nb.addStandaloneFolder(w.other.path);
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      final away = '${w.other.path}/away.canvas';
      await w.engineWrite(nb, away, File(orig).readAsStringSync());
      await nb.filesChanged([away]);
      await w.engineDelete(nb, orig);
      await nb.filesChanged([orig]);
      await nb.open(w.pB2);
      for (var i = 0; i < 100 && nb.pageTitleOf(w.pB) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final fresh = w.pull();
      await fresh.load();
      await fresh.addStandaloneFolder(w.other.path);
      expect(fresh.pageTitleOf(w.pB), isNotNull, reason: 'a reload lists it');
      expect(nb.pageTitleOf(w.pB), isNotNull, reason: 'so does the live notebook');
    });

    test('with no read-only roots a row stays after leaving', () async {
      final nb = w.pull(roots: const []);
      await nb.load();
      await nb.open(w.pB);
      final orig = w.path(w.work, w.pB);
      File(orig).deleteSync();
      await nb.filesChanged([orig]);
      await nb.open(w.pB2);
      expect(nb.pageTitleOf(w.pB), isNotNull);
    });
  });
}

final Uint8List good2 = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
