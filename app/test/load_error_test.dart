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

  Object? failWith;
  Completer<void>? hangOn;

  @override
  Future<List<PageEntry>> scan({bool createFolder = true, bool sweep = true}) async {
    if (failWith case final e?) throw e;
    if (hangOn case final h?) await h.future;
    return super.scan(createFolder: createFolder, sweep: sweep);
  }
}

void main() {
  late Directory dir;
  late _FlakyStore store;
  late Notebook nb;

  Future<void> start(WidgetTester t, Future<void> Function() load) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('noted_load_error');
      store = _FlakyStore(Directory('${dir.path}/pages')..createSync());
      nb = Notebook(store, buildModules(), saveDelay: Duration.zero);
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
}
