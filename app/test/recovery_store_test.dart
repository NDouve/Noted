// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_core/noted_core.dart';

NotedPage _page(String id, String title) => NotedPage.create(PageMeta.create(id: id, title: title, order: 0));

// The name entries had before the layout changed (case folded everywhere).
String _legacyName(String folder, String id) {
  var h = 0xcbf29ce484222325;
  for (final u in utf8.encode('${folder.replaceAll(r'\', '/').toLowerCase()}|$id')) {
    h = ((h ^ u) * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return '$id-${h.toRadixString(16)}';
}

Future<void> Function(String) _failAt(String point) => (p) async {
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

  String name(String path) => path.split(RegExp(r'[\\/]')).last;

  RecoveryStore store({Future<void> Function(String)? hook}) => RecoveryStore(dir, windows: false, hook: hook);

  // An entry in the layout used before the single file (format 1).
  void legacy(String folder, NotedPage page, {String? base, NotedPage? canvas, DateTime? time}) {
    dir.createSync(recursive: true);
    final s = _legacyName(folder, page.id);
    File('${dir.path}/$s.canvas').writeAsStringSync(writePage(canvas ?? page));
    File('${dir.path}/$s.json').writeAsStringSync(
      jsonEncode({
        'format': 1,
        'folder': folder,
        'pageId': page.id,
        if (time != null || true) 'time': (time ?? t).toIso8601String(),
        'base': base,
      }),
    );
  }

  group('one entry per generation', () {
    test('every write is a new file and nothing is replaced', () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final b = await store().write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later);
      expect(a.gen, isNot(b.gen));
      expect(a.gen, hasLength(32));
      expect(files('.entry'), hasLength(2));
      expect(name(a.file.path), endsWith('.g${a.gen}.entry'));
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'one', 'two'});
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('the file is format 3, and the writer records its kind, session and device', () async {
      final e = await store().write(
        folder: '/n',
        page: _page('p1', 'one'),
        baseText: null,
        time: t,
        kind: 'ai',
        session: 'sess',
        device: 'DESKTOP',
        supersedes: const ['old'],
      );
      final m = jsonDecode(e.file.readAsStringSync()) as Map<String, dynamic>;
      expect(m['format'], 3);
      expect(m['gen'], e.gen);
      expect(m['writer'], {'kind': 'ai', 'session': 'sess', 'device': 'DESKTOP'});
      expect(m['supersedes'], ['old']);
      expect(m['created'], t.toIso8601String());
      final read = (await store().list()).entries.single;
      expect(read.kind, 'ai');
      expect(read.session, 'sess');
      expect(read.device, 'DESKTOP');
      expect(read.supersedes, ['old']);
    });

    test('an entry is one file', () async {
      await RecoveryStore(dir).write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      expect(dir.listSync().whereType<File>(), hasLength(1));
    });

    test('an entry named in another\'s supersedes is left out of live', () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      await store().write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later, supersedes: [a.gen]);
      final l = await store().list();
      expect(l.entries, hasLength(2));
      expect(l.live.map((e) => e.page.meta.title), ['two']);
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

    test('case-distinct locations are separate entries when case matters', () async {
      await store().write(folder: '/Notes', page: _page('p1', 'upper'), baseText: null, time: t);
      await store().write(folder: '/notes', page: _page('p1', 'lower'), baseText: null, time: t);
      expect(files('.entry'), hasLength(2));
      final stems = files('.entry').map((p) => name(p).split('.g').first).toSet();
      expect(stems, hasLength(2));
    });

    test('on Windows they are one location (one name prefix)', () async {
      final w = RecoveryStore(dir, windows: true);
      await w.write(folder: r'D:\Notes', page: _page('p1', 'a'), baseText: null, time: t);
      await w.write(folder: r'd:/notes', page: _page('p1', 'b'), baseText: null, time: t);
      final stems = files('.entry').map((p) => name(p).split('.g').first).toSet();
      expect(stems, hasLength(1));
    });
  });

  group('crash leftovers', () {
    test('a crash before publishing: the complete tmp is published by the next listing, whatever its time', () async {
      final base2 = writePage(_page('p1', 'base-two'));
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: later);
      await expectLater(
        store(hook: _failAt('tmp-written')).write(folder: '/n', page: _page('p1', 'two'), baseText: base2, time: t),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.tmp'), hasLength(1));
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title).toSet(), {'one', 'two'});
      expect(l.entries.firstWhere((e) => e.page.meta.title == 'two').baseText, base2);
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
    });

    test('a tmp that a name of its generation already holds is deleted (a hard link left behind)', () async {
      final e = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      File('${e.file.path}.9-9.tmp').writeAsBytesSync(e.file.readAsBytesSync());
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(l.problems, isEmpty);
      expect(files('.tmp'), isEmpty);
      expect(files('.entry'), hasLength(1));
    });

    test('a tmp whose name holds other bytes is kept and reported', () async {
      final e = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final m = jsonDecode(e.file.readAsStringSync()) as Map<String, dynamic>;
      m['created'] = later.toIso8601String();
      File('${e.file.path}.9-9.tmp').writeAsStringSync(jsonEncode(m));
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(l.problems, hasLength(1));
      expect(files('.tmp'), hasLength(1));
    });

    test('a leftover that is cut short or inconsistent is kept and reported', () async {
      final e = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final text = e.file.readAsStringSync();
      File('${e.file.path}.1-1.tmp').writeAsStringSync(text.substring(0, text.length ~/ 2));
      final m = jsonDecode(text) as Map<String, dynamic>;
      m['pageId'] = 'other';
      File('${e.file.path}.2-2.tmp').writeAsStringSync(jsonEncode(m));
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(l.problems, hasLength(2));
      expect(l.damaged, hasLength(2));
      expect(files('.tmp'), hasLength(2));
    });

    test('an unfinished write of the old layout is removed if an entry holds it, else reported', () async {
      await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      File('${dir.path}/a-1.canvas.tmp').writeAsStringSync(writePage(_page('p1', 'one')));
      File('${dir.path}/b-1.canvas.tmp').writeAsStringSync(writePage(_page('p1', 'not held')));
      final l = await store().list();
      expect(l.problems, hasLength(1));
      expect(files('.tmp').map(name), ['b-1.canvas.tmp']);
    });

    test('a publish that fails drops its tmp (the caller keeps the edits)', () async {
      await expectLater(
        store(hook: (p) async {
          if (p == 'tmp-written') {
            // Something is at every name an entry could take: not possible to
            // know it here, so make the folder unusable for the publish.
            for (final f in dir.listSync()) {
              if (f is File && f.path.endsWith('.tmp')) {
                final target = f.path.substring(0, f.path.indexOf('.entry') + '.entry'.length);
                Directory(target).createSync();
              }
            }
          }
        }).write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t),
        throwsA(isA<FileSystemException>()),
      );
      expect(files('.tmp'), isEmpty);
    });

    test('a file that ends in .collision is never read, folded or deleted', () async {
      final e = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final stray = File('${e.file.path}.collision')..writeAsBytesSync(e.file.readAsBytesSync());
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(stray.existsSync(), isTrue);
      expect(await store().retire(l.entries.single), isTrue);
      expect(stray.existsSync(), isTrue, reason: 'retire leaves it, with the name of the generation');
      expect(files('.entry'), isEmpty);
    });
  });

  group('format 2 and format 1', () {
    test('format 2 is read as a legacy entry, without a rewrite', () async {
      final folder = '/n';
      final name2 = _legacyName(folder, 'p1');
      dir.createSync(recursive: true);
      // The layout of a format 2 file, named as this build names the folder.
      final seed = await store().write(folder: folder, page: _page('p1', 'x'), baseText: null, time: t);
      final stem = name(seed.file.path).split('.g').first;
      File(seed.file.path).deleteSync();
      final text = jsonEncode({
        'format': 2,
        'folder': folder,
        'pageId': 'p1',
        'time': t.toIso8601String(),
        'base': null,
        'page': writePage(_page('p1', 'two')),
      });
      final f = File('${dir.path}/$stem.entry')..writeAsStringSync(text);
      expect(name2, isNotEmpty);
      final l = await store().list();
      final e = l.entries.single;
      expect(e.kind, 'legacy');
      expect(e.gen, startsWith('v2-'));
      expect(e.supersedes, isEmpty);
      expect(e.page.meta.title, 'two');
      expect(f.readAsStringSync(), text, reason: 'not rewritten');
      expect(files('.entry'), hasLength(1));
    });

    test('a format 1 pair is converted, and the old files go', () async {
      legacy('/n', _page('p1', 'one'));
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'one');
      expect(l.entries.single.gen, startsWith('v1-'));
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
      expect(files('.entry'), hasLength(1));
    });

    test('the same pair converted twice gives the same generation and the same bytes', () async {
      legacy('/n', _page('p1', 'one'), base: writePage(_page('p1', 'b')));
      final other = Directory('${root.path}/rec2')..createSync();
      for (final f in dir.listSync().whereType<File>()) {
        f.copySync('${other.path}/${name(f.path)}');
      }
      await store().list();
      await RecoveryStore(other, windows: false).list();
      final a = File(files('.entry').single);
      final b = other.listSync().whereType<File>().singleWhere((f) => f.path.endsWith('.entry'));
      expect(name(a.path), name(b.path));
      expect(a.readAsBytesSync(), b.readAsBytesSync());
      final m = jsonDecode(a.readAsStringSync()) as Map<String, dynamic>;
      expect(m['created'], t.toIso8601String());
      expect(m['writer'], {'kind': 'legacy', 'session': 'v1', 'device': ''});
      expect(m['supersedes'], isEmpty);
    });

    test('converting again after a stop between publishing and removing the old files leaves one entry', () async {
      legacy('/n', _page('p1', 'one'));
      await expectLater(
        store(hook: _failAt('envelope-published')).list(),
        completes,
      );
      // The first pass stopped (its failure is reported); the next finishes.
      final l = await store().list();
      expect(l.entries, hasLength(1));
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
      expect(files('.entry'), hasLength(1));
    });

    test('retiring a converted entry removes the pair it came from, so it is not converted again', () async {
      legacy('/n', _page('p1', 'one'));
      // The conversion stops after publishing, before the old files are removed.
      final listed = await store(hook: _failAt('envelope-published')).list();
      expect(listed.entries, hasLength(1));
      expect(files('.canvas'), hasLength(1));
      expect(await store().retire(listed.entries.single), isTrue);
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
      expect((await store().list()).entries, isEmpty);
    });

    test('a retire stopped between the two files of a converted pair leaves no lone .canvas, and finishes later', () async {
      legacy('/n', _page('p1', 'one'));
      final listed = await store(hook: _failAt('envelope-published')).list();
      var once = true;
      final stopping = store(
        hook: (p) async {
          if (p == 'legacy-pair-file-deleted' && once) {
            once = false;
            throw const FileSystemException('injected');
          }
        },
      );
      expect(await stopping.retire(listed.entries.single), isFalse);
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), hasLength(1));
      expect(await store().retire(listed.entries.single), isTrue);
      expect(files('.json'), isEmpty);
      expect((await store().list()).entries, isEmpty);
    });

    test('a lone old metadata file that an entry holds is removed, one that none holds is kept and reported', () async {
      final seed = await store().write(folder: '/n', page: _page('p1', 'x'), baseText: null, time: t);
      expect(seed.baseText, isNull);
      legacy('/n', _page('p1', 'x'));
      File('${dir.path}/${_legacyName('/n', 'p1')}.canvas').deleteSync();
      await store().list();
      expect(files('.json'), isEmpty);
      legacy('/n', _page('p2', 'y'), base: writePage(_page('p2', 'b')));
      File('${dir.path}/${_legacyName('/n', 'p2')}.canvas').deleteSync();
      final l = await store().list();
      expect(l.problems, hasLength(1));
      expect(files('.json'), hasLength(1));
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

  group('landing and retiring', () {
    test('markLanding renames to .landing, and unmarkLanding puts it back', () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final mark = await store().markLanding([a]);
      expect(mark.ok, isTrue);
      expect(files('.entry'), isEmpty);
      expect(files('.landing'), hasLength(1));
      final l = await store().list();
      expect(l.entries.single.landing, isTrue);
      expect(l.entries.single.gen, a.gen);
      await store().unmarkLanding(mark.renamed);
      expect(files('.landing'), isEmpty);
      expect(files('.entry'), hasLength(1));
      expect((await store().list()).entries.single.landing, isFalse);
    });

    test('a rename that fails puts back the ones before it and reports not ok', () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final b = await store().write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later);
      var n = 0;
      final mark = await store(
        hook: (p) async {
          if (p == 'landing-renamed' && ++n == 2) throw const FileSystemException('injected');
        },
      ).markLanding([a, b]);
      expect(mark.ok, isFalse);
      expect(files('.landing'), isEmpty);
      expect(files('.entry'), hasLength(2));
    });

    test('retire removes every name of a generation: .landing beside a hard-linked .entry, a .cas-old and a .landed',
        () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      // The rename leaves its source, as a hard link would on POSIX.
      final s = store(
        hook: (p) async {
          if (p == 'landing-renamed') {
            for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.landing')).toList()) {
              f.copySync(f.path.replaceFirst(RegExp(r'\.landing$'), '.entry'));
            }
          }
        },
      );
      expect((await s.markLanding([a])).ok, isTrue);
      final bytes = File(files('.landing').single).readAsBytesSync();
      File('${files('.landing').single.replaceFirst(RegExp(r'\.landing$'), '.entry')}.1-a-b.cas-old').writeAsBytesSync(bytes);
      File(files('.landing').single.replaceFirst(RegExp(r'\.landing$'), '.landed')).writeAsBytesSync(bytes);
      final listed = (await store().list()).entries;
      expect(listed, hasLength(1), reason: 'the names of one generation are one entry');
      expect(await store().retire(listed.single), isTrue);
      expect(dir.listSync().whereType<File>(), isEmpty, reason: 'no name of the generation is left');
    });

    test('a name that appears while retiring leaves the entry waiting to be retired', () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      var once = true;
      final original = a.file.readAsBytesSync();
      final s = store(
        hook: (p) async {
          if (p == 'retire-name-deleted' && once) {
            once = false;
            File('${a.file.path}.7-7.tmp').writeAsBytesSync(original);
          }
        },
      );
      final listed = (await store().list()).entries.single;
      expect(await s.retire(listed), isFalse);
      expect(files('.tmp'), hasLength(1));
      expect(File(files('.tmp').single).readAsBytesSync(), original);
      expect(await store().retire(listed), isTrue);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    test('retire keeps a generation written after the listing', () async {
      final s = store();
      final listed = await s.write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      await s.write(folder: '/n', page: _page('p1', 'newer'), baseText: null, time: later);
      expect(await s.retire(listed), isTrue);
      expect((await s.list()).entries.single.page.meta.title, 'newer');
    });

    test('ancestors are retired first; a crash between the deletes leaves the superseder alone', () async {
      final a = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: null, time: t);
      final b = await store().write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later, supersedes: [a.gen]);
      var deletes = 0;
      final s = store(
        hook: (p) async {
          if (p == 'retire-name-deleted' && ++deletes == 2) throw const FileSystemException('injected');
        },
      );
      expect(await s.retire(a), isTrue);
      expect(await s.retire(b), isFalse);
      // Never the other way: the ancestor is gone, so b alone is never exposed with it.
      final l = await store().list();
      expect(l.entries.map((e) => e.gen).toList()..sort(), isNot(contains(a.gen)));
    });
  });

  group('identities must agree', () {
    Future<File> valid({String? base}) async {
      final e = await store().write(folder: '/n', page: _page('p1', 'one'), baseText: base, time: t);
      return e.file;
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

    test('the generation in the file is not the one in its name', () async {
      final f = await valid();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      m['gen'] = 'abc123';
      f.writeAsStringSync(jsonEncode(m));
      await expectRejected(f.path);
    });

    test('an invalid entry is kept beside a new write, and never trusted', () async {
      final f = await valid();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      m['page'] = 'not a page';
      final bad = jsonEncode(m);
      f.writeAsStringSync(bad);
      await store().write(folder: '/n', page: _page('p1', 'two'), baseText: null, time: later);
      expect(f.readAsStringSync(), bad);
      final l = await store().list();
      expect(l.entries.single.page.meta.title, 'two');
      expect(l.problems, hasLength(1));
    });

    test('migration does not delete an old copy because of an invalid envelope', () async {
      final f = await valid();
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      m['page'] = writePage(_page('other', 'x'));
      f.writeAsStringSync(jsonEncode(m));
      legacy('/n', _page('p1', 'old'));
      final l = await store().list();
      expect(l.entries.map((e) => e.page.meta.title), ['old']);
      expect(files('.canvas'), isEmpty);
      expect(files('.json'), isEmpty);
    });
  });
}
