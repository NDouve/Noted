// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Cloud parity step 6: watching chosen cloud folders (M8, amends 0129): the
// presenter's `changed` events reach the notebook, the 0064 check runs on iOS
// without folder watching, downloads are asked for at open and on each change
// event, and "Still downloading" is listed (R5.5, R5.13), against the fake
// channel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/icloud_folders.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_core/noted_core.dart';

import 'support/icloud_world.dart';

void main() {
  late IcloudWorld w;

  setUp(() async {
    w = IcloudWorld();
    await w.init();
  });
  tearDown(() => w.dispose());

  String slashes(String s) => s.replaceAll(r'\', '/');

  Future<void> externalPage(String id, {int order = 5}) async {
    await PageStore(w.drive).saveNew(NotedPage.create(PageMeta.create(id: id, title: 'Page $id', order: order)));
  }

  List<String> ids(Notebook nb) => [for (final m in nb.tree.roots) m.id];

  group('presenter events reach the notebook (M8)', () {
    test('a change event for a page another device wrote lists it', () async {
      final f = await w.picked();
      final nb = w.notebook(f);
      await nb.load();
      expect(ids(nb), isNot(contains('ext1')));
      await externalPage('ext1');
      await w.channel.emit('changed', {'path': w.path('ext1.canvas')});
      await waitFor(() => ids(nb).contains('ext1'), what: 'the page to be listed');
    });

    test('a move reports both paths: the old page goes and the new one is listed', () async {
      await externalPage('keep0', order: 0); // the open page, so old1 isn't
      await externalPage('old1');
      final f = await w.picked();
      final nb = w.notebook(f);
      await nb.load();
      expect(ids(nb), contains('old1'));
      File(w.path('old1.canvas')).deleteSync();
      await externalPage('new1');
      await w.channel.emit('changed', {'path': w.path('old1.canvas'), 'to': w.path('new1.canvas')});
      await waitFor(() => ids(nb).contains('new1') && !ids(nb).contains('old1'), what: 'both paths to be looked at');
    });

    test('a stub\'s change is its file\'s: the file that replaced it is looked at', () async {
      final f = await w.picked();
      final nb = w.notebook(f);
      await nb.load();
      await externalPage('ext2');
      await w.channel.emit('changed', {'path': w.path('.ext2.canvas.icloud')});
      await waitFor(() => ids(nb).contains('ext2'), what: 'the page to be listed');
    });

    test('the events of a version temp are not passed on', () async {
      final f = await w.picked();
      final seen = <String>[];
      f.onChanged = (p, to) => seen.add(p);
      await w.channel.emit('changed', {'path': w.path('.x.canvas.noted-version-0123456789abcdef.tmp')});
      await w.channel.emit('changed', {'path': w.path('x.canvas')});
      expect(seen.map(slashes), [slashes(w.path('x.canvas'))]);
    });

    test('with no folder access there is no hook, and a plain notebook is unchanged', () async {
      final nb = Notebook(PageStore(w.drive), buildModules());
      w.notebooks.add(nb);
      await nb.load();
      expect(nb.requestDownload, isNull);
      expect(nb.cloudVersionIssues, isEmpty);
    });
  });

  group('the 0064 check on iOS, which has no folder watching', () {
    Future<Notebook> openIn(Directory pages, {required bool withIcloud}) async {
      final IcloudFolders? f = withIcloud ? await w.picked(platform: CloudPlatform.ios) : null;
      final nb = f == null
          ? Notebook(
              PageStore(pages),
              buildModules(),
              bindersFile: File('${w.root.path}/app/binders.json'),
              recoveryDirectory: Directory('${w.root.path}/app/recovery'),
              folderCheckInterval: const Duration(milliseconds: 30),
              saveDelay: const Duration(hours: 1),
            )
          : w.notebook(f, pages: pages, folderCheck: const Duration(milliseconds: 30));
      if (f == null) w.notebooks.add(nb);
      await nb.load();
      return nb;
    }

    test('a chosen iCloud folder that goes away is noticed although watchFiles is false', () async {
      final pages = Directory(w.path('pages'))..createSync();
      final nb = await openIn(pages, withIcloud: true);
      expect(nb.defaultFolderAvailable, isTrue);
      pages.deleteSync(recursive: true);
      await waitFor(() => !nb.defaultFolderAvailable, what: 'the folder check');
      pages.createSync();
      await waitFor(() => nb.defaultFolderAvailable, what: 'the folder to come back');
    });

    test('without folder access (no iCloud) and no watching, nothing is checked', () async {
      final pages = Directory(w.path('pages'))..createSync();
      final nb = await openIn(pages, withIcloud: false);
      pages.deleteSync(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(nb.defaultFolderAvailable, isTrue);
    });
  });

  group('not downloaded (R5.5)', () {
    test('a stub is listed "Still downloading", the download is asked for at open and again on each change event', () async {
      final f = await w.picked(platform: CloudPlatform.ios);
      File(w.path('.gone1.canvas.icloud')).writeAsStringSync('');
      final nb = w.notebook(f);
      await nb.load();
      final listed = nb.unreadable.where((u) => u.reason == 'Still downloading').toList();
      expect(listed, hasLength(1));
      expect(slashes(listed.single.path), slashes(w.path('gone1.canvas')));
      final asked = () => w.channel.callsOf('startDownloading').map((c) => slashes('${c.args['path']}')).toList();
      expect(asked(), contains(slashes(w.path('gone1.canvas'))), reason: 'asked for at open');
      final before = asked().length;
      await w.channel.emit('changed', {'path': w.path('.gone1.canvas.icloud')});
      await waitFor(() => asked().length > before, what: 'the next request');
      // It arrives: the stub goes, the file is read and listed as a page.
      File(w.path('.gone1.canvas.icloud')).deleteSync();
      await PageStore(w.drive).saveNew(NotedPage.create(PageMeta.create(id: 'gone1', title: 'Arrived', order: 5)));
      await w.channel.emit('changed', {'path': w.path('gone1.canvas')});
      await waitFor(() => nb.tree.roots.any((m) => m.id == 'gone1'), what: 'the page to arrive');
      expect(nb.unreadable.where((u) => u.reason == 'Still downloading'), isEmpty);
    });

    test('an autosave on a dataless page requests the download, keeps the edit in recovery and saves on the change event', () async {
      final f = await w.picked(platform: CloudPlatform.ios);
      final nb = w.notebook(f);
      await nb.load();
      final id = nb.currentId!;
      await nb.flush();
      final file = File(w.path('$id.canvas'));
      final before = file.readAsStringSync();
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      // The file is evicted: only its stub is there.
      file.deleteSync();
      File(w.path('.$id.canvas.icloud')).writeAsStringSync('');
      await nb.flush();
      expect(nb.trouble.kind, TroubleKind.failing);
      expect(nb.trouble.reason, 'the page file is still downloading');
      expect((await nb.pendingRecovery()).entries, hasLength(1), reason: 'the edit is in recovery');
      expect(w.channel.callsOf('startDownloading').map((c) => slashes('${c.args['path']}')), contains(slashes(file.path)));
      expect(file.existsSync(), isFalse, reason: 'nothing was written over the stub');
      // The download finishes: the file is back and iCloud says so.
      file.writeAsStringSync(before);
      File(w.path('.$id.canvas.icloud')).deleteSync();
      await w.channel.emit('changed', {'path': file.path});
      await waitFor(() => !nb.trouble.isTrouble, what: 'the save on the change event');
      expect(readPage(file.readAsStringSync()).nodes, isNotEmpty, reason: 'the kept edit landed');
      expect((await nb.pendingRecovery()).entries, isEmpty);
    });
  });
}
