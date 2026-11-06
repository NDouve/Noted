// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/device_storage.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

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
    final stage = Directory('${root.path}/stage')..createSync();
    final e1 = await RecoveryStore(stage).write(folder: newFolder('pages'), page: _page('p1', 'e1'), baseText: null, time: t2);
    File('${rec.path}/x.rekey.1-1.tmp').writeAsBytesSync(e1.file.readAsBytesSync());
    final l = await store().list();
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

  test('a persistent delete failure: the generation is listed once and replays once, in two listings of a session', () async {
    await writeOld(oldFolder('pages'), _page('p1', 'one'), t1);
    final old = entryFiles().single;
    final s = store();
    // Windows refuses to move or delete a file that is open.
    final held = old.openSync();
    try {
      final l1 = await s.list();
      expect(l1.entries, hasLength(1), reason: 'the old copy and its twin are one generation');
      expect(entryFiles(), hasLength(2));
      // The page landed; its entry is deleted.
      s.markLanded(l1.entries.single.gen);
      await s.delete(l1.entries.single);
      expect(entryFiles(), hasLength(1), reason: 'the old file is still there');
      final l2 = await s.list();
      expect(entryFiles(), hasLength(1), reason: 'not re-keyed again');
      expect(l2.entries, hasLength(1));
      expect(s.isLanded(l2.entries.single.gen), isTrue, reason: 'offered as landed, so replay deletes it and merges nothing');
    } finally {
      held.closeSync();
    }
  }, skip: !Platform.isWindows ? 'needs a file the OS will not delete while it is open' : false);
}

// The name entries had before the layout changed (case folded everywhere).
String _legacyName(String folder, String id) {
  var h = 0xcbf29ce484222325;
  for (final u in utf8.encode('${folder.replaceAll(r'\', '/').toLowerCase()}|$id')) {
    h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return '$id-${h.toRadixString(16)}';
}
