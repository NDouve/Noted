// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/counting_io.dart';

/// The check of a page file after a watcher event reads the file. On Windows a
/// file open for reading can't be renamed, so a read that overlapped the
/// notebook's own save of that file (a compare-and-swap replace, which moves
/// the file aside) made the save fail with a sharing violation (errno 32). The
/// read now takes its turn under the folder's lock, as the replace does.
void main() {
  late Directory dir;
  late Notebook nb;
  late PageStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('noted_check_lock');
    store = PageStore(dir);
    nb = Notebook(store, buildModules(), saveDelay: Duration.zero);
    await nb.load();
  });

  tearDown(() async {
    await nb.flush();
    nb.dispose();
    await dir.delete(recursive: true);
  });

  test('a check of a page file reads it only when the folder is free', () async {
    final log = IoLog();
    await countingIo(log, () async {
      final other = await nb.createPage();
      await nb.createPage(); // opens another page, so [other] is closed
      await nb.flush();
      final path = store.pathFor(other);

      // A save (or any other job) is running in the folder.
      final release = Completer<void>();
      final job = nb.folderLocks.run(dir, () => release.future);
      log.clear();

      final check = nb.checkFile(path);
      // Time for a check that doesn't wait for the folder to read the file.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      log.ops.add(const IoOp('marker', 'released'));
      release.complete();
      await job;
      await check;

      final marker = log.ops.indexWhere((o) => o.kind == 'marker');
      final read = log.ops.indexWhere((o) => o.kind == 'read' && o.path.endsWith('$other.canvas'));
      expect(read, isNonNegative, reason: 'the check read the file: ${log.ops}');
      expect(read, greaterThan(marker), reason: 'the read waited for the folder job: ${log.ops}');
    });
  });

  test('a hung job on the folder does not hold the check for long', () async {
    final other = await nb.createPage();
    await nb.createPage();
    await nb.flush();
    final hung = Completer<void>();
    unawaited(nb.folderLocks.run(dir, () => hung.future));
    final watch = Stopwatch()..start();
    // The check reads the file after a short wait, not when the job ends.
    await nb.checkFile(store.pathFor(other)).timeout(const Duration(seconds: 5));
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    hung.complete();
  });
}
