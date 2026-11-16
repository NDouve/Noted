// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted/src/menu_bar.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/page_title_field.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted/src/status_strip.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/settle_saves.dart';
import 'support/shell_world.dart';
import 'support/trouble_world.dart';

// Step 5 of the UI follow-up: the toolbar under the menu bar, the title inside
// the canvas column, the status strip, and the Details toggle in the menu bar.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Rect rect(WidgetTester t, Finder f) => t.getRect(f);
  final menuBar = find.byType(AppMenuBar);
  final toolbar = find.byType(CommandToolbar);
  final panel = find.byKey(const ValueKey('context-panel-inline'));
  final strip = find.byKey(const ValueKey('status-strip'));
  final toggle = find.byKey(const ValueKey('details-toggle'));
  final breadcrumb = find.byKey(const ValueKey('breadcrumb'));

  group('desktop at 1440', () {
    testWidgets('rows, columns and the title line up', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1440, 900));
      final bar = rect(t, menuBar);
      expect(bar.height, 36);
      final tools = rect(t, toolbar);
      // The toolbar runs from the tree to the window edge, under the menu bar.
      expect(tools.left, rect(t, find.byType(VerticalDivider).first).right);
      expect(tools.right, 1440);
      expect(tools.top, bar.bottom);
      // Details runs from the toolbar to the window bottom; the strip is left of it.
      final p = rect(t, panel);
      final s = rect(t, strip);
      expect(p.top, tools.bottom);
      expect(p.bottom, 900, reason: 'Details runs beside the strip');
      expect(s.height, 34);
      expect(s.bottom, 900);
      expect(s.left, tools.left);
      expect(s.right, p.left);
      // The title is in the canvas column: 32 in, 16 down, under the breadcrumb.
      final crumb = rect(t, breadcrumb);
      expect(crumb.left, tools.left + 32);
      expect(crumb.top, tools.bottom + 16);
      expect(crumb.right, lessThanOrEqualTo(p.left));
      final title = rect(t, find.byType(PageTitleField));
      expect(title.left, tools.left + 32);
      expect(
        title.top,
        closeTo(crumb.bottom + 12, 0.5),
        reason: '12 px between the breadcrumb and the title',
      );
      expect(
        title.bottom,
        lessThanOrEqualTo(rect(t, find.byKey(PageCanvas.overlayKey)).top),
      );
      expect(find.text('Pages / Alpha'), findsOneWidget);
      // The old title row's controls are gone.
      expect(find.byKey(const ValueKey('page-settings')), findsNothing);
      expect(find.byKey(const ValueKey('sidebar-menu')), findsNothing);
      await w.close(t);
    });

    testWidgets(
      'the Details toggle is at the right end of the menu bar and shows and hides the panel',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1440, 900));
        final bar = rect(t, menuBar);
        final b = rect(t, toggle);
        expect(b.right, 1440 - 16);
        expect(b.top, greaterThanOrEqualTo(bar.top));
        expect(b.bottom, lessThanOrEqualTo(bar.bottom));
        final scheme = Theme.of(t.element(toggle)).colorScheme;
        Material face() => t.widget<Material>(
          find.descendant(of: toggle, matching: find.byType(Material)).first,
        );
        expect(panel, findsOneWidget);
        expect(face().color, scheme.primaryContainer);
        expect(t.semantics.find(toggle), isNotNull);

        await t.tap(toggle);
        await w.settle(t);
        expect(panel, findsNothing);
        expect(face().color, scheme.surface);
        // The toolbar and the strip take the room.
        expect(rect(t, toolbar).right, 1440);
        await t.tap(toggle);
        await w.settle(t);
        expect(panel, findsOneWidget);
        expect(face().color, scheme.primaryContainer);
        await w.close(t);
      },
    );

    testWidgets('the Contextual toolbar sits in the same place', (t) async {
      final w = await ShellWorld.open(
        t,
        size: const Size(1440, 900),
        toolbar: ToolbarStyle.contextual,
      );
      final tools = rect(t, toolbar);
      expect(tools.top, rect(t, menuBar).bottom);
      expect(tools.right, 1440);
      expect(rect(t, panel).top, tools.bottom);
      expect(rect(t, breadcrumb).top, tools.bottom + 16);
      await w.close(t);
    });

    testWidgets('a healthy page leaves the status strip empty', (t) async {
      final w = await ShellWorld.open(t, size: const Size(1440, 900));
      expect(find.byKey(const ValueKey('status-strip-text')), findsNothing);
      expect(StatusStrip.textFor(w.nb), isNull);
      await w.close(t);
    });

    testWidgets(
      'files dropped on the viewport make a box; drops on the header, strip and panel do not',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1440, 900));
        final file = File('${w.dir.path}/dropped.pdf')
          ..writeAsBytesSync([1, 2, 3]);
        final target = t.widget<DropTarget>(find.byType(DropTarget));
        Future<void> dropAt(Offset at) async {
          await t.runAsync(() async {
            target.onDragDone!(
              DropDoneDetails(
                files: [DropItemFile(file.path)],
                localPosition: at,
                globalPosition: at,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 200));
          });
          await w.settle(t);
        }

        int boxes() => w.nb.current!.page.nodes.whereType<BoxRecord>().length;
        await dropAt(rect(t, strip).center);
        await dropAt(rect(t, breadcrumb).center);
        await dropAt(rect(t, panel).center);
        await dropAt(rect(t, toolbar).center);
        expect(boxes(), 0);
        await dropAt(rect(t, find.byKey(PageCanvas.overlayKey)).center);
        expect(boxes(), 1);
        await w.close(t);
      },
    );

    testWidgets(
      'at 1000 px a drop on the open Details overlay or its scrim makes no box',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1000, 800));
        final file = File('${w.dir.path}/dropped.pdf')
          ..writeAsBytesSync([1, 2, 3]);
        final target = t.widget<DropTarget>(find.byType(DropTarget));
        Future<void> dropAt(Offset at) async {
          await t.runAsync(() async {
            target.onDragDone!(
              DropDoneDetails(
                files: [DropItemFile(file.path)],
                localPosition: at,
                globalPosition: at,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 200));
          });
          await w.settle(t);
        }

        int boxes() => w.nb.current!.page.nodes.whereType<BoxRecord>().length;
        final view = rect(t, find.byKey(PageCanvas.overlayKey));
        await t.tap(toggle);
        await w.settle(t);
        expect(
          find.byKey(const ValueKey('context-panel-inline')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('panel-header-title')),
          findsOneWidget,
          reason: 'the overlay is open',
        );
        await dropAt(
          rect(t, find.byKey(const ValueKey('panel-header-title'))).center,
        );
        await dropAt(view.centerLeft + const Offset(40, 0));
        expect(boxes(), 0);
        await t.tap(toggle);
        await w.settle(t);
        expect(find.byKey(const ValueKey('panel-header-title')), findsNothing);
        await dropAt(view.center);
        expect(boxes(), 1);
        await w.close(t);
      },
    );

    testWidgets('keys typed in the title do not reach the canvas commands', (
      t,
    ) async {
      final w = await ShellWorld.open(t, size: const Size(1440, 900));
      await w.addNote(t, 'a', 'one');
      await w.addNote(t, 'b', 'two', at: const Bounds(100, 300, 300, 40));
      w.nb.current!.select('a');
      await t.pump();
      List<String> order() =>
          w.nb.current!.page.nodes.map((n) => n.id).toList();
      final before = order();
      await t.tap(find.byKey(const ValueKey('page-title-field')));
      await t.pump();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('page-title-field')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      // P (Pen), Ctrl+Shift+] (bring to front) and Escape (leave the tool,
      // then clear the selection) belong to the canvas, not to the title.
      await t.sendKeyEvent(LogicalKeyboardKey.keyP);
      await t.pump();
      expect(w.nb.tools.active, isNull);
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pump();
      expect(order(), before);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(w.nb.current!.selectedId, 'a');
      // The field still takes its text.
      await t.enterText(find.byKey(const ValueKey('page-title-field')), 'Pen');
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('page-title-field')))
            .controller!
            .text,
        'Pen',
      );
      await w.close(t);
    });

    testWidgets(
      'the title is edited in its new place and the rename is saved',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(1440, 900));
        await t.enterText(
          find.byKey(const ValueKey('page-title-field')),
          'Renamed',
        );
        await t.testTextInput.receiveAction(TextInputAction.done);
        await w.settle(t);
        expect(w.nb.current!.page.meta.title, 'Renamed');
        expect(find.text('Pages / Renamed'), findsOneWidget);
        await w.close(t);
      },
    );
  });

  group('a read-only page', () {
    late Directory dir;
    late Notebook nb;

    testWidgets(
      'the banner is a full-width band under the title and the strip says so',
      (t) async {
        t.view.physicalSize = const Size(1440, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        late String page;
        await t.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('noted_shell_ro');
          final folder = await Directory('${dir.path}/Work').create();
          Notebook make() => Notebook(
            PageStore(Directory('${dir.path}/pages')..createSync()),
            buildModules(),
            saveDelay: Duration.zero,
            bindersFile: File('${dir.path}/binders.json'),
          );
          final first = make();
          await first.load();
          final b = await first.addBinder(folder.path);
          page = await first.createPage(binderPath: b.path);
          await first.flush();
          first.dispose();
          File('${folder.path}/$binderFileName')
              .writeAsStringSync('{ not json');
          nb = make();
          await nb.load();
          await nb.open(page);
        });
        await t.pumpWidget(
          NotedApp(
            notebook: nb,
            settings: AppSettings(File('${dir.path}/settings.json')),
          ),
        );
        await t.pump();
        await t.pump();

        final banner = find.byKey(const ValueKey('read-only-banner'));
        expect(banner, findsOneWidget);
        final title = rect(t, find.byType(PageTitleField));
        final band = rect(t, banner);
        final tools = rect(t, toolbar);
        // Below the title, as wide as the canvas column (Details is docked).
        expect(band.top, greaterThanOrEqualTo(title.bottom));
        expect(band.left, tools.left);
        expect(band.right, rect(t, panel).left);
        expect(
          band.bottom,
          lessThanOrEqualTo(rect(t, find.byKey(PageCanvas.overlayKey)).top),
        );
        expect(find.byKey(const ValueKey('page-settings')), findsNothing);
        // The strip names the state.
        final text = t
            .widget<Text>(find.byKey(const ValueKey('status-strip-text')))
            .data!;
        expect(text, startsWith('Read-only: '));
        expect(rect(t, strip).height, 34);

        await t.pumpWidget(const SizedBox());
        await settleSaves(t, nb);
        await t.runAsync(() async {
          nb.dispose();
          await dir.delete(recursive: true);
        });
      },
    );
  });

  group('desktop below the desktop width', () {
    testWidgets(
      'keeps the header row: drawer button, title and page settings, no breadcrumb or strip',
      (t) async {
        final w = await ShellWorld.open(t, size: const Size(700, 800));
        expect(find.byKey(const ValueKey('sidebar-menu')), findsOneWidget);
        expect(find.byKey(const ValueKey('page-settings')), findsOneWidget);
        expect(find.byType(PageTitleField), findsOneWidget);
        expect(breadcrumb, findsNothing);
        expect(strip, findsNothing);
        // The title is above the toolbar, as it was.
        expect(
          rect(t, find.byType(PageTitleField)).bottom,
          lessThanOrEqualTo(rect(t, toolbar).top),
        );

        await t.tap(find.byKey(const ValueKey('page-settings')));
        await w.settle(t);
        expect(find.byType(SettingsPanel), findsOneWidget);
        await t.tapAt(const Offset(5, 5));
        await w.settle(t);
        await t.tap(find.byKey(const ValueKey('sidebar-menu')));
        await t.pumpAndSettle();
        expect(find.text('Beta'), findsOneWidget);
        await w.close(t);
      },
    );
  });

  group('mobile target', () {
    Future<(Directory, Notebook)> mobile(WidgetTester t, double width) async {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      late Directory dir;
      late Notebook nb;
      await t.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('noted_shell_mobile');
        nb = Notebook(
          PageStore(Directory('${dir.path}/pages')..createSync()),
          buildModules(),
          saveDelay: Duration.zero,
        );
        await nb.load();
        await nb.rename(nb.currentId!, 'Alpha');
      });
      await t.pumpWidget(NotedApp(notebook: nb));
      await t.pump();
      return (dir, nb);
    }

    Future<void> done(WidgetTester t, Directory dir, Notebook nb) async {
      await t.pumpWidget(const SizedBox());
      await settleSaves(t, nb);
      await t.runAsync(() async {
        nb.dispose();
        await dir.delete(recursive: true);
      });
      // Before the test ends: the framework checks the override then.
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets(
      '800 wide: the drawer button and page settings are in the header row',
      (t) async {
        final (dir, nb) = await mobile(t, 800);
        expect(breadcrumb, findsNothing);
        expect(strip, findsNothing);
        expect(toggle, findsNothing);
        await t.tap(find.byKey(const ValueKey('sidebar-menu')));
        await t.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);
        await t.tapAt(const Offset(790, 400));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('page-settings')));
        await t.pumpAndSettle();
        expect(find.byType(SettingsPanel), findsOneWidget);
        await t.tapAt(const Offset(5, 5));
        await t.pumpAndSettle();
        await done(t, dir, nb);
      },
    );

    testWidgets(
      '1200 wide: page settings stays in the header row, the tree is inline',
      (t) async {
        final (dir, nb) = await mobile(t, 1200);
        expect(breadcrumb, findsNothing);
        expect(strip, findsNothing);
        expect(find.byKey(const ValueKey('page-settings')), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('page-settings')));
        await t.pumpAndSettle();
        expect(find.byType(SettingsPanel), findsOneWidget);
        await t.tapAt(const Offset(5, 5));
        await t.pumpAndSettle();
        await done(t, dir, nb);
      },
    );
  });

  // The strip's save-trouble lines, their precedence over the read-only
  // reason, and the way back to an empty strip.
  group('the status strip under save trouble', () {
    late TroubleWorld tw;

    setUp(() async {
      tw = TroubleWorld();
      await tw.init();
    });
    tearDown(() => tw.dispose());

    Widget host(Notebook nb) => MaterialApp(
      theme: buildNotedTheme(Brightness.light, touch: false),
      home: Scaffold(body: StatusStrip(notebook: nb)),
    );

    String? line(WidgetTester t) {
      final f = find.byKey(const ValueKey('status-strip-text'));
      return f.evaluate().isEmpty ? null : t.widget<Text>(f).data;
    }

    testWidgets('a save that fails, then a retry that works', (t) async {
      late Notebook nb;
      await t.runAsync(() async {
        nb = tw.make(pick: () async => null);
        await tw.editedPage(nb);
        tw.storeFor(tw.pages).failWith = accessDenied();
        await nb.flush();
      });
      await t.pumpWidget(host(nb));
      expect(nb.trouble.kind, TroubleKind.failing);
      expect(line(t), "Couldn't save this page");
      await t.runAsync(() async {
        tw.storeFor(tw.pages).failWith = null;
        await nb.retrySave();
      });
      await t.pump();
      expect(nb.trouble.isTrouble, isFalse);
      expect(line(t), isNull);
    });

    testWidgets('a save and a recovery write that both fail', (t) async {
      late Notebook nb;
      await t.runAsync(() async {
        nb = tw.make(pick: () async => null);
        await tw.editedPage(nb);
        tw.rec.parent.createSync(recursive: true);
        File(tw.rec.path).writeAsStringSync('in the way');
        tw.storeFor(tw.pages).failWith = accessDenied();
        await nb.flush();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pumpWidget(host(nb));
      expect(nb.trouble.kind, TroubleKind.recoveryFailing);
      expect(line(t), 'Changes exist only on screen');
    });

    testWidgets(
      'kept changes shown as a preview win over the read-only reason, and the strip empties when they land',
      (t) async {
        late Notebook nb;
        late String id;
        await t.runAsync(() async {
          nb = tw.make(
            backoffFirst: const Duration(milliseconds: 20),
            backoffMax: const Duration(milliseconds: 20),
          );
          id = await tw.editedPage(nb);
          tw.storeFor(tw.pages).failWith = accessDenied();
          await nb.flush();
          await nb.createPage();
          await nb.open(id);
        });
        await t.pumpWidget(host(nb));
        expect(nb.trouble.kind, TroubleKind.preview);
        expect(
          nb.readOnlyReason,
          isNotNull,
          reason: 'a preview is also read-only',
        );
        expect(line(t), "Kept changes haven't been saved to this page");
        expect(line(t), isNot(startsWith('Read-only')));
        await t.runAsync(() async {
          tw.storeFor(tw.pages).failWith = null;
          for (
            var i = 0;
            i < 100 && nb.trouble.kind != TroubleKind.saved;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        });
        await t.pump();
        expect(nb.trouble.kind, TroubleKind.saved);
        expect(nb.readOnlyReason, isNull);
        expect(line(t), isNull);
      },
    );
  });
}
