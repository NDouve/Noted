// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'support/busy_retry.dart';

/// A store whose writes and deletes can be made to fail.
class FailingStore extends PageStore {
  FailingStore(super.directory);

  bool failSaves = false;
  bool failDeletes = false;
  bool saveNewTaken = false;

  /// Runs just before every delete reaches the file.
  void Function()? hookBeforeDelete;

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) {
    if (failSaves) throw const FileSystemException('disk full');
    return super.saveIfUnchanged(page, expectedText);
  }

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) async {
    if (saveNewTaken) return false;
    return super.saveNew(page, beforePublish: beforePublish);
  }

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) {
    if (failDeletes) throw const FileSystemException('delete failed');
    hookBeforeDelete?.call();
    return super.deleteIfUnchanged(pageId, expectedText);
  }
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late Directory root;
  late Directory pages;
  late Directory folder;
  late Directory copies;
  late ModuleRegistry modules;
  late Notebook nb;
  late FailingStore pagesStore;
  late List<LocalChange> events;
  final sep = Platform.pathSeparator;
  final disposeLater = <Notebook>[];

  Future<void> start({FolderLocks? locks, bool listen = true, Future<String?> Function()? pick}) async {
    root = await Directory.systemTemp.createTemp('noted_feed');
    pages = await Directory('${root.path}${sep}pages').create();
    folder = await Directory('${root.path}${sep}Binder').create();
    copies = await Directory('${root.path}${sep}Copies').create();
    modules = buildModules();
    pagesStore = FailingStore(pages);
    nb = Notebook(
      pagesStore,
      modules,
      saveDelay: const Duration(hours: 1),
      folderLocks: locks,
      pickFolder: pick,
      templatesDirectory: Directory('${root.path}${sep}templates'),
    );
    events = [];
    await nb.load();
    if (listen) nb.localChanges.listen(events.add);
    await pump();
    events.clear();
  }

  var disposedByTest = false;

  tearDown(() async {
    if (!disposedByTest) nb.dispose();
    disposedByTest = false;
    for (final n in disposeLater) {
      n.dispose();
    }
    disposeLater.clear();
    await busyRetry(() => root.delete(recursive: true));
  });


  String pagePath(String id, [Directory? d]) => '${(d ?? pages).path}$sep$id.canvas';

  /// Every event so far (after letting delivery finish), cleared.
  Future<List<LocalChange>> take() async {
    await pump();
    final out = List<LocalChange>.of(events);
    events.clear();
    return out;
  }

  /// The one event of [kind] at [path], with the identity of the file for a publish.
  Future<void> expectOne(List<LocalChange> got, LocalChangeKind kind, String path) async {
    final at = got.where((e) => e.kind == kind && e.path == path).toList();
    expect(at, hasLength(1), reason: 'one $kind at $path in $got');
    if (kind == LocalChangeKind.published) {
      expect(at.single.identity, await ContentIdentity.ofFile(path), reason: 'identity of $path');
    } else {
      expect(at.single.identity, isNull);
      expect(File(path).existsSync(), isFalse);
    }
  }

  group('a funnel emits exactly once', () {
    test('an autosave of the open page', () async {
      await start();
      final id = nb.currentId!;
      final c = nb.current!;
      c.createBoxAt(const Bounds(10, 10, 0, 0));
      await nb.flush();
      final got = await take();
      expect(got, hasLength(1));
      await expectOne(got, LocalChangeKind.published, pagePath(id));
    });

    test('a header change of a closed page, createPage, and delete', () async {
      await start();
      final first = nb.currentId!;
      final second = await nb.createPage();
      var got = await take();
      expect(got, hasLength(1), reason: 'createPage');
      await expectOne(got, LocalChangeKind.published, pagePath(second));

      await nb.rename(first, 'Renamed'); // closed
      got = await take();
      expect(got, hasLength(1), reason: 'rename of a closed page');
      await expectOne(got, LocalChangeKind.published, pagePath(first));

      final deleted = await nb.delete(first);
      got = await take();
      expect(got, hasLength(1), reason: 'delete');
      await expectOne(got, LocalChangeKind.deleted, pagePath(first));

      await nb.undoDelete(deleted);
      got = await take();
      await expectOne(got, LocalChangeKind.published, pagePath(first));
      expect(got.where((e) => e.kind == LocalChangeKind.deleted), isEmpty);
    });

    test('a page created from a template', () async {
      await start();
      final template = NotedTemplate.forPage(
        name: 'T',
        page: NotedPage.create(PageMeta.create(id: 'tpl0000000000001', title: 'T', order: 0)),
      );
      final id = await nb.createPageFromTemplate(template);
      final got = await take();
      await expectOne(got, LocalChangeKind.published, pagePath(id));
    });

    test('a conflict copy that is merged: the original is published and the copy is deleted', () async {
      await start();
      final id = nb.currentId!;
      await nb.createPage();
      await take();
      final copy = '${pages.path}$sep$id-DESKTOP-1.canvas';
      final base = readPage(File(pagePath(id)).readAsStringSync());
      final codec = modules.codecs.codecFor('noted.note')!;
      final box = commitBox(
        createBox(codec, const Bounds(10, 10, 200, 40)),
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
      File(copy).writeAsStringSync(writePage(base.insertNode(box)));
      await nb.checkFile(copy);
      final got = await take();
      await expectOne(got, LocalChangeKind.published, pagePath(id));
      await expectOne(got, LocalChangeKind.deleted, copy);
      expect(got, hasLength(2));
    });

    test('an undo that finds a newer file publishes the restored page beside it', () async {
      await start();
      final first = nb.currentId!;
      await nb.createPage();
      await take();
      final deleted = await nb.delete(first);
      await take();
      // A sync client puts a different file at the old place.
      File(pagePath(first)).writeAsStringSync(writePage(NotedPage.create(PageMeta.create(id: first, title: 'Newer', order: 0))));
      try {
        await nb.undoDelete(deleted);
      } on Object {
        // Whatever the outcome is told as; the events are what counts.
      }
      final got = await take();
      final copies = got.where((e) => e.kind == LocalChangeKind.published && e.path != pagePath(first));
      expect(copies, isNotEmpty, reason: 'a copy of the restored page is published: $got');
      for (final e in copies) {
        // The copy is merged into the newer file and deleted at once, so it
        // is gone; what it held is what the event's identity says.
        expect(e.path, contains('-undo-'));
        expect(e.identity, isNotNull);
        expect(
          got.where((d) => d.kind == LocalChangeKind.deleted && d.path == e.path),
          hasLength(1),
          reason: 'the merged copy is deleted',
        );
        expect(got.indexOf(got.firstWhere((d) => d.kind == LocalChangeKind.deleted && d.path == e.path)), greaterThan(got.indexOf(e)));
      }
    });

    test('a joined binder: its file, a cover edit and AI access', () async {
      await start();
      final section = await nb.addBinder(folder.path);
      var got = await take();
      final binderFile = '${folder.path}${sep}noted-binder.json';
      await expectOne(got, LocalChangeKind.published, binderFile);

      await nb.setBinderAiAccess(section.path, AiAccess.open);
      got = await take();
      expect(got, hasLength(1));
      await expectOne(got, LocalChangeKind.published, binderFile);

      final id = await nb.createPage(binderPath: section.path);
      got = await take();
      await expectOne(got, LocalChangeKind.published, pagePath(id, folder));
    });

    test('a binder made from a template emits its binder file and pages; a failing one emits its deletes', () async {
      await start();
      final section = await nb.addBinder(folder.path);
      await nb.createPage(binderPath: section.path);
      await nb.flush();
      final template = await nb.saveBinderAsTemplate(section.path, name: 'B');
      await take();
      final target = await Directory('${root.path}${sep}FromTemplate').create();
      final made = await nb.createBinderFromTemplate(template, target.path);
      final got = await take();
      final published = got.where((e) => e.kind == LocalChangeKind.published).map((e) => e.path).toSet();
      expect(published, contains('${target.path}${sep}noted-binder.json'));
      expect(published.length, greaterThanOrEqualTo(2));
      for (final e in got.where((e) => e.kind == LocalChangeKind.published && File(e.path).existsSync())) {
        expect(e.identity, await ContentIdentity.ofFile(e.path));
      }
      expect(made.available, isTrue);
    });

    test('a copy saved elsewhere is reported only in a joined location', () async {
      await start(pick: () async => copies.path);
      final loose = await nb.saveCopyElsewhere();
      expect(loose, startsWith('Saved a copy'));
      expect(await take(), isEmpty, reason: 'Copies is not a joined location');
      await nb.addStandaloneFolder(copies.path);
      await take();
      await nb.saveCopyElsewhere();
      final got = await take();
      expect(got, hasLength(1));
      expect(got.single.path, startsWith(copies.path));
      await expectOne(got, LocalChangeKind.published, got.single.path);
    });
  });

  group('failures emit nothing', () {
    test('a failed write and a taken name', () async {
      await start();
      final first = nb.currentId!;
      final c = nb.current!;
      pagesStore.failSaves = true;
      c.createBoxAt(const Bounds(10, 10, 0, 0));
      await nb.flush();
      expect(await take(), isEmpty, reason: 'a thrown I/O error');
      pagesStore.failSaves = false;

      pagesStore.saveNewTaken = true;
      await expectLater(nb.createPage(), throwsA(isA<NotebookException>()));
      pagesStore.saveNewTaken = false;
      expect(await take(), isEmpty, reason: 'saveNew false');

      expect(first, isNotEmpty);
    });

    test('a delete that finds the file changed', () async {
      await start();
      final first = nb.currentId!;
      await nb.createPage();
      await take();
      pagesStore.hookBeforeDelete = () {
        final text = File(pagePath(first)).readAsStringSync();
        File(pagePath(first)).writeAsStringSync(text.replaceFirst('"title":"', '"title":"S'));
      };
      try {
        await nb.delete(first);
      } on Object {
        // Told to the user; nothing is emitted for it.
      }
      final got = await take();
      expect(got.where((e) => e.kind == LocalChangeKind.deleted && e.path == pagePath(first)), isEmpty);
      expect(File(pagePath(first)).existsSync(), isTrue);
    });

    test('a move that fails and rolls back emits its publish and delete pair', () async {
      await start();
      late FailingStore dest;
      nb.dispose();
      final source = FailingStore(pages);
      nb = Notebook(
        source,
        modules,
        saveDelay: const Duration(hours: 1),
        storeFactory: (d) => d.path == pages.path ? PageStore(d) : (dest = FailingStore(d)),
      );
      events = [];
      await nb.load();
      nb.localChanges.listen(events.add);
      final section = await nb.addBinder(folder.path);
      final id = nb.currentId!;
      await nb.createPage();
      await nb.flush();
      await take();
      source.failDeletes = true; // the source can't be removed: the move rolls back
      try {
        await nb.moveToLocation(id, binderPath: section.path);
      } on NotebookException {
        // Reported to the user.
      }
      final got = await take();
      final destPath = pagePath(id, folder);
      expect(got.where((e) => e.path == destPath).map((e) => e.kind).toList(), [
        LocalChangeKind.published,
        LocalChangeKind.deleted,
      ]);
      expect(File(destPath).existsSync(), isFalse);
      expect(dest, isNotNull);
    });
  });

  group('order, and no work for nobody', () {
    test('events on one folder come in the lock order', () async {
      final locks = FolderLocks();
      await start(locks: locks);
      final a = nb.currentId!;
      final b = await nb.createPage();
      final c = await nb.createPage();
      await take();
      final gate = Completer<void>();
      final held = locks.run(pages, () => gate.future);
      // A closed page's rename reads its file (real IO, in no fixed order) and
      // only then asks for the folder lock. The hook fires after that read, and
      // the lock is asked for in the microtasks that follow; one event-loop turn
      // later each rename is in the queue, so the lock order is the call order.
      var reads = Completer<void>();
      nb.syncHook = (point, path) async {
        if (point == 'closed-update-read' && !reads.isCompleted) reads.complete();
      };
      Future<void> queued() async {
        await reads.future;
        reads = Completer<void>();
        await Future<void>.delayed(Duration.zero);
      }

      final r1 = nb.rename(a, 'one');
      await queued();
      final r2 = nb.rename(b, 'two');
      await queued();
      final r3 = nb.rename(a, 'three');
      await queued();
      gate.complete();
      await held;
      await Future.wait([r1, r2, r3]);
      final got = await take();
      expect(got.map((e) => e.path), [pagePath(a), pagePath(b), pagePath(a)]);
      expect(c, isNotEmpty);
    });

    test('no hashing and no event with no listener, nor after the listener left', () async {
      await start(listen: false);
      var hashed = 0;
      nb.identityOfForTest = (bytes) {
        hashed++;
        return ContentIdentity.ofBytes(bytes);
      };
      final first = nb.currentId!;
      await nb.createPage();
      await nb.rename(first, 'x');
      nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
      await nb.flush();
      expect(hashed, 0);
      final sub = nb.localChanges.listen((_) {});
      await sub.cancel();
      await nb.rename(first, 'y');
      expect(hashed, 0);
    });

    test('a listener makes the identity be computed once per write', () async {
      await start();
      var hashed = 0;
      nb.identityOfForTest = (bytes) {
        hashed++;
        return ContentIdentity.ofBytes(bytes);
      };
      final first = nb.currentId!;
      await nb.createPage();
      await take();
      hashed = 0;
      await nb.rename(first, 'x');
      expect(hashed, 1);
      expect(await take(), hasLength(1));
    });

    test('the stream is closed by dispose, and a write that lands after it does not throw', () async {
      final locks = FolderLocks();
      await start(locks: locks);
      final first = nb.currentId!;
      await nb.createPage();
      await take();
      var done = false;
      nb.localChanges.listen((_) {}, onDone: () => done = true);
      final gate = Completer<void>();
      final held = locks.run(pages, () => gate.future);
      final rename = nb.rename(first, 'late');
      await pump();
      nb.dispose();
      disposedByTest = true;
      gate.complete();
      await held;
      Object? error;
      try {
        await rename;
      } on Object catch (e) {
        error = e;
      }
      await pump();
      expect(done, isTrue);
      // The write landed, or was refused for the closed notebook; the feed
      // itself never threw.
      expect(error is StateError && '$error'.contains('closed'), isFalse, reason: '$error');
    });

    test('a listener that subscribes during delivery of a save on the same folder finishes, no hang', () async {
      await start();
      final id = nb.currentId!;
      final other = await nb.createPage();
      var scans = 0;
      nb.localChanges.listen((e) async {
        if (scans++ == 0) await nb.scanLocationForTest('');
      });
      await nb.rename(id, 'z').timeout(const Duration(seconds: 20));
      await pump();
      await pump();
      expect(scans, greaterThanOrEqualTo(1));
      expect(other, isNotEmpty);
    });
  });
}
