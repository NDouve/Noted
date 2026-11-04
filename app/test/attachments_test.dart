// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

/// A store that runs a hook whenever a page's text is read.
class _HookedStore extends PageStore {
  _HookedStore(super.directory);

  void Function()? onRead;

  @override
  Future<String> readText(String pageId) {
    onRead?.call();
    return super.readText(pageId);
  }
}

// The images and files of a page in the notebook: the setting, the assets
// folder and its life with the page (move, template, delete, undo,
// recovery).
void main() {
  late Directory root;
  late Directory pages;
  late Directory extra;
  late Directory rec;
  late List<Notebook> opened;
  final bytes = Uint8List.fromList(utf8.encode('a file to attach'));
  final hash = contentHash(bytes);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_attachments');
    pages = await Directory('${root.path}/pages').create();
    extra = await Directory('${root.path}/Elsewhere').create();
    rec = Directory('${root.path}/rec');
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook make({Duration saveDelay = Duration.zero, PageStore? store}) {
    final nb = Notebook(
      store ?? PageStore(pages),
      buildModules(),
      saveDelay: saveDelay,
      bindersFile: File('${root.path}/app/binders.json'),
      templatesDirectory: Directory('${root.path}/app/templates'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
      cacheDirectory: Directory('${root.path}/cache'),
    );
    opened.add(nb);
    return nb;
  }

  Directory assets(Directory folder, String id) => Directory('${folder.path}/$id.assets');
  File asset(Directory folder, String id) => File('${assets(folder, id).path}/$hash.txt');

  // Adds a file box holding [bytes] to the open page, through its store.
  Future<void> attach(Notebook nb) async {
    final store = nb.attachments!;
    final made = await const FileModule().createFromFile(IncomingFile('a.txt', bytes), store);
    final (data, size) = made!;
    const codec = FileCodec();
    nb.current!.insertBox(
      commitBox(createBox(codec, Bounds(10, 10, size.width, size.height)), codec, data),
    );
    await nb.flush();
  }

  group('the setting', () {
    test('folder by default; a page, its subpages and a binder pass it down', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final sub = await nb.createPage(parentId: a);
      expect(nb.attachmentStorageFor(a), AttachmentStorage.folder);
      await nb.setAttachmentStorage(a, AttachmentStorage.embedded);
      expect(nb.attachmentStorageFor(sub), AttachmentStorage.embedded, reason: 'inherited');
      expect(nb.ownAttachmentStorage(sub), isNull);
      await nb.setAttachmentStorage(sub, AttachmentStorage.folder);
      expect(nb.attachmentStorageFor(sub), AttachmentStorage.folder, reason: 'its own');
      await nb.setAttachmentStorage(sub, null);
      expect(nb.attachmentStorageFor(sub), AttachmentStorage.embedded);
      await nb.flush();
      // Saved in the page header.
      expect(readPage(File('${pages.path}/$a.canvas').readAsStringSync()).meta.attachmentStorage, AttachmentStorage.embedded);

      final binder = await nb.addBinder(extra.path);
      final p = await nb.createPage(binderPath: binder.path);
      expect(nb.attachmentStorageFor(p), AttachmentStorage.folder);
      await nb.setBinderAttachmentStorage(binder.path, AttachmentStorage.embedded);
      expect(nb.attachmentStorageFor(p), AttachmentStorage.embedded);
      expect(File('${extra.path}/$binderFileName').readAsStringSync(), contains('"attachments":"embedded"'));
    });

    test('an unknown value in a page file is kept when the page is saved', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await nb.flush();
      final f = File('${pages.path}/$a.canvas');
      f.writeAsStringSync(f.readAsStringSync().replaceFirst('"pageId"', '"attachments":"cloud","pageId"'));
      final nb2 = make();
      await nb2.load();
      expect(nb2.attachmentStorageFor(a), AttachmentStorage.folder, reason: 'unknown: the default');
      await nb2.rename(a, 'Renamed');
      await nb2.flush();
      expect(f.readAsStringSync(), contains('"attachments":"cloud"'));
    });
  });

  group('the open page\'s store', () {
    test('folder mode writes <page id>.assets/<hash>.<ext>; embedded writes nothing', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      final s = await nb.attachments!.put(bytes, extension: 'txt');
      expect(s.embedded, isNull);
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(nb.attachments!.exists('$hash.txt'), isTrue);
      expect(await nb.attachments!.read('$hash.txt'), bytes);

      await nb.setAttachmentStorage(a, AttachmentStorage.embedded);
      final e = await nb.attachments!.put(Uint8List.fromList([1, 2, 3]), extension: 'bin');
      expect(e.embedded, [1, 2, 3]);
      expect(assets(pages, a).listSync(), hasLength(1));
    });

    test('size guard: over 5 MB goes to the folder in embedded mode, with a notice', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await nb.setAttachmentStorage(a, AttachmentStorage.embedded);
      final notices = <String>[];
      final sub = nb.attachmentNotices.listen(notices.add);
      final big = Uint8List(embedLimitBytes + 1);
      final s = await nb.attachments!.put(big, extension: 'zip');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(s.embedded, isNull);
      expect(s.overLimit, isTrue);
      expect(File('${assets(pages, a).path}/${s.fileName}').lengthSync(), big.length);
      expect(notices, [overLimitNotice]);
    });

    test('Embed attachments and Move attachments to folder convert the boxes, as one undo step', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      final r = await nb.convertAttachments(a, AttachmentStorage.embedded);
      expect(r.changed, 1);
      await nb.flush();
      final text = File('${pages.path}/$a.canvas').readAsStringSync();
      expect(text, contains(base64Encode(bytes)));
      nb.current!.undo();
      await nb.flush();
      expect(File('${pages.path}/$a.canvas').readAsStringSync(), isNot(contains(base64Encode(bytes))));
      nb.current!.redo();
      asset(pages, a).deleteSync();
      final back = await nb.convertAttachments(a, AttachmentStorage.folder);
      expect(back.changed, 1);
      expect(asset(pages, a).readAsBytesSync(), bytes);
    });

    test('a file box of a type the page disallows is not converted', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      await nb.setBoxType(a, 'noted.file', false);
      final before = writePage(nb.current!.page);
      final r = await nb.convertAttachments(a, AttachmentStorage.embedded);
      expect(r.changed, 0);
      expect(writePage(nb.current!.page), before);
      await nb.setBoxType(a, 'noted.file', null);
      expect((await nb.convertAttachments(a, AttachmentStorage.embedded)).changed, 1);
    });
  });

  // R-1 (area-data-integrity-2): moving a box to the folder dropped its
  // embedded data although the good copy was never stored.
  group('Move attachments to folder when the copy cannot be stored', () {
    AttachmentRef refOf(Notebook nb) {
      final c = nb.current!;
      final b = c.page.nodes.whereType<BoxRecord>().single;
      return ((c.modules.codecs.resolve(b) as LiveBox).data as FileData).ref;
    }

    // An embedded file box whose file is, in the folder, only a prefix of
    // its bytes (a sync client mid-write).
    Future<(Notebook, String)> embeddedWithPrefix() async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      expect((await nb.convertAttachments(a, AttachmentStorage.embedded)).changed, 1);
      await nb.flush();
      asset(pages, a).writeAsBytesSync(bytes.sublist(0, 3));
      return (nb, a);
    }

    void rejectNew({required bool recoveryToo}) {
      attachmentBeforeCreateHook = (path) {
        final inRec = path.replaceAll('\\', '/').contains('/rec/');
        if (path.contains('.assets') && (recoveryToo || !inRec)) throw const FileSystemException('injected');
      };
      addTearDown(() => attachmentBeforeCreateHook = null);
    }

    bool recHoldsAssets() => rec.existsSync() && rec.listSync(recursive: true).any((e) => e is File);

    for (final recoveryToo in [true, false]) {
      test('an incomplete file at the name, recovery ${recoveryToo ? 'read-only' : 'writable'}: the box stays embedded, also after a restart', () async {
        final (nb, a) = await embeddedWithPrefix();
        rejectNew(recoveryToo: recoveryToo);
        final r = await nb.convertAttachments(a, AttachmentStorage.folder);
        expect(r.changed, 0);
        expect(r.failed, 1);
        expect(refOf(nb).bytes, bytes);
        await nb.flush();
        expect(recHoldsAssets(), isFalse, reason: 'nothing hash-named waits in recovery');
        expect(asset(pages, a).lengthSync(), 3, reason: 'the incomplete file is left alone');

        final fresh = make();
        await fresh.load();
        await fresh.open(a);
        expect(refOf(fresh).bytes, bytes);
      });
    }

    test('the folder rejects new files and nothing is at the name: the box stays embedded and nothing waits in recovery', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      expect((await nb.convertAttachments(a, AttachmentStorage.embedded)).changed, 1);
      asset(pages, a).deleteSync();
      rejectNew(recoveryToo: false);
      final r = await nb.convertAttachments(a, AttachmentStorage.folder);
      expect(r.changed, 0);
      expect(r.failed, 1);
      expect(refOf(nb).bytes, bytes);
      expect(recHoldsAssets(), isFalse);
      expect(rec.existsSync() && rec.listSync().isNotEmpty, isFalse, reason: 'no kept assets folder waits to land');
    });
  });

  group('the assets folder follows its page', () {
    test('delete removes it; undo brings it back', () async {
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      expect(asset(pages, a).existsSync(), isTrue);
      final deleted = await nb.delete(a);
      expect(assets(pages, a).existsSync(), isFalse);
      await nb.undoDelete(deleted);
      expect(asset(pages, a).readAsBytesSync(), bytes);
    });

    test('a delete that can no longer be undone removes the set-aside copy', () async {
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final deleted = await nb.delete(a);
      final trash = Directory('${root.path}/app/deleted-attachments');
      expect(trash.listSync(), isNotEmpty);
      nb.discardDeleted(deleted);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(trash.listSync(), isEmpty);
    });

    test('moving to another storage folder moves it too', () async {
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final binder = await nb.addBinder(extra.path);
      await nb.moveToLocation(a, binderPath: binder.path);
      expect(assets(pages, a).existsSync(), isFalse);
      expect(asset(extra, a).readAsBytesSync(), bytes);
    });

    // A page with its file box (a hash-named attachment) and a note.txt of its own.
    Future<(Notebook, String, BinderSection)> pageWithNotes({PageStore? store}) async {
      final nb = make(store: store);
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      File('${assets(pages, a).path}/notes.txt').writeAsStringSync('mine');
      final binder = await nb.addBinder(extra.path);
      return (nb, a, binder);
    }

    test('a different file already at the destination is kept, the original stays, and it is reported', () async {
      final (nb, a, binder) = await pageWithNotes();
      final clash = File('${assets(extra, a).path}/notes.txt')..createSync(recursive: true);
      clash.writeAsBytesSync([1, 2, 3]);

      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('The page was moved'), contains('"notes.txt"'), contains('the original stays'), contains('Elsewhere')),
              )
              .having((e) => e.needsAction, 'needsAction', isTrue),
        ),
      );
      expect(clash.readAsBytesSync(), [1, 2, 3], reason: 'the existing file is not trusted or replaced');
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine', reason: 'the original is not deleted');
      expect(asset(extra, a).readAsBytesSync(), bytes, reason: 'the file that did copy moved');
      expect(asset(pages, a).existsSync(), isFalse);
      expect(File('${extra.path}/$a.canvas').existsSync(), isTrue, reason: 'the page itself moved');
      expect(extra.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a hash-named destination file that fails its hash is a partial copy and is replaced', () async {
      final (nb, a, binder) = await pageWithNotes();
      asset(extra, a)
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      File('${assets(extra, a).path}/notes.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(asset(extra, a).readAsBytesSync(), bytes);
      expect(assets(pages, a).existsSync(), isFalse);
    });

    test('a folder or other non-file at the destination is never trusted', () async {
      final (nb, a, binder) = await pageWithNotes();
      Directory('${assets(extra, a).path}/notes.txt').createSync(recursive: true);
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('"notes.txt"'))),
      );
      expect(Directory('${assets(extra, a).path}/notes.txt').existsSync(), isTrue);
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine');
    });

    test('a volume without hard links: the target is created exclusively and filled', () async {
      attachmentPublishHook = (tmp, target) async => throw const FileSystemException('no hard links');
      addTearDown(() => attachmentPublishHook = null);
      final (nb, a, binder) = await pageWithNotes();
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(asset(extra, a).readAsBytesSync(), bytes);
      expect(File('${assets(extra, a).path}/notes.txt').readAsStringSync(), 'mine');
      expect(assets(pages, a).existsSync(), isFalse);
      expect(extra.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('without hard links, a file that appears at the target meanwhile is never written over', () async {
      attachmentPublishHook = (tmp, target) async => throw const FileSystemException('no hard links');
      attachmentBeforePublishHook = (target) async {
        if (target.endsWith('notes.txt')) File(target).writeAsStringSync('arrived first');
      };
      addTearDown(() {
        attachmentPublishHook = null;
        attachmentBeforePublishHook = null;
      });
      final (nb, a, binder) = await pageWithNotes();
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('"notes.txt"'))),
      );
      expect(File('${assets(extra, a).path}/notes.txt').readAsStringSync(), 'arrived first');
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine');
      expect(extra.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('an extensionless write never clobbers an existing <hash>.tmp attachment', () async {
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      final store = nb.attachments!;
      final real = await store.put(bytes, extension: 'tmp'); // a file called report.tmp
      expect(real.fileName.endsWith('.tmp'), isTrue);
      final plain = await store.put(bytes, extension: ''); // the same bytes, no extension
      expect(plain.fileName, isNot(real.fileName));
      expect(File('${assets(pages, a).path}/${real.fileName}').readAsBytesSync(), bytes);
      expect(File('${assets(pages, a).path}/${plain.fileName}').readAsBytesSync(), bytes);
    });

    test('a source attachment that changed after it was copied is kept', () async {
      final store = _HookedStore(pages);
      final (nb, a, binder) = await pageWithNotes(store: store);
      final notes = File('${assets(pages, a).path}/notes.txt');
      store.onRead = () {
        if (File('${assets(extra, a).path}/notes.txt').existsSync() && notes.readAsStringSync() == 'mine') {
          notes.writeAsStringSync('mine, then edited');
        }
      };
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      store.onRead = null;
      expect(notes.readAsStringSync(), 'mine, then edited', reason: 'no longer what was copied');
      expect(asset(pages, a).existsSync(), isFalse, reason: 'the unchanged file is removed');
    });

    test('a source that changed just before it was set aside is put back as it is, with no aside file left', () async {
      final (nb, a, binder) = await pageWithNotes();
      attachmentBeforeRemoveHook = (src) async {
        if (src.path.endsWith('notes.txt')) src.writeAsStringSync('changed at the last moment');
      };
      addTearDown(() => attachmentBeforeRemoveHook = null);
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'changed at the last moment');
      expect(assets(pages, a).listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a file that takes the source path while it is set aside is never deleted, nothing is left over', () async {
      final (nb, a, binder) = await pageWithNotes();
      attachmentAfterAsideHook = (source) {
        if (!source.path.endsWith('notes.txt')) return;
        // A sync client puts a new file at the source path while the old one is set aside.
        source.writeAsStringSync('arrived');
      };
      addTearDown(() => attachmentAfterAsideHook = null);
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'arrived');
      expect(File('${assets(extra, a).path}/notes.txt').readAsStringSync(), 'mine');
      final left = assets(pages, a).listSync().whereType<File>().where((f) => f.path.contains('.cas-')).toList();
      expect(left, isEmpty, reason: 'the verified set-aside original is deleted, not kept');
    });

    test('a source that changes as it is set aside, with a new file at its path before it is put back: both stay and it is reported', () async {
      final (nb, a, binder) = await pageWithNotes();
      attachmentMoveAsideHook = (source) {
        if (source.path.endsWith('notes.txt')) source.writeAsStringSync('changed at the last moment');
      };
      attachmentBeforeRestoreHook = (source) {
        // The set-aside file no longer matches; a new file takes its path.
        if (source.path.endsWith('notes.txt')) source.writeAsStringSync('arrived');
      };
      addTearDown(() {
        attachmentMoveAsideHook = null;
        attachmentBeforeRestoreHook = null;
      });
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('The page was moved'), contains('leftover temporary file')),
          ),
        ),
      );
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'arrived');
      final left = assets(pages, a).listSync().whereType<File>().where((f) => f.path.contains('.cas-')).toList();
      expect(left.map((f) => f.readAsStringSync()), ['changed at the last moment'], reason: 'the changed original is kept');
    });

    test('R-1: an attachment that changed at the destination is kept when the move is rolled back', () async {
      final store = _HookedStore(pages);
      final (nb, a, binder) = await pageWithNotes(store: store);
      var fired = false;
      store.onRead = () {
        final copied = File('${assets(extra, a).path}/notes.txt');
        if (fired || !copied.existsSync()) return;
        fired = true;
        // The copy is made. A sync client changes the copied attachment, and the
        // source page changes too, so the move is rolled back.
        copied.writeAsStringSync('changed at the destination');
        final page = File('${pages.path}/$a.canvas');
        page.writeAsStringSync(page.readAsStringSync().replaceFirst('"title":"', '"title":"Synced '));
      };
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Nothing was moved'), contains('were kept')),
          ),
        ),
      );
      expect(fired, isTrue);
      expect(File('${assets(extra, a).path}/notes.txt').readAsStringSync(), 'changed at the destination');
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine');
      expect(File('${extra.path}/$a.canvas').existsSync(), isFalse, reason: 'the unchanged page copy goes');
    });

    test('leftover unique temporary files in the source: a complete one is put back, an incomplete one is kept and reported', () async {
      final (nb, a, binder) = await pageWithNotes();
      final done = Uint8List.fromList(utf8.encode('finished but never renamed'));
      final h = contentHash(done);
      File('${assets(pages, a).path}/$h.txt.1700000000000-3.tmp').writeAsBytesSync(done);
      File('${assets(pages, a).path}/$h.png.1700000000000-4.tmp').writeAsBytesSync([1, 2]);
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('a leftover temporary file')),
        ),
      );
      expect(File('${assets(extra, a).path}/$h.txt').readAsBytesSync(), done, reason: 'put back, then moved');
      expect(File('${assets(pages, a).path}/$h.png.1700000000000-4.tmp').existsSync(), isTrue);
    });

    test('a complete <hash>.<ext>.tmp (an unfinished write) in the source lands as <hash>.<ext>', () async {
      final (nb, a, binder) = await pageWithNotes();
      final other = Uint8List.fromList(utf8.encode('stopped before its rename'));
      final h = contentHash(other);
      File('${assets(pages, a).path}/$h.txt.tmp').writeAsBytesSync(other);
      File('${assets(pages, a).path}/0000.tmp').writeAsBytesSync([1]); // not a hash name: skipped
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(File('${assets(extra, a).path}/$h.txt').readAsBytesSync(), other);
      expect(File('${assets(extra, a).path}/0000.tmp').existsSync(), isFalse);
      expect(File('${assets(pages, a).path}/$h.txt.tmp').existsSync(), isFalse, reason: 'verified, so removed');
    });

    test('an attachment called report.tmp (<hash>.tmp) keeps its name through a move', () async {
      final (nb, a, binder) = await pageWithNotes();
      final report = Uint8List.fromList(utf8.encode('a real file named report.tmp'));
      final name = attachmentFileName(contentHash(report), 'tmp');
      expect(name.endsWith('.tmp'), isTrue);
      File('${assets(pages, a).path}/$name').writeAsBytesSync(report);
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(File('${assets(extra, a).path}/$name').readAsBytesSync(), report);
      expect(File('${assets(extra, a).path}/${contentHash(report)}').existsSync(), isFalse, reason: 'never renamed');
      expect(File('${assets(pages, a).path}/$name').existsSync(), isFalse);
    });

    test('a broken hash-named target is replaced only when the source holds the hash', () async {
      final (nb, a, binder) = await pageWithNotes();
      // The source file does not hold the hash in its name either.
      asset(pages, a).writeAsBytesSync([5, 5]);
      asset(extra, a)
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains(hash))),
      );
      expect(asset(extra, a).readAsBytesSync(), [1]);
      expect(asset(pages, a).readAsBytesSync(), [5, 5]);
    });

    test('a destination file with the same bytes (an earlier interrupted move) is trusted and the original goes', () async {
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final binder = await nb.addBinder(extra.path);
      asset(extra, a)
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      expect(assets(pages, a).existsSync(), isFalse);
      expect(asset(extra, a).readAsBytesSync(), bytes);
    });

    test('a file that reached the source after the copy survives the move', () async {
      final store = _HookedStore(pages);
      final nb = make(store: store);
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final binder = await nb.addBinder(extra.path);
      final arrived = File('${assets(pages, a).path}/arrived-later.txt');
      // The page's text is read again after the attachments were copied.
      store.onRead = () {
        if (asset(extra, a).existsSync() && !arrived.existsSync()) arrived.writeAsStringSync('synced in');
      };
      expect(await nb.moveToLocation(a, binderPath: binder.path), isTrue);
      store.onRead = null;
      expect(arrived.readAsStringSync(), 'synced in', reason: 'not part of what was copied, so not deleted');
      expect(File('${assets(extra, a).path}/arrived-later.txt').existsSync(), isFalse);
      expect(asset(pages, a).existsSync(), isFalse, reason: 'the copied and verified file is removed');
      expect(asset(extra, a).readAsBytesSync(), bytes);
    });

    test('a cross-drive set-aside and undo copy file by file; a different file in the way is kept with its source and reported', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      File('${assets(pages, a).path}/notes.txt').writeAsStringSync('mine');
      final deleted = await nb.delete(a);
      expect(assets(pages, a).existsSync(), isFalse);
      final trash = Directory('${root.path}/app/deleted-attachments');
      final inTrash = trash.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('notes.txt')).single;
      expect(inTrash.readAsStringSync(), 'mine');

      // Something else already sits under the same name at the original place.
      final clash = File('${assets(pages, a).path}/notes.txt')..createSync(recursive: true);
      clash.writeAsBytesSync([9, 9]);
      await expectLater(
        nb.undoDelete(deleted),
        throwsA(
          isA<NotebookException>()
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('brought back'),
                  contains('could not be restored completely'),
                  contains('a different file with the same name was already there'),
                  contains('deleted-attachments'),
                ),
              )
              .having((e) => e.needsAction, 'needsAction', isTrue),
        ),
      );
      expect(clash.readAsBytesSync(), [9, 9], reason: 'never written over');
      expect(inTrash.existsSync(), isTrue, reason: 'the only verified copy is not deleted');
      expect(nb.tree[a], isNotNull, reason: 'the page itself is back');
    });

    test('an undo that fails for a reason that is not known names no cause, but shows where the files are', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final deleted = await nb.delete(a);
      // A plain file where the assets folder has to be made.
      File('${pages.path}/$a.assets').writeAsStringSync('in the way');
      await expectLater(
        nb.undoDelete(deleted),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('could not be restored completely'),
              isNot(contains('a different file')),
              contains('deleted-attachments'),
            ),
          ),
        ),
      );
    });

    test('a cross-drive undo with nothing in the way restores the files', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final deleted = await nb.delete(a);
      await nb.undoDelete(deleted);
      expect(asset(pages, a).readAsBytesSync(), bytes);
    });

    test('templates copy it: saving one, using one, deleting one', () async {
      final nb = make();
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      final t = await nb.savePageAsTemplate(a, name: 'With file');
      final tAssets = Directory('${root.path}/app/templates/${t.id}.assets/$a');
      expect(File('${tAssets.path}/$hash.txt').existsSync(), isTrue);

      final made = await nb.createPageFromTemplate(t);
      expect(made, isNot(a));
      expect(asset(pages, made).readAsBytesSync(), bytes, reason: 'under the new page id');

      final listing = await nb.listTemplates(TemplateKind.page);
      await nb.deleteTemplate(listing.items.single);
      expect(Directory('${root.path}/app/templates/${t.id}.assets').existsSync(), isFalse);
    });

    test('a file added while the folder is away is kept for recovery and lands with the page', () async {
      final nb = make(saveDelay: const Duration(hours: 1));
      await nb.load();
      final x = await nb.createPage(folderPath: extra.path);
      await nb.flush();
      await nb.open(x);
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      final away = Directory('${root.path}/Elsewhere-away');
      await extra.rename(away.path);
      // The folder went before the notebook noticed: the file goes to the
      // recovery folder and can still be read.
      final s = await nb.attachments!.put(bytes, extension: 'txt');
      expect(File('${rec.path}/$x.assets/${s.fileName}').existsSync(), isTrue);
      expect(nb.attachments!.exists(s.fileName), isTrue);
      expect(await nb.attachments!.read(s.fileName), bytes);
      await nb.checkFolders();
      expect((await nb.pendingRecovery()).entries, hasLength(1));

      await away.rename(extra.path);
      await nb.checkFolders();
      expect(asset(extra, x).readAsBytesSync(), bytes);
      expect(Directory('${rec.path}/$x.assets').existsSync(), isFalse);
    });
  });

  test('the store is told when files arrive in the folder', () async {
    final nb = make();
    await nb.load();
    final a = nb.currentId!;
    final store = nb.attachments!;
    var told = 0;
    store.changes.addListener(() => told++);
    expect(store.exists('$hash.txt'), isFalse);
    // Another device's sync client writes the file.
    assets(pages, a).createSync();
    asset(pages, a).writeAsBytesSync(bytes);
    store.filesChanged();
    expect(told, greaterThan(0));
    expect(store.exists('$hash.txt'), isTrue);
  });

  test('PageAttachments opens an embedded file from a temporary copy with its name', () async {
    final openedFiles = <File>[];
    final store = PageAttachments(
      pageFolder: pages,
      pageId: 'p',
      storage: () => AttachmentStorage.folder,
      cacheDirectory: Directory('${root.path}/cache'),
      opener: (f) async => openedFiles.add(f),
      watch: false,
    );
    addTearDown(store.dispose);
    await store.open('Report.pdf', bytes: bytes);
    expect(openedFiles.single.path, endsWith('Report.pdf'));
    expect(openedFiles.single.readAsBytesSync(), bytes);
    await store.put(bytes, extension: 'txt');
    await store.open('a.txt', fileName: '$hash.txt');
    String norm(String p) => p.replaceAll(r'\', '/');
    expect(norm(openedFiles.last.path), norm(asset(pages, 'p').path));
  });
}
