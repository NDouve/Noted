// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

import 'support/trouble_world.dart';

// The mobile relative paths (sync stage 1): the codec, the notebook and the
// recovery store. The codec is tested here with POSIX-shaped iOS paths.
void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
  });

  const d = '/var/mobile/Containers/Data/Application/AAAA-1111/Documents';
  const old = '/var/mobile/Containers/Data/Application/BBBB-2222/Documents';

  String stored(String p, {String documents = d}) => storedPath(p, windows: false, documents: documents);
  String resolved(String p, {String documents = d, bool gone = true}) =>
      resolveStoredPath(p, windows: false, documents: documents, exists: (_) => !gone);

  group('codec', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('a path under the documents folder is stored relative and resolves back', () {
      expect(stored('$d/Noted/binders/Work'), '@documents/Noted/binders/Work');
      expect(resolved('@documents/Noted/binders/Work'), '$d/Noted/binders/Work');
      expect(stored(d), '@documents/');
      expect(resolved('@documents/'), d);
      expect(resolved('@documents'), d);
      // Idempotent.
      expect(stored('@documents/Noted/x'), '@documents/Noted/x');
    });

    test('paths outside the documents folder stay absolute', () {
      expect(stored('/Users/me/Notes'), '/Users/me/Notes');
      expect(stored('${d}2/Noted'), '${d}2/Noted');
      expect(resolved('/Users/me/Notes'), '/Users/me/Notes');
    });

    test('a leading /private is ignored on either side', () {
      expect(stored('/private$d/Noted/pages'), '@documents/Noted/pages');
      expect(stored('$d/Noted/pages', documents: '/private$d'), '@documents/Noted/pages');
      expect(resolved('/private$old/Noted/pages'), '$d/Noted/pages');
      expect(resolved('$old/Noted/pages', documents: '/private$d'), '/private$d/Noted/pages');
    });

    test('an absolute path under an old container is re-keyed by position', () {
      expect(resolved('$old/Noted/binders/a'), '$d/Noted/binders/a');
      expect(resolved('$old/Noted'), '$d/Noted');
      // Under the current container: as is.
      expect(resolved('$d/Noted/binders/a'), '$d/Noted/binders/a');
    });

    test('paths that do not match the old-container rule stay as written', () {
      // Two segments differ.
      expect(resolved('/var/mobile/Containers/Data/Other/BBBB-2222/Documents/Noted/x'),
          '/var/mobile/Containers/Data/Other/BBBB-2222/Documents/Noted/x');
      // Segment n is not "Documents".
      const other = '/var/mobile/Containers/Data/Application/BBBB-2222/Library';
      expect(resolved('$other/Noted/x'), '$other/Noted/x');
      // Segment n+1 is not Noted: outside D/Noted.
      expect(resolved('$old/Other/x'), '$old/Other/x');
      expect(resolved(old), old);
      // The old path still exists.
      expect(resolved('$old/Noted/x', gone: false), '$old/Noted/x');
      // A shorter prefix.
      expect(resolved('/var/mobile/Noted/x'), '/var/mobile/Noted/x');
    });

    test('a .. segment is refused and kept as written', () {
      expect(resolved('@documents/../etc'), '@documents/../etc');
      expect(resolved('@documents/Noted/../../x'), '@documents/Noted/../../x');
      expect(stored('$d/Noted/../x'), '$d/Noted/../x');
    });

    test('/@documents/ (an older build\'s normalised write) reads back', () {
      expect(resolved('/@documents/Noted/binders/a'), '$d/Noted/binders/a');
      expect(isDocumentsForm('/@documents/Noted'), isTrue);
      expect(isDocumentsForm('$d/Noted'), isFalse);
    });

    test('desktop is the identity', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(stored('$d/Noted/x'), '$d/Noted/x');
      expect(resolved('@documents/Noted/x'), '@documents/Noted/x');
      expect(resolved('$old/Noted/x'), '$old/Noted/x');
    });

    test('without a documents folder (before initDeviceStorage) it is the identity', () {
      expect(storedPath('$d/Noted/x', windows: false), '$d/Noted/x');
      expect(resolveStoredPath('@documents/Noted/x', windows: false), '@documents/Noted/x');
    });

    test('Windows folds case and accepts backslashes', () {
      const w = r'C:\Users\x\Temp\c2\Documents';
      expect(storedPath(r'c:\users\x\temp\c2\documents\Noted\a', windows: true, documents: w),
          '@documents/Noted/a');
      expect(resolveStoredPath('@documents/Noted/a', windows: true, documents: w), r'C:\Users\x\Temp\c2\Documents\Noted\a');
      expect(
        resolveStoredPath(r'C:\Users\x\Temp\c1\Documents\Noted\a', windows: true, documents: w, exists: (_) => false),
        r'C:\Users\x\Temp\c2\Documents\Noted\a',
      );
    });
  });

  group('recovery re-key', _recoveryTests);
  group('notebook', _notebookTests);
  group('B1: generation hashes', _b1Tests);
  group('guards', _guardTests);
}

