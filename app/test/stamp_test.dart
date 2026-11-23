// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// File stamps (S): a check skips a file whose stamp is the one Noted last
// scanned, read or published, and reads any other (0157, rule P). A read is
// told by the `check-read` sync hook, which a skipped file never reaches.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  late Directory root;
  late Directory pages;
  late List<Notebook> opened;
  late List<String> reads;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_stamp');
    pages = await Directory('${root.path}/pages').create();
    opened = [];
    reads = [];
  });
  tearDown(() async {
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await root.delete(recursive: true);
  });

  Notebook make() {
    final nb = Notebook(
      PageStore(pages),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}/app/binders.json'),
    );
    nb.syncHook = (point, path) async {
      if (point == 'check-read') reads.add(path);
    };
    opened.add(nb);
    return nb;
  }

  String pathOf(String id) => '${pages.path}/$id.canvas';

  // A fresh notebook that scanned two pages on disk, with the first open: the
  // second is the closed page the checks below look at.
  Future<(Notebook, String, String)> scanned() async {
    final first = make();
    await first.load();
    final a = first.currentId!;
    final b = await first.createPage();
    await first.flush();
    await first.open(a);
    await first.flush();
    first.dispose();
    opened.remove(first);
    final nb = make();
    await nb.load();
    await nb.open(a);
    reads.clear();
    return (nb, a, b);
  }

  test('a scanned file whose stamp still matches is not read by a check', () async {
    final (nb, _, b) = await scanned();
    await nb.checkFile(pathOf(b));
    expect(reads, isEmpty);
  });

  test('a file whose stamp changed is read', () async {
    final (nb, _, b) = await scanned();
    File(pathOf(b)).writeAsStringSync(' ', mode: FileMode.append);
    await nb.checkFile(pathOf(b));
    expect(reads, [pathOf(b)]);
  });

  test('a file Noted published is not read by a check (onPublishStamp)', () async {
    final nb = make();
    await nb.load();
    final a = nb.currentId!;
    final b = await nb.createPage();
    await nb.flush();
    await nb.open(a);
    await nb.flush();
    // A closed page's title is written by a publish that reports the stamp.
    await nb.rename(b, 'Renamed');
    await nb.flush();
    reads.clear();
    await nb.checkFile(pathOf(b));
    expect(reads, isEmpty);
  });

  test('the open page is always read', () async {
    final (nb, a, _) = await scanned();
    await nb.checkFile(pathOf(a));
    expect(reads, [pathOf(a)]);
  });

  test('a changed _known entry drops the stamp: the file is read', () async {
    final (nb, _, b) = await scanned();
    nb.setKnownTextForTest(pathOf(b), 'something else');
    await nb.checkFile(pathOf(b));
    expect(reads, [pathOf(b)]);
  });

  test('a read that finds the file unchanged records the stamp: the next check skips it', () async {
    final (nb, _, b) = await scanned();
    nb.setKnownTextForTest(pathOf(b), File(pathOf(b)).readAsStringSync());
    await nb.checkFile(pathOf(b));
    expect(reads, [pathOf(b)]);
    reads.clear();
    await nb.checkFile(pathOf(b));
    expect(reads, isEmpty);
  });
}
