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
import 'package:noted/src/recovery_store.dart';
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

/// A store whose page [failId] can't be written (and from then on its folder is
/// [unwritable]), so Undo of that page fails.
class _FailNewStore extends PageStore {
  _FailNewStore(super.directory, this.unwritable);

  final Directory unwritable;
  String? failId;
  bool broken = false;

  @override
  Directory get directory => broken ? unwritable : super.directory;

  @override
  Future<bool> saveNew(NotedPage page, {Future<void> Function()? beforePublish}) async {
    if (page.id == failId) {
      broken = true;
      return false;
    }
    return super.saveNew(page, beforePublish: beforePublish);
  }
}

/// A store that runs a hook once, just before the next compare-and-delete of a page.
class _DeleteHookStore extends PageStore {
  _DeleteHookStore(super.directory);

  void Function()? beforeDeleteOnce;

  @override
  Future<DeleteResult> deleteIfUnchanged(
    String pageId,
    String expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    Future<void> Function()? beforeDelete,
    void Function()? beforeRestore,
  }) {
    final f = beforeDeleteOnce;
    beforeDeleteOnce = null;
    f?.call();
    return super.deleteIfUnchanged(
      pageId,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforeDelete: beforeDelete,
      beforeRestore: beforeRestore,
    );
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

  Notebook make({Duration saveDelay = Duration.zero, PageStore? store, Future<String?> Function()? pick}) {
    final nb = Notebook(
      store ?? PageStore(pages),
      buildModules(),
      saveDelay: saveDelay,
      bindersFile: File('${root.path}/app/binders.json'),
      templatesDirectory: Directory('${root.path}/app/templates'),
      recoveryDirectory: rec,
      folderCheckInterval: Duration.zero,
      cacheDirectory: Directory('${root.path}/cache'),
      pickFolder: pick,
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

    // Old (damaged and short) bytes for a destination file, of the same length
    // as [bytes] and shorter.
    final damagedBytes = Uint8List.fromList(List.filled(bytes.length, 7));
    final shortBytes = Uint8List.fromList([1]);

    String nameOf(String path) => path.split(RegExp(r'[\\/]')).last;
    bool under(File f, String folder) => f.path.replaceAll('\\', '/').contains('/$folder/');

    List<File> damagedFiles(Directory d) => [
      for (final e in d.listSync())
        if (e is File && isDamagedCopyName(nameOf(e.path))) e,
    ];

    // Moves the page and returns the note the user is given (the move is made).
    Future<String> movedWithNote(Notebook nb, String a, BinderSection binder) async {
      try {
        await nb.moveToLocation(a, binderPath: binder.path);
      } on NotebookException catch (e) {
        expect(e.needsAction, isTrue);
        return e.message;
      }
      fail('the user should have been told');
    }

    void seedDestination(String a, List<int> old) {
      asset(extra, a)
        ..createSync(recursive: true)
        ..writeAsBytesSync(old);
    }

    test('a full-size destination file with other bytes is kept as .damaged-<hex>, the good copy takes its name, and the user is told', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      final note = await movedWithNote(nb, a, binder);
      final aside = damagedCopyName('$hash.txt', contentHash(damagedBytes));
      expect(
        note,
        allOf(
          startsWith('The page was moved'),
          contains('damaged copy of "$hash.txt"'),
          contains('"$aside"'),
          contains('the good copy was used'),
        ),
      );
      expect(asset(extra, a).readAsBytesSync(), bytes);
      final kept = damagedFiles(assets(extra, a));
      expect(kept.map((f) => nameOf(f.path)), [aside]);
      expect(kept.single.readAsBytesSync(), damagedBytes, reason: 'the old bytes are never lost');
      expect(assets(pages, a).existsSync(), isFalse, reason: 'the verified source is removed');
    });

    test('a stable shorter destination file is kept as an incomplete copy, the good copy takes its name', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, shortBytes);
      final note = await movedWithNote(nb, a, binder);
      final aside = damagedCopyName('$hash.txt', contentHash(shortBytes));
      expect(note, allOf(contains('incomplete copy of "$hash.txt"'), contains('"$aside"')));
      expect(asset(extra, a).readAsBytesSync(), bytes);
      expect(File('${assets(extra, a).path}/$aside').readAsBytesSync(), shortBytes);
      expect(assets(pages, a).existsSync(), isFalse);
    });

    for (final unreadable in [false, true]) {
      test('a destination file that is ${unreadable ? 'unreadable' : 'changing'} is left alone, the source stays and the user is told', () async {
        final (nb, a, binder) = await pageWithNotes();
        seedDestination(a, damagedBytes);
        var fired = false;
        attachmentAfterHashHook = (f) async {
          if (!f.path.endsWith('$hash.txt') || !under(f, 'Elsewhere')) return;
          fired = true;
          if (unreadable) throw const FileSystemException('locked');
          f.writeAsBytesSync([...damagedBytes, 1]); // a sync client is still writing
        };
        addTearDown(() => attachmentAfterHashHook = null);
        final note = await movedWithNote(nb, a, binder);
        expect(fired, isTrue);
        expect(note, allOf(contains('"$hash.txt"'), contains('still changing'), contains('the original stays')));
        expect(asset(extra, a).readAsBytesSync(), unreadable ? damagedBytes : [...damagedBytes, 1]);
        expect(damagedFiles(assets(extra, a)), isEmpty);
        expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'the source is not deleted');
      });
    }

    for (final same in [false, true]) {
      test('a file that arrives between the set-aside and the publish is never replaced (${same ? 'same bytes: verified' : 'other bytes: differing'})', () async {
        final (nb, a, binder) = await pageWithNotes();
        seedDestination(a, damagedBytes);
        var fired = false;
        attachmentBeforePublishHook = (target) async {
          if (!target.endsWith('$hash.txt')) return;
          fired = true;
          File(target).writeAsBytesSync(same ? bytes : [9, 9]);
        };
        addTearDown(() => attachmentBeforePublishHook = null);
        final aside = damagedCopyName('$hash.txt', contentHash(damagedBytes));
        final note = await movedWithNote(nb, a, binder);
        expect(fired, isTrue);
        expect(note, allOf(contains('"$hash.txt"'), contains('"$aside"')));
        if (same) {
          expect(asset(extra, a).readAsBytesSync(), bytes);
          expect(assets(pages, a).existsSync(), isFalse, reason: 'verified: the source goes');
        } else {
          expect(note, contains('different file'));
          expect(asset(extra, a).readAsBytesSync(), [9, 9], reason: 'what arrived is kept as it is');
          expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'the source stays');
        }
        expect(File('${assets(extra, a).path}/$aside').readAsBytesSync(), damagedBytes, reason: 'the aside is kept');
      });
    }

    test('a set-aside that is refused (the aside is replaced) overwrites nothing and ends differing after one look', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      var fired = false;
      attachmentAfterSetAsideHook = (aside) {
        fired = true;
        File(aside).writeAsBytesSync([4, 4, 4]); // not what was checked
      };
      addTearDown(() => attachmentAfterSetAsideHook = null);
      final note = await movedWithNote(nb, a, binder);
      expect(fired, isTrue);
      expect(note, allOf(contains('"$hash.txt"'), contains('different file')));
      expect(asset(extra, a).readAsBytesSync(), [4, 4, 4], reason: 'put back as it was found, never replaced');
      expect(damagedFiles(assets(extra, a)), isEmpty);
      expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'the source stays');
    });

    test('without hard links, the damaged destination file is kept aside and the good copy is filled', () async {
      var fired = false;
      attachmentPublishHook = (tmp, target) async {
        fired = true;
        throw const FileSystemException('no hard links');
      };
      addTearDown(() => attachmentPublishHook = null);
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      final note = await movedWithNote(nb, a, binder);
      expect(fired, isTrue);
      expect(note, contains('damaged copy of "$hash.txt"'));
      expect(asset(extra, a).readAsBytesSync(), bytes);
      expect(damagedFiles(assets(extra, a)).single.readAsBytesSync(), damagedBytes);
      expect(extra.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a volume that cannot set a file aside replaces nothing: both files stay and the target is differing', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      var fired = false;
      attachmentBeforeSetAsideHook = (aside) {
        fired = true;
        throw const FileSystemException('no exclusive move');
      };
      addTearDown(() => attachmentBeforeSetAsideHook = null);
      final note = await movedWithNote(nb, a, binder);
      expect(fired, isTrue);
      expect(note, allOf(contains('"$hash.txt"'), contains('different file'), contains('the original stays')));
      expect(asset(extra, a).readAsBytesSync(), damagedBytes);
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(damagedFiles(assets(extra, a)), isEmpty);
    });

    test('an identical .damaged- file already there: the target goes only by delete-if-unchanged and the good copy is published', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      final aside = File('${assets(extra, a).path}/${damagedCopyName('$hash.txt', contentHash(damagedBytes))}')
        ..writeAsBytesSync(damagedBytes);
      final note = await movedWithNote(nb, a, binder);
      expect(note, contains('damaged copy of "$hash.txt"'));
      expect(asset(extra, a).readAsBytesSync(), bytes);
      expect(damagedFiles(assets(extra, a)).map((f) => nameOf(f.path)), [nameOf(aside.path)]);
      expect(aside.readAsBytesSync(), damagedBytes);
      expect(assets(pages, a).existsSync(), isFalse);
    });

    test('a rollback after a later failure removes this move\'s good copy and keeps the aside, which the message names', () async {
      final store = _HookedStore(pages);
      final (nb, a, binder) = await pageWithNotes(store: store);
      seedDestination(a, damagedBytes);
      var fired = false;
      store.onRead = () {
        if (fired || !File('${assets(extra, a).path}/notes.txt').existsSync()) return;
        fired = true;
        final page = File('${pages.path}/$a.canvas');
        page.writeAsStringSync(page.readAsStringSync().replaceFirst('"title":"', '"title":"Synced '));
      };
      final aside = damagedCopyName('$hash.txt', contentHash(damagedBytes));
      await expectLater(
        nb.moveToLocation(a, binderPath: binder.path),
        throwsA(
          isA<NotebookException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Nothing was moved'),
              contains('damaged copy of "$hash.txt"'),
              contains('"$aside"'),
              contains("the good copy wasn't put in its place"),
              isNot(contains('the good copy was used')),
            ),
          ),
        ),
      );
      expect(fired, isTrue);
      expect(asset(extra, a).existsSync(), isFalse, reason: 'the good copy this move published is removed');
      expect(File('${assets(extra, a).path}/$aside').readAsBytesSync(), damagedBytes, reason: 'the aside stays');
      expect(asset(pages, a).readAsBytesSync(), bytes);
    });

    test('undo delete into a page folder holding a damaged file keeps it aside and posts a notice', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      final deleted = await nb.delete(a);
      assets(pages, a).createSync(recursive: true);
      asset(pages, a).writeAsBytesSync(damagedBytes);
      await nb.undoDelete(deleted);
      await Future<void>.delayed(Duration.zero);
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(damagedFiles(assets(pages, a)).single.readAsBytesSync(), damagedBytes);
      expect(notices, contains(contains('damaged copy of "$hash.txt"')));
    });

    // A page is deleted on the copy path, the folder it returns to holds a file
    // that stops the undo, and the bar expires: the trash copy has to survive.
    for (final variant in ['changing', 'unreadable', 'stray']) {
      test('9b: an undo that stops on a $variant file keeps the trash copy through expiry and a reload', () async {
        Notebook.forceCopyMoveForTest = true;
        addTearDown(() => Notebook.forceCopyMoveForTest = false);
        final nb = make();
        await nb.load();
        final a = await nb.createPage();
        await nb.open(a);
        await attach(nb);
        final notices = <String>[];
        nb.attachmentNotices.listen(notices.add);
        final deleted = await nb.delete(a);
        final trash = Directory('${root.path}/app/deleted-attachments');
        final inTrash = trash.listSync(recursive: true).whereType<File>().singleWhere((f) => f.path.endsWith('$hash.txt'));
        var fired = false;
        // What has to survive: the good copy, or (stray) the file no copy takes along.
        var keep = inTrash;
        if (variant == 'stray') {
          keep = File('${inTrash.parent.path}/junk.tmp')..writeAsStringSync('stray');
        } else {
          assets(pages, a).createSync(recursive: true);
          asset(pages, a).writeAsBytesSync(damagedBytes);
          attachmentAfterHashHook = (f) async {
            if (!f.path.endsWith('$hash.txt') || !under(f, 'pages')) return;
            fired = true;
            if (variant == 'unreadable') throw const FileSystemException('locked');
            f.writeAsBytesSync([...damagedBytes, 1]);
          };
          addTearDown(() => attachmentAfterHashHook = null);
        }
        await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
        attachmentAfterHashHook = null;
        if (variant != 'stray') expect(fired, isTrue);
        expect(keep.readAsBytesSync(), variant == 'stray' ? utf8.encode('stray') : bytes, reason: 'survives the undo');
        if (variant == 'stray') expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'the good copy went back');
        await nb.discardPendingDelete(); // the bar expires
        expect(keep.existsSync(), isTrue, reason: 'and the expiry');
        await Future<void>.delayed(Duration.zero);
        // The undo's own message tells where the files are; a changing file is also noticed.
        if (variant != 'stray') expect(notices, contains(contains('still changing')));
        await nb.flush();
        nb.dispose();
        opened.remove(nb);
        final again = make();
        await again.load();
        expect(keep.existsSync(), isTrue, reason: 'and a reload');
      });
    }

    // A store whose page [failId] can't be written back, and whose folder can't
    // take a conflict copy beside it either (so Undo of that page fails and the
    // bar is renewed).
    _FailNewStore failingStore() {
      File('${root.path}/blocker').writeAsStringSync('x'); // a folder under a file can't be made
      return _FailNewStore(pages, Directory('${root.path}/blocker/folder'));
    }

    Directory trashDir() => Directory('${root.path}/app/deleted-attachments');
    List<File> trashFiles() => trashDir().existsSync() ? trashDir().listSync(recursive: true).whereType<File>().toList() : [];

    for (final variant in ['changing', 'unreadable']) {
      test('9b: two pages deleted, a partial undo where B is blocked ($variant) and B\'s page can\'t be written: the bar really expires and B\'s kept folder keeps its bytes', () async {
        Notebook.forceCopyMoveForTest = true;
        addTearDown(() => Notebook.forceCopyMoveForTest = false);
        final store = failingStore();
        final nb = make(store: store);
        await nb.load();
        final a = await nb.createPage();
        await nb.open(a);
        await attach(nb);
        final b = await nb.createPage(parentId: a);
        await nb.open(b);
        await attach(nb);
        final deleted = await nb.delete(a);
        expect(trashFiles().where((f) => f.path.contains(b) && f.path.endsWith('$hash.txt')), hasLength(1));
        final inTrashB = trashFiles().singleWhere((f) => f.path.contains(b) && f.path.endsWith('$hash.txt'));
        // B's attachments are blocked by a file that is still being written.
        assets(pages, b).createSync(recursive: true);
        asset(pages, b).writeAsBytesSync(damagedBytes);
        var fired = false;
        attachmentAfterHashHook = (f) async {
          if (!f.path.endsWith('$hash.txt') || !f.path.contains(b) || !under(f, 'pages')) return;
          fired = true;
          if (variant == 'unreadable') throw const FileSystemException('locked');
          f.writeAsBytesSync([...damagedBytes, 1]);
        };
        addTearDown(() => attachmentAfterHashHook = null);
        store.failId = b;
        await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
        attachmentAfterHashHook = null;
        store.failId = null;
        store.broken = false;
        expect(fired, isTrue);
        expect(nb.isPendingDelete(deleted), isTrue, reason: 'the bar is renewed');
        expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'A is restored');
        expect(inTrashB.readAsBytesSync(), bytes);

        await nb.discardPendingDelete(); // an expiry does not reach a held entry
        expect(nb.isHeldDelete(deleted), isTrue);
        expect(inTrashB.readAsBytesSync(), bytes, reason: 'its set-aside is still there');
        nb.discardDeleted(deleted); // the user lets it go (the held bar's X): _removeSetAside runs
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(nb.isPendingDelete(deleted), isFalse);
        expect(inTrashB.readAsBytesSync(), bytes, reason: 'B\'s kept folder keeps its bytes');
        expect(trashFiles().where((f) => f.path.contains(a)), isEmpty, reason: 'A\'s trash folder is gone');
        await nb.flush();
        nb.dispose();
        opened.remove(nb);
        final again = make();
        await again.load();
        expect(inTrashB.readAsBytesSync(), bytes, reason: 'and a reload');
      });
    }

    test('9c: a delete whose set-aside stops part way on A (B is fine), then undo, a real expiry and a reload: A\'s kept folder stays, B\'s is removed, nothing is lost', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final store = failingStore();
      final nb = make(store: store);
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final b = await nb.createPage(parentId: a);
      await nb.open(b);
      await attach(nb);
      File('${assets(pages, a).path}/junk.tmp').writeAsStringSync('stray'); // not taken along
      var fires = 0;
      attachmentBeforePublishHook = (target) async {
        if (!target.endsWith('$hash.txt') || !under(File(target), 'deleted-attachments') || !target.contains(a)) return;
        fires++;
        File(target).writeAsBytesSync([8, 8]); // a different file arrives in A's set-aside folder
      };
      addTearDown(() => attachmentBeforePublishHook = null);
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      final deleted = await nb.delete(a);
      attachmentBeforePublishHook = null;
      // Fired on A twice: the arrival was set aside as damaged and the next one stayed (differing).
      expect(fires, 2, reason: 'the hook fired on A only');
      await Future<void>.delayed(Duration.zero);
      expect(notices, contains(contains('different file')), reason: 'the user is told');
      final inTrashA = trashFiles().singleWhere((f) => f.path.contains(a) && f.path.endsWith('$hash.txt'));
      expect(inTrashA.readAsBytesSync(), [8, 8]);
      final aTrashDir = trashDir().listSync(recursive: true).whereType<Directory>().firstWhere((d) => d.path.endsWith('$a.assets'));
      expect(damagedFiles(aTrashDir).single.readAsBytesSync(), [8, 8], reason: 'the first arrival was kept aside');
      expect(trashFiles().where((f) => f.path.contains(b) && f.path.endsWith('$hash.txt')), hasLength(1));
      expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'the source stayed in the page folder');

      store.failId = b; // so the bar is renewed
      await expectLater(nb.undoDelete(deleted), throwsA(isA<NotebookException>()));
      store.failId = null;
      store.broken = false;
      expect(nb.isPendingDelete(deleted), isTrue);
      expect(asset(pages, b).readAsBytesSync(), bytes, reason: 'B\'s attachment is back');
      await nb.discardPendingDelete(); // an expiry does not reach a held entry
      expect(nb.isHeldDelete(deleted), isTrue);
      expect(inTrashA.readAsBytesSync(), [8, 8], reason: 'the kept set-aside of A is still there');
      nb.discardDeleted(deleted); // the user lets it go: _removeSetAside runs
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(inTrashA.readAsBytesSync(), [8, 8], reason: 'A\'s kept folder stays');
      expect(trashFiles().where((f) => f.path.contains(b)), isEmpty, reason: 'B\'s trash folder is removed');
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(File('${assets(pages, a).path}/junk.tmp').existsSync(), isTrue);
      await nb.flush();
      nb.dispose();
      opened.remove(nb);
      final again = make();
      await again.load();
      expect(inTrashA.readAsBytesSync(), [8, 8]);
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(asset(pages, b).readAsBytesSync(), bytes);
    });

    test('a source file changed between the copy and its removal during a delete: both versions survive undo, expiry and a reload', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final store = failingStore();
      final nb = make(store: store);
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      File('${assets(pages, a).path}/notes.txt').writeAsStringSync('mine');
      var fires = 0;
      attachmentBeforeRemoveHook = (src) async {
        final n = nameOf(src.path);
        if (!under(src, 'pages') || (n != '$hash.txt' && n != 'notes.txt')) return;
        fires++;
        src.writeAsBytesSync(n == 'notes.txt' ? utf8.encode('mine, changed') : damagedBytes);
      };
      addTearDown(() => attachmentBeforeRemoveHook = null);
      final deleted = await nb.delete(a);
      attachmentBeforeRemoveHook = null;
      expect(fires, 2);
      // Both changed sources stayed in the page folder; the old copies are in the trash.
      expect(asset(pages, a).readAsBytesSync(), damagedBytes);
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine, changed');
      final trashNotes = trashFiles().singleWhere((f) => f.path.endsWith('notes.txt'));
      expect(trashNotes.readAsStringSync(), 'mine');

      store.failId = a; // A's page can't be written back: the bar is renewed
      await expectLater(
        nb.undoDelete(deleted),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('deleted-attachments'))),
      );
      store.failId = null;
      store.broken = false;
      expect(nb.isPendingDelete(deleted), isTrue);
      // The hash file: the changed one is kept aside, the old copy is published.
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(damagedFiles(assets(pages, a)).single.readAsBytesSync(), damagedBytes);
      // The non-hash file differs: both stay, and the folder is kept and named.
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine, changed');
      expect(trashNotes.readAsStringSync(), 'mine');
      await nb.discardPendingDelete(); // a real expiry
      expect(trashNotes.readAsStringSync(), 'mine', reason: 'the kept folder stays');
      await nb.flush();
      nb.dispose();
      opened.remove(nb);
      final again = make();
      await again.load();
      expect(trashNotes.readAsStringSync(), 'mine');
      expect(asset(pages, a).readAsBytesSync(), bytes);
      expect(damagedFiles(assets(pages, a)).single.readAsBytesSync(), damagedBytes);
      expect(File('${assets(pages, a).path}/notes.txt').readAsStringSync(), 'mine, changed');
    });

    test('R-2: an undo that fails with a plain file error after a damaged file was set aside still reports the aside and the kept folder', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final nb = make();
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      final deleted = await nb.delete(a);
      assets(pages, a).createSync(recursive: true);
      asset(pages, a).writeAsBytesSync(damagedBytes);
      var fired = false;
      attachmentBeforePublishHook = (target) async {
        if (!target.endsWith('$hash.txt') || !under(File(target), 'pages')) return;
        fired = true;
        throw const FileSystemException('disk error while publishing');
      };
      addTearDown(() => attachmentBeforePublishHook = null);
      await expectLater(
        nb.undoDelete(deleted),
        throwsA(isA<NotebookException>().having((e) => e.message, 'message', contains('deleted-attachments'))),
      );
      attachmentBeforePublishHook = null;
      await Future<void>.delayed(Duration.zero);
      expect(fired, isTrue);
      final aside = damagedCopyName('$hash.txt', contentHash(damagedBytes));
      expect(File('${assets(pages, a).path}/$aside').readAsBytesSync(), damagedBytes);
      expect(
        notices,
        contains(
          allOf(
            contains('damaged copy of "$hash.txt"'),
            contains('"$aside"'),
            contains("the good copy wasn't put in its place and stays in the folder of deleted pages"),
            isNot(contains('the good copy was used')),
          ),
        ),
      );
      expect(trashFiles().single.readAsBytesSync(), bytes, reason: 'the good copy is kept in the trash');
    });

    test('a put-back that fails for another reason (a file in the way) still posts a notice that names the folder', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final store = _DeleteHookStore(pages);
      final nb = make(store: store);
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final notices = <String>[];
      nb.attachmentNotices.listen(notices.add);
      store.beforeDeleteOnce = () {
        final page = File('${pages.path}/$a.canvas');
        page.writeAsStringSync(page.readAsStringSync().replaceFirst('"title":"', '"title":"Synced '));
        File('${pages.path}/$a.assets').writeAsStringSync('in the way'); // a plain file where the folder goes
      };
      await nb.delete(a);
      await Future<void>.delayed(Duration.zero);
      final kept = trashFiles().singleWhere((f) => f.path.endsWith('$hash.txt'));
      expect(kept.readAsBytesSync(), bytes);
      expect(notices, contains(allOf(contains('could not be put back'), contains(nameOf(kept.parent.path)), contains('deleted-attachments'))));
    });

    test('a source file that can\'t be read during the copy is the move\'s own failure: it rolls back and does not blame the destination', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      final locked = asset(pages, a).openSync();
      try {
        locked.lockSync(FileLock.blockingExclusive);
        Object? error;
        try {
          await nb.moveToLocation(a, binderPath: binder.path);
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<NotebookException>());
        final msg = (error! as NotebookException).message;
        expect(msg, startsWith('Could not move the page'));
        expect(msg, isNot(contains('still changing')));
        expect(File('${extra.path}/$a.canvas').existsSync(), isFalse, reason: 'rolled back');
        expect(File('${assets(extra, a).path}/notes.txt').existsSync(), isFalse, reason: 'this move\'s copy is removed');
        expect(asset(extra, a).readAsBytesSync(), damagedBytes, reason: 'the destination file is untouched');
      } finally {
        locked.unlockSync();
        locked.closeSync();
      }
      expect(asset(pages, a).readAsBytesSync(), bytes);
    }, skip: Platform.isWindows ? null : 'needs a mandatory file lock (Windows)');

    test('the old files could not be removed after a damaged destination was set aside: the message names the aside', () async {
      final store = _DeleteHookStore(pages);
      final (nb, a, binder) = await pageWithNotes(store: store);
      seedDestination(a, damagedBytes);
      store.beforeDeleteOnce = () => throw const FileSystemException('source gone');
      final note = await movedWithNote(nb, a, binder);
      expect(note, allOf(contains('Could not remove the old files'), contains('damaged copy of "$hash.txt"'), contains('.damaged-')));
      expect(File('${assets(extra, a).path}/${damagedCopyName('$hash.txt', contentHash(damagedBytes))}').readAsBytesSync(), damagedBytes);
    });

    test('a failure writing the kept changes after a damaged destination was set aside: the message names the aside', () async {
      final (nb, a, binder) = await pageWithNotes();
      seedDestination(a, damagedBytes);
      // A kept edit of the page moves with it; writing its new copy fails.
      final text = File('${pages.path}/$a.canvas').readAsStringSync();
      final disk = readPage(text);
      await RecoveryStore(rec).write(
        folder: pages.path,
        page: disk.withMeta(disk.meta.withTitle('an unsaved edit')),
        baseText: text,
        time: DateTime.now(),
      );
      await nb.refreshRecoveryIndexForTest();
      var fired = false;
      nb.recoveryStoreForTest!.hook = (point) async {
        if (point != 'write') return;
        fired = true;
        throw const FileSystemException('disk full');
      };
      final note = await movedWithNote(nb, a, binder);
      expect(fired, isTrue);
      expect(note, allOf(contains('Nothing was moved'), contains('damaged copy of "$hash.txt"'), contains('.damaged-')));
    });

    test('9d: a page that changed while deleting, put back into a folder with a changing file, keeps its trash folder through expiry', () async {
      Notebook.forceCopyMoveForTest = true;
      addTearDown(() => Notebook.forceCopyMoveForTest = false);
      final store = _DeleteHookStore(pages);
      final nb = make(store: store);
      await nb.load();
      final a = await nb.createPage();
      await nb.open(a);
      await attach(nb);
      final b = await nb.createPage(parentId: a);
      await nb.open(b);
      await attach(nb);
      var fired = false;
      store.beforeDeleteOnce = () {
        // A's file changes after it was read, and a file that is still being
        // written is at the hash name in its (now empty) assets folder.
        final page = File('${pages.path}/$a.canvas');
        page.writeAsStringSync(page.readAsStringSync().replaceFirst('"title":"', '"title":"Synced '));
        assets(pages, a).createSync(recursive: true);
        asset(pages, a).writeAsBytesSync(damagedBytes);
        attachmentAfterHashHook = (f) async {
          if (!f.path.endsWith('$hash.txt') || !under(f, 'pages')) return;
          fired = true;
          f.writeAsBytesSync([...damagedBytes, 1]);
        };
      };
      addTearDown(() => attachmentAfterHashHook = null);
      final deleted = await nb.delete(a);
      attachmentAfterHashHook = null;
      expect(fired, isTrue);
      expect(deleted.keptNote, isNotNull);
      final trash = Directory('${root.path}/app/deleted-attachments');
      final aTrash = trash.listSync(recursive: true).whereType<File>().singleWhere(
        (f) => f.path.endsWith('$hash.txt') && f.path.contains(a),
      );
      expect(aTrash.readAsBytesSync(), bytes);
      await nb.discardPendingDelete(); // the bar expires
      expect(aTrash.readAsBytesSync(), bytes, reason: 'the folder that could not be put back is not removed with the trash');
      expect(
        trash.listSync(recursive: true).whereType<File>().where((f) => f.path.contains(b)),
        isEmpty,
        reason: 'the other page\'s set-aside folder is removed',
      );
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

  group('Save a copy elsewhere and the attachments', () {
    late Directory dest;

    setUp(() async => dest = await Directory('${root.path}/Copies').create());

    // The attachments folder of the only copy made in [dest], or null.
    Directory? copiedAssets() {
      final d = dest.listSync().whereType<Directory>().where((d) => d.path.endsWith('.assets'));
      return d.isEmpty ? null : d.single;
    }

    test('the page\'s attachment files arrive, and the message is plain', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      final said = await nb.saveCopyElsewhere();
      expect(said, 'Saved a copy to ${dest.path}.');
      expect(File('${copiedAssets()!.path}/$hash.txt').readAsBytesSync(), bytes);
      expect(asset(pages, a).readAsBytesSync(), bytes, reason: 'the original is untouched');
    });

    test('a source folder that is not there is named, not skipped silently', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      assets(pages, a).deleteSync(recursive: true);
      final said = await nb.saveCopyElsewhere();
      expect(said, startsWith('Saved a copy to ${dest.path}, but '));
      expect(said, contains('$hash.txt'));
      expect(said, contains('not copied'));
    });

    test('a different file already under the name is reported, and left as it is', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      // The recovery store holds another file under the same name.
      final other = File('${rec.path}/$a.assets/$hash.txt')..createSync(recursive: true);
      other.writeAsStringSync('something else');
      final said = await nb.saveCopyElsewhere();
      expect(said, contains('$hash.txt'));
      expect(said, contains('not copied'));
      expect(File('${copiedAssets()!.path}/$hash.txt').readAsBytesSync(), bytes);
      expect(other.readAsStringSync(), 'something else', reason: 'the source is untouched');
    });

    // The page's own folder holds a file under the hash name that fails its
    // hash, and the recovery store's folder holds the good one: the first copy
    // is damaged by the time the second arrives.
    Future<Notebook> pageWithDamagedFirst(List<int> damaged) async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      File('${rec.path}/$a.assets/$hash.txt')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      asset(pages, a).writeAsBytesSync(damaged);
      return nb;
    }

    test('a damaged file at the copy\'s destination is kept aside and named, and the good one is used', () async {
      final damaged = List<int>.filled(bytes.length, 7);
      final nb = await pageWithDamagedFirst(damaged);
      final said = await nb.saveCopyElsewhere();
      final aside = damagedCopyName('$hash.txt', contentHash(damaged));
      expect(said, startsWith('Saved a copy to ${dest.path}, but '));
      expect(said, allOf(contains('damaged copy of "$hash.txt"'), contains('"$aside"')));
      expect(File('${copiedAssets()!.path}/$hash.txt').readAsBytesSync(), bytes);
      expect(File('${copiedAssets()!.path}/$aside').readAsBytesSync(), damaged);
    });

    test('a good copy whose publish is refused after the set-aside is not reported as used, though an earlier copy into the same target was verified', () async {
      final damaged = List<int>.filled(bytes.length, 7);
      final nb = await pageWithDamagedFirst(damaged);
      var calls = 0;
      attachmentBeforePublishHook = (target) async {
        if (!target.endsWith('$hash.txt') || !target.replaceAll(r'\', '/').contains('/Copies/')) return;
        // The first call is the page folder's own (damaged) file; the second is the good copy.
        if (++calls == 2) File(target).writeAsBytesSync([9, 9]);
      };
      addTearDown(() => attachmentBeforePublishHook = null);
      final said = await nb.saveCopyElsewhere();
      expect(calls, 2, reason: 'the hook fired for both copies');
      expect(said, allOf(contains('damaged copy of "$hash.txt"'), contains("the good copy wasn't put in its place")));
      expect(said, isNot(contains('was used')));
      // The good bytes are still in recovery, so that is named; the damaged
      // original's folder alone is not claimed to hold them.
      expect(said, contains('the recovery folder'));
      expect(said, isNot(contains("stays in the original's folder.")));
      expect(File('${copiedAssets()!.path}/$hash.txt').readAsBytesSync(), [9, 9], reason: 'what arrived is kept');
    });

    test('a destination file that is still changing during the copy is named, not reported as a plain success', () async {
      final damaged = List<int>.filled(bytes.length, 7);
      final nb = await pageWithDamagedFirst(damaged);
      var fired = false;
      attachmentAfterHashHook = (f) async {
        if (!f.path.endsWith('$hash.txt') || !f.path.replaceAll('\\', '/').contains('/Copies/')) return;
        fired = true;
        f.writeAsBytesSync([...damaged, 1]); // a sync client is still writing
      };
      addTearDown(() => attachmentAfterHashHook = null);
      final said = await nb.saveCopyElsewhere();
      expect(fired, isTrue);
      expect(said, startsWith('Saved a copy to ${dest.path}, but '));
      expect(said, allOf(contains('"$hash.txt"'), contains('still changing')));
      expect(File('${copiedAssets()!.path}/$hash.txt').readAsBytesSync(), [...damaged, 1], reason: 'left alone');
    });

    test('a page whose folder went away while it was open still reports its files', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      await nb.addStandaloneFolder(extra.path);
      final a = await nb.createPage(folderPath: extra.path);
      await nb.open(a);
      await attach(nb);
      extra.deleteSync(recursive: true);
      await nb.checkFolders();
      expect(nb.current!.readOnly, isTrue, reason: 'the page waits for its folder');
      final said = await nb.saveCopyElsewhere();
      expect(said, startsWith('Saved a copy to ${dest.path}, but '));
      expect(said, contains('$hash.txt'));
    });

    test('a leftover temporary file that could not be put back is reported', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      final a = nb.currentId!;
      await attach(nb);
      File('${assets(pages, a).path}/notes.1-1.tmp').writeAsStringSync('half a file');
      final said = await nb.saveCopyElsewhere();
      expect(said, contains('leftover temporary files'));
      expect(said, contains('notes.1-1.tmp'));
      expect(File('${copiedAssets()!.path}/$hash.txt').readAsBytesSync(), bytes);
    });

    test('with the page folder gone and a box type that cannot be asked, it says so', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      await nb.addStandaloneFolder(extra.path);
      final a = await nb.createPage(folderPath: extra.path);
      await nb.open(a);
      await attach(nb);
      await nb.setBoxType(a, FileCodec.id, false);
      extra.deleteSync(recursive: true);
      await nb.checkFolders();
      final said = await nb.saveCopyElsewhere();
      expect(said, startsWith('Saved a copy to ${dest.path}, but '));
      expect(said, contains("attachments folder wasn't available"));
      expect(said, contains('1 box is'));
    });

    test('a switched-off box type with no attachments folder at all is not a warning', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      final a = nb.currentId!;
      nb.current!.insertBox(
        BoxRecord.create(
          id: 'draw1',
          typeId: 'noted.drawing',
          dataVersion: 1,
          bounds: const Bounds(10, 10, 100, 100),
          data: RawJson.encode(const <String, Object?>{}),
          snapshotText: '',
          rev: 'r',
        ),
      );
      await nb.setBoxType(a, 'noted.drawing', false);
      await nb.flush();
      expect(assets(pages, a).existsSync(), isFalse);
      expect(await nb.saveCopyElsewhere(), 'Saved a copy to ${dest.path}.');
    });

    test('the page folder gone but a recovery attachments folder present still gets the note', () async {
      final nb = make(pick: () async => dest.path);
      await nb.load();
      await nb.addStandaloneFolder(extra.path);
      final a = await nb.createPage(folderPath: extra.path);
      await nb.open(a);
      await attach(nb);
      await nb.setBoxType(a, FileCodec.id, false);
      File('${rec.path}/$a.assets/$hash.txt')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      extra.deleteSync(recursive: true);
      await nb.checkFolders();
      final said = await nb.saveCopyElsewhere();
      expect(said, contains("attachments folder wasn't available"));
    });
  });
}
