// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';

/// A store whose first scan fails or hangs, as a device folder can.
class _FlakyStore extends PageStore {
  _FlakyStore(super.directory);

  int scans = 0;
  Object? failWith;
  Completer<void>? hangOn;

  @override
  Future<List<PageEntry>> scan({bool createFolder = true, bool sweep = true}) async {
    scans++;
    if (failWith case final e?) throw e;
    if (hangOn case final h?) await h.future;
    return super.scan(createFolder: createFolder, sweep: sweep);
  }
}

void main() {
  late Directory dir;
  late _FlakyStore store;
  late Notebook nb;

  Future<void> start(WidgetTester t, Future<void> Function() load, {Duration? retryFirst, bool binders = false}) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_load_error');
      store = _FlakyStore(Directory('${dir.path}/pages')..createSync());
      nb = Notebook(
        store,
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: binders ? File('${dir.path}/binders.json') : null,
        settingsRetryFirst: retryFirst ?? const Duration(seconds: 2),
      );
      await load();
    });
    await t.pumpWidget(NotedApp(notebook: nb));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await settleSaves(t, nb);
    await t.runAsync(() async {
      nb.dispose();
      await dir.delete(recursive: true);
    });
  }

  testWidgets('a failed load shows its error and Retry opens a page', (t) async {
    await start(t, () async {});
    await t.runAsync(() async {
      store.failWith = const FileSystemException('disk said no');
      await nb.loadChecked();
    });
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('load-error-text')), findsOneWidget);
    expect(find.textContaining('disk said no'), findsOneWidget);

    store.failWith = null;
    await t.tap(find.byKey(const ValueKey('load-error-retry')));
    for (var i = 0; i < 100 && nb.currentId == null; i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await t.pump();
    expect(nb.loadError, isNull);
    expect(nb.currentId, isNotNull);
    expect(find.byKey(const ValueKey('load-error-text')), findsNothing);
    await close(t);
  });

  testWidgets('a load that hangs ends in the error screen, and clears if it finishes', (t) async {
    await start(t, () async {});
    final hang = store.hangOn = Completer<void>();
    await t.runAsync(() => nb.loadChecked(timeout: const Duration(milliseconds: 100)));
    await t.pump();
    expect(find.byKey(const ValueKey('load-error-text')), findsOneWidget);
    expect(find.textContaining('Loading took more than'), findsOneWidget);

    hang.complete();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await t.pump();
    expect(nb.loadError, isNull);
    expect(nb.currentId, isNotNull);
    await close(t);
  });

  Future<void> waitFor(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
  }

  testWidgets('a late success, or a Retry, tells loadSucceeded (OneDrive sync starts then)', (t) async {
    await start(t, () async {});
    var succeeded = false;
    unawaited(nb.loadSucceeded.then((_) => succeeded = true));
    store.failWith = const FileSystemException('disk said no');
    await t.runAsync(() => nb.loadChecked());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(succeeded, isFalse, reason: 'a failed load is not a success');

    store.failWith = null;
    final hang = store.hangOn = Completer<void>();
    await t.runAsync(() => nb.loadChecked(timeout: const Duration(milliseconds: 100)));
    expect(nb.loadError, isNotNull);
    expect(succeeded, isFalse, reason: 'a timeout is not a success');
    hang.complete();
    await waitFor(t, () => succeeded);
    expect(succeeded, isTrue, reason: 'a load that ends well after the timeout is');
    await close(t);
  });

  testWidgets('Retry during a timed-out run starts no second load, and says it is still loading', (t) async {
    await start(t, () async {});
    final hang = store.hangOn = Completer<void>();
    await t.runAsync(() => nb.loadChecked(timeout: const Duration(milliseconds: 100)));
    await t.pump();
    expect(store.scans, 1);
    expect(nb.loadRunning, isTrue);
    expect(find.byKey(const ValueKey('load-error-still')), findsOneWidget);
    final retry = t.widget<FilledButton>(find.byKey(const ValueKey('load-error-retry')));
    expect(retry.onPressed, isNull);

    await t.runAsync(() => nb.loadChecked(timeout: const Duration(milliseconds: 100)));
    expect(store.scans, 1, reason: 'the running load is rejoined');
    expect(nb.loadError, isNotNull);

    hang.complete();
    await waitFor(t, () => nb.currentId != null);
    expect(store.scans, 1);
    expect(nb.loadError, isNull);
    expect(nb.loadRunning, isFalse);
    await close(t);
  });

  testWidgets('the binder-list retry stays out of a failed load and of the Retry that follows', (t) async {
    await start(t, () async {}, retryFirst: const Duration(milliseconds: 50), binders: true);
    store.failWith = const FileSystemException('disk said no');
    await t.runAsync(() => nb.loadChecked());
    expect(nb.settingsHoldForTest, 'locked');
    File('${dir.path}/binders.json').writeAsStringSync('{"binders":[],"binderIds":{}}');
    // Well past the first retry: it must not open a page behind the error.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await t.pump();
    expect(nb.currentId, isNull);
    expect(nb.loadError, isNotNull);
    expect(nb.settingsTimerActiveForTest, isTrue);

    store.failWith = null;
    final before = store.scans;
    await t.runAsync(() => nb.loadChecked());
    await t.pump();
    expect(store.scans, before + 1, reason: 'one scan for the one load');
    expect(nb.loadError, isNull);
    expect(nb.currentId, isNotNull);
    expect(nb.settingsHoldForTest, isNull);
    await close(t);
  });

  testWidgets('AI writes are refused while the load has failed or is timed out', (t) async {
    await start(t, () async {});
    store.failWith = const FileSystemException('disk said no');
    await t.runAsync(() => nb.loadChecked());
    expect(await t.runAsync(() => nb.aiWaitLoaded(const Duration(milliseconds: 100))), isFalse);

    store.failWith = null;
    await t.runAsync(() => nb.loadChecked());
    expect(await t.runAsync(() => nb.aiWaitLoaded(const Duration(milliseconds: 100))), isTrue);
    await close(t);
  });
}
