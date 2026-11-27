// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Sharing and opening a binder as a .zip (design t6): the share and the open
// on the real file system, with the notebook.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_zip/binder_zip_flow.dart';
import 'package:noted/src/export/export_write.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/import/zip_reader.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/notebook_folder.dart';

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
}
