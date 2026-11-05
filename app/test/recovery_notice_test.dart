// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'support/settle_saves.dart';
import 'package:noted/src/recovery_notice.dart';
import 'package:noted/src/recovery_store.dart' show RecoveryListing;
import 'package:noted_core/noted_core.dart';

void main() {
  // File access needs real time, so it all happens inside runAsync.
  Future<(Directory, Notebook)> setUpNotebook(WidgetTester tester, {required bool pending}) async {
    return (await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('noted_recovery_notice');
      final extra = await Directory('${root.path}/Elsewhere').create();
      final nb = Notebook(
        PageStore(await Directory('${root.path}/pages').create()),
        buildModules(),
        saveDelay: const Duration(hours: 1),
        bindersFile: File('${root.path}/app/binders.json'),
        folderCheckInterval: Duration.zero,
      );
      await nb.load();
      if (pending) {
        final x = await nb.createPage(folderPath: extra.path);
        await nb.flush();
        await nb.open(x);
        nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
        await extra.rename('${root.path}/Elsewhere-away');
        await nb.checkFolders();
      }
      return (root, nb);
    }))!;
  }

  Future<void> tearDownNotebook(WidgetTester tester, Directory root, Notebook nb) async {
    await settleSaves(tester, nb);
    await tester.runAsync(() async {
      nb.dispose();
      await root.delete(recursive: true);
    });
  }

  testWidgets('the quit notice is shown when entries are pending, and ends when dismissed', (tester) async {
    final (root, nb) = await setUpNotebook(tester, pending: true);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    var done = false;
    late Future<void> future;
    await tester.runAsync(() async {
      future = showRecoveryNoticeOnExit(nb, key).then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('recovery-exit-notice')), findsOneWidget);
    expect(find.textContaining("1 page couldn't be saved"), findsOneWidget);
    expect(done, isFalse);
    await tester.tap(find.byKey(const ValueKey('recovery-exit-ok')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => future);
    expect(done, isTrue);
    await tearDownNotebook(tester, root, nb);
  });

  testWidgets("the quit notice lists Can't open rows as 'name: reason', like the sidebar", (tester) async {
    final (root, nb) = await setUpNotebook(tester, pending: false);
    await tester.runAsync(() async {
      final rec = await Directory('${root.path}/app/recovery').create(recursive: true);
      File('${rec.path}/bad-1.json').writeAsStringSync('{ nope');
      File('${rec.path}/bad-1.canvas').writeAsStringSync('not a page');
    });
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    late Future<void> future;
    await tester.runAsync(() async {
      future = showRecoveryNoticeOnExit(nb, key);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump();
    expect(find.text("Can't open:"), findsOneWidget);
    expect(find.textContaining("bad-1: Recovery entry can't be read"), findsOneWidget);
    expect(find.textContaining(root.path), findsNothing, reason: 'the file name, not the whole path');
    await tester.tap(find.byKey(const ValueKey('recovery-exit-ok')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => future);
    await tearDownNotebook(tester, root, nb);
  });

  testWidgets('no quit notice when nothing is pending', (tester) async {
    final (root, nb) = await setUpNotebook(tester, pending: false);
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    await tester.runAsync(() => showRecoveryNoticeOnExit(nb, key));
    await tester.pump();
    expect(find.byKey(const ValueKey('recovery-exit-notice')), findsNothing);
    await tearDownNotebook(tester, root, nb);
  });

  testWidgets('a listing that never finishes does not hold up quitting; the notice says recovery was not checked', (
    tester,
  ) async {
    final (root, base) = await setUpNotebook(tester, pending: false);
    final nb = _HangingListing(base.store, buildModules());
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
    late Future<void> future;
    await tester.runAsync(() async {
      future = showRecoveryNoticeOnExit(nb, key, listingTimeout: const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('recovery-exit-unchecked')), findsOneWidget);
    expect(find.text('Recovery could not be checked'), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-exit-notice')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('recovery-exit-ok')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => future);
    nb.dispose();
    await tearDownNotebook(tester, root, base);
  });

  for (final fails in [false, true]) {
    testWidgets(
      'a timed-out quit notice lists the in-memory notices, and a listing ${fails ? 'failing' : 'finishing'} later adds nothing',
      (tester) async {
        final (root, base) = await setUpNotebook(tester, pending: false);
        final nb = _HangingListing(base.store, buildModules())
          ..own = [
            UnreadablePage('${root.path}/pages/a.canvas', 'Saved, but the page changed right after.'),
            UnreadablePage(r'C:\x\recovery\bad-1', "Recovery entry can't be read"),
          ];
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(MaterialApp(navigatorKey: key, home: const SizedBox()));
        late Future<void> future;
        await tester.runAsync(() async {
          future = showRecoveryNoticeOnExit(nb, key, listingTimeout: const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 400));
        });
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('recovery-exit-unchecked')), findsOneWidget);
        expect(find.text("Can't open:"), findsOneWidget);
        expect(find.textContaining('a.canvas: Saved, but the page changed right after.'), findsOneWidget);
        // A Windows path shows only its last part.
        expect(find.textContaining("bad-1: Recovery entry can't be read"), findsOneWidget);
        expect(find.textContaining(r'C:\x'), findsNothing);
        // The listing settles after the timeout: no second dialog, no error.
        await tester.runAsync(() async {
          if (fails) {
            nb.listing.completeError(StateError('late'));
          } else {
            nb.listing.complete(const RecoveryListing([], []));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('recovery-exit-ok')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() => future);
        expect(find.byType(AlertDialog), findsNothing);
        nb.dispose();
        await tearDownNotebook(tester, root, base);
      },
    );
  }
}

/// A notebook whose recovery listing finishes only when told (an unresponsive
/// drive), with settable in-memory notices.
class _HangingListing extends Notebook {
  _HangingListing(super.store, super.modules)
    : super(saveDelay: const Duration(hours: 1), folderCheckInterval: Duration.zero);

  final listing = Completer<RecoveryListing>();
  List<UnreadablePage> own = const [];

  @override
  Future<RecoveryListing> pendingRecovery() => listing.future;

  @override
  List<UnreadablePage> get recoveryOwnDamaged => own;
}
