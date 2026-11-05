// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_lock.dart';
import 'package:noted_core/noted_core.dart';

/// A page store whose publishes can be made to fail or to hang, as a locked
/// file or a dead drive would (R-1 v5 tests).
class FailStore extends PageStore {
  FailStore(super.directory);

  /// Thrown by every compare-and-swap save while set.
  Object? failWith;

  /// Every compare-and-swap save waits for this first, while set.
  Completer<void>? stall;

  /// Only the page with this id stalls (null: every page).
  String? stallId;

  int attempts = 0;

  /// Runs at the start of a save (before it stalls or fails).
  void Function()? onAttempt;

  @override
  Future<ReplaceResult> saveIfUnchanged(
    NotedPage page,
    String? expectedText, {
    void Function()? beforeMoveAside,
    void Function()? afterRead,
    void Function()? beforePublish,
    void Function()? beforeRestore,
  }) async {
    attempts++;
    onAttempt?.call();
    final s = stall;
    if (s != null && (stallId == null || stallId == page.id)) await s.future;
    final f = failWith;
    if (f != null) throw f;
    return super.saveIfUnchanged(
      page,
      expectedText,
      beforeMoveAside: beforeMoveAside,
      afterRead: afterRead,
      beforePublish: beforePublish,
      beforeRestore: beforeRestore,
    );
  }
}

/// "Access is denied." as Windows reports it.
FileSystemException accessDenied([String path = '']) => FileSystemException(
  'Cannot write',
  path,
  const OSError('Access is denied.', 5),
);

/// Folders and notebooks for a test, cleaned up after it.
class TroubleWorld {
  late Directory root;
  late Directory pages;
  late Directory other;
  late Directory rec;
  late File settings;
  final List<Notebook> opened = [];
  final Map<String, FailStore> stores = {};

  Future<void> init() async {
    root = await Directory.systemTemp.createTemp('noted_r1v5');
    pages = await Directory('${root.path}/pages').create();
    other = await Directory('${root.path}/other').create();
    rec = Directory('${root.path}/app/recovery');
    settings = File('${root.path}/app/binders.json');
  }

  FailStore storeFor(Directory d) =>
      stores.putIfAbsent(d.path, () => FailStore(d));

  Notebook make({
    RecoveryLock? lock,
    Duration saveDelay = const Duration(hours: 1),
    Duration leaveLimit = const Duration(milliseconds: 400),
    Duration busyWindow = const Duration(milliseconds: 600),
    Duration backoffFirst = const Duration(hours: 1),
    Duration backoffMax = const Duration(hours: 1),
    Directory? recovery,
    Future<String?> Function()? pick,
  }) {
    final nb = Notebook(
      storeFor(pages),
      buildModules(),
      saveDelay: saveDelay,
      bindersFile: settings,
      recoveryDirectory: recovery ?? rec,
      folderCheckInterval: Duration.zero,
      storeFactory: storeFor,
      recoveryLock: lock,
      pickFolder: pick,
      leaveSaveLimit: leaveLimit,
      busyReadWindow: busyWindow,
      backoffFirst: backoffFirst,
      backoffMax: backoffMax,
    );
    opened.add(nb);
    return nb;
  }

  /// A page in the default folder, saved, open, with one new box pending.
  Future<String> editedPage(Notebook nb) async {
    await nb.load();
    final id = nb.currentId!;
    await nb.flush();
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    return id;
  }

  File pageFile(String id, [Directory? dir]) =>
      File('${(dir ?? pages).path}/$id.canvas');

  List<File> recFiles() => rec.existsSync()
      ? [
          for (final f in rec.listSync())
            if (f is File && f.path.endsWith('.entry')) f,
        ]
      : const [];

  /// Quitting without a last save: nothing more is written.
  void crash(Notebook nb) {
    nb.dispose();
    opened.remove(nb);
  }

  Future<void> dispose() async {
    for (final nb in opened) {
      nb.dispose();
    }
    for (final s in stores.values) {
      s.failWith = null;
      final st = s.stall;
      if (st != null && !st.isCompleted) st.complete();
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (root.existsSync()) {
      for (var i = 0; i < 20; i++) {
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  }
}

/// Waits until [done] holds, for up to [within].
Future<void> until(
  bool Function() done, {
  Duration within = const Duration(seconds: 10),
  String? what,
}) async {
  final end = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('timed out waiting for ${what ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// The text of the only note box of [page], or the number of boxes.
int boxCount(NotedPage page) => page.nodes.whereType<BoxRecord>().length;
