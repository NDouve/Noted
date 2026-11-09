// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

NotedPage _page(String id, String title) =>
    NotedPage.create(PageMeta.create(id: id, title: title, order: 0));

// The name entries had before the layout changed (case folded everywhere).
String _legacyName(String folder, String id) {
  var h = 0xcbf29ce484222325;
  for (final u in utf8.encode('${folder.replaceAll(r'\', '/').toLowerCase()}|$id')) {
    h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return '$id-${h.toRadixString(16)}';
}

Future<void> Function(String) _failAt(String point) =>
    (p) async {
      if (p == point) throw const FileSystemException('injected');
    };

void main() {
  late Directory root;
  late Directory dir;
  final t = DateTime.utc(2026, 10, 25, 10);
  final later = t.add(const Duration(minutes: 1));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_recovery_store');
    dir = Directory('${root.path}/rec');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  List<String> files(String ext) => dir.existsSync()
      ? [
          for (final f in dir.listSync())
            if (f is File && f.path.endsWith(ext)) f.path,
        ]
      : [];

  RecoveryStore store({Future<void> Function(String)? hook}) => RecoveryStore(dir, windows: false, hook: hook);

  // An entry in the layout used before the single file.
  void legacy(String folder, NotedPage page, {String? base, String? stem, NotedPage? canvas, DateTime? time}) {
    dir.createSync(recursive: true);
    final s = stem ?? _legacyName(folder, page.id);
    File('${dir.path}/$s.canvas').writeAsStringSync(writePage(canvas ?? page));
    File('${dir.path}/$s.json').writeAsStringSync(
      jsonEncode({
        'format': 1,
        'folder': folder,
        'pageId': page.id,
        'time': (time ?? t).toIso8601String(),
        'base': base,
      }),
    );
  }

  group('R-5 location identity', () {
    test('case-distinct locations are separate entries when case matters', () async {
      final s = store();
      await s.write(folder: '/Notes', page: _page('p1', 'upper'), baseText: null, time: t);
      await s.write(folder: '/notes', page: _page('p1', 'lower'), baseText: null, time: t);
      final l = await s.list();
      expect(l.problems, isEmpty);
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'upper', 'lower'});
    });

    test('on Windows they are one location', () async {
      final s = RecoveryStore(dir, windows: true);
      await s.write(folder: r'D:\Notes', page: _page('p1', 'one'), baseText: null, time: t);
      await s.write(folder: 'd:/notes', page: _page('p1', 'two'), baseText: null, time: t);
      final l = await s.list();
      expect(l.entries, hasLength(1));
      expect(l.entries.single.page.meta.title, 'two');
    });

    test('an old entry is migrated, nothing lost, and it is idempotent', () async {
      legacy(r'D:\Notes', _page('p1', 'old'), base: writePage(_page('p1', 'base')));
      final s = store();
      final l = await s.list();
      expect(l.problems, isEmpty);
      final e = l.entries.single;
      expect(e.page.meta.title, 'old');
      expect(e.folder, r'D:\Notes');
      expect(e.baseText, writePage(_page('p1', 'base')));
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
      expect(files('.entry'), hasLength(1));
      final again = await s.list();
      expect(again.entries, hasLength(1));
      expect(again.problems, isEmpty);
    });

    test('an old entry newer than the existing one of its page is kept beside it', () async {
      const rel = 'relative_notes_folder';
      final abs = File(rel).absolute.path;
      await store().write(folder: rel, page: _page('p1', 'existing'), baseText: null, time: t);
      legacy(abs, _page('p1', 'old'), time: later);
      expect(_legacyName(rel, 'p1') == _legacyName(abs, 'p1'), isFalse);
      final s = store();
      final l = await s.list();
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'existing', 'old'});
      expect(l.problems, isEmpty);
      expect(l.damaged, isEmpty);
      expect(files('.entry'), hasLength(2));
      expect(files('.canvas'), isEmpty);
      final again = await s.list();
      expect(again.entries, hasLength(2));
      expect(again.problems, isEmpty);
    });

    test('an old entry with the same time but other content is kept beside the existing one', () async {
      const rel = 'relative_notes_folder';
      final abs = File(rel).absolute.path;
      await store().write(folder: rel, page: _page('p1', 'existing'), baseText: null, time: t);
      legacy(abs, _page('p1', 'old'), time: t);
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'existing', 'old'});
      expect(l.problems, isEmpty);
      expect(files('.entry'), hasLength(2));
      expect(files('.canvas'), isEmpty);
    });

    test('an old entry identical to the existing one, or older than it, is superseded', () async {
      const rel = 'relative_notes_folder';
      final abs = File(rel).absolute.path;
      await store().write(folder: rel, page: _page('p1', 'existing'), baseText: null, time: t);
      legacy(abs, _page('p1', 'existing'), time: later); // same page and base, a later time
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'existing');
      expect(l.problems, isEmpty);
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);

      legacy(abs, _page('p1', 'other'), time: t.subtract(const Duration(hours: 1)));
      final l2 = await store().list();
      expect(l2.entries.single.page.meta.title, 'existing');
      expect(l2.problems, isEmpty);
      expect(files('.entry'), hasLength(1));
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
    });

    test('an old entry whose time can\'t be read is never superseded: kept and reported', () async {
      const rel = 'relative_notes_folder';
      final abs = File(rel).absolute.path;
      await store().write(folder: rel, page: _page('p1', 'existing'), baseText: null, time: later);
      legacy(abs, _page('p1', 'old'), time: t);
      final j = File('${dir.path}/${_legacyName(abs, 'p1')}.json');
      j.writeAsStringSync(j.readAsStringSync().replaceFirst(t.toIso8601String(), 'not a time'));
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'existing');
      expect(l.problems, hasLength(1));
      expect(files('.canvas'), hasLength(1));
      expect(files('.json'), hasLength(1));
    });

    test('an old entry superseded by a later one and stopped between the deletes leaves nothing to report', () async {
      const rel = 'relative_notes_folder';
      final abs = File(rel).absolute.path;
      await store().write(folder: rel, page: _page('p1', 'existing'), baseText: null, time: later);
      legacy(abs, _page('p1', 'old'), time: t);
      File('${dir.path}/${_legacyName(abs, 'p1')}.canvas').deleteSync(); // stopped after the first delete
      expect(files('.json'), hasLength(1));
      final l = await store().list();
      expect(l.problems, isEmpty);
      expect(files('.json'), isEmpty);
      expect(l.entries.single.page.meta.title, 'existing');
    });

    test('a migration stopped after publishing is finished later without a duplicate', () async {
      legacy(r'D:\Notes', _page('p1', 'old'));
      final first = await store(hook: _failAt('envelope-published')).list();
      expect(first.entries.length, lessThanOrEqualTo(1));
      expect(files('.entry'), hasLength(1));
      expect(files('.canvas'), hasLength(1)); // the old files are still there
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(l.problems, isEmpty);
      expect(files('.entry'), hasLength(1));
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
    });

    test('a migration stopped between the two deletes leaves nothing to report', () async {
      legacy(r'D:\Notes', _page('p1', 'old'));
      await store().list();
      legacy(r'D:\Notes', _page('p1', 'old')); // stopped after the first delete: only the page is left
      File('${dir.path}/${_legacyName(r'D:\Notes', 'p1')}.json').deleteSync();
      expect(files('.canvas'), hasLength(1));
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(l.problems, isEmpty);
      expect(files('.canvas'), isEmpty);
      expect(files('.entry'), hasLength(1));
    });

    test('a listing stopped between the two deletes finishes the migration before returning', () async {
      legacy(r'D:\Notes', _page('p1', 'old'));
      final l = await store(hook: _failAt('legacy-first-deleted')).list();
      expect(l.entries, hasLength(1));
      expect(l.problems, isEmpty);
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
    });

    test('a lone old metadata file that an entry already holds is removed, not reported', () async {
      legacy(r'D:\Notes', _page('p1', 'old'), base: writePage(_page('p1', 'b')));
      await store().list();
      final meta = jsonEncode({
        'format': 1,
        'folder': r'D:\Notes',
        'pageId': 'p1',
        'time': t.toIso8601String(),
        'base': writePage(_page('p1', 'b')),
      });
      File('${dir.path}/${_legacyName(r'D:\Notes', 'p1')}.json').writeAsStringSync(meta);
      final l = await store().list();
      expect(l.problems, isEmpty);
      expect(files('.json'), isEmpty);
      expect(l.entries, hasLength(1));
    });

    test('a lone old file that no entry holds is kept and reported', () async {
      dir.createSync(recursive: true);
      File('${dir.path}/orphan-1.canvas').writeAsStringSync(writePage(_page('p1', 'x')));
      final l = await store().list();
      expect(l.entries, isEmpty);
      expect(l.problems, hasLength(1));
      expect(File('${dir.path}/orphan-1.canvas').existsSync(), isTrue);
    });

    test('a lone old metadata file with another base and an equal time is kept and reported', () async {
      legacy(r'D:\Notes', _page('p1', 'old'), base: writePage(_page('p1', 'b')));
      await store().list();
      File('${dir.path}/${_legacyName(r'D:\Notes', 'p1')}.json').writeAsStringSync(
        jsonEncode({
          'format': 1,
          'folder': r'D:\Notes',
          'pageId': 'p1',
          'time': t.toIso8601String(),
          'base': writePage(_page('p1', 'another base')),
        }),
      );
      final l = await store().list();
      expect(l.problems, hasLength(1));
      expect(files('.json'), hasLength(1));
      expect(l.entries, hasLength(1));
    });

    test('a lone old metadata file that only a promoted tmp holds is removed in the same listing', () async {
      await expectLater(
        store(hook: _failAt('tmp-written')).write(
          folder: r'D:\Notes',
          page: _page('p1', 'new'),
          baseText: null,
          time: later,
        ),
        throwsA(isA<FileSystemException>()),
      );
      File('${dir.path}/${_legacyName(r'D:\Notes', 'p1')}.json').writeAsStringSync(
        jsonEncode({
          'format': 1,
          'folder': r'D:\Notes',
          'pageId': 'p1',
          'time': t.toIso8601String(),
          'base': null,
        }),
      );
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'new');
      expect(l.problems, isEmpty);
      expect(files('.json'), isEmpty);
    });
  });

  group('R-10 one generation', () {
    test('a crash before publishing: a newer complete generation is promoted', () async {
      final base1 = writePage(_page('p1', 'base-one'));
      final base2 = writePage(_page('p1', 'base-two'));
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: base1, time: t);
      await expectLater(
        store(hook: _failAt('tmp-written')).write(folder: '/n', page: _page('p1', 'two'), baseText: base2, time: later),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.tmp'), hasLength(1));
      final l = await store().list();
      final e = l.entries.single;
      // The page and the base are of the same generation.
      expect(e.page.meta.title, 'two');
      expect(e.baseText, base2);
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('a crash before publishing: a leftover that is older, or identical, is deleted as superseded', () async {
      final base1 = writePage(_page('p1', 'base-one'));
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: base1, time: t);
      await expectLater(
        store(hook: _failAt('tmp-written')).write(
          folder: '/n',
          page: _page('p1', 'two'),
          baseText: null,
          time: t.subtract(const Duration(minutes: 1)),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        store(hook: _failAt('tmp-written')).write(folder: '/n', page: _page('p1', 'one'), baseText: base1, time: t),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.tmp'), hasLength(2));
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'one');
      expect(l.entries.single.baseText, base1);
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('a leftover with the same time but other content is kept as a second entry', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      await expectLater(
        store(hook: _failAt('tmp-written')).write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: t),
        throwsA(isA<FileSystemException>()),
      );
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'one', 'two'});
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
      expect(files('.entry'), hasLength(2));
    });

    test('a leftover of a fresh slot goes to a free slot, never over the entry in slot 1', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final slot1 = File(files('.entry').single);
      final before = slot1.readAsStringSync();
      await expectLater(
        store(hook: _failAt('tmp-written')).write(
          folder: '/n',
          page: _page('p1', 'two'),
          baseText: null,
          time: later,
          freshSlot: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.tmp').single, contains('_dup2.entry.'));
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'one', 'two'});
      expect(l.problems, isEmpty);
      expect(slot1.readAsStringSync(), before, reason: 'the entry in slot 1 is untouched');
      expect(files('.tmp'), isEmpty);
    });

    test('a leftover whose time can\'t be read is never superseded: kept and reported', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: later);
      await expectLater(
        store(hook: _failAt('tmp-written')).write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: t),
        throwsA(isA<FileSystemException>()),
      );
      final tmp = File(files('.tmp').single);
      tmp.writeAsStringSync(tmp.readAsStringSync().replaceFirst(t.toIso8601String(), 'not a time'));
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'one');
      expect(l.problems, hasLength(1));
      expect(files('.tmp'), hasLength(1));
    });

    test('a crash on the first write: the complete leftover becomes the entry', () async {
      await expectLater(
        store(hook: _failAt('tmp-written')).write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.entry'), isEmpty);
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'one');
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('a leftover that is cut short or inconsistent is kept and reported', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final entry = File(files('.entry').single);
      final text = entry.readAsStringSync();
      File('${entry.path}.1-1.tmp').writeAsStringSync(text.substring(0, text.length ~/ 2));
      final m = jsonDecode(text) as Map<String, dynamic>;
      m['pageId'] = 'other';
      File('${entry.path}.2-2.tmp').writeAsStringSync(jsonEncode(m));
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(l.entries.single.page.meta.title, 'one');
      expect(l.problems, hasLength(2));
      expect(l.damaged, hasLength(2));
      expect(files('.tmp'), hasLength(2));
    });

    test('a leftover that another slot already holds is deleted, not renamed over an older slot', () async {
      await store().write(folder: '/n', page: _page('p1', 'old'), baseText: null, time: t);
      final slot1 = File(files('.entry').single);
      final oldText = slot1.readAsStringSync();
      await store().write(folder: '/n', page: _page('p1', 'new'), baseText: null, time: later);
      final newText = slot1.readAsStringSync();
      slot1.writeAsStringSync(oldText);
      File(slot1.path.replaceFirst('.entry', '_dup2.entry')).writeAsStringSync(newText);
      File('${slot1.path}.9-9.tmp').writeAsStringSync(newText);
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title).toList()..sort(), ['new', 'old']);
      expect(files('.tmp'), isEmpty);
      expect(files('.entry'), hasLength(2));
    });

    test('an unfinished write of the old layout is removed if an entry holds it, else reported', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      File('${dir.path}/a-1.canvas.tmp').writeAsStringSync(writePage(_page('p1', 'one')));
      File('${dir.path}/b-1.canvas.tmp').writeAsStringSync(writePage(_page('p1', 'not held')));
      final l = await store().list();
      expect(l.problems, hasLength(1));
      expect(files('.tmp').map((p) => p.split(RegExp(r'[\\/]')).last), ['b-1.canvas.tmp']);
    });

    test('a rename that fails keeps the complete tmp file, which the next listing promotes', () async {
      final s = store();
      await s.write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final entry = File(files('.entry').single);
      entry.deleteSync();
      Directory(entry.path).createSync(); // the rename can't replace a folder
      await expectLater(
        s.write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.tmp'), hasLength(1));
      Directory(entry.path).deleteSync();
      final l = await s.list();
      expect(l.entries.single.page.meta.title, 'two');
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('deleting a listed entry keeps a generation written after the listing', () async {
      final s = store();
      await s.write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final listed = (await s.list()).entries.single;
      await s.write(folder: '/n', page: _page('p1', 'newer'), baseText: null, time: later);
      await s.delete(listed);
      expect((await s.list()).entries.single.page.meta.title, 'newer');
      // The generation that was listed is deleted.
      await s.delete((await s.list()).entries.single);
      expect(files('.entry'), isEmpty);
    });

    test('an entry of another location or page under the same name is not overwritten', () async {
      // Entry for /a stored under the name that /b would use.
      final scratch = Directory('${root.path}/scratch');
      await RecoveryStore(scratch, windows: false).write(folder: '/b', page: _page('p1', 'b'), baseText: null, time: t);
      final nameOfB = scratch.listSync().single.path.split(RegExp(r'[\\/]')).last;
      await store().write(folder: '/a', page: _page('p1', 'a'), baseText: null, time: t);
      final entry = File(files('.entry').single);
      final aText = entry.readAsStringSync();
      final stolen = File('${dir.path}/$nameOfB');
      entry.renameSync(stolen.path);
      await store().write(folder: '/b', page: _page('p1', 'b'), baseText: null, time: later);
      expect(stolen.readAsStringSync(), aText);
      expect(files('.entry'), hasLength(2));
      expect(files('.entry').where((p) => p.contains('_dup2')), hasLength(1));
    });

    test('a listing waits for a write in progress', () async {
      final reached = Completer<void>();
      final gate = Completer<void>();
      final s = store(
        hook: (p) async {
          if (p != 'tmp-written') return;
          reached.complete();
          await gate.future;
        },
      );
      final w = s.write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      await reached.future;
      var listed = false;
      final listing = store().list().then((v) {
        listed = true;
        return v;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(listed, isFalse);
      gate.complete();
      await w;
      final l = await listing;
      expect(l.entries, hasLength(1));
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('another spelling of the folder shares the sequence (Windows)', () async {
      final reached = Completer<void>();
      final gate = Completer<void>();
      final w = RecoveryStore(
        dir,
        hook: (p) async {
          if (p != 'tmp-written') return;
          reached.complete();
          await gate.future;
        },
      ).write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      await reached.future;
      var listed = false;
      final other = RecoveryStore(Directory(dir.path.toUpperCase())).list().then((v) {
        listed = true;
        return v;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(listed, isFalse);
      gate.complete();
      await w;
      expect((await other).entries, hasLength(1));
    }, skip: !Platform.isWindows);

    test('an entry is one file', () async {
      await RecoveryStore(dir).write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      expect(dir.listSync().whereType<File>(), hasLength(1));
      expect(files('.entry'), hasLength(1));
    });
  });

  group('R-6 identities must agree', () {
    Future<File> valid({String? base}) async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: base, time: t);
      return File(files('.entry').single);
    }

    Future<void> expectRejected(String path) async {
      final l = await store().list();
      expect(l.entries, isEmpty);
      expect(l.problems, hasLength(1));
      expect(l.damaged, hasLength(1));
      expect(File(path).existsSync(), isTrue);
    }

    test('the metadata page id differs from the page', () async {
      final f = await valid();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      m['pageId'] = 'other';
      f.writeAsStringSync(jsonEncode(m));
      await expectRejected(f.path);
    });

    test('the page is another page', () async {
      final f = await valid();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      m['page'] = writePage(_page('p2', 'two'));
      f.writeAsStringSync(jsonEncode(m));
      await expectRejected(f.path);
    });

    test('the base is another page', () async {
      final f = await valid(base: writePage(_page('p1', 'base')));
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      m['base'] = writePage(_page('p2', 'base'));
      f.writeAsStringSync(jsonEncode(m));
      await expectRejected(f.path);
    });

    test('the file name belongs to another entry', () async {
      final f = await valid();
      final moved = File('${dir.path}/p9-123.entry');
      f.renameSync(moved.path);
      await expectRejected(moved.path);
    });

    test('an old entry whose canvas is another page is not converted', () async {
      legacy('/n', _page('p1', 'one'), canvas: _page('p2', 'two'));
      final l = await store().list();
      expect(l.entries, isEmpty);
      expect(l.problems, hasLength(1));
      expect(files('.canvas'), hasLength(1));
      expect(files('.json'), hasLength(1));
      expect(files('.entry'), isEmpty);
    });
  });

  group('R-1 an invalid envelope is never replaced or trusted', () {
    // Rewrites the single entry so its metadata still matches but [change]
    // alters the fields; returns the new text.
    String corrupt(void Function(Map<String, dynamic> m) change) {
      final entry = File(files('.entry').single);
      final m = jsonDecode(entry.readAsStringSync()) as Map<String, dynamic>;
      change(m);
      final text = jsonEncode(m);
      entry.writeAsStringSync(text);
      return text;
    }

    for (final (name, change) in <(String, void Function(Map<String, dynamic>))>[
      ('the embedded page is another page', (m) => m['page'] = writePage(_page('other', 'x'))),
      ('the embedded page is unreadable', (m) => m['page'] = 'not a page'),
    ]) {
      test('a write over a slot whose $name keeps it and writes _dup2', () async {
        await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
        final slot1 = File(files('.entry').single);
        final bad = corrupt(change);
        await store().write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later);
        expect(slot1.readAsStringSync(), bad);
        final dup = files('.entry').where((p) => p.endsWith('_dup2.entry')).toList();
        expect(dup, hasLength(1));
        expect(jsonDecode(File(dup.single).readAsStringSync())['time'], later.toIso8601String());
        final l = await store().list();
        expect(l.entries.single.page.meta.title, 'two');
        // Only the invalid entry: a readable _dup slot is an entry like any other.
        expect(l.problems, hasLength(1));
      });
    }

    test('a valid tmp is not deleted against an invalid later envelope', () async {
      await store().write(folder: '/n', page: _page('p1', 'tmp'), baseText: null, time: later);
      final slot1 = File(files('.entry').single);
      File('${slot1.path}.9-9.tmp').writeAsStringSync(slot1.readAsStringSync());
      corrupt((m) {
        m['page'] = writePage(_page('other', 'x'));
        m['time'] = later.add(const Duration(hours: 1)).toIso8601String();
      });
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title), ['tmp']);
      expect(files('.tmp'), isEmpty);
      expect(files('.entry').where((p) => p.endsWith('_dup2.entry')), hasLength(1));
    });

    test('a lone old .canvas survives beside an invalid envelope with the same page text', () async {
      await store().write(folder: '/n', page: _page('p1', 'x'), baseText: null, time: t);
      final other = writePage(_page('other', 'x'));
      corrupt((m) => m['page'] = other);
      File('${dir.path}/a-1.canvas').writeAsStringSync(other);
      await store().list();
      expect(files('.canvas'), hasLength(1));
    });

    test('a tmp survives beside an envelope with the wrong file name and the same content', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final slot1 = File(files('.entry').single);
      final text = slot1.readAsStringSync();
      slot1.renameSync('${dir.path}/wrong-name.entry');
      File('${slot1.path}.9-9.tmp').writeAsStringSync(text);
      await store().list();
      expect(files('.tmp'), isEmpty);
      expect(slot1.existsSync(), isTrue);
      expect(slot1.readAsStringSync(), text);
    });

    test('migration does not delete an old copy because of an invalid envelope', () async {
      await store().write(folder: '/n', page: _page('p1', 'x'), baseText: null, time: t);
      corrupt((m) {
        m['page'] = writePage(_page('other', 'x'));
        m['time'] = later.add(const Duration(hours: 1)).toIso8601String();
      });
      legacy('/n', _page('p1', 'old'));
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title), ['old']);
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
    });
  });
}
