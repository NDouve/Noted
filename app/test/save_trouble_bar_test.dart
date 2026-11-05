// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted/src/save_trouble_bar.dart';

import 'support/trouble_world.dart';

void main() {
  late TroubleWorld w;

  setUp(() async {
    w = TroubleWorld();
    await w.init();
  });

  tearDown(() => w.dispose());

  Widget host(Widget child) => MaterialApp(
    theme: buildNotedTheme(Brightness.light, touch: false),
    home: Scaffold(body: child),
  );

  testWidgets(
    'a failing save shows the bar with Retry, Save a copy and Discard changes',
    (tester) async {
      late Notebook nb;
      await tester.runAsync(() async {
        nb = w.make(pick: () async => null);
        await w.editedPage(nb);
        w.storeFor(w.pages).failWith = accessDenied();
        await nb.flush();
      });
      await tester.pumpWidget(
        host(
          ListenableBuilder(
            listenable: nb,
            builder: (_, _) => SaveTroubleBar(notebook: nb),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('save-trouble-bar')), findsOneWidget);
      expect(
        find.textContaining("Couldn't save this page: Access is denied"),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('save-trouble-retry')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-trouble-discard')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('save-trouble-text')), findsNothing);
      // Retry with the failure gone clears the bar.
      await tester.runAsync(() async {
        w.storeFor(w.pages).failWith = null;
        await nb.retrySave();
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('save-trouble-bar')), findsNothing);
    },
  );

  testWidgets(
    'when recovery fails too the warning stays, names the cause, and expands to the advice',
    (tester) async {
      late Notebook nb;
      await tester.runAsync(() async {
        nb = w.make(pick: () async => null);
        await w.editedPage(nb);
        // The recovery folder is a file: nothing can be written there.
        w.rec.parent.createSync(recursive: true);
        File(w.rec.path).writeAsStringSync('in the way');
        w.storeFor(w.pages).failWith = accessDenied();
        await nb.flush();
        await Future<void>.delayed(
          const Duration(milliseconds: 300),
        ); // the cause check
      });
      await tester.pumpWidget(
        host(
          ListenableBuilder(
            listenable: nb,
            builder: (_, _) => SaveTroubleBar(notebook: nb),
          ),
        ),
      );
      expect(
        find.textContaining("Noted can't save anything on this computer"),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('save-trouble-cause')), findsOneWidget);
      expect(find.byKey(const ValueKey('save-trouble-advice')), findsNothing);
      expect(find.byKey(const ValueKey('save-trouble-copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('save-trouble-text')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('save-trouble-expand')));
      await tester.pump();
      expect(find.byKey(const ValueKey('save-trouble-advice')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('save-trouble-expand')));
      await tester.pump();
      expect(find.byKey(const ValueKey('save-trouble-advice')), findsNothing);
      expect(
        find.byKey(const ValueKey('save-trouble-bar')),
        findsOneWidget,
        reason: 'collapsing keeps the warning',
      );
    },
  );

  testWidgets(
    'the question "Your changes will be lost" has Cancel as the default and the filled button',
    (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const SizedBox()),
      );
      final answer = showTroubleQuestion(
        key,
        UserQuestion.leaveAndLose,
        'Notes',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Your changes will be lost'), findsOneWidget);
      final cancel = tester.widget<FilledButton>(
        find.byKey(const ValueKey('trouble-question-cancel')),
      );
      expect(cancel.autofocus, isTrue);
      await tester.tap(find.byKey(const ValueKey('trouble-question-cancel')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await answer, isFalse);
    },
  );

  testWidgets('the kept-changes notice lasts about 30 seconds and has Show', (
    tester,
  ) async {
    var shown = false;
    final bar = keptNoticeBar(
      const KeptNotice(pageId: 'p', title: 'T', reason: 'it is locked'),
      () => shown = true,
    );
    expect(bar.duration, const Duration(seconds: 30));
    expect(bar.action!.label, 'Show');
    bar.action!.onPressed();
    expect(shown, isTrue);
  });

  testWidgets('"Noted is already open." has Quit', (tester) async {
    await tester.pumpWidget(const AlreadyOpenApp());
    expect(find.text('Noted is already open.'), findsOneWidget);
    expect(find.byKey(const ValueKey('already-open-quit')), findsOneWidget);
  });
}
