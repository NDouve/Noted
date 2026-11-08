// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The OneDrive screens (sync stage 3): the folder browser, the section of the
// hidden Microsoft entry in About, and the guard's question.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/about_dialog.dart';
import 'package:noted/src/home.dart';
import 'package:noted/src/onedrive_folder_picker.dart';
import 'package:noted/src/onedrive_sync.dart';
import 'package:noted_sync/noted_sync.dart';

import 'support/onedrive_world.dart';
import 'support/real_io.dart';

FakeFolders _tree() {
  final f = FakeFolders();
  f.children[null] = [FakeFolders.folder('D', 'Documents'), FakeFolders.folder('P', 'Pictures')];
  f.children['D'] = [
    FakeFolders.folder('N', 'Notes'),
    FakeFolders.folder('E', 'Empty'),
    FakeFolders.folder('B', 'ABinder'),
  ];
  f.hints['N'] = const FolderHint(canvasCount: 12, binderCount: 3, holdsBinderFile: false);
  f.hints['B'] = const FolderHint(canvasCount: 1, binderCount: 0, holdsBinderFile: true);
  return f;
}

void main() {
  Future<void> io(WidgetTester t, {int turns = 6}) async {
    for (var i = 0; i < turns; i++) {
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(() => realIoPause(50));
    }
    await t.pumpAndSettle();
  }

  group('the folder browser', () {
    ChosenRoot? result;
    var closed = false;

    Future<void> open(WidgetTester t, FakeFolders folders) async {
      result = null;
      closed = false;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await pickOneDriveFolder(context, folders);
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('open')));
      await t.pumpAndSettle();
    }

    String title(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('picker-title'))).data!;

    testWidgets('goes down and up, with a hint for the open folder', (t) async {
      await open(t, _tree());
      expect(title(t), 'OneDrive');
      expect(find.text('Documents'), findsOneWidget);
      expect(find.byIcon(Icons.folder_rounded), findsWidgets, reason: 'the rounded icon set');
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      expect(t.getSize(find.byKey(const ValueKey('picker-folder-D'))).height, greaterThanOrEqualTo(44));
      expect(find.text('Pictures'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('picker-hint'))).data, contains("top level of OneDrive can't be chosen"));
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNull);

      await into(t, 'D');
      expect(title(t), 'Documents');
      expect(find.text('Notes'), findsOneWidget);
      await into(t, 'N');
      expect(title(t), 'Notes');
      expect(find.text('No folders here'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('picker-hint'))).data, '12 pages, 3 binders');
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNotNull);

      await t.tap(find.byKey(const ValueKey('picker-up')));
      await t.pumpAndSettle();
      expect(title(t), 'Documents');
      await t.tap(find.byKey(const ValueKey('picker-up')));
      await t.pumpAndSettle();
      expect(title(t), 'OneDrive');
      expect(closed, isFalse);
      await t.tap(find.byKey(const ValueKey('picker-up')));
      await t.pumpAndSettle();
      expect(closed, isTrue, reason: 'up at the top closes it');
      expect(result, isNull);
    });

    testWidgets('Use this folder returns the folder, its drive and its path', (t) async {
      await open(t, _tree());
      await into(t, 'D');
      await into(t, 'N');
      await t.tap(find.byKey(const ValueKey('picker-use')));
      await t.pumpAndSettle();
      expect(closed, isTrue);
      expect(result!.itemId, 'N');
      expect(result!.driveId, 'drv1');
      expect(result!.path, 'Documents/Notes');
    });

    testWidgets('a folder that is a binder is refused', (t) async {
      await open(t, _tree());
      await into(t, 'D');
      await into(t, 'B');
      expect(find.text('This is a binder. Choose the folder that holds it.'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('picker-use'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('picker-use')), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(closed, isFalse);
      expect(result, isNull);
    });

    testWidgets('a folder with no Noted files asks first', (t) async {
      await open(t, _tree());
      await into(t, 'D');
      await into(t, 'E');
      expect(t.widget<Text>(find.byKey(const ValueKey('picker-hint'))).data, 'No Noted files');
      await t.tap(find.byKey(const ValueKey('picker-use')));
      await t.pumpAndSettle();
      expect(find.text('No Noted files here'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('picker-empty-cancel')));
      await t.pumpAndSettle();
      expect(closed, isFalse, reason: 'cancel stays in the browser');
      await t.tap(find.byKey(const ValueKey('picker-use')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('picker-empty-use')));
      await t.pumpAndSettle();
      expect(closed, isTrue);
      expect(result!.itemId, 'E');
    });

    testWidgets('a folder that cannot be listed says so and can be tried again', (t) async {
      final f = _FailingFolders();
      await open(t, f);
      expect(find.byKey(const ValueKey('picker-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('picker-hint')), findsNothing, reason: 'no top-level hint under an error');
      f.fail = false;
      f.children[null] = [FakeFolders.folder('P', 'Pictures')];
      await t.tap(find.byKey(const ValueKey('picker-retry')));
      await t.pumpAndSettle();
      expect(find.text('Pictures'), findsOneWidget);
      expect(find.byKey(const ValueKey('picker-error')), findsNothing);
    });
  });

  group('the section in About', () {
    late OneDriveWorld w;

    Future<void> build(WidgetTester t, {bool chosen = true, bool withSync = true}) async {
      await t.runAsync(() async {
        w = await OneDriveWorld.create(chosen: chosen, now: () => DateTime(2026, 11, 8, 14, 5));
        w.folders
          ..children.addAll(_tree().children)
          ..hints.addAll(_tree().hints);
        await w.sync.start();
      });
      await t.pumpWidget(
        oneDriveApp(withSync ? w.sync : null, Scaffold(body: AboutNotedDialog(microsoft: w.account))),
      );
      for (var i = 0; i < 5; i++) {
        await t.tap(find.byKey(const ValueKey('about-line')));
        await t.pump();
      }
    }

    Future<void> finish(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      w.sync.dispose();
      await t.runAsync(() async {
        w.nb.dispose();
        await w.top.delete(recursive: true);
      });
    }

    testWidgets('no folder chosen: choose one, then the path and the status show', (t) async {
      await build(t, chosen: false);
      expect(find.byKey(const ValueKey('od-choose')), findsOneWidget);
      expect(find.byKey(const ValueKey('od-check-now')), findsNothing);
      await t.tap(find.byKey(const ValueKey('od-choose')));
      await t.pumpAndSettle();
      await into(t, 'D');
      await into(t, 'N');
      await t.tap(find.byKey(const ValueKey('picker-use')));
      await io(t, turns: 40);
      expect(find.byKey(const ValueKey('od-choose')), findsNothing, reason: 'no way to pick another');
      expect(t.widget<Text>(find.byKey(const ValueKey('od-path'))).data, 'Documents/Notes');
      expect(t.widget<Text>(find.byKey(const ValueKey('od-status'))).data, 'Up to date, checked 14:05');
      expect(w.chosenFile.existsSync(), isTrue);
      await finish(t);
    });

    testWidgets('a chosen folder shows its status, Check now and the issues', (t) async {
      await build(t);
      await t.pump();
      expect(t.widget<Text>(find.byKey(const ValueKey('od-path'))).data, 'Documents/Notes');
      expect(find.byKey(const ValueKey('od-choose')), findsNothing);
      expect(find.byKey(const ValueKey('od-issues')), findsNothing);
      final before = w.runner.rounds;
      await t.tap(find.byKey(const ValueKey('od-check-now')));
      await t.pump();
      await t.runAsync(() => realIoPause(20));
      await t.pump();
      expect(w.runner.rounds, before + 1);

      w.runner.issues = [
        const SyncIssue('Work/p.canvas', 'changed on this device; OneDrive version not applied'),
        const SyncIssue('q.canvas', 'no checksum'),
      ];
      await t.runAsync(() async {
        w.runner.changed();
        await Future<void>.delayed(Duration.zero);
      });
      await t.pump();
      expect(find.text('2 issues'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('od-issues')));
      await t.pumpAndSettle();
      expect(find.text('Work/p.canvas'), findsOneWidget);
      expect(find.text('changed on this device; OneDrive version not applied'), findsOneWidget);
      expect(find.text('q.canvas'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      await finish(t);
    });

    testWidgets('the status shows why it paused', (t) async {
      await build(t);
      w.runner.status = const SyncStatus(SyncState.paused, 'Offline');
      await t.runAsync(() async {
        w.runner.changed();
        await Future<void>.delayed(Duration.zero);
      });
      await t.pump();
      expect(t.widget<Text>(find.byKey(const ValueKey('od-status'))).data, 'Paused: Offline');
      await finish(t);
    });

    testWidgets('a chosen file that cannot be read shows a paused line and no way to choose', (t) async {
      await t.runAsync(() async {
        w = await OneDriveWorld.create(chosen: false, chosenText: 'x');
        await w.sync.start();
      });
      await t.pumpWidget(oneDriveApp(w.sync, Scaffold(body: AboutNotedDialog(microsoft: w.account))));
      for (var i = 0; i < 5; i++) {
        await t.tap(find.byKey(const ValueKey('about-line')));
        await t.pump();
      }
      expect(find.byKey(const ValueKey('od-choose')), findsNothing);
      expect(t.widget<Text>(find.byKey(const ValueKey('od-status'))).data, contains("can't be read"));
      await finish(t);
    });

    testWidgets('signed out: the section is gone', (t) async {
      await build(t);
      expect(find.byKey(const ValueKey('od-section')), findsOneWidget);
      await t.runAsync(() => w.account.signOut());
      await t.pump();
      expect(find.byKey(const ValueKey('od-section')), findsNothing);
      await finish(t);
    });

    testWidgets('without a controller (desktop, or no client id) the entry has no OneDrive part', (t) async {
      await build(t, withSync: false);
      expect(find.byKey(const ValueKey('ms-section')), findsOneWidget);
      expect(find.byKey(const ValueKey('od-section')), findsNothing);
      expect(find.textContaining('OneDrive'), findsNothing);
      await finish(t);
    });
  });

  group('the guard question', () {
    late OneDriveWorld w;

    Future<void> build(WidgetTester t) async {
      await t.runAsync(() async {
        w = await OneDriveWorld.create();
        await w.sync.start();
      });
      await t.pumpWidget(oneDriveApp(w.sync, Home(notebook: w.nb)));
      await io(t);
    }

    Future<void> finish(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
        await t.runAsync(() => realIoPause(30));
      }
      w.sync.dispose();
      await t.runAsync(() async {
        w.nb.dispose();
        await w.top.delete(recursive: true);
      });
    }

    Future<void> ask(WidgetTester t, GuardQuestion q) async {
      w.runner.guardQuestion = q;
      await t.runAsync(() async {
        w.runner.changed();
        await Future<void>.delayed(Duration.zero);
      });
      await t.pumpAndSettle();
    }

    final q = GuardQuestion(['Work/a.canvas', 'Work/b.canvas']);

    testWidgets('lists the pages and Remove them here too answers yes', (t) async {
      await build(t);
      await ask(t, q);
      expect(find.text('OneDrive says 2 pages were removed.'), findsOneWidget);
      expect(find.text('Work/a.canvas'), findsOneWidget);
      expect(find.text('Work/b.canvas'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-remove')));
      await t.pumpAndSettle();
      expect(w.runner.answers, [(q, true)]);
      expect(find.byKey(const ValueKey('onedrive-guard')), findsNothing);
      await finish(t);
    });

    testWidgets('Keep them here answers no', (t) async {
      await build(t);
      await ask(t, GuardQuestion(['a.canvas']));
      expect(find.text('OneDrive says 1 page was removed.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(w.runner.answers.single.$2, isFalse);
      await finish(t);
    });

    testWidgets('it is asked once per question, and again when it comes back', (t) async {
      await build(t);
      await ask(t, q);
      await t.runAsync(() async {
        w.runner.changed();
        await Future<void>.delayed(Duration.zero);
      });
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(w.runner.answers.length, 1);
      await ask(t, q);
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget, reason: 'a new question');
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(w.runner.answers.length, 2);
      await finish(t);
    });

    testWidgets('system Back and a tap outside do not close it', (t) async {
      await build(t);
      await ask(t, q);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget, reason: 'Back');
      await t.tapAt(const Offset(2, 2));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget, reason: 'outside');
      expect(w.runner.answers, isEmpty);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(w.runner.answers.length, 1, reason: 'it can still be answered');
      await finish(t);
    });

    testWidgets('one dialog at a time: a changed question replaces it and a gone one closes it', (t) async {
      await build(t);
      await ask(t, q);
      await ask(t, GuardQuestion(['x.canvas']));
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget);
      expect(find.text('OneDrive says 1 page was removed.'), findsOneWidget);
      expect(find.text('OneDrive says 2 pages were removed.'), findsNothing);
      w.runner.guardQuestion = null;
      await t.runAsync(() async {
        w.runner.changed();
        await Future<void>.delayed(Duration.zero);
      });
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('onedrive-guard')), findsNothing);
      expect(w.runner.answers, isEmpty, reason: 'closing is not an answer');
      await finish(t);
    });

    testWidgets('keeping is the filled button, removing the destructive one, and the list scrolls', (t) async {
      await build(t);
      await ask(t, q);
      expect(t.widget(find.byKey(const ValueKey('onedrive-guard-keep'))), isA<FilledButton>());
      final remove = t.widget<OutlinedButton>(find.byKey(const ValueKey('onedrive-guard-remove')));
      expect(remove.style?.foregroundColor?.resolve({}), Theme.of(t.element(find.byKey(const ValueKey('onedrive-guard')))).colorScheme.error);
      expect(
        find.descendant(of: find.byKey(const ValueKey('onedrive-guard')), matching: find.byType(Scrollbar)),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      await finish(t);
    });

    testWidgets('an answer that cannot be saved says so, and the question is asked again', (t) async {
      await build(t);
      w.runner.answerError = StateError('disk full');
      await ask(t, q);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(find.text("Your answer couldn't be saved. OneDrive will ask again."), findsOneWidget);
      expect(w.runner.answers, isEmpty);
      expect(find.byKey(const ValueKey('onedrive-guard')), findsNothing);
      w.runner.answerError = null;
      await t.runAsync(() async {
        w.runner.changed();
        await Future<void>.delayed(Duration.zero);
      });
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget, reason: 'asked again at the next change');
      await t.tap(find.byKey(const ValueKey('onedrive-guard-keep')));
      await t.pumpAndSettle();
      expect(w.runner.answers.length, 1);
      await finish(t);
    });

    testWidgets('it shows over another screen', (t) async {
      await build(t);
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('another screen'))));
      await t.pumpAndSettle();
      expect(find.text('another screen'), findsOneWidget);
      await ask(t, q);
      expect(find.byKey(const ValueKey('onedrive-guard')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('onedrive-guard-remove')));
      await t.pumpAndSettle();
      expect(find.text('another screen'), findsOneWidget, reason: 'the screen stays');
      await finish(t);
    });
  });
}

Future<void> into(WidgetTester t, String id) async {
  await t.tap(find.byKey(ValueKey('picker-folder-$id')));
  await t.pumpAndSettle();
}

/// A source whose first listing fails.
class _FailingFolders extends FakeFolders {
  bool fail = true;

  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) async {
    if (fail) throw StateError('offline');
    return super.listFolders(parentItemId: parentItemId);
  }
}
