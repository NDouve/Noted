// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/export/export_targets.dart';

void main() {
  late Directory temp;
  late Directory binder, pages, recovery, cache, appData, outside;

  String sub(Directory d, String name) => '${d.path}${Platform.pathSeparator}$name';

  Directory dir(String name) => Directory(sub(temp, name))..createSync(recursive: true);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('noted_export_targets');
    binder = dir('binders/B');
    pages = dir('pages');
    recovery = dir('app/recovery');
    cache = dir('app/cache');
    appData = dir('app');
    outside = dir('Documents');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  ExportTargetCheck check({
    bool? caseInsensitive,
    bool sandboxed = false,
    String Function(String)? resolve,
    List<String>? roots,
  }) => ExportTargetCheck(
    roots: () => roots ?? [binder.path, pages.path, recovery.path, cache.path, appData.path],
    caseInsensitive: caseInsensitive,
    sandboxed: sandboxed,
    resolve: resolve,
  );

  test('a place outside Noted\'s folders is allowed', () {
    expect(check().refuses(sub(outside, 'out.txt')), isFalse);
    expect(exportTargetRefusedMessage, "Choose a place outside Noted's folders.");
  });

  test('every refused folder, and everything below it, is refused', () {
    final c = check();
    for (final d in [binder, pages, recovery, cache, appData]) {
      expect(c.refuses(sub(d, 'x.txt')), isTrue, reason: d.path);
      expect(c.refuses(d.path), isTrue, reason: d.path);
    }
    // Inside a page's assets folder and a binder's templates.
    expect(c.refuses(sub(Directory(sub(pages, 'p.assets'))..createSync(), 'x.png')), isTrue);
    expect(c.refuses(sub(Directory(sub(binder, 'templates'))..createSync(), 'x.notedtemplate')), isTrue);
  });

  test('a new file under a refused parent that does not exist yet is refused too', () {
    expect(check().refuses(sub(binder, 'new/deep/x.txt')), isTrue);
  });

  test('a sibling with the same prefix is not inside the folder (whole components)', () {
    final near = dir('pages-two');
    expect(check().refuses(sub(near, 'x.txt')), isFalse);
  });

  test('case does not matter where paths are case-insensitive, and does where they are not', () {
    // No file system in the way (its own case rules, and a parent that does not
    // exist is refused): only the comparison of components.
    String same(String p) => p;
    final upper = sub(pages, 'X.txt').replaceFirst('pages', 'PAGES');
    expect(check(caseInsensitive: true, resolve: same).refuses(upper), isTrue);
    expect(check(caseInsensitive: false, resolve: same).refuses(upper), isFalse);
    // Components compare lowercased when insensitive: a different-case root name.
    final roots = [pages.path.toUpperCase()];
    expect(check(caseInsensitive: true, resolve: same, roots: roots).refuses(sub(pages, 'x.txt')), isTrue);
    expect(check(caseInsensitive: false, resolve: same, roots: roots).refuses(sub(pages, 'x.txt')), isFalse);
  });

  test('a symlink into a refused folder is refused', () {
    final link = Link(sub(outside, 'shortcut'));
    try {
      link.createSync(binder.path);
    } on FileSystemException {
      // Symlinks need a privilege on Windows; the other tests cover the rest.
      markTestSkipped('symlinks are not allowed here');
      return;
    }
    expect(check().refuses(sub(Directory(link.path), 'x.txt')), isTrue);
    expect(check().refuses(link.path), isTrue);
  });

  test('a path that can\'t be resolved is refused', () {
    final c = check(
      resolve: (p) => throw FileSystemException('cannot resolve', p, const OSError('no', 5)),
    );
    expect(c.refuses(sub(outside, 'x.txt')), isTrue);
  });

  test('a root that can\'t be resolved is compared by its stored path', () {
    final gone = sub(temp, 'gone/pages');
    expect(check(roots: [gone]).refuses('$gone${Platform.pathSeparator}x.txt'), isTrue);
    expect(check(roots: [gone]).refuses(sub(outside, 'x.txt')), isFalse);
  });

  group('in the macOS sandbox', () {
    // The parent can't be resolved (EPERM): the granted path itself is compared.
    String deny(String p) => throw FileSystemException('denied', p, const OSError('Operation not permitted', 1));

    test('an EPERM parent is checked by the granted path', () {
      final inside = sub(binder, 'x.txt');
      final out = sub(outside, 'x.txt');
      expect(check(sandboxed: true, resolve: deny).refuses(inside), isTrue, reason: 'inside a refused root');
      expect(check(sandboxed: true, resolve: deny).refuses(out), isFalse, reason: 'outside every root');
      expect(check(sandboxed: true, resolve: deny).refuses(out, granted: inside), isTrue, reason: 'the granted URL is inside');
    });

    test('without the sandbox an EPERM is refused', () {
      expect(check(resolve: deny).refuses(sub(outside, 'x.txt')), isTrue);
    });

    test('a different error is refused even in the sandbox', () {
      String broken(String p) => throw FileSystemException('broken', p, const OSError('io', 5));
      expect(check(sandboxed: true, resolve: broken).refuses(sub(outside, 'x.txt')), isTrue);
    });
  });

  test('the key drops a \\\\?\\ prefix and dot parts', () {
    final c = check(caseInsensitive: false);
    expect(c.keyOf(r'\\?\C:\a\.\b\..\c'), ['C:', 'a', 'c']);
    expect(c.keyOf(r'\\?\UNC\server\share\x'), ['server', 'share', 'x']);
  });
}
