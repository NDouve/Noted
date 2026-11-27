// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Sharing and opening a binder as a .zip (design t6): the share and the open
// on the real file system, with the notebook.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_commands.dart';
import 'package:noted/src/binder_zip/binder_zip_flow.dart';
import 'package:noted/src/export/export_write.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/import/zip_reader.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/notebook_folder.dart';
import 'support/png_builder.dart';

void main() {
  late Directory root;
  late List<Notebook> opened;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_binder_zip');
    Directory('${root.path}/app/pages').createSync(recursive: true);
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Notebook make({Future<String?> Function()? pick}) {
    final nb = Notebook(
      PageStore(Directory('${root.path}/app/pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
      templatesDirectory: Directory('${root.path}/app/templates'),
      cacheDirectory: Directory('${root.path}/cache'),
      folderCheckInterval: Duration.zero,
      pickFolder: pick,
    );
    opened.add(nb);
    return nb;
  }

  ExportWriter writer() => ExportWriter(askReplace: (_) async => true, askPutBack: (_, _) async => false);

  Future<void> attach(Notebook nb, String name, List<int> bytes) async {
    final store = nb.attachments!;
    final made = await const FileModule().createFromFile(IncomingFile(name, Uint8List.fromList(bytes)), store);
    final (data, size) = made!;
    const codec = FileCodec();
    nb.current!.insertBox(commitBox(createBox(codec, Bounds(10, 10, size.width, size.height)), codec, data));
    await nb.flush();
  }

  Map<String, Uint8List> filesUnder(String dir) => {
    for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
      f.path.substring(dir.length + 1).replaceAll(r'\', '/'): f.readAsBytesSync(),
  };

  test('a binder saved as a .zip opens again with the same files', () async {
    final source = Directory('${root.path}/Work')..createSync();
    final nb = make(pick: () async => '${root.path}${sep}into');
    await nb.load();
    final b = await nb.addBinder(source.path);
    await nb.setBinderAiAccess(b.path, AiAccess.open);
    final id = await nb.createPage(binderPath: b.path);
    await nb.open(id);
    await attach(nb, 'a.txt', [1, 2, 3]);
    await nb.flush();
    final before = filesUnder(source.path);

    final target = '${root.path}${sep}out${sep}Work.zip';
    Directory('${root.path}/out').createSync();
    binderZipSavePicker = (_) async => target;
    final saved = await saveBinderZip(nb, b, roots: () => nb.exportRefusedFolders, writer: writer());
    expect(saved, 'Saved Work.zip.');
    final zip = ZipReader(File(target).readAsBytesSync(), ImportLimits.desktop);
    expect(zip.names.toSet(), {for (final k in before.keys) 'Work/$k'});

    await nb.removeBinder(b.path);
    source.renameSync('${root.path}${sep}moved');
    Directory('${root.path}/into').createSync();
    binderZipOpenPicker = () async => target;
    final message = await openBinderZip(nb, roots: () => nb.exportRefusedFolders);
    expect(message, startsWith('Opened "'));
    final after = filesUnder('${root.path}${sep}into${sep}Work');
    expect(after.keys.toSet(), before.keys.toSet());
    for (final k in before.keys) {
      if (k == binderFileName) continue;
      expect(after[k], before[k], reason: k);
    }
  });

  test("the entry points: a binder row's Save as .zip… and File › Open binder from .zip…", () async {
    final source = Directory('${root.path}${sep}Work')..createSync();
    final nb = make(pick: () async => null);
    await nb.load();
    final b = await nb.addBinder(source.path);
    final a = _Actions();
    final r = binderCommands(nb, b, a);
    final save = r[AppCommands.binderSaveZip]!;
    expect(save.label, 'Save as .zip…');
    expect(r.commands.map((c) => c.id), containsAllInOrder([AppCommands.binderSaveAsTemplate, AppCommands.binderSaveZip, AppCommands.binderRemove]));
    await save.run();
    final open = openBinderZipCommand(nb, a);
    expect(open.label, 'Open binder from .zip…');
    expect(open.enabled, isTrue);
    await open.run();
    expect(a.calls, ['save Work', 'open']);
    r.dispose();
  });

  // B4: the reload-equivalence scenario of design t6 §9.
  test('reload equivalence: shared, removed, moved away, opened; files and a fresh notebook agree', () async {
    final source = Directory('${root.path}${sep}Work')..createSync();
    final into = Directory('${root.path}${sep}Opened')..createSync();
    // A page with a box type this build doesn't know, written before the add.
    const pageB = 'b0b1b2b3b4b5b6b7';
    final future = BoxRecord.create(
      id: 'futurebox',
      typeId: 'x.future',
      dataVersion: 3,
      bounds: const Bounds(20, 20, 200, 80),
      data: RawJson.trusted('{"kept" : [1, 2, {"as":"written"}]}'),
      snapshotText: 'a snapshot of the future box',
      rev: 'r0',
    );
    final unknownText = writePage(NotedPage.create(PageMeta.create(id: pageB, title: 'Future', order: 5)).insertNode(future));
    File('${source.path}$sep$pageB.canvas').writeAsStringSync(unknownText);

    final nb = make(pick: () async => into.path);
    await nb.load();
    final b = await nb.addBinder(source.path);
    await nb.setBinderAiAccess(b.path, AiAccess.open);
    final a = await nb.createPage(binderPath: b.path);
    await nb.open(a);
    await nb.rename(a, 'Alpha');
    await attach(nb, 'notes.txt', 'a file attachment'.codeUnits);
    final png = buildPng(4, 3);
    final made = await const ImageModule().createFromFile(IncomingFile('pic.png', png), nb.attachments!);
    final (image, size) = made!;
    const codec = ImageCodec();
    nb.current!.insertBox(commitBox(createBox(codec, Bounds(40, 40, size.width, size.height)), codec, image));
    await nb.flush();
    final sub = await nb.createPage(parentId: a);
    await nb.rename(sub, 'Sub');
    final second = await nb.createPage(binderPath: b.path);
    await nb.rename(second, 'Second');
    await nb.flush();
    await nb.savePageAsTemplate(a, name: 'From alpha', inBinder: true);
    await nb.flush();
    // A conflict copy of the first page and a copy of the binder file, which
    // this notebook doesn't watch for.
    final alphaText = File('${source.path}$sep$a.canvas').readAsStringSync();
    File('${source.path}$sep$a-LAPTOP.canvas').writeAsStringSync(alphaText.replaceFirst('"Alpha"', '"Alpha on the laptop"'));
    final binderText = File('${source.path}$sep$binderFileName').readAsStringSync();
    File('${source.path}${sep}noted-binder (1).json').writeAsStringSync(binderText.replaceFirst('"title":"', '"title":"Copy of '));
    final before = filesUnder(source.path);
    expect(before.keys, containsAll(['$a-LAPTOP.canvas', 'noted-binder (1).json', '$pageB.canvas']));
    expect(before.keys.where((k) => k.startsWith('templates/')), isNotEmpty);
    expect(before.keys.where((k) => k.startsWith('$a.assets/')), hasLength(2));

    // Shared, removed from the sidebar, the folder moved away.
    Directory('${root.path}${sep}out').createSync();
    final target = '${root.path}${sep}out${sep}Work.zip';
    binderZipSavePicker = (_) async => target;
    expect(await saveBinderZip(nb, b, roots: () => nb.exportRefusedFolders, writer: writer()), 'Saved Work.zip.');
    await nb.removeBinder(b.path);
    source.renameSync('${root.path}${sep}Away');
    final away = '${root.path}${sep}Away';

    // Opened into a new parent; the add settles.
    binderZipOpenPicker = () async => target;
    final message = await openBinderZip(nb, roots: () => nb.exportRefusedFolders);
    expect(message, startsWith('Opened "'));
    await settleNotebooks(notebooks: [nb]);
    await nb.flush();
    final openedPath = '${into.path}${sep}Work';
    final after = filesUnder(openedPath);

    // Every file byte-equal, but the merged page, the removed copy and the patch.
    final source2 = filesUnder(away);
    expect(after.containsKey('$a-LAPTOP.canvas'), isFalse, reason: 'the copy was merged and removed');
    expect(after.keys.toSet(), source2.keys.toSet().difference({'$a-LAPTOP.canvas'}));
    for (final k in source2.keys) {
      if (k == '$a.canvas' || k == '$a-LAPTOP.canvas') continue;
      if (k == binderFileName) {
        expect(utf8.decode(after[k]!), Binder.parse(binderText).withAiAccess(AiAccess.guarded).write(), reason: 'the Guarded patch only');
        continue;
      }
      expect(after[k], source2[k], reason: k);
    }
    // Invariant 2: the unknown box's page file is byte-equal.
    expect(utf8.decode(after['$pageB.canvas']!), unknownText);

    // A fresh notebook over the same folders shows what the opened one shows.
    Future<Map<String, Object>> view(Notebook n) async {
      final out = <String, Object>{};
      final ids = [for (final p in n.treeOfPage(a).roots) p.id];
      final tree = n.treeOfPage(a);
      final all = <String>[];
      void walk(String id) {
        all.add(id);
        for (final c in tree.childrenOf(id)) {
          walk(c.id);
        }
      }

      ids.forEach(walk);
      for (final id in all) {
        await n.open(id);
        final page = n.current!.page;
        out[id] = [
          page.meta.title,
          page.meta.parentId,
          for (final node in page.nodes)
            if (node is BoxRecord) '${node.id}:${node.typeId}:${node.snapshotText}',
        ].join('|');
      }
      return out;
    }

    final live = await view(nb);
    expect(live.keys, containsAll([a, sub, second, pageB]));
    expect(live[pageB], contains('futurebox:x.future:a snapshot of the future box'));
    await nb.flush();
    nb.dispose();
    opened.remove(nb);
    final fresh = make();
    await fresh.load();
    expect(await view(fresh), live);
    expect(fresh.binderAiAccess(openedPath), AiAccess.guarded);
  });
}

class _Actions implements PageTreeActions {
  final List<String> calls = [];
  @override
  Future<void> binderSaveZip(BinderSection binder) async => calls.add('save ${binder.title}');
  @override
  Future<void> openBinderZip() async => calls.add('open');
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
