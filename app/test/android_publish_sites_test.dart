// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Every publish site publishes on Android (run 2026-11-25-01, task 1). Android's
// SELinux policy refuses `link` to apps, so each case runs with the Android
// branch taken, the publisher registered, `link` forced to fail with EACCES
// (and counted) and the rename done by lstat then rename. A case passes when
// the site works, and where a target is put in its way (the steal seam) it is
// not replaced. One case per row of the design's section 1.
//
// The last group is recovery's `_moveToFree`, with the publish itself made to
// throw (no publisher registered).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_lock.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart' show DavIdKind, PullEngine, RoundResult, WebDavClient, WebDavDriver;
import 'package:noted_core/src/storage/exclusive_move.dart' show debugMoveStrategy, debugNoReplaceErrno;

import '../../packages/noted_sync/test/fake_webdav.dart';
import '../../packages/noted_sync/test/helpers.dart' show FakeClock;
import 'support/android_publish.dart';
import 'support/binder_seams.dart';
import 'support/notebook_folder.dart';

NotedPage _page(String id, String title) => NotedPage.create(PageMeta.create(id: id, title: title, order: 0));

// An entry in the layout used before the single file (a `.canvas` and a `.json`
// with a hashed name), which the store converts when it lists.
void _legacy(Directory rec, NotedPage page, DateTime time) {
  rec.createSync(recursive: true);
  var h = 0xcbf29ce484222325;
  for (final u in utf8.encode('/notes|${page.id}')) {
    h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  final stem = '${page.id}-${h.toRadixString(16)}';
  File('${rec.path}/$stem.canvas').writeAsStringSync(writePage(page));
  File('${rec.path}/$stem.json').writeAsStringSync(
    jsonEncode({'format': 1, 'folder': '/Notes', 'pageId': page.id, 'time': time.toIso8601String(), 'base': null}),
  );
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_android_sites');
    resetDeviceStorage();
    useAndroidPublish();
  });

  tearDown(() async {
    resetAndroidPublish();
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    await deleteTestFolder(root);
  });

  List<String> names(Directory d) => [
    for (final e in d.listSync()) e.path.split(RegExp(r'[\\/]')).last,
  ]..sort();

  Directory sub(String name) => Directory('${root.path}${Platform.pathSeparator}$name')..createSync(recursive: true);

  group('the call order in main.dart', () {
    test('useRenamePublishOnAndroid() comes before initDeviceStorage( and RecoveryLock', () {
      final src = File('lib/main.dart')
          .readAsStringSync()
          .split(RegExp(r'\r?\n'))
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final call = src.indexOf('useRenamePublishOnAndroid()');
      final init = src.indexOf('await initDeviceStorage(');
      final lock = src.indexOf('RecoveryLock.besides(');
      expect(call, greaterThan(0), reason: 'main() registers the Android publisher');
      expect(call, lessThan(init), reason: 'before any storage is read or written');
      expect(call, lessThan(lock));
      expect(src.indexOf('WidgetsFlutterBinding.ensureInitialized()'), lessThan(call));
    });
  });

  group('the page store and the replace primitives', () {
    late Directory dir;
    late PageStore store;
    late File pageFile;

    setUp(() {
      dir = sub('pages');
      store = PageStore(dir);
      pageFile = File(store.pathFor('p1'));
    });

    test('saveNew publishes a new page, and a page that is taken stays as it is', () async {
      expect(await store.saveNew(_page('p1', 'One')), isTrue);
      expect(readPage(pageFile.readAsStringSync()).meta.title, 'One');
      expect(androidLinkCalls, 1, reason: 'link was tried once, and refused');
      expect(names(dir), ['p1.canvas']);
      // Taken: a file is created in the way after the temp is written.
      expect(
        await store.saveNew(
          _page('p2', 'Two'),
          beforePublish: () async => File(store.pathFor('p2')).writeAsStringSync('theirs'),
        ),
        isFalse,
      );
      expect(File(store.pathFor('p2')).readAsStringSync(), 'theirs');
      expect(names(dir), ['p1.canvas', 'p2.canvas']);
    });

    test('a checked replace publishes the new page and leaves nothing aside', () async {
      await store.saveNew(_page('p1', 'One'));
      final old = pageFile.readAsStringSync();
      final r = await store.saveIfUnchanged(_page('p1', 'Two'), old);
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(readPage(pageFile.readAsStringSync()).meta.title, 'Two');
      expect(names(dir), ['p1.canvas']);
    });

    test('a file that takes the name at the publish is kept, and the original is a conflict copy', () async {
      await store.saveNew(_page('p1', 'One'));
      final old = pageFile.readAsStringSync();
      final r = await store.saveIfUnchanged(
        _page('p1', 'Mine'),
        old,
        beforePublish: () => pageFile.writeAsStringSync('theirs'),
      );
      expect(r.outcome, ReplaceOutcome.supersededKept);
      expect(pageFile.readAsStringSync(), 'theirs', reason: 'never replaced');
      expect(File(r.keptPath!).readAsStringSync(), old, reason: 'the original is kept as a conflict copy');
      expect(names(dir).where((n) => n.contains('.cas-') || n.endsWith('.tmp')), isEmpty);
    });

    test('a page that changed while it was set aside is put back, not replaced', () async {
      await store.saveNew(_page('p1', 'One'));
      final old = pageFile.readAsStringSync();
      final r = await store.saveIfUnchanged(
        _page('p1', 'Mine'),
        old,
        beforeMoveAside: () => pageFile.writeAsStringSync('changed meanwhile'),
      );
      expect(r.outcome, ReplaceOutcome.changed);
      expect(pageFile.readAsStringSync(), 'changed meanwhile');
      expect(names(dir), ['p1.canvas']);
    });

    test('a delete puts back a page that changed before it, and keeps what it can not put back', () async {
      await store.saveNew(_page('p1', 'One'));
      final old = pageFile.readAsStringSync();
      // The verified original changes under its set-aside name before the drop.
      final r = await store.deleteIfUnchanged(
        'p1',
        old,
        beforeFinalCheck: (path) async => File(path).writeAsStringSync('late write'),
      );
      expect(r.outcome, DeleteOutcome.changed);
      expect(pageFile.readAsStringSync(), 'late write', reason: 'put back through a publish');
      expect(names(dir), ['p1.canvas']);
      // And with the name taken meanwhile, the set-aside file is kept beside it.
      final r2 = await store.deleteIfUnchanged(
        'p1',
        'late write',
        beforeFinalCheck: (path) async {
          File(path).writeAsStringSync('another late write');
          pageFile.writeAsStringSync('theirs');
        },
      );
      expect(r2.outcome, DeleteOutcome.changedKept);
      expect(pageFile.readAsStringSync(), 'theirs');
      expect(File(r2.keptPath!).readAsStringSync(), 'another late write');
    });

    test('the sweep puts a leftover back where its name is free, and keeps it beside a newer file', () async {
      await store.saveNew(_page('p1', 'One'));
      final text = pageFile.readAsStringSync();
      final left = File('${pageFile.path}.123-a-b$verifiedSuffix');
      pageFile.renameSync(left.path);
      expect(await sweepAsideFiles(dir), [pageFile.path]);
      expect(pageFile.readAsStringSync(), text);
      expect(names(dir), ['p1.canvas']);
      // A newer file is at the name: the leftover is kept as a conflict copy.
      pageFile.renameSync(left.path);
      pageFile.writeAsStringSync('newer');
      final kept = await sweepAsideFiles(dir);
      expect(kept, hasLength(1));
      expect(kept.single, contains('-conflict-'));
      expect(File(kept.single).readAsStringSync(), text);
      expect(pageFile.readAsStringSync(), 'newer');
    });
  });

  group('templates', () {
    test('a template is saved with a publish, a taken name is refused, and a delete works', () async {
      final store = TemplateStore(sub('templates'));
      final t = NotedTemplate.forPage(name: 'N', page: _page('p1', 'One'));
      final file = await store.save(t);
      expect(file.existsSync(), isTrue);
      expect(androidLinkCalls, greaterThan(0));
      await expectLater(store.save(t), throwsA(isA<FileSystemException>()));
      final listed = (await store.scan()).whereType<ReadableTemplate>().single;
      final r = await store.delete(file.path, listed.identity);
      expect(r.outcome, DeleteOutcome.deleted);
      expect(file.existsSync(), isFalse);
    });
  });

  group('attachments', () {
    test('a new attachment is published, not created and filled (copied: false)', () async {
      final dir = sub('att');
      final bytes = Uint8List.fromList(List.generate(40, (i) => i * 3));
      final hash = contentHash(bytes);
      var filled = false;
      attachmentAfterFillHook = (_) async => filled = true;
      addTearDown(() => attachmentAfterFillHook = null);
      expect(await writeNewAttachmentFile(File('${dir.path}/$hash.bin'), bytes, hash), isTrue);
      expect(File('${dir.path}/$hash.bin').readAsBytesSync(), bytes);
      expect(filled, isFalse, reason: 'the create-and-fill fallback was not used');
      expect(androidLinkCalls, greaterThan(0));
      expect(names(dir), ['$hash.bin']);
    });

    test('copying a file publishes it at a free name and leaves a taken name alone', () async {
      final from = sub('from');
      final to = sub('to');
      File('${from.path}/a.txt').writeAsStringSync('one');
      File('${to.path}/b.txt').writeAsStringSync('theirs');
      File('${from.path}/b.txt').writeAsStringSync('mine');
      final r = AttachmentCopy();
      await copyAttachmentFile(File('${from.path}/a.txt'), '${to.path}/a.txt', 'a.txt', r);
      expect(File('${to.path}/a.txt').readAsStringSync(), 'one');
      expect(r.verified, hasLength(1));
      await copyAttachmentFile(File('${from.path}/b.txt'), '${to.path}/b.txt', 'b.txt', r);
      expect(File('${to.path}/b.txt').readAsStringSync(), 'theirs', reason: 'never replaced');
      expect(names(to).where((n) => n.endsWith('.tmp')), isEmpty);
    });

    test('a kept copy is put back as the missing file (restoreKeptCopy)', () async {
      final dir = sub('att');
      final bytes = Uint8List.fromList(List.generate(40, (i) => i + 1));
      final hash = contentHash(bytes);
      File('${dir.path}/$hash.bin$keptMarker' '1-1').writeAsBytesSync(bytes);
      expect(await restoreKeptCopy(dir, '$hash.bin', hash, bytes.length), isTrue);
      expect(File('${dir.path}/$hash.bin').readAsBytesSync(), bytes);
      expect(names(dir), ['$hash.bin']);
      // A second kept copy is not put over the file now there.
      File('${dir.path}/$hash.bin$keptMarker' '1-2').writeAsBytesSync(bytes);
      expect(await restoreKeptCopy(dir, '$hash.bin', hash, bytes.length), isFalse);
    });

    test('the leftover sweep publishes an interrupted write back to its name', () async {
      final dir = sub('att');
      final bytes = Uint8List.fromList(List.generate(40, (i) => i + 2));
      final hash = contentHash(bytes);
      File('${dir.path}/$hash.bin.77-3.tmp').writeAsBytesSync(bytes);
      final r = AttachmentCopy();
      await sweepAttachmentLeftovers(dir, r);
      expect(File('${dir.path}/$hash.bin').readAsBytesSync(), bytes);
      expect(r.keptAside, isEmpty);
      expect(names(dir), ['$hash.bin']);
    });
  });

  group('recovery', () {
    late Directory rec;
    final t = DateTime.utc(2026, 10, 25, 10);

    setUp(() => rec = Directory('${root.path}/rec'));

    test('an entry is written and read back', () async {
      final s = RecoveryStore(rec, windows: false);
      await s.write(folder: '/Notes', page: _page('p1', 'edit'), baseText: null, time: t);
      final l = await RecoveryStore(rec, windows: false).list();
      expect(l.problems, isEmpty);
      expect(l.entries.single.page.meta.title, 'edit');
    });

    test('an entry of the old layout is converted through a publish', () async {
      _legacy(rec, _page('p1', 'old'), t);
      final l = await RecoveryStore(rec, windows: false).list();
      expect(l.problems, isEmpty);
      expect(l.entries.single.page.meta.title, 'old');
      expect(names(rec).where((n) => n.endsWith('.entry')), hasLength(1));
      expect(names(rec).where((n) => n.endsWith('.json') || n.endsWith('.canvas')), isEmpty);
      expect(androidLinkCalls, greaterThan(0));
    });
  });

  group('the notebook, on the mobile layout', () {
    late Seams seams;
    final notebooks = <Notebook>[];
    final locks = <RecoveryLock>[];

    setUp(() async {
      seams = Seams();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final docs = sub('docs');
      final cache = sub('cache');
      final support = sub('support');
      await initDeviceStorage(documents: () async => docs, cache: () async => cache, support: () async => support);
    });

    tearDown(() async {
      for (final n in notebooks) {
        if (!n.disposedForTest) {
          await n.flush();
          n.dispose();
        }
      }
      notebooks.clear();
      for (final l in locks) {
        l.releaseForTest();
      }
      locks.clear();
    });

    Notebook make() {
      final nb = Notebook(
        PageStore(defaultPagesDirectory()),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: defaultBindersFile(),
        recoveryDirectory: defaultRecoveryDirectory(defaultBindersFile()),
        binderStoreFactory: (d) => SeamStore(d, seams),
        binderRecheckDelay: const Duration(milliseconds: 100),
        asideRestoreAfter: const Duration(milliseconds: 400),
        coverRetryFirst: const Duration(milliseconds: 60),
      );
      notebooks.add(nb);
      return nb;
    }

    Directory pagesDir() => defaultPagesDirectory();

    File pageFile(String id) => File('${pagesDir().path}${Platform.pathSeparator}$id.canvas');

    test('first launch on empty storage creates its first page', () async {
      final lock = RecoveryLock.besides(defaultRecoveryDirectory(defaultBindersFile()));
      expect(lock.acquireSync(), RecoveryLockResult.acquired);
      locks.add(lock);
      final nb = buildAppNotebook(recoveryLock: lock);
      notebooks.add(nb);
      await nb.load().timeout(const Duration(seconds: 20));
      expect(nb.currentId, isNotNull);
      final files = names(pagesDir()).where((n) => n.endsWith('.canvas')).toList();
      expect(files, ['${nb.currentId}.canvas']);
      expect(names(pagesDir()).where((n) => n.endsWith('.tmp') || n.contains('.cas-')), isEmpty);
      expect(androidLinkCalls, greaterThan(0), reason: 'the page went through the Android path');
    });

    test('a save, a delete and its Undo', () async {
      final nb = make();
      await nb.load();
      final first = nb.currentId!;
      await nb.rename(first, 'Renamed');
      await nb.flush();
      expect(readPage(pageFile(first).readAsStringSync()).meta.title, 'Renamed');
      final second = await nb.createPage();
      expect(pageFile(second).existsSync(), isTrue);
      final deleted = await nb.delete(second);
      expect(pageFile(second).existsSync(), isFalse);
      await nb.undoDelete(deleted);
      expect(pageFile(second).existsSync(), isTrue, reason: 'Undo put the page back through a publish');
      expect(names(pagesDir()).where((n) => n.endsWith('.tmp') || n.contains('.cas-')), isEmpty);
    });

    test('a page a sync client put at the name meanwhile is not replaced by an Undo', () async {
      final nb = make();
      await nb.load();
      final second = await nb.createPage();
      final deleted = await nb.delete(second);
      // Another device puts a page with that id there.
      pageFile(second).writeAsStringSync(writePage(_page(second, 'Newer')));
      await nb.undoDelete(deleted).then<void>((_) {}, onError: (_) {});
      expect(readPage(pageFile(second).readAsStringSync()).meta.title, 'Newer');
    });

    test('a conflict copy is merged and removed', () async {
      final nb = make();
      await nb.load();
      final id = nb.currentId!;
      final codec = nb.modules.codecs.codecFor('noted.note')!;
      final box = commitBox(
        createBox(codec, const Bounds(10, 10, 200, 40)).withId('00000000000000a1'),
        codec,
        codec.decode({
          'document': {
            'type': 'page',
            'children': [
              {
                'type': 'paragraph',
                'data': {
                  'delta': [
                    {'insert': 'from the copy'},
                  ],
                },
              },
            ],
          },
        }, 1),
      );
      final disk = readPage(pageFile(id).readAsStringSync());
      final copy = File('${pagesDir().path}${Platform.pathSeparator}$id-DESKTOP-1.canvas')
        ..writeAsStringSync(writePage(disk.insertNode(box)));
      await nb.checkFile(copy.path);
      await nb.flush();
      expect(copy.existsSync(), isFalse, reason: 'the copy is gone once merged');
      expect(readPage(pageFile(id).readAsStringSync()).nodes.map((n) => n.id), contains('00000000000000a1'));
      expect(names(pagesDir()).where((n) => n.endsWith('.tmp') || n.contains('.cas-')), isEmpty);
    });

    test('a binder, its settings, and a put-back of its interrupted write', () async {
      final nb = make();
      await nb.load();
      final folder = sub('Work');
      final section = await nb.addBinder(folder.path);
      expect(File('${folder.path}${Platform.pathSeparator}$binderFileName').existsSync(), isTrue);
      await nb.setBinderBoxType(section.path, 'image', false);
      expect(nb.binders.single.binder!.boxTypeChoice('image'), isFalse);
      final saved = File('${folder.path}${Platform.pathSeparator}$binderFileName').readAsStringSync();
      expect(Binder.parse(saved).boxTypeChoice('image'), isFalse, reason: 'the setting is in the file');
      // An update ends with the file gone and its temp left: Put back.
      seams.beforeMoveAside = () {
        seams.beforeMoveAside = null;
        File('${folder.path}${Platform.pathSeparator}$binderFileName').deleteSync();
      };
      await nb.setBinderBoxType(section.path, 'image', true);
      await nb.checkBinderFile('${folder.path}${Platform.pathSeparator}$binderFileName');
      final row = nb.binderCopyRows(nb.binders.single).single;
      await nb.putBackBinderCopy(section.path, row.path);
      expect(File('${folder.path}${Platform.pathSeparator}$binderFileName').existsSync(), isTrue);
      expect(names(folder).where((n) => n.endsWith('.tmp') || n.contains('.cas-')), isEmpty);
    });

    test('a kept file of a page lands in its attachments folder (the landing)', () async {
      final nb = make();
      await nb.load();
      final id = nb.currentId!;
      final kept = Directory('${defaultRecoveryDirectory(defaultBindersFile()).path}${Platform.pathSeparator}${assetsFolderName(id)}')
        ..createSync(recursive: true);
      File('${kept.path}${Platform.pathSeparator}a.txt').writeAsStringSync('kept file');
      await nb.recoverNowForTest();
      final landed = File('${pagesDir().path}${Platform.pathSeparator}${assetsFolderName(id)}${Platform.pathSeparator}a.txt');
      expect(landed.readAsStringSync(), 'kept file');
      expect(androidLinkCalls, greaterThan(0));
    });
  });

  group('the pull (WebDAV, oc:fileid ids)', () {
    setUpAll(() => HttpOverrides.global = null);

    late FakeWebDav fake;
    late FakeClock clock;
    late Directory work;
    late Directory state;
    late String rootId;

    setUp(() async {
      fake = await FakeWebDav.start(ids: FakeDavIds.ocFileId);
      rootId = fake.addFolder('Noted');
      clock = FakeClock();
      work = sub('webdav/acct/Noted');
      state = sub('support/state');
    });

    tearDown(() => fake.close());

    PullEngine engine() => PullEngine(
      workingCopy: work,
      stateDir: state,
      locks: FolderLocks(),
      driver: WebDavDriver(
        client: WebDavClient(
          root: fake.urlOf('Noted'),
          user: FakeWebDav.user,
          password: fake.password,
          clock: clock,
          allowLoopbackHttp: true,
        ),
        idKind: DavIdKind.fileId,
        rootId: rootId,
      ),
      clock: clock,
    );

    String text(String id, String title) => writePage(_page(id, title));

    Future<RoundResult> round(PullEngine e) async {
      clock.advance(const Duration(seconds: 31));
      return e.runRound();
    }

    test('a new file is published to the working copy, and a re-path moves it', () async {
      final e = engine();
      fake.addFile('Noted/p1.canvas', utf8.encode(text('p1', 'One')));
      var r = await round(e);
      expect(r.error, isNull);
      expect(File('${work.path}/p1.canvas').readAsStringSync(), text('p1', 'One'));
      expect(androidLinkCalls, greaterThan(0), reason: 'the pull published through the Android path');
      // The writer renames it: the same file id, a new path (a re-path).
      fake.rename('Noted/p1.canvas', 'moved.canvas');
      r = await round(e);
      expect(r.error, isNull);
      r = await round(e);
      expect(File('${work.path}/moved.canvas').readAsStringSync(), text('p1', 'One'));
      expect(File('${work.path}/p1.canvas').existsSync(), isFalse);
      expect(names(work).where((n) => n.endsWith('.tmp') || n.contains('.cas-')), isEmpty);
    });

    test('a different local file at the name is never replaced by a pulled one', () async {
      File('${work.path}/p2.canvas').writeAsStringSync('local, different');
      final e = engine();
      fake.addFile('Noted/p2.canvas', utf8.encode(text('p2', 'Two')));
      await round(e);
      await round(e);
      expect(File('${work.path}/p2.canvas').readAsStringSync(), 'local, different');
      expect([for (final i in e.issues) '$i'].any((t) => t.contains('different file')), isTrue);
    });
  });

  // Recovery's `_moveToFree`, reached by the conversion of an old entry, with
  // the publish itself throwing (no publisher registered, `link` refused): it
  // takes the no-replace rename, and only a volume that can't rename without
  // replacing falls back to a check and a plain rename.
  group("recovery's _moveToFree after a publish that throws", () {
    late Directory rec;
    final t = DateTime.utc(2026, 10, 25, 10);

    setUp(() {
      rec = Directory('${root.path}/rec');
      useAndroidPublish(register: false);
      _legacy(rec, _page('p1', 'old'), t);
    });

    List<String> entries() => names(rec).where((n) => n.endsWith('.entry')).toList();
    List<String> legacyFiles() => names(rec).where((n) => n.endsWith('.json') || n.endsWith('.canvas')).toList();

    test('it moves to a free slot', () async {
      final l = await RecoveryStore(rec, windows: false).list();
      expect(l.problems, isEmpty);
      expect(l.entries.single.page.meta.title, 'old');
      expect(entries(), hasLength(1));
      expect(legacyFiles(), isEmpty);
      expect(androidLinkCalls, greaterThan(0), reason: 'the publish was tried and refused');
    });

    test('it gives false at a taken slot, and leaves what is there as it is', () async {
      var stolen = false;
      final s = RecoveryStore(
        rec,
        windows: false,
        hook: (point) async {
          if (point != 'tmp-written' || stolen) return;
          stolen = true;
          // A file takes the first slot after the temp is written.
          final slot = rec.listSync().whereType<File>().map((f) => f.path).where((p) => p.endsWith('.entry.1.tmp') || p.contains('.entry.')).toList();
          expect(slot, isNotEmpty);
          final target = slot.first.substring(0, slot.first.indexOf('.entry.') + '.entry'.length);
          File(target).writeAsStringSync('theirs');
        },
      );
      await s.list();
      expect(stolen, isTrue);
      final theirs = rec.listSync().whereType<File>().where((f) => f.path.endsWith('.entry') && f.readAsStringSync() == 'theirs');
      expect(theirs, hasLength(1), reason: 'the file that took the slot is untouched');
    });

    test('a busy rename rethrows the publish error and moves nothing', () async {
      debugMoveStrategy = null;
      debugNoReplaceErrno = Platform.isWindows ? 5 : 13;
      final l = await RecoveryStore(rec, windows: false).list();
      expect(entries(), isEmpty);
      expect(legacyFiles(), hasLength(2), reason: 'the old entry is kept');
      expect(l.problems, isNotEmpty);
    });

    test('a volume that cannot rename without replacing uses the check-then-rename', () async {
      debugMoveStrategy = null;
      debugNoReplaceErrno = Platform.isWindows ? 17 : 38;
      final l = await RecoveryStore(rec, windows: false).list();
      expect(l.problems, isEmpty);
      expect(entries(), hasLength(1));
      expect(legacyFiles(), isEmpty);
    });
  });
}