// Guards: these describe today's behaviour and pass on main as well. Desktop
// files must stay byte for byte the same, and a build that doesn't know the
// relative form must read it without harm.
void _guardTests() {
  late Directory root;
  final opened = <Notebook>[];

  setUp(() async => root = await Directory.systemTemp.createTemp('noted_mobile_guard'));

  tearDown(() async {
    for (final nb in opened) {
      nb.dispose();
    }
    opened.clear();
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Notebook build(AppSettings settings) {
    final nb = Notebook(
      PageStore(Directory('${root.path}/pages')..createSync(recursive: true)),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: Directory('${root.path}/app/recovery'),
      settings: settings,
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  test('6: desktop files are byte for byte what main writes (binders.json, settings.json, recovery entry and tmp)', () async {
    final settings = AppSettings(File('${root.path}/app/settings.json'));
    final nb = build(settings);
    await nb.load();
    final a = await nb.createBinder(name: 'A');
    final other = Directory('${root.path}/other')..createSync();
    await nb.setDefaultPageFolder(other.path);
    settings.theme = ThemeSetting.dark;
    await nb.flush();
    final p = a.path;
    final f = nb.standaloneFolders.single.path;
    final id = a.binder!.id;
    expect(
      File('${root.path}/app/binders.json').readAsStringSync(),
      '{"format":1,"binders":[${jsonEncode(p)}],'
      '"binderIds":{${jsonEncode(p)}:${jsonEncode(id)}},"standaloneFolders":[${jsonEncode(f)}]}\n',
    );
    expect(
      File('${root.path}/app/settings.json').readAsStringSync(),
      '{"defaultPageFolder":${jsonEncode(f)},"format":1,"theme":"dark"}',
    );

    // A recovery entry: its name and bytes, and the tmp a failed rename leaves.
    final rec = Directory('${root.path}/rec');
    final folder = '${root.path}/pages';
    final time = DateTime.utc(2026, 10, 25, 10);
    final page = _page('p1', 'one');
    final text = writePage(page);
    final expected = jsonEncode({
      'format': 2,
      'folder': folder,
      'pageId': 'p1',
      'time': '2026-10-25T10:00:00.000Z',
      'base': null,
      'page': text,
    });
    var h = 0xcbf29ce484222325;
    final key = File(folder).absolute.path.replaceAll(r'\', '/');
    for (final u in utf8.encode('${Platform.isWindows ? key.toLowerCase() : key}|p1')) {
      h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    final name = 'p1-${h.toRadixString(16)}';
    final s = RecoveryStore(rec);
    await s.write(folder: folder, page: page, baseText: null, time: time);
    expect(File('${rec.path}/$name.entry').readAsStringSync(), expected);
    // A failed rename: a directory sits where the entry goes.
    File('${rec.path}/$name.entry').deleteSync();
    Directory('${rec.path}/$name.entry').createSync();
    await expectLater(s.write(folder: folder, page: page, baseText: null, time: time), throwsA(anything));
    final tmps = [
      for (final e in rec.listSync())
        if (e is File && e.path.contains('.entry.') && e.path.endsWith('.tmp')) e,
    ];
    expect(tmps, hasLength(1));
    expect(tmps.single.readAsStringSync(), expected);
  });

  // The name main gives the entry of page p1 in [folder] (desktop).
  String entryName(String folder) {
    var h = 0xcbf29ce484222325;
    final key = File(folder).absolute.path.replaceAll(r'\', '/');
    for (final u in utf8.encode('${Platform.isWindows ? key.toLowerCase() : key}|p1')) {
      h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return 'p1-${h.toRadixString(16)}';
  }

  test('a directory where an entry goes: a listing completes, its tmp is kept in another slot and a later write works', () async {
    final rec = Directory('${root.path}/rec');
    final folder = '${root.path}/pages';
    final name = entryName(folder);
    final s = RecoveryStore(rec)..transactionLimit = const Duration(seconds: 5);
    await s.write(folder: folder, page: _page('p1', 'one'), baseText: null, time: DateTime.utc(2026, 10, 25, 10));
    File('${rec.path}/$name.entry').deleteSync();
    Directory('${rec.path}/$name.entry').createSync();
    await expectLater(
      s.write(folder: folder, page: _page('p1', 'one'), baseText: null, time: DateTime.utc(2026, 10, 25, 10)),
      throwsA(anything),
    );
    final l = await s.list().timeout(const Duration(seconds: 10));
    expect(l.entries, hasLength(1));
    expect(l.entries.single.file.path, endsWith('${name}_dup2.entry'));
    expect(rec.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
    expect(Directory('${rec.path}/$name.entry').existsSync(), isTrue);
    await s.write(folder: '${root.path}/other', page: _page('p2', 'two'), baseText: null, time: DateTime.utc(2026, 10, 25, 11));
    expect((await s.list()).entries, hasLength(2));
  });

  test('a directory where a legacy entry is converted to: the listing completes and the entry takes the next slot', () async {
    final rec = Directory('${root.path}/rec')..createSync(recursive: true);
    final folder = '${root.path}/pages';
    final name = entryName(folder);
    Directory('${rec.path}/$name.entry').createSync();
    final legacy = _legacyName(folder, 'p1');
    File('${rec.path}/$legacy.canvas').writeAsStringSync(writePage(_page('p1', 'one')));
    File('${rec.path}/$legacy.json').writeAsStringSync(
      jsonEncode({'format': 1, 'folder': folder, 'pageId': 'p1', 'time': '2026-10-25T10:00:00.000Z', 'base': null}),
    );
    final s = RecoveryStore(rec)..transactionLimit = const Duration(seconds: 5);
    final l = await s.list().timeout(const Duration(seconds: 10));
    expect(l.entries, hasLength(1));
    expect(l.entries.single.file.path, endsWith('${name}_dup2.entry'));
    expect(File('${rec.path}/$legacy.canvas').existsSync(), isFalse);
  });

  test('7: a build that does not know @documents/ reads the new format harmlessly (codec off)', () async {
    final b = File('${root.path}/app/binders.json')..createSync(recursive: true);
    b.writeAsStringSync(
      '{"format":1,"binders":["@documents/Noted/binders/Work"],"standaloneFolders":["@documents/Noted/other"],'
      '"binderIds":{"@documents/Noted/binders/Work":"b1"}}\n',
    );
    final s = File('${root.path}/app/settings.json');
    s.writeAsStringSync('{"format":1,"theme":"system","defaultPageFolder":"@documents/Noted/pages","defaultBinderFolder":"@documents/Noted/binders"}');
    final settings = AppSettings(s);
    expect(settings.defaultPageFolder, '@documents/Noted/pages');
    expect(settings.defaultBinderFolder, '@documents/Noted/binders');
    final before = [for (final e in root.listSync(recursive: true)) e.path]..sort();
    final nb = build(settings);
    await nb.load();
    expect(nb.binders.single.available, isFalse);
    expect(nb.standaloneFolders, isNotEmpty);
    expect(nb.standaloneFolders.every((f) => !f.available), isTrue);
    // A real folder is added: binders.json is saved.
    final real = Directory('${root.path}/real')..createSync();
    await nb.addStandaloneFolder(real.path);
    await nb.flush();
    settings.theme = ThemeSetting.dark;
    // Nothing was created for the dead folders, nothing deleted.
    expect(Directory('@documents').existsSync(), isFalse);
    expect(Directory('${root.path}/@documents').existsSync(), isFalse);
    final after = [for (final e in root.listSync(recursive: true)) e.path]..sort();
    final added = after.where((p) => !before.contains(p)).map((p) => p.replaceAll(r'\', '/')).toList();
    expect(added.where((p) => p.contains('@documents')), isEmpty);
    expect(before.every(after.contains), isTrue);
    // The raw strings are kept when the files are saved again.
    final j = jsonDecode(b.readAsStringSync()) as Map<String, Object?>;
    expect(j['binders'], ['@documents/Noted/binders/Work']);
    // An older build normalises these against its working directory (nothing is created; the folders stay unavailable).
    expect(j['standaloneFolders'], hasLength(3));
    expect((j['standaloneFolders']! as List).where((p) => (p as String).endsWith('@documents/Noted/other')), hasLength(1));
    expect((j['binderIds']! as Map).keys, ['@documents/Noted/binders/Work']);
    final sj = jsonDecode(s.readAsStringSync()) as Map<String, Object?>;
    expect(sj['defaultPageFolder'], '@documents/Noted/pages');
    expect(sj['defaultBinderFolder'], '@documents/Noted/binders');
  });
}

// Generation hashes are over the folder as stored, so a replacement of one's own
// generation is never refused as foreign (iOS, no container change).
void _b1Tests() {
  late TroubleWorld w;

  setUp(() async {
    w = TroubleWorld();
    await w.init();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    resetDeviceStorage();
    // The test root is the documents folder: the pages are `@documents/pages`.
    await initDeviceStorage(documents: () async => w.root, cache: () async => w.root, support: () async => w.root);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    await w.dispose();
  });

  String norm(String p) => p.replaceAll(r'\', '/');

  test('a store write may replace an entry in an @documents folder that it holds the generation of', () async {
    final s = RecoveryStore(w.rec);
    final folder = '${w.root.path}/pages';
    final t1 = DateTime.utc(2026, 10, 25, 10);
    final first = await s.write(folder: folder, page: _page('p1', 'one'), baseText: null, time: t1);
    expect(first.file.readAsStringSync(), contains('"folder":"@documents/pages"'));
    expect(first.gen, s.generationFor(folder, t1, null, first.pageText));
    final second = await s.write(
      folder: folder,
      page: _page('p1', 'two'),
      baseText: null,
      time: t1.add(const Duration(minutes: 1)),
      replaceable: {first.gen},
    );
    final listed = (await s.list()).entries;
    expect(listed, hasLength(1));
    expect(listed.single.gen, second.gen);
    expect(norm(listed.single.folder), norm(folder));
  });

  test('an open page gets two recovery keeps in a row; the second replaces the first', () async {
    final nb = w.make();
    await w.editedPage(nb);
    w.storeFor(w.pages).failWith = accessDenied();
    await nb.flush();
    final first = (await nb.pendingRecovery()).entries.single;
    expect(first.file.readAsStringSync(), contains('"folder":"@documents/pages"'));
    nb.current!.createBoxAt(const Bounds(90, 90, 0, 0));
    await nb.flush();
    final entries = (await nb.pendingRecovery()).entries;
    expect(entries, hasLength(1), reason: 'the second keep replaced the first, it was not refused as foreign');
    expect(entries.single.gen, isNot(first.gen));
    expect(entries.single.pageText, writePage(nb.current!.page));
    expect(w.recFiles(), hasLength(1));
  });

  test('moving a page with kept edits between two @documents locations succeeds; its entry is under the new location', () async {
    final nb = w.make();
    final id = await w.editedPage(nb);
    w.storeFor(w.pages).failWith = accessDenied();
    await nb.flush();
    await nb.addStandaloneFolder(w.other.path);
    expect((await nb.pendingRecovery()).entries, hasLength(1));
    await nb.createPage(); // leave the page
    expect(await nb.moveToFolder(id, w.other.path), isTrue);
    final entries = (await nb.pendingRecovery()).entries;
    expect(entries, hasLength(1));
    expect(norm(entries.single.folder), norm(w.other.path));
    expect(entries.single.file.readAsStringSync(), contains('"folder":"@documents/other"'));
    expect(w.recFiles(), hasLength(1));
  });
}

// The notebook on a changing container: binders.json and settings.json as the
// build before this change wrote them (absolute), then a new container.
void _notebookTests() {
  late Directory root;
  late AppSettings settings;
  final opened = <Notebook>[];

  Directory docs(String c) => Directory('${root.path}/$c/Documents');
  String support(String c) => '${root.path}/$c/Support';

  Future<void> container(String c) async {
    resetDeviceStorage();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final d = docs(c)..createSync(recursive: true);
    final s = Directory(support(c))..createSync(recursive: true);
    await initDeviceStorage(documents: () async => d, cache: () async => s, support: () async => s);
  }

  Notebook build(String c) {
    final d = docs(c).path;
    settings = AppSettings(File('${support(c)}/Noted/settings.json'));
    final nb = Notebook(
      PageStore(Directory('$d/Noted/pages')..createSync(recursive: true)),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      bindersFile: File('$d/Noted/binders.json'),
      recoveryDirectory: Directory('${support(c)}/Noted/recovery'),
      settings: settings,
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  void close(Notebook nb) {
    nb.dispose();
    opened.remove(nb);
  }

  String norm(String p) => p.replaceAll(r'\', '/');

  Map<String, Object?> readJson(File f) => jsonDecode(f.readAsStringSync()) as Map<String, Object?>;

  // Rewrites the stored `@documents/` strings of c as the absolute paths of
  // the build before this change.
  void absolutize(String c) {
    String abs(String s) =>
        s.startsWith('@documents/') ? '${docs(c).path}/${s.substring('@documents/'.length)}' : s;
    final b = File('${docs(c).path}/Noted/binders.json');
    final j = readJson(b);
    j['binders'] = [for (final p in j['binders']! as List) abs(p as String)];
    if (j['standaloneFolders'] != null) {
      j['standaloneFolders'] = [for (final p in j['standaloneFolders']! as List) abs(p as String)];
    }
    j['binderIds'] = {for (final e in (j['binderIds']! as Map).entries) abs(e.key as String): e.value};
    b.writeAsStringSync(jsonEncode(j));
    final s = File('${support(c)}/Noted/settings.json');
    final sj = readJson(s);
    for (final k in ['defaultPageFolder', 'defaultBinderFolder']) {
      if (sj[k] != null) sj[k] = abs(sj[k]! as String);
    }
    s.writeAsStringSync(jsonEncode(sj));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_mobile_nb');
  });

  tearDown(() async {
    for (final nb in opened) {
      nb.dispose();
    }
    opened.clear();
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('an old-form entry whose twin replayed and was deleted is not offered again in the same session (old file undeletable)', () async {
    await container('c1');
    var nb = build('c1');
    await nb.load();
    final id = nb.currentId!;
    await nb.flush();
    final pagesDir = Directory('${docs('c1').path}/Noted/pages').absolute.path;
    final before = readPage(File('$pagesDir/$id.canvas').readAsStringSync()).nodes.length;
    nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
    // The entry as the build before relative paths wrote it.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await RecoveryStore(Directory('${support('c1')}/Noted/recovery')).write(
      folder: pagesDir,
      page: nb.current!.page,
      baseText: File('$pagesDir/$id.canvas').readAsStringSync(),
      time: DateTime.now(),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    close(nb); // quits with the edit unsaved

    docs('c1').parent.renameSync(docs('c2').parent.path);
    await container('c2');
    nb = build('c2');
    final rec = nb.recoveryStoreForTest!;
    rec.deleteForTest = (path, expected) async => throw FileSystemException('held', path);
    await nb.load();
    final file = File('${docs('c2').path}/Noted/pages/$id.canvas');
    expect(readPage(file.readAsStringSync()).nodes, hasLength(before + 1), reason: 'the edit landed once');
    expect((await nb.pendingRecovery()).entries, isEmpty);
    final recDir = Directory('${support('c2')}/Noted/recovery');
    List<File> entries() => [for (final f in recDir.listSync()) if (f is File && f.path.endsWith('.entry')) f];
    expect(entries(), hasLength(1), reason: 'only the old-form file is left');
    expect(entries().single.readAsStringSync(), isNot(contains('@documents')));

    // The box is deleted on purpose; a second listing and a replay in the same
    // session must not bring it back.
    await nb.open(id);
    nb.current!.delete(nb.current!.page.nodes.last.id);
    await nb.flush();
    await rec.list();
    expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'the old entry is not offered again');
    await nb.recoverNowForTest();
    expect(readPage(file.readAsStringSync()).nodes, hasLength(before));
  });

  test('1: after a container change every binder, folder and default is found; the next save writes @documents/ forms', () async {
    await container('c1');
    var nb = build('c1');
    await nb.load();
    final a = await nb.createBinder(name: 'A');
    final b = await nb.createBinder(name: 'B');
    final other = Directory('${docs('c1').path}/Noted/other')..createSync();
    await nb.setDefaultPageFolder(other.path);
    final pa = await nb.createPage(binderPath: a.path);
    final pb = await nb.createPage(binderPath: b.path);
    final po = await nb.createPage(folderPath: other.path);
    final ids = {a.binder!.id, b.binder!.id};
    await nb.flush();
    close(nb);
    settings.theme = ThemeSetting.dark; // writes settings.json
    final saved = readJson(File('${docs('c1').path}/Noted/binders.json'));
    expect((saved['binders']! as List).first, startsWith('@documents/Noted/binders/'));
    absolutize('c1');
    expect(File('${docs('c1').path}/Noted/binders.json').readAsStringSync(), isNot(contains('@documents')));

    // The app container changes: the old folder is gone.
    docs('c1').parent.renameSync(docs('c2').parent.path);
    await container('c2');
    nb = build('c2');
    await nb.load();

    expect(nb.binders, hasLength(2));
    expect(nb.binders.every((s) => s.available), isTrue);
    expect({for (final s in nb.binders) s.binder!.id}, ids);
    expect(nb.standaloneFolders.single.available, isTrue);
    bool has(String id) => nb.tree[id] != null || nb.binders.any((s) => s.tree[id] != null);
    expect([pa, pb, po].map(has), everyElement(isTrue));
    expect(norm(nb.newPageFolderPath), norm('${docs('c2').path}/Noted/other'));
    expect(settings.defaultPageFolder, isNotNull);
    expect(norm(settings.defaultPageFolder!), norm('${docs('c2').path}/Noted/other'));
    final fresh = await nb.createPage();
    await nb.flush();
    expect(File('${docs('c2').path}/Noted/other/$fresh.canvas').existsSync(), isTrue);

    // The next ordinary save writes the relative forms; nothing was removed.
    await nb.createBinder(name: 'C');
    await nb.flush();
    final j = readJson(File('${docs('c2').path}/Noted/binders.json'));
    expect(j['binders'], everyElement(startsWith('@documents/Noted/binders/')));
    expect(j['binders'], hasLength(3));
    expect((j['binderIds']! as Map).keys, everyElement(startsWith('@documents/Noted/binders/')));
    expect(j['standaloneFolders'], ['@documents/Noted/other']);
    expect(j['removedBinders'] ?? const [], isEmpty);
    expect(File('${docs('c2').path}/Noted/binders.json').readAsStringSync(), isNot(contains('Documents')));
    settings.theme = ThemeSetting.light;
    expect(readJson(File('${support('c2')}/Noted/settings.json'))['defaultPageFolder'], '@documents/Noted/other');
  });
}

NotedPage _page(String id, String title) => NotedPage.create(PageMeta.create(id: id, title: title, order: 0));

// The recovery store on a container change. Old-form entries are written the
// way the build before this change wrote them (the desktop path of the store
// is the identity), then the container changes and a store lists them.
void _recoveryTests() {
  late Directory root;
  late Directory rec;
  final t1 = DateTime.utc(2026, 10, 25, 10);
  final t2 = t1.add(const Duration(minutes: 5));

  String norm(String p) => p.replaceAll(r'\', '/');

  Future<void> container(String name) async {
    resetDeviceStorage();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final d = Directory('${root.path}/$name/Documents')..createSync(recursive: true);
    await initDeviceStorage(documents: () async => d, cache: () async => d, support: () async => d);
  }

  // A folder of the old container c1, which does not exist any more.
  String oldFolder(String rel) => '${root.path}/c1/Documents/Noted/$rel';

  // The same folder in the container the tests run in (c2).
  String newFolder(String rel) => '${root.path}/c2/Documents/Noted/$rel';

  RecoveryStore store({Future<void> Function(String)? hook}) => RecoveryStore(rec, hook: hook);

  // What the build before this change wrote.
  Future<void> writeOld(String folder, NotedPage page, DateTime time, {String? base}) async {
    final was = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await store().write(folder: folder, page: page, baseText: base, time: time);
    } finally {
      debugDefaultTargetPlatformOverride = was;
    }
  }

  List<File> entryFiles() => [
    for (final f in rec.listSync())
      if (f is File && f.path.endsWith('.entry')) f,
  ]..sort((a, b) => a.path.compareTo(b.path));

  List<String> others() => [
    for (final f in rec.listSync())
      if (f is File && !f.path.endsWith('.entry')) f.path,
  ];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_mobile_paths');
    rec = Directory('${root.path}/rec');
    await container('c2');
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Set<String> titles(RecoveryListing l) => {for (final e in l.entries) e.page.meta.title};

  test('entries of the old container are re-keyed, once each, and listed under the current folder', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    await writeOld(oldFolder('binders/Work'), _page('p2', 'two'), t1);
    expect(entryFiles(), hasLength(2));
    final l = await store().list();
    expect(l.problems, isEmpty);
    expect(titles(l), {'one', 'two'});
    expect(norm(l.entries.firstWhere((e) => e.pageId == 'p1').folder), norm(newFolder('pages')));
    expect(norm(l.entries.firstWhere((e) => e.pageId == 'p2').folder), norm(newFolder('binders/Work')));
    expect(entryFiles(), hasLength(2));
    expect(others(), isEmpty);
    for (final f in entryFiles()) {
      expect(f.readAsStringSync(), contains('"folder":"@documents/Noted/'));
    }
    // A fresh store finds the same and has nothing more to do.
    final again = await store().list();
    expect(titles(again), {'one', 'two'});
    expect(entryFiles(), hasLength(2));
  });

  test('an identical entry at the new key means already re-keyed: the old file goes, one entry stays', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    await store().write(folder: newFolder('pages'), page: _page('p1', 'one'), baseText: null, time: t1);
    expect(entryFiles(), hasLength(2));
    final l = await store().list();
    expect(l.entries, hasLength(1));
    expect(entryFiles(), hasLength(1));
  });

  test('a different, later entry at the new key never makes the old one redundant: both are kept', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'old edit'), t1);
    final e2 = await store().write(folder: newFolder('pages'), page: _page('p1', 'new edit'), baseText: null, time: t2);
    final before = e2.file.readAsBytesSync();
    final l = await store().list();
    expect(titles(l), {'old edit', 'new edit'});
    expect(entryFiles(), hasLength(2));
    expect(e2.file.readAsBytesSync(), before, reason: 'the entry at the new key is untouched');
    expect(others(), isEmpty);
  });

  group('a crash', () {
    for (final point in ['tmp-written', 'rekey-published', 'rekey-before-delete']) {
      test('at $point leaves one entry per generation after the next listing', () async {
        await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
        await writeOld(oldFolder('binders/Work'), _page('p2', 'two'), t1);
        var armed = true;
        final crashing = store(
          hook: (p) async {
            if (armed && p == point) {
              armed = false;
              throw StateError('crash at $p');
            }
          },
        );
        await expectLater(crashing.list(), throwsStateError);
        // Whatever temp the crash left is a re-key temp, never an `.entry.` one.
        for (final p in others()) {
          expect(p, isNot(contains('.entry.')), reason: 'a re-key temp name never contains .entry.');
          if (p.endsWith('.tmp')) expect(p, contains('.rekey.'));
        }
        if (point == 'tmp-written') expect(others(), isNotEmpty);
        final l = await store().list();
        expect(l.problems, isEmpty, reason: '${l.problems}');
        expect(titles(l), {'one', 'two'});
        expect(l.entries, hasLength(2));
        expect(entryFiles(), hasLength(2));
        expect(others(), isEmpty);
      });
    }

    test('after the new file was published, with the old one set aside (.cas-old), still one entry each', () async {
      await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
      final old = entryFiles().single;
      var armed = true;
      await expectLater(
        store(
          hook: (p) async {
            if (armed && p == 'rekey-before-delete') {
              armed = false;
              // The old file is set aside, as deleteFileIfUnchanged does it.
              old.renameSync('${old.path}.12345.cas-old');
              throw StateError('crash');
            }
          },
        ).list(),
        throwsStateError,
      );
      expect(others(), hasLength(1));
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(entryFiles(), hasLength(1));
      expect(others(), isEmpty);
    });

    test('at tmp-written while heading for _dup2: both entries and the old edits land', () async {
      await writeOld(oldFolder('pages'), _page('p1', 'old edit'), t1);
      final e2 = await store().write(folder: newFolder('pages'), page: _page('p1', 'new edit'), baseText: null, time: t2);
      final before = e2.file.readAsBytesSync();
      var armed = true;
      await expectLater(
        store(
          hook: (p) async {
            if (armed && p == 'tmp-written') {
              armed = false;
              throw StateError('crash');
            }
          },
        ).list(),
        throwsStateError,
      );
      final l = await store().list();
      expect(titles(l), {'old edit', 'new edit'});
      expect(l.entries, hasLength(2));
      expect(entryFiles(), hasLength(2));
      expect(e2.file.readAsBytesSync(), before);
      expect(others(), isEmpty);
    });
  });

  test('a re-key temp beside an older, different entry at the new key: both are listed, the entry is unchanged (B2)', () async {
    // E2 was written at the new key first (older time); E1's re-key temp then
    // carries a later time and must not be renamed over E2's slot.
    final e2 = await store().write(folder: newFolder('pages'), page: _page('p1', 'e2'), baseText: null, time: t1);
    final before = e2.file.readAsBytesSync();
    // E1's old file is gone; only its re-key temp, named as the code names it
    // (after the old file), is left.
    await writeOld(oldFolder('pages'), _page('p1', 'e1'), t2);
    final oldFile = entryFiles().firstWhere((f) => f.path != e2.file.path);
    final stage = Directory('${root.path}/stage')..createSync();
    final e1 = await RecoveryStore(stage).write(folder: newFolder('pages'), page: _page('p1', 'e1'), baseText: null, time: t2);
    final stem = oldFile.path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.entry$'), '');
    oldFile.deleteSync();
    File('${rec.path}/$stem.rekey.1-1.tmp').writeAsBytesSync(e1.file.readAsBytesSync());
    final l = await store().list();
    expect(l.problems.where((p) => p.contains('rekey') || p.contains('unfinished')), isEmpty, reason: 'a re-key temp is not an unfinished write: ${l.problems}');
    expect(titles(l), {'e1', 'e2'});
    expect(l.entries, hasLength(2));
    expect(e2.file.readAsBytesSync(), before);
    expect(others(), isEmpty);
  });

  group('old-form tmp and legacy entries beside a different, later entry at the new key (cross-form rule)', () {
    // An ordinary `.entry.*.tmp` of the old build: a failed rename left it.
    Future<File> oldTmp(NotedPage page, DateTime time) async {
      await writeOld(oldFolder('pages'), page, time);
      final f = entryFiles().single;
      final tmp = File('${f.path}.1-1.tmp');
      f.renameSync(tmp.path);
      return tmp;
    }

    test('(a) the tmp is not deleted by the later entry and nothing is renamed over', () async {
      await oldTmp(_page('p1', 'e1'), t1);
      final e2 = await store().write(folder: newFolder('pages'), page: _page('p1', 'e2'), baseText: null, time: t2);
      final before = e2.file.readAsBytesSync();
      final l = await store().list();
      expect(titles(l), {'e1', 'e2'});
      expect(entryFiles(), hasLength(2));
      expect(e2.file.readAsBytesSync(), before);
      expect(others(), isEmpty);
    });

    test('(b) unreadable at the first listing, readable at the next: same outcome', () async {
      final tmp = await oldTmp(_page('p1', 'e1'), t1);
      // Unreadable at the first listing (a sync client has it half written).
      final good = tmp.readAsBytesSync();
      tmp.writeAsStringSync('{"format":2,');
      final first = await store().list();
      expect(first.problems, isNotEmpty, reason: 'kept and reported');
      // A failed save then wrote a different, later entry at the new key.
      final e2 = await store().write(folder: newFolder('pages'), page: _page('p1', 'e2'), baseText: null, time: t2);
      final before = e2.file.readAsBytesSync();
      // The tmp is readable at the next listing.
      tmp.writeAsBytesSync(good);
      final l = await store().list();
      expect(titles(l), {'e1', 'e2'});
      expect(entryFiles(), hasLength(2));
      expect(e2.file.readAsBytesSync(), before);
      expect(others(), isEmpty);
    });

    test('(c) a legacy pair is converted in its own form and re-keyed, beside the later entry', () async {
      final folder = oldFolder('pages');
      final page = _page('p1', 'e1');
      final name = _legacyName(folder, 'p1');
      rec.createSync(recursive: true);
      File('${rec.path}/$name.canvas').writeAsStringSync(writePage(page));
      File('${rec.path}/$name.json').writeAsStringSync(
        jsonEncode({'format': 1, 'folder': folder, 'pageId': 'p1', 'time': t1.toIso8601String(), 'base': null}),
      );
      final e2 = await store().write(folder: newFolder('pages'), page: _page('p1', 'e2'), baseText: null, time: t2);
      final before = e2.file.readAsBytesSync();
      final l = await store().list();
      expect(titles(l), {'e1', 'e2'});
      expect(entryFiles(), hasLength(2));
      expect(e2.file.readAsBytesSync(), before);
      expect(others(), isEmpty);
    });
  });

  test('a read-back that does not match keeps the old file (note 5)', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    final old = entryFiles().single;
    final oldBytes = old.readAsBytesSync();
    final s = store(
      hook: (p) async {
        if (p != 'rekey-published') return;
        // Something else replaced the twin before it was read back.
        for (final f in entryFiles()) {
          if (f.path != old.path) f.writeAsStringSync('garbage');
        }
      },
    );
    await s.list();
    expect(old.existsSync(), isTrue);
    expect(old.readAsBytesSync(), oldBytes);
  });

  test('the pass stops before the transaction limit; the next listing finishes it (note 6)', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    await writeOld(oldFolder('binders/Work'), _page('p2', 'two'), t1);
    // A fake time source: the limit's timer never fires and "out of time"
    // (75% of the limit) reads a clock that only the hook moves, so a slow
    // machine cannot change the outcome.
    const limit = Duration(seconds: 4);
    var now = Duration.zero;
    var slow = true;
    final s = store(
      hook: (p) async {
        if (slow && p == 'tmp-written') {
          slow = false;
          now += limit * 0.8;
        }
      },
    )
      ..uptime = (() => now)
      ..timerFactory = ((d, cb) => Timer(const Duration(hours: 1), cb));
    final l = await s.transaction((tx) => tx.list(), limit: limit);
    expect(titles(l), {'one', 'two'});
    expect(l.entries, hasLength(2));
    expect(others(), isEmpty, reason: 'no temp is left');
    final done = await store().list();
    expect(done.entries, hasLength(2));
    expect(entryFiles(), hasLength(2));
    for (final f in entryFiles()) {
      expect(f.readAsStringSync(), contains('@documents/'));
    }
  });

  test('a persistent delete failure: the generation is listed once and replays once, in two listings of a session', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    final s = store();
    // The old file can't be deleted, as when something holds it open.
    s.deleteForTest = (path, expected) async => throw FileSystemException('held', path);
    final l1 = await s.list();
    expect(l1.entries, hasLength(1), reason: 'the old copy and its twin are one generation');
    expect(entryFiles(), hasLength(2));
    // The page landed and its entry is deleted the way the replay does it (no
    // markLanded: the delete succeeds).
    await s.delete(l1.entries.single);
    expect(entryFiles(), hasLength(1), reason: 'the old file is still there');
    final l2 = await s.list();
    expect(entryFiles(), hasLength(1), reason: 'not re-keyed again');
    expect(l2.entries, hasLength(1));
    expect(s.isLanded(l2.entries.single.gen), isTrue, reason: 'offered as landed, so replay deletes it and merges nothing');
  });

  test('an old-form entry that landed before the re-key and could not be deleted is not re-keyed into a generation that replays again', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    final s = store();
    // A process that only reads (or a listing that stopped early): the old-form
    // entry is in the index as it is.
    await s.indexReadOnly();
    final old = s.indexEntries.single;
    expect(old.storedFolder, isNot(startsWith('@documents')));
    s.markLanded(old.gen); // the replay landed it; deleting the entry failed
    final l = await s.list();
    expect(entryFiles(), hasLength(1), reason: 'no new generation was made');
    expect(l.entries.single.storedFolder, old.storedFolder);
    expect(s.isLanded(l.entries.single.gen), isTrue, reason: 'still landed: replay only deletes it');
  });

  test('a newer keep that replaces a twinned entry\'s slot retires the undeletable old-form twin too', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    final s = store();
    s.deleteForTest = (path, expected) async => throw FileSystemException('held', path);
    final x = (await s.list()).entries.single;
    // The closed writer merges X and writes over X's slot.
    final y = await s.write(
      folder: x.folder,
      page: _page('p1', 'two'),
      baseText: null,
      time: t1.add(const Duration(hours: 1)),
      replaceable: {x.gen},
    );
    List<String> offered(RecoveryListing l) => [
      for (final e in l.entries)
        if (!s.isLanded(e.gen)) e.page.meta.title,
    ];
    expect(offered(await s.list()), ['two'], reason: 'the old generation is not offered beside its replacement');
    await s.delete(y);
    expect(offered(await s.list()), isEmpty, reason: 'nor after the replacement landed and was deleted');
  });

  test('a re-key temp that cannot be read is reported and kept', () async {
    rec.createSync(recursive: true);
    final tmp = File('${rec.path}/p1-abc.rekey.1-1.tmp')..writeAsStringSync('{"format":2,');
    final l = await store().list();
    expect(l.problems.single, contains('p1-abc.rekey.1-1.tmp'));
    expect(tmp.existsSync(), isTrue);
  });
}

// The name entries had before the layout changed (case folded everywhere).
String _legacyName(String folder, String id) {
  var h = 0xcbf29ce484222325;
  for (final u in utf8.encode('${folder.replaceAll(r'\', '/').toLowerCase()}|$id')) {
    h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return '$id-${h.toRadixString(16)}';
}
