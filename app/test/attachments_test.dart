// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

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

  Notebook make({Duration saveDelay = Duration.zero}) {
    final nb = Notebook(
      PageStore(pages),
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
