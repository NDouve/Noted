// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/cloud_sync.dart';
import 'package:noted/src/notebook.dart';

import 'busy_retry.dart';
import 'real_io.dart';

// The one rule for a test that owns a notebook and the temp folder it lives
// in: the notebook is settled before the folder is deleted.
//
// A notebook has work in flight that a test does not see: a save on the
// autosave timer or the chain, a read of a page, binder or settings file, a
// check of an attachment file. On Windows a folder with a file open can't be
// deleted, so a teardown that raced one failed now and then. The notebook
// reports all of it as `inFlightForTest` (null when idle); [deleteTestFolder]
// waits for that, then deletes, and fails naming what was still running.

/// The notebooks of a test that live in [dir]: built there and not yet
/// settled and disposed. A notebook is related when its page folder or its
/// binders file is inside [dir].
List<Notebook> notebooksIn(Directory dir) {
  // A disposed notebook with nothing running needs no more watching.
  Notebook.liveForTest.removeWhere((n) => n.disposedForTest && n.inFlightForTest == null);
  final top = _norm(dir.absolute.path);
  bool inside(String path) {
    final p = _norm(File(path).absolute.path);
    return p == top || p.startsWith('$top/');
  }

  return [
    for (final n in Notebook.liveForTest)
      if (inside(n.store.directory.path) || (n.bindersFile != null && inside(n.bindersFile!.path))) n,
  ];
}

String _norm(String path) {
  final p = path.replaceAll('\\', '/');
  return Platform.isWindows ? p.toLowerCase() : p;
}

/// The cloud syncs (OneDrive, WebDAV) whose working copies are in [dir]. A
/// disposed sync's round keeps running and may still write there.
List<CloudSync> syncsIn(Directory dir) {
  CloudSync.liveForTest.removeWhere((c) => c.disposedForTest && c.inFlightForTest == null);
  final top = _norm(dir.absolute.path);
  return [
    for (final c in CloudSync.liveForTest)
      if (_norm(c.workingRoot.absolute.path).startsWith(top)) c,
  ];
}

/// What [notebooks] (and the [syncs] beside them) have in flight (null:
/// nothing).
String? inFlightOf(Iterable<Notebook> notebooks, [Iterable<CloudSync> syncs = const []]) {
  final parts = <String>[
    for (final n in notebooks)
      ?n.inFlightForTest,
    for (final c in syncs)
      ?c.inFlightForTest,
  ];
  return parts.isEmpty ? null : parts.join(' | ');
}

/// Fails, naming what is in flight, unless none of [notebooks] has any work
/// in flight. [what] says when it was checked.
void expectSettled(Iterable<Notebook> notebooks, {String what = 'now'}) {
  final busy = inFlightOf(notebooks);
  if (busy != null) fail('A notebook has work in flight $what: $busy.');
}

/// Lets all the work of [notebooks] (default: those in [under]) finish, then
/// checks it is so for two polls in a row. A save that starts in a widget
/// test's fake-time zone needs that zone pumped: pass the [tester], which is
/// pumped past the autosave delay between short real delays so the file IO
/// can complete. Without it only real time passes. Bounded: after [limit]
/// (scaled by [realIoScale]) the test fails and names what was running.
Future<void> settleNotebooks({
  WidgetTester? tester,
  Iterable<Notebook>? notebooks,
  Directory? under,
  Duration limit = const Duration(seconds: 20),
}) async {
  assert(notebooks != null || under != null, 'say which notebooks');
  final scaled = limit * realIoScale;
  final clock = Stopwatch()..start();
  var quiet = 0;
  while (true) {
    final list = notebooks?.toList() ?? notebooksIn(under!);
    final busy = inFlightOf(list, under == null ? const [] : syncsIn(under));
    if (busy == null) {
      if (++quiet >= 2) break;
    } else {
      quiet = 0;
      if (clock.elapsed > scaled) fail('Notebook work did not finish within $scaled: $busy.');
    }
    if (tester != null) {
      final delay = [for (final n in list) n.saveDelay].fold(Duration.zero, (a, b) => a > b ? a : b);
      // Runs the timer of a save scheduled in the fake zone.
      await tester.pump(delay + const Duration(milliseconds: 1));
      await tester.runAsync(() => realIoPause(busy == null ? 10 : 30));
    } else {
      await realIoPause(busy == null ? 10 : 30);
    }
  }
}

/// Settles the notebooks in [dir], then deletes it. A delete that still fails
/// fails the test saying what was in flight; Windows' short hold on a file
/// that was just closed is covered by [busyRetry] (a deadline of 20 s, only
/// for "in use", "access denied" and "not empty").
///
/// Call it from the zone the notebook works in (inside `runAsync` for a
/// widget test), after the test's own [settleNotebooks] with the tester when
/// saves started in the fake zone.
Future<void> deleteTestFolder(Directory dir, {Iterable<Notebook>? notebooks}) async {
  final own = (notebooks ?? notebooksIn(dir)).toList();
  await settleNotebooks(notebooks: own, under: dir);
  try {
    if (dir.existsSync()) await busyRetry(() => dir.delete(recursive: true));
  } on FileSystemException catch (e) {
    fail('Could not delete ${dir.path} after the notebooks settled: $e. In flight: ${inFlightOf(own) ?? 'nothing'}.');
  }
}
