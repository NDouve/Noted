// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/binder_colors.dart' show binderSidebarColor;
import 'package:noted/src/binder_cover.dart' show parseBinderColor;
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_notice.dart';
import 'package:noted_core/noted_core.dart';

import '../support/harness.dart';
import '../support/note_helpers.dart';

final _sep = Platform.pathSeparator;

Future<void> _drag(Session s, Offset from, Offset to) async {
  final t = s.tester;
  final g = await t.startGesture(from);
  await t.pump(kLongPressTimeout + const Duration(milliseconds: 150));
  await g.moveTo(from + const Offset(0, 4));
  await t.pump(const Duration(milliseconds: 50));
  await g.moveTo(to);
  await t.pump(const Duration(milliseconds: 50));
  await g.moveTo(to + const Offset(0, 0.5));
  await t.pump(const Duration(milliseconds: 50));
  await g.up();
  await s.pump(600);
}

Future<void> _pagesMenu(Session s, String item) async {
  await s.tapKey('pages-menu', settle: 500);
  await s.tapText(item, settle: 700);
}

Future<void> _gearItem(Session s, String key) async {
  await s.tapKey('settings-menu', settle: 500);
  await s.tapKey(key, settle: 700);
}

/// Checklist steps 18-30, 109-118, 128-130, 139-142, 182, 202-205
/// (folders, binders, missing folders, recovery).
void foldersBindersSuite() {
  group('folders and binders', () {
    testWidgets('step 018-020, 205: default page folder from the gear; subpages stay with their parent', (t) async {
      await withSession(t, 'defaultfolder', (s) async {
        final extra = s.env.folder('Elsewhere');
        final first = s.nb.currentId!;
        s.pickAnswer = extra.path;
        await _gearItem(s, 'settings-default-page-folder');
        expect(s.picks, 1);
        expect(s.nb.newPageFolderPath, isNotEmpty);
        await t.tap(find.byTooltip('New page'));
        await s.until(() => s.canvasFiles(extra).length == 1, what: 'page in the chosen folder');
        final id = s.nb.currentId!;
        expect(s.hasPageFile(extra, id), isTrue);
        expect(s.hasPageFile(s.env.pages, id), isFalse);
        // A second top-level page also goes there (no dialog lists folders).
        expect(find.byType(AlertDialog), findsNothing);
        // A subpage of a page in the built-in folder stays in that folder.
        final sub = await s.nb.createPage(parentId: first);
        expect(s.hasPageFile(s.env.pages, sub), isTrue);
        // A subpage of the page in the chosen folder lands beside its parent.
        final sub2 = await s.nb.createPage(parentId: id);
        expect(s.hasPageFile(extra, sub2), isTrue);
        // The choice is remembered across a restart.
        await s.flush();
        final saved = jsonDecode(s.env.settingsFile.readAsStringSync()) as Map<String, Object?>;
        expect(saved['defaultPageFolder'], isNotNull);
        await s.restart();
        await t.tap(find.byTooltip('New page'));
        await s.until(() => s.canvasFiles(extra).length == 3, what: 'page in the chosen folder after restart');
      });
    });

    testWidgets('step 021: a binder folder cannot be used as a standalone folder', (t) async {
      await withSession(t, 'binderfolder', (s) async {
        final bin = s.env.folder('Work');
        await s.nb.addBinder(bin.path);
        await s.pump(300);
        s.pickAnswer = bin.path;
        await _gearItem(s, 'settings-default-page-folder');
        await s.until(() => find.textContaining('holds a binder').evaluate().isNotEmpty, what: 'error message');
        expect(s.settings.defaultPageFolder, isNull);
        expect(s.canvasFiles(bin), isEmpty);
        // Move to folder refuses it too.
        final id = s.nb.tree.roots.first.id;
        await s.pageMenu(id, 'Move to folder…');
        await s.until(() => s.picks >= 2, what: 'second pick');
        expect(s.canvasFiles(bin), isEmpty);
        expect(s.hasPageFile(s.env.pages, id), isTrue);
      });
    });

    testWidgets('step 204: Move to folder moves a page and its subpages', (t) async {
      await withSession(t, 'movetofolder', (s) async {
        final extra = s.env.folder('NewHome');
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Mover');
        final b = await s.newPage('Child', parentId: a);
        await s.flush();
        s.pickAnswer = extra.path;
        await s.pageMenu(a, 'Move to folder…');
        await s.until(() => s.hasPageFile(extra, a) && s.hasPageFile(extra, b), what: 'files moved');
        expect(s.hasPageFile(s.env.pages, a), isFalse);
        expect(s.hasPageFile(s.env.pages, b), isFalse);
        expect(s.kids(a), [b]);
        expect(s.nb.standaloneFolders.single.path.toLowerCase(), extra.path.toLowerCase().replaceAll('/', r'\'));
      });
    });

    testWidgets('step 109-111: dropping a default-folder page onto a page of a second folder moves its files', (t) async {
      await withSession(t, 'secondfolder', (s) async {
        final second = s.env.folder('Second');
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Home page');
        final mover = await s.newPage('Mover');
        final moverKid = await s.newPage('Mover kid', parentId: mover);
        final host = await s.nb.createPage(folderPath: second.path);
        await s.nb.rename(host, 'Host');
        await s.flush();
        await s.pump(300);
        expect(s.hasPageFile(second, host), isTrue);
        final r = t.getRect(s.row(host));
        await _drag(s, t.getTopLeft(s.row(mover)) + const Offset(60, 18), Offset(r.left + 80, r.top + r.height * 0.5));
        await s.until(() => s.hasPageFile(second, mover), what: 'moved file');
        expect(s.kids(host), [mover]);
        expect(s.hasPageFile(s.env.pages, mover), isFalse);
        // 111: the subpages' files move too.
        expect(s.hasPageFile(second, moverKid), isTrue);
        expect(s.hasPageFile(s.env.pages, moverKid), isFalse);
        expect(s.hasPageFile(s.env.pages, a), isTrue);
      });
    });

    testWidgets('step 022-026, 030: binder lifecycle from the Pages menu: cover, color, new page, remove, reopen', (t) async {
      await withSession(t, 'binder', (s) async {
        await _pagesMenu(s, 'New binder');
        await s.until(() => s.nb.binders.length == 1, what: 'binder');
        final b = s.nb.binders.single;
        expect(find.text('Binder cover'), findsOneWidget);
        expect(s.picks, 0);
        // 023: edit the cover fields.
        await t.enterText(find.byKey(const ValueKey('cover-title')), 'Projects');
        await t.enterText(find.byKey(const ValueKey('cover-owner')), 'Sam');
        await t.enterText(find.byKey(const ValueKey('cover-description')), 'All my work');
        await t.tap(find.byKey(const ValueKey('cover-title')));
        await s.pump(300);
        // 024: a color swatch changes the stripe.
        final hex = binderPalette[4];
        await t.tap(find.byKey(ValueKey('cover-color-$hex')));
        await s.pump(600);
        await s.flush();
        final saved = (await BinderStore(Directory(b.path)).read() as BinderFound).binder;
        expect([saved.title, saved.owner, saved.description, saved.color], ['Projects', 'Sam', 'All my work', hex]);
        expect(find.text('PROJECTS'), findsOneWidget);
        final stripeFinder = find.byKey(ValueKey('binder-stripe-${b.path}'));
        final stripe = t.widget<Container>(stripeFinder);
        expect((stripe.decoration! as BoxDecoration).color, binderSidebarColor(t.element(stripeFinder), hex));
        expect(parseBinderColor(hex), isNot(parseBinderColor(binderPalette.first)));
        // 025: last edited is shown.
        expect(find.byKey(const ValueKey('cover-last-edited')), findsOneWidget);
        // 026: New page in the binder menu, no dialog.
        await s.tapKey('binder-menu-${b.path}', settle: 500);
        await s.tapText('New page', settle: 700);
        await s.until(() => s.canvasFiles(Directory(b.path)).length == 1, what: 'binder page');
        expect(find.byType(AlertDialog), findsNothing);
        // 029: Remove from sidebar asks, keeps the files.
        await s.tapKey('binder-menu-${b.path}', settle: 500);
        await s.tapText('Remove from sidebar', settle: 600);
        expect(find.text('Remove binder from sidebar?'), findsOneWidget);
        await s.tapText('Remove', settle: 700);
        expect(s.nb.binders, isEmpty);
        expect(File('${b.path}$_sep$binderFileName').existsSync(), isTrue);
        expect(s.canvasFiles(Directory(b.path)), hasLength(1));
        // 030: choosing that folder again reopens the binder unchanged.
        s.pickAnswer = b.path;
        await _pagesMenu(s, 'New binder in another folder…');
        await s.until(() => s.nb.binders.length == 1, what: 'binder again');
        expect(s.nb.binders.single.title, 'Projects');
        expect(s.nb.binders.single.binder!.color, hex);
        expect(s.nb.binders.single.binder!.description, 'All my work');
      });
    });

    testWidgets('step 202-203: New binder is named "New binder" with the title selected; the next is "New binder 2"', (t) async {
      await withSession(t, 'binders2', (s) async {
        await _pagesMenu(s, 'New binder');
        await s.until(() => s.nb.binders.length == 1, what: 'first binder');
        expect(s.nb.binders.single.title, 'New binder');
        final title = t.widget<TextField>(find.byKey(const ValueKey('cover-title')));
        expect(title.focusNode!.hasFocus, isTrue);
        expect(title.controller!.text, 'New binder');
        await _pagesMenu(s, 'New binder');
        await s.until(() => s.nb.binders.length == 2, what: 'second binder');
        final names = s.nb.binders.map((b) => b.path.split(RegExp(r'[\\/]')).last).toList();
        expect(names, ['New binder', 'New binder 2']);
        expect(s.nb.binders.last.title, 'New binder 2');
      });
    });

    testWidgets('step 027-028: dragging a page onto a binder header moves it in; back onto Pages moves it out with its subpages', (t) async {
      await withSession(t, 'binderdrag', (s) async {
        final folder = s.env.folder('Work');
        final binder = await s.nb.addBinder(folder.path);
        final a = s.nb.currentId!;
        await s.nb.rename(a, 'Alpha');
        final m = await s.newPage('Mover');
        final mk = await s.newPage('Mover kid', parentId: m);
        await s.flush();
        await s.pump(300);
        final header = t.getCenter(find.byKey(ValueKey('binder-header-${binder.path}')));
        await _drag(s, t.getTopLeft(s.row(m)) + const Offset(60, 18), header);
        await s.until(() => s.hasPageFile(folder, m), what: 'page in binder folder');
        expect(s.hasPageFile(s.env.pages, m), isFalse);
        expect(s.hasPageFile(folder, mk), isTrue);
        final pagesHeader = t.getCenter(find.byKey(const ValueKey('pages-header')));
        await _drag(s, t.getTopLeft(s.row(m)) + const Offset(60, 18), pagesHeader);
        await s.until(() => s.hasPageFile(s.env.pages, m), what: 'page back in pages');
        expect(s.hasPageFile(folder, m), isFalse);
        expect(s.hasPageFile(s.env.pages, mk), isTrue);
      });
    });

    testWidgets('step 112-116: binder file renamed, damaged and restored', (t) async {
      late Directory folder;
      late String inB;
      await withSession(
        t,
        'binderfile',
        (s) async {
          BinderSection binder() => s.nb.binders.single;
          inB = binder().tree.roots.first.id;
          final file = File('${folder.path}$_sep$binderFileName');
          final bak = File('${file.path}.bak');
          // 112: renamed: unavailable.
          file.renameSync(bak.path);
          await s.until(() => binder().status == BinderStatus.unavailable, what: 'unavailable');
          await s.until(() => find.text('On another device').evaluate().isNotEmpty, what: 'label');
          // 113: renamed back.
          bak.renameSync(file.path);
          await s.until(() => binder().status == BinderStatus.available, what: 'available again');
          expect(find.text('On another device'), findsNothing);
          // 114: first "{" deleted.
          final text = file.readAsStringSync();
          file.writeAsStringSync(text.replaceFirst('{', ''));
          await s.until(() => binder().status == BinderStatus.unreadable, what: 'unreadable');
          expect(find.text("Binder file can't be read"), findsOneWidget);
          // 115: its page opens read-only, with a banner; typing does nothing.
          await t.tap(find.byKey(ValueKey('page-row-$inB')));
          await s.pump(600);
          expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
          expect(s.nb.current!.readOnly, isTrue);
          await t.tapAt(toScreen(t, const Offset(600, 300)));
          await s.pump(300);
          expect(s.nb.current!.page.nodes, isEmpty);
          // 116: restored.
          file.writeAsStringSync(text);
          await s.until(() => binder().status == BinderStatus.available, what: 'readable again');
          await s.until(() => find.byKey(const ValueKey('read-only-banner')).evaluate().isEmpty, what: 'banner gone');
          expect(s.nb.current!.readOnly, isFalse);
        },
        prepare: (env) async {
          folder = env.folder('Work');
          final nb = Notebook(PageStore(env.pages), buildModules(), bindersFile: env.binders, recoveryDirectory: env.recovery);
          await nb.load();
          final sec = await nb.addBinder(folder.path);
          final p = await nb.createPage(binderPath: sec.path);
          await nb.rename(p, 'Inside');
          await nb.flush();
          nb.dispose();
        },
        watchFiles: true,
        folderCheckInterval: const Duration(milliseconds: 400),
      );
    });

    testWidgets('step 117-118: a standalone folder moved away makes its pages read-only; back, editable', (t) async {
      late Directory second;
      late String pageId;
      await withSession(
        t,
        'folderaway',
        (s) async {
          pageId = s.nb.tree.roots.firstWhere((p) => p.title == 'Far page').id;
          await s.nb.open(pageId);
          await s.pump(400);
          expect(s.nb.current!.readOnly, isFalse);
          final away = Directory('${second.path}-away');
          second.renameSync(away.path);
          await s.until(() => find.text('On another device').evaluate().isNotEmpty, what: 'folder unavailable');
          await s.until(() => s.nb.current!.readOnly, what: 'open page read-only');
          expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
          away.renameSync(second.path);
          await s.until(() => find.text('On another device').evaluate().isEmpty, what: 'folder back');
          await s.until(() => !s.nb.current!.readOnly, what: 'editable again');
          expect(find.byKey(const ValueKey('read-only-banner')), findsNothing);
        },
        prepare: (env) async {
          second = env.folder('Second');
          final nb = Notebook(PageStore(env.pages), buildModules(), bindersFile: env.binders, recoveryDirectory: env.recovery);
          await nb.load();
          final id = await nb.createPage(folderPath: second.path);
          await nb.rename(id, 'Far page');
          await nb.flush();
          nb.dispose();
        },
        watchFiles: true,
        folderCheckInterval: const Duration(milliseconds: 400),
      );
    });

    testWidgets('step 128-130: a binder folder moved away greys its pages and makes the open page read-only; back restores', (t) async {
      late Directory folder;
      late String inB;
      await withSession(
        t,
        'binderaway',
        (s) async {
          BinderSection binder() => s.nb.binders.single;
          inB = binder().tree.roots.first.id;
          await s.nb.open(inB);
          await s.pump(300);
          await putNote(s, 'keep me');
          await s.flush();
          final away = Directory('${folder.path}-away');
          folder.renameSync(away.path);
          await s.until(() => binder().status == BinderStatus.unavailable, what: 'binder unavailable');
          await s.until(() => s.nb.current!.readOnly, what: 'read-only');
          expect(find.text('On another device'), findsOneWidget);
          expect(find.byKey(const ValueKey('read-only-banner')), findsOneWidget);
          // 129: typing does nothing.
          await t.tapAt(toScreen(t, const Offset(700, 400)));
          await s.pump(300);
          expect(s.nb.current!.page.nodes.whereType<BoxRecord>(), hasLength(1));
          away.renameSync(folder.path);
          await s.until(() => binder().status == BinderStatus.available, what: 'binder back');
          await s.until(() => !s.nb.current!.readOnly, what: 'editable');
          expect(s.nb.current!.page.nodes.whereType<BoxRecord>().single.snapshotText, 'keep me');
        },
        prepare: (env) async {
          folder = env.folder('Work');
          final nb = Notebook(PageStore(env.pages), buildModules(), bindersFile: env.binders, recoveryDirectory: env.recovery);
          await nb.load();
          final sec = await nb.addBinder(folder.path);
          final p = await nb.createPage(binderPath: sec.path);
          await nb.rename(p, 'Inside');
          await nb.flush();
          nb.dispose();
        },
        watchFiles: true,
        folderCheckInterval: const Duration(milliseconds: 400),
      );
    });

    testWidgets('step 139-142: an edit in a vanished folder is kept for recovery and saved when the folder is back', (t) async {
      late Directory second;
      late String pageId;
      final env = await Env.create('recovery');
      final s = Session(t, env);
      try {
        second = env.folder('Second');
        final pre = Notebook(PageStore(env.pages), buildModules(), bindersFile: env.binders, recoveryDirectory: env.recovery);
        await pre.load();
        pageId = await pre.createPage(folderPath: second.path);
        await pre.rename(pageId, 'Far page');
        await pre.flush();
        pre.dispose();
        await s.launch(watchFiles: true, folderCheckInterval: const Duration(milliseconds: 400));
        await s.nb.open(pageId);
        await s.pump(300);
        addNote(s, [para('typed just before')]);
        // Move the folder away immediately, before the save.
        final away = Directory('${second.path}-away');
        second.renameSync(away.path);
        await s.until(() => s.nb.current!.readOnly, what: 'page read-only');
        await s.nb.flush();
        // 140: the quit notice says one page waits.
        final listing = await s.nb.pendingRecovery();
        expect(listing.entries, hasLength(1));
        // 142 (before): the recovery folder holds the entry.
        expect(env.recovery.existsSync(), isTrue);
        expect(env.recovery.listSync(), isNotEmpty);
        await s.close();
        // 141: restart with the folder back: the edit is on the page.
        away.renameSync(second.path);
        await s.launch(watchFiles: true, folderCheckInterval: const Duration(milliseconds: 400));
        await s.nb.open(pageId);
        await s.pump(500);
        expect(s.nb.current!.page.nodes.whereType<BoxRecord>().single.snapshotText, 'typed just before');
        // 142: and the recovery folder is empty again.
        await s.until(
          () => !env.recovery.existsSync() || env.recovery.listSync().isEmpty,
          what: 'recovery folder empty',
        );
        expect((await s.nb.pendingRecovery()).entries, isEmpty);
      } finally {
        try {
          await s.close();
        } catch (_) {}
        t.view.reset();
        await env.dispose();
      }
    });

    testWidgets('step 140: the quit notice says how many pages wait', (t) async {
      final env = await Env.create('quitnotice');
      try {
        final nav = GlobalKey<NavigatorState>();
        final nb = Notebook(
          PageStore(env.pages),
          buildModules(),
          bindersFile: env.binders,
          recoveryDirectory: env.recovery,
        );
        // A recovery entry waits for a vanished folder.
        final second = env.folder('Second');
        await nb.load();
        final id = await nb.createPage(folderPath: second.path);
        await nb.open(id);
        nb.current!.createBoxAt(const Bounds(10, 10, 0, 0));
        final c = nb.current!;
        c.commit(
          c.page.nodes.whereType<BoxRecord>().single.id,
          c.modules.codecs.codecFor(c.page.nodes.whereType<BoxRecord>().single.typeId)!.decode({
            'document': {
              'type': 'page',
              'children': [para('waiting')],
            },
          }, 1),
        );
        second.renameSync('${second.path}-away');
        await nb.flush();
        expect((await nb.pendingRecovery()).entries, hasLength(1));
        t.view.physicalSize = const Size(1000, 700);
        t.view.devicePixelRatio = 1;
        await t.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
        final shown = showRecoveryNoticeOnExit(nb, nav);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('1 page'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('recovery-exit-ok')));
        await t.pump(const Duration(milliseconds: 300));
        await shown;
        await t.pumpWidget(const SizedBox());
        nb.dispose();
      } finally {
        t.view.reset();
        await env.dispose();
      }
    });

    testWidgets('step 182: a damaged recovery entry appears under Can\'t open with its reason', (t) async {
      await withSession(
        t,
        'baddrecovery',
        (s) async {
          expect(find.text("CAN'T OPEN"), findsOneWidget);
          expect(find.text('bad-1'), findsOneWidget);
          expect(
            find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith("Recovery entry can't be read")),
            findsOneWidget,
          );
          // The app never deletes it.
          expect(File('${s.env.recovery.path}${_sep}bad-1.json').existsSync(), isTrue);
        },
        prepare: (env) async {
          env.recovery.createSync(recursive: true);
          File('${env.recovery.path}${_sep}bad-1.json').writeAsStringSync('{ nope');
          File('${env.recovery.path}${_sep}bad-1.canvas').writeAsStringSync('not a page');
        },
      );
    });
  });
}
