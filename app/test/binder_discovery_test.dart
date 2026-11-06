// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Binders found by id (0050): discovery reads the folders this device looks in
// and lists the binders other devices made, and remembers the ones this device
// removed. Real temp folders; no watchers (the two-instance test has those).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/open_files.dart';
import 'package:noted/src/recovery_store.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/busy_retry.dart';

Map<String, Object?> doc(String text) => {
  'document': {
    'type': 'page',
    'children': [
      {
        'type': 'paragraph',
        'data': {
          'delta': [
            {'insert': text},
          ],
        },
      },
    ],
  },
};

// A store that deletes its folder once, as the scan starts (another device
// removing it between the notebook's checks and its read).
class _VanishingStore extends PageStore {
  _VanishingStore(super.directory);

  static bool armed = false;

  @override
  Future<List<PageEntry>> scan({bool createFolder = true, bool sweep = true}) async {
    if (armed) {
      armed = false;
      await directory.delete(recursive: true);
    }
    return super.scan(createFolder: createFolder, sweep: sweep);
  }
}

// A settings file that exists but can't be read (a lock) until [unlocked],
// when both reads go to the real file.
class _LockedFile implements File {
  _LockedFile(this.real);

  final File real;
  bool unlocked = false;

  @override
  Future<bool> exists() async => unlocked ? real.exists() : true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async => unlocked
      ? real.readAsString(encoding: encoding)
      : throw FileSystemException('locked by another program', real.path);

  @override
  Future<Uint8List> readAsBytes() async =>
      unlocked ? real.readAsBytes() : throw FileSystemException('locked by another program', real.path);

  @override
  String get path => real.path;

  @override
  Directory get parent => real.parent;

  @override
  File get absolute => real.absolute;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<File> rename(String newPath) => real.rename(newPath);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
}

// The binder test seam: counts every point that fires, throws a lock at
// `settings-read` while [locked], and runs [on] for a point.
class _Hooks {
  bool locked = false;
  final fired = <String, int>{};
  final on = <String, Future<void> Function(String path)>{};

  int count(String point) => fired[point] ?? 0;

  Future<void> call(String point, String path) async {
    fired[point] = count(point) + 1;
    if (point == 'settings-read' && locked) {
      throw FileSystemException('locked by another program', path);
    }
    await on[point]?.call(path);
  }
}

Binder mkBinder({required String title, required String id}) =>
    Binder.create(title: title, id: id, color: binderPalette.first);

void main() {
  late Directory root;
  late ModuleRegistry modules;
  late List<Notebook> opened;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_discovery');
    await Directory('${root.path}/pages').create();
    modules = buildModules();
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      nb.binderHook = null;
      nb.syncHook = null;
      await nb.discoveryIdle;
      await nb.flush();
      nb.dispose();
    }
    await busyRetry(() => root.delete(recursive: true));
  });

  String k(String p) {
    final s = File(p).absolute.path.replaceAll(r'\', '/');
    return Platform.isWindows ? s.toLowerCase() : s;
  }

  String at(String rel) => '${root.path}/$rel';

  File settingsFile() => File(at('binders.json'));

  Map<String, Object?> saved() => jsonDecode(settingsFile().readAsStringSync()) as Map<String, Object?>;

  void writeSettings(Map<String, Object?> m) => settingsFile().writeAsStringSync(jsonEncode(m));

  // A binder another device made: its folder, binder file and pages.
  Future<String> binderAt(String rel, String id, {String? title, List<String> pages = const []}) async {
    final dir = Directory(at(rel));
    await dir.create(recursive: true);
    await BinderStore(dir).create(mkBinder(title: title ?? rel.split('/').last, id: id));
    for (final p in pages) {
      await PageStore(dir).save(NotedPage.create(PageMeta.create(id: p, title: 'Page $p', order: 0)));
    }
    return dir.path;
  }

  Notebook make({
    File? file,
    PageStore Function(Directory)? storeFactory,
    String pagesRel = 'pages',
    String settingsName = 'binders.json',
    Directory? templates,
    bool watch = false,
    Duration? interval,
    Duration? retryFirst,
    AppSettings? settings,
    Future<String?> Function()? pick,
  }) {
    final nb = Notebook(
      PageStore(Directory(at(pagesRel))),
      modules,
      saveDelay: Duration.zero,
      bindersFile: file ?? File(at(settingsName)),
      storeFactory: storeFactory ?? PageStore.new,
      templatesDirectory: templates,
      watchFiles: watch,
      watchDebounce: const Duration(milliseconds: 50),
      discoveryDebounce: const Duration(milliseconds: 50),
      folderCheckInterval: interval ?? const Duration(seconds: 3),
      settingsRetryFirst: retryFirst ?? const Duration(hours: 1),
      settings: settings,
      pickFolder: pick,
    );
    opened.add(nb);
    return nb;
  }

  Future<Notebook> start({
    File? file,
    PageStore Function(Directory)? storeFactory,
    Directory? templates,
    int? removedCap,
  }) async {
    final nb = make(file: file, storeFactory: storeFactory, templates: templates);
    if (removedCap != null) nb.setDiscoveryLimitsForTest(removed: removedCap);
    await nb.load();
    await nb.discoveryIdle;
    return nb;
  }

  Future<Notebook> restart(Notebook nb, {int? removedCap}) async {
    await nb.discoveryIdle;
    await nb.flush();
    nb.dispose();
    opened.remove(nb);
    return start(removedCap: removedCap);
  }

  Set<String> listedKeys(Notebook nb) => {for (final b in nb.binders) k(b.path)};

  List<String> idsOf(Notebook nb) => [for (final b in nb.binders) ?b.binder?.id]..sort();

  List<String> treeOf(BinderSection s) {
    final out = <String>[];
    void walk(PageMeta m, int depth) {
      out.add('${'  ' * depth}${m.id}:${m.title}');
      for (final c in s.tree.childrenOf(m.id)) {
        walk(c, depth + 1);
      }
    }

    for (final r in s.tree.roots) {
      walk(r, 0);
    }
    return out;
  }

  const a1 = 'a000000000000001';
  const a2 = 'a000000000000002';
  const a3 = 'a000000000000003';
  const a4 = 'a000000000000004';

  group('found binders', () {
    test(
      '1: found in the default binder folder, the page folder, a standalone folder and beside an unavailable binder',
      () async {
        Directory(at('extra')).createSync();
        writeSettings({
          'format': 1,
          'binders': [at('other/Gone')],
          'binderIds': <String, Object?>{},
          'standaloneFolders': [at('extra')],
        });
        await binderAt('binders/B1', a1);
        await binderAt('pages/B2', a2);
        await binderAt('extra/B3', a3);
        await binderAt('other/B4', a4);
        final nb = await start();
        expect(idsOf(nb), [a1, a2, a3, a4]);
        // The unavailable listed binder stays as it was.
        final gone = nb.binders.firstWhere((b) => k(b.path) == k(at('other/Gone')));
        expect(gone.available, isFalse);
        // Nothing was created in the shared folders.
        expect(Directory(at('other')).listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toSet(), {'B4'});
      },
    );

    test('1: a standalone folder that holds a binder file is not added (its sibling is)', () async {
      await binderAt('Listed', a1);
      Directory(at('s1')).createSync();
      writeSettings({
        'format': 1,
        'binders': [at('Listed')],
        'binderIds': {at('Listed'): a1},
        'standaloneFolders': [at('s1')],
      });
      await BinderStore(Directory(at('s1'))).create(mkBinder(title: 'Standalone', id: a2));
      await binderAt('Sib', a3);
      final nb = await start();
      expect(listedKeys(nb), {k(at('Listed')), k(at('Sib'))});
    });

    test('2: a removed binder is not listed again by a pass or after a restart; Open binder re-adds it', () async {
      await binderAt('binders/B1', a1);
      await binderAt('binders/B2', a2);
      var nb = await start();
      expect(idsOf(nb), [a1, a2]);
      final b1 = nb.binders.firstWhere((b) => b.binder!.id == a1).path;
      await nb.removeBinder(b1);
      expect((saved()['removedBinders'] as List), [a1]);
      await nb.discoverBinders();
      await nb.discoveryIdle;
      expect(idsOf(nb), [a2]);
      // A binder made afterwards is found (control).
      await binderAt('binders/B3', a3);
      await nb.discoverBinders();
      expect(idsOf(nb), [a2, a3]);
      nb = await restart(nb);
      expect(idsOf(nb), [a2, a3]);
      // Open binder… (a hand add) lists it and clears the id.
      await nb.addBinder(b1);
      expect(idsOf(nb), [a1, a2, a3]);
      expect((saved()['removedBinders'] as List? ?? const []), isEmpty);
      expect((saved()['binderIds'] as Map)[b1], a1);
      nb = await restart(nb);
      expect(idsOf(nb), [a1, a2, a3]);
    });

    for (final firstD1 in [true, false]) {
      test(
        '3: one id in two folders under different roots is added in neither (${firstD1 ? 'D1 first' : 'D2 first'}) and after a reload',
        () async {
          writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
          // The folders arrive in the order given; the pass sees both together.
          if (firstD1) {
            await binderAt('binders/D1', a1, title: 'Twin');
            await binderAt('pages/D2', a1, title: 'Twin');
          } else {
            await binderAt('pages/D2', a1, title: 'Twin');
            await binderAt('binders/D1', a1, title: 'Twin');
          }
          await binderAt('binders/Control', a2);
          var nb = await start();
          expect(idsOf(nb), [a2], reason: 'neither twin is listed (the control is)');
          expect(nb.discoveryNotes, hasLength(1));
          expect(nb.discoveryNotes.single.reason, contains('more than one folder'));
          nb = await restart(nb);
          expect(idsOf(nb), [a2]);
          expect(nb.discoveryNotes, hasLength(1));
        },
      );
    }

    test('4: a listed binder missing at P and found at Q gives a hint, lists nothing and writes nothing; Open binder on Q is refused', () async {
      await binderAt('binders/Q', a1, title: 'Moved');
      writeSettings({
        'format': 1,
        'binders': [at('away/P')],
        'binderIds': {at('away/P'): a1},
      });
      final before = settingsFile().readAsBytesSync();
      final nb = await start();
      expect(listedKeys(nb), {k(at('away/P'))});
      expect(nb.binders.single.available, isFalse);
      expect(nb.binderMovedTo(at('away/P')).map(k), [k(at('binders/Q'))]);
      expect(settingsFile().readAsBytesSync(), before);
      await expectLater(
        nb.addBinder(at('binders/Q')),
        throwsA(
          isA<NotebookException>().having((e) => e.message, 'message', contains('Remove it from the sidebar first')),
        ),
      );
      expect(listedKeys(nb), {k(at('away/P'))});
      expect(settingsFile().readAsBytesSync(), before);
    });

    test('5: a copy of an available binder is refused; its page file and its binder file open nothing', () async {
      await binderAt('binders/P', a1, title: 'Orig', pages: ['p1']);
      final nb = await start();
      expect(idsOf(nb), [a1]);
      final p = nb.binders.single;
      await nb.open('p1');
      Directory(at('binders/Copy')).createSync();
      for (final f in Directory(at('binders/P')).listSync().whereType<File>()) {
        f.copySync('${at('binders/Copy')}/${f.path.split(RegExp(r'[\\/]')).last}');
      }
      // Discovery only notes it (a copy of an available binder: not used).
      await nb.discoverBinders();
      expect(idsOf(nb), [a1]);
      await expectLater(openExistingFile(nb, at('binders/Copy/p1.canvas')), throwsA(isA<NotebookException>()));
      expect(nb.binders, hasLength(1));
      expect(nb.binders.single, same(p));
      expect(nb.currentId, 'p1');
      await expectLater(openExistingFile(nb, at('binders/Copy/$binderFileName')), throwsA(isA<NotebookException>()));
      expect(nb.binders, hasLength(1));
      expect(nb.coverPath, isNull);
    });

    test('6: only a settled, readable binder file counts; each is added once readable', () async {
      Directory(at('binders/PC2only')).createSync(recursive: true);
      File(at('binders/PC2only/noted-binder-PC2.json')).writeAsStringSync(mkBinder(title: 'x', id: a2).write());
      Directory(at('binders/bad')).createSync(recursive: true);
      File(at('binders/bad/$binderFileName')).writeAsStringSync('{oops');
      Directory(at('binders/newer')).createSync(recursive: true);
      File(at('binders/newer/$binderFileName'))
          .writeAsStringSync(mkBinder(title: 'x', id: a3).write().replaceFirst('"format":1', '"format":99'));
      Directory(at('binders/nonhex')).createSync(recursive: true);
      File(at('binders/nonhex/$binderFileName'))
          .writeAsStringSync(mkBinder(title: 'x', id: 'not-hex-id-at-all').write());
      await binderAt('binders/good', a1);
      final nb = await start();
      // The good sibling is added although the others are present: a file that
      // was read and isn't a candidate blocks nothing.
      expect(idsOf(nb), [a1]);
      // Each becomes a binder once it is one.
      File(at('binders/PC2only/$binderFileName')).writeAsStringSync(mkBinder(title: 'x', id: a2).write());
      File(at('binders/bad/$binderFileName')).writeAsStringSync(mkBinder(title: 'x', id: a3).write());
      File(at('binders/newer/$binderFileName')).writeAsStringSync(mkBinder(title: 'x', id: a4).write());
      File(at('binders/nonhex/$binderFileName'))
          .writeAsStringSync(mkBinder(title: 'x', id: 'b000000000000001').write());
      await nb.discoverBinders();
      expect(idsOf(nb), [a1, a2, a3, a4, 'b000000000000001']);
    });

    test('7: links are not followed, .assets and hidden folders are not found, a second level is ignored', () async {
      final target = await binderAt('elsewhere/T', a1);
      try {
        Link(at('binders/Linked')).createSync(target);
      } on FileSystemException {
        // No permission to make links here: the rest still holds.
      }
      await binderAt('binders/x.assets', a2);
      await binderAt('binders/.hidden', a3);
      await binderAt('binders/Outer/Inner', a4);
      await binderAt('binders/Direct', 'a000000000000006');
      final nb = await start();
      expect(idsOf(nb), ['a000000000000006'], reason: 'only the folder that is a binder, directly under a root');
    });

    test('7: at most 1000 folders of a root are looked at, in name order, skipped names not counted', () async {
      writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
      for (var i = 0; i < 1000; i++) {
        Directory(at('binders/f${i.toString().padLeft(4, '0')}')).createSync(recursive: true);
      }
      Directory(at('binders/x.assets')).createSync();
      Directory(at('binders/.git')).createSync();
      Directory(at('binders/templates')).createSync();
      await BinderStore(Directory(at('binders/f0999'))).create(mkBinder(title: 'last in', id: a1));
      await BinderStore(Directory(at('binders/g'))).create(mkBinder(title: 'cut off', id: a2));
      final nb = make();
      final read = <String>[];
      nb.binderHook = (point, path) async {
        if (point == 'candidate-read') read.add(path);
      };
      await nb.load();
      await nb.discoveryIdle;
      expect(read.where((p) => p.contains('f0999')), hasLength(1), reason: 'the 1000th folder is read');
      expect(read.where((p) => p.contains('${sep}g$sep')), isEmpty, reason: 'the 1001st is not');
      // The pass was cut short, but what it found is added, and a note says so.
      expect(idsOf(nb), [a1]);
      expect(nb.discoveryNotes.single.reason, contains('only the first 1000 folders'));
    });

    test('8: a folder that vanishes as it is read is not recreated and not listed', () async {
      await binderAt('binders/Q', a1);
      writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
      _VanishingStore.armed = true;
      final nb = await start(storeFactory: _VanishingStore.new);
      expect(_VanishingStore.armed, isFalse);
      expect(nb.binders, isEmpty);
      expect(Directory(at('binders/Q')).existsSync(), isFalse);
      // Control: a hand add of the same kind of folder does create it again.
      await binderAt('binders/R', a2);
      _VanishingStore.armed = true;
      final r = await nb.addBinder(at('binders/R'));
      expect(r.path, endsWith('R'));
      expect(Directory(at('binders/R')).existsSync(), isTrue);
    });

    group('the window between the scan and the watcher', () {
      // Q is a binder of another device; the settings list nothing, or (for a
      // hand add) remember its id as removed so that the pass leaves it alone.
      void settingsFor({required bool hand}) => writeSettings({
        'format': 1,
        'binders': <String>[],
        'binderIds': <String, Object?>{},
        if (hand) 'removedBinders': [a1],
      });

      // Loads a notebook that adds Q (found, or by hand) with [hook] running in
      // the window, then returns the live section.
      Future<Notebook> addQ({required bool hand, required Future<void> Function() inWindow}) async {
        settingsFor(hand: hand);
        final nb = make();
        nb.binderHook = (point, path) async {
          if (point == 'opened') await inWindow();
        };
        await nb.load();
        await nb.discoveryIdle;
        if (hand) await nb.addBinder(at('binders/Q'));
        nb.binderHook = null;
        return nb;
      }

      test('9: a page file added in the window is listed without a restart', () async {
        await binderAt('binders/Q', a1, pages: ['p1']);
        final nb = await addQ(
          hand: false,
          inWindow: () =>
              PageStore(Directory(at('binders/Q')))
                  .save(NotedPage.create(PageMeta.create(id: 'late', title: 'Late', order: 0))),
        );
        expect(treeOf(nb.binders.single).map((s) => s.trim().split(':').first).toSet(), {'p1', 'late'});
      });

      for (final hand in [false, true]) {
        for (final variant in ['replace', 'delete']) {
          test(
            '9b: ${hand ? 'a hand add' : 'a found add'}, a page ${variant}d in the window matches a fresh load',
            () async {
              await binderAt('binders/Q', a1, pages: ['a', 'b', 'c']);
              final nb = await addQ(
                hand: hand,
                inWindow: () async {
                  if (variant == 'replace') {
                    await PageStore(Directory(at('binders/Q')))
                        .save(NotedPage.create(PageMeta.create(id: 'a', parentId: 'b', title: 'A2', order: 0)));
                  } else {
                    File(at('binders/Q/c.canvas')).deleteSync();
                  }
                },
              );
              final live = treeOf(nb.binders.single);
              if (variant == 'replace') expect(live.any((l) => l.contains('A2')), isTrue);
              if (variant == 'delete') expect(live.any((l) => l.contains('c:')), isFalse);
              await nb.flush();
              nb.dispose();
              opened.remove(nb);
              final fresh = await start();
              expect(live, treeOf(fresh.binders.single));
            },
          );
        }
      }

      for (final hand in [false, true]) {
        for (final variant in ['damaged', 'otherId', 'deleted']) {
          test(
            '9c: ${hand ? 'a hand add' : 'a found add'}, the binder file replaced in the window ($variant)',
            () async {
              await binderAt('binders/Q', a1, pages: ['p1']);
              final pageBytes = File(at('binders/Q/p1.canvas')).readAsBytesSync();
              final nb = await addQ(
                hand: hand,
                inWindow: () async {
                  final f = File(at('binders/Q/$binderFileName'));
                  switch (variant) {
                    case 'damaged':
                      f.writeAsStringSync('{oops');
                    case 'otherId':
                      f.writeAsStringSync(mkBinder(title: 'Other', id: a2).write());
                    case 'deleted':
                      f.deleteSync();
                  }
                },
              );
              expect(File(at('binders/Q/p1.canvas')).readAsBytesSync(), pageBytes, reason: 'no page was written');
              if ((variant == 'otherId' || variant == 'deleted') && !hand) {
                // A found add is undone (another binder there, or no binder file any
                // more): nothing is listed and binders.json is as it was.
                expect(nb.binders, isEmpty);
                expect(saved(), {'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
                return;
              }
              final live = nb.binders.single;
              final status = switch (variant) {
                'damaged' => BinderStatus.unreadable,
                'deleted' => BinderStatus.unavailable,
                _ => BinderStatus.available, // a hand add keeps today's adoption
              };
              expect(live.status, status);
              final liveTree = treeOf(live);
              await nb.flush();
              nb.dispose();
              opened.remove(nb);
              final fresh = await start();
              expect(fresh.binders.single.status, status);
              if (variant == 'damaged') expect(treeOf(fresh.binders.single), liveTree);
            },
          );
        }
      }
    });

    test('10: a binder being made from a template is claimed and listed once; a rollback that keeps its file remembers its id', () async {
      final tpl = Directory(at('tpl'));
      final nb0 = await start(templates: tpl);
      Directory(at('src')).createSync();
      final src = await nb0.addBinder(at('src'));
      final pid = await nb0.createPage(binderPath: src.path);
      await nb0.flush();
      final t = await nb0.saveBinderAsTemplate(src.path, name: 'Tpl');
      await nb0.removeBinder(src.path);
      final target = Directory(at('binders/Made'))..createSync(recursive: true);
      final pausedFor = <String>[];
      nb0.binderHook = (point, path) async {
        if (point != 'claimed') return;
        pausedFor.add(path);
        await nb0.discoverBinders();
        expect(nb0.binders.where((b) => k(b.path) == k(target.path)), isEmpty, reason: 'claimed: not found yet');
      };
      final made = await nb0.createBinderFromTemplate(t, target.path, openCover: false);
      nb0.binderHook = null;
      await nb0.discoveryIdle;
      expect(pausedFor, hasLength(1));
      expect(nb0.binders.where((b) => k(b.path) == k(target.path)), hasLength(1));
      expect(made.available, isTrue);
      expect(pid, isNotEmpty);
      // A rollback that keeps the binder file (it changed) remembers its id.
      final target2 = Directory(at('binders/Failed'))..createSync(recursive: true);
      nb0.binderHook = (point, path) async {
        if (point != 'claimed') return;
        final f = File('${target2.path}/$binderFileName');
        f.writeAsStringSync(f.readAsStringSync().replaceFirst('{', '{"touched":1,'));
        throw const FileSystemException('disk full');
      };
      await expectLater(
        nb0.createBinderFromTemplate(t, target2.path, openCover: false),
        throwsA(isA<NotebookException>()),
      );
      nb0.binderHook = null;
      final keptId = (await BinderStore(target2).read() as BinderFound).binder.id;
      expect(saved()['removedBinders'], contains(keptId));
      await nb0.discoverBinders();
      await nb0.discoveryIdle;
      expect(nb0.binders.where((b) => b.binder?.id == keptId), isEmpty);
    });

    test('11: a found add held in its job while the same folder is added by hand lists it once', () async {
      await binderAt('binders/Q', a1);
      writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
      final nb = make();
      final held = Completer<void>();
      final reached = Completer<void>();
      nb.binderHook = (point, path) async {
        if (point == 'job' && !held.isCompleted) {
          reached.complete();
          await held.future;
        }
      };
      await nb.load();
      await reached.future;
      final hand = nb.addBinderChecked(at('binders/Q'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      held.complete();
      final r = await hand;
      await nb.discoveryIdle;
      expect(nb.binders, hasLength(1));
      expect(r.section, same(nb.binders.single));
      // The found add listed it; the hand add found it already there.
      expect(r.added, isFalse);
      expect((saved()['binders'] as List), hasLength(1));
      expect((saved()['binderIds'] as Map), hasLength(1));
    });

    group('12: binders removed on older builds (the upgrade)', () {
      test('an old file: the unlisted binder is recorded as removed, shown, and stays unlisted after a restart; a later binder is found', () async {
        await binderAt('binders/U', a1, title: 'Old');
        writeSettings({'format': 1, 'binders': <String>[]});
        var nb = await start();
        expect(nb.binders, isEmpty);
        expect(saved()['removedBinders'], [a1]);
        expect(saved()['binderIds'], isEmpty);
        expect(nb.discoveryNotes.single.reason, contains('wasn\'t added'));
        nb = await restart(nb);
        expect(nb.binders, isEmpty);
        await binderAt('binders/V', a2);
        await nb.discoverBinders();
        expect(idsOf(nb), [a2]);
      });

      test('no binders.json: a binder is found', () async {
        await binderAt('binders/U', a1);
        final nb = await start();
        expect(idsOf(nb), [a1]);
      });

      test('a save before the upgrade closes leaves it open: still an upgrade after a restart', () async {
        await binderAt('binders/F', a1, title: 'Flaky');
        writeSettings({'format': 1, 'binders': <String>[]});
        final nb = make();
        nb.binderHook = (point, path) async {
          if (point == 'candidate-read') throw const FileSystemException('offline');
        };
        await nb.load();
        await nb.discoveryIdle;
        // A settings write (a standalone folder) while the upgrade is open.
        Directory(at('sa')).createSync();
        await nb.addStandaloneFolder(at('sa'));
        expect(saved().containsKey('binderIds'), isFalse);
        expect(nb.binders, isEmpty);
        nb.binderHook = null;
        final again = await restart(nb);
        // Still an upgrade: recorded as removed, not listed.
        expect(again.binders, isEmpty);
        expect(saved()['removedBinders'], [a1]);
      });

      test('a new install with no binders writes binderIds as {} and the next launch is not an upgrade', () async {
        var nb = await start();
        Directory(at('sa')).createSync();
        await nb.addStandaloneFolder(at('sa'));
        expect(saved()['binderIds'], isEmpty);
        expect(saved().containsKey('binderIds'), isTrue);
        nb = await restart(nb);
        await binderAt('binders/W', a1);
        await nb.discoverBinders();
        expect(idsOf(nb), [a1]);
      });

      test(
        'a candidate read that fails in the first pass keeps the upgrade open; the binder is recorded once readable',
        () async {
          await binderAt('binders/F', a1);
          await binderAt('binders/U', a2);
          writeSettings({'format': 1, 'binders': <String>[]});
          final nb = make();
          var fail = true;
          nb.binderHook = (point, path) async {
            if (point == 'candidate-read' && fail && path.contains('${sep}F$sep')) {
              throw const FileSystemException('offline');
            }
          };
          await nb.load();
          await nb.discoveryIdle;
          expect(saved()['removedBinders'], [a2]);
          expect(saved().containsKey('binderIds'), isFalse);
          fail = false;
          await nb.discoverBinders();
          expect(nb.binders, isEmpty);
          expect(saved()['removedBinders'], containsAll([a1, a2]));
          expect(saved()['binderIds'], isEmpty);
        },
      );

    });

    test('13: binderIds are recorded, pruned and adopted; unknown fields are kept', () async {
      writeSettings({
        'format': 1,
        'binders': <String>[],
        'binderIds': <String, Object?>{},
        'future': [1, 2],
      });
      final p = await binderAt('mine/P', a1);
      final nb = await start();
      await nb.addBinder(p);
      expect((saved()['binderIds'] as Map)[nb.binders.single.path], a1);
      expect(saved()['future'], [1, 2]);
      // Adoption: another binder file at the listed path replaces the id, and
      // an id that was removed is no longer.
      writeSettings({
        ...saved(),
        'removedBinders': [a2],
      });
      final again = await restart(nb);
      await BinderStore(Directory(p)).save(mkBinder(title: 'Other', id: a2));
      await again.checkBinderFile('$p/$binderFileName');
      expect((saved()['binderIds'] as Map).values, [a2]);
      expect(saved()['removedBinders'] ?? const [], isEmpty);
      // Removing prunes the key and remembers the id.
      await again.removeBinder(again.binders.single.path);
      expect(saved()['binderIds'], isEmpty);
      expect(saved()['removedBinders'], [a2]);
      expect(saved()['future'], [1, 2]);
    });

    test('13b: a binder an older build removed after the ids were recorded stays removed', () async {
      final p = await binderAt('binders/P', a1);
      await binderAt('binders/Sibling', a2);
      // P left `binders` but is still a key of `binderIds`.
      writeSettings({
        'format': 1,
        'binders': <String>[],
        'binderIds': {p: a1},
      });
      final nb = await start();
      expect(idsOf(nb), [a2]);
      await nb.addStandaloneFolder((Directory(at('sa'))..createSync()).path);
      expect(saved()['removedBinders'], [a1]);
      expect((saved()['binderIds'] as Map).keys, [nb.binders.single.path]);
    });

    test('13c: a pass with one unreadable candidate admits no new id; the next pass does; a refused open keeps a removed id removed', () async {
      writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
      await binderAt('binders/F', a1);
      await binderAt('binders/Good', a2);
      final nb = make();
      var fail = true;
      nb.binderHook = (point, path) async {
        if (point == 'candidate-read' && fail && path.contains('${sep}F$sep')) {
          throw const FileSystemException('offline');
        }
      };
      await nb.load();
      await nb.discoveryIdle;
      expect(nb.binders, isEmpty);
      fail = false;
      await nb.discoverBinders();
      expect(idsOf(nb), [a1, a2]);

      // A refused Open (the page is a copy of one in Noted) puts the removed id back.
      final dup = await nb.createPage();
      await nb.flush();
      final dupPath = '${nb.defaultFolderPath}$sep$dup.canvas';
      await binderAt('elsewhere/Y', 'a00000000000000f');
      File(dupPath).copySync(at('elsewhere/Y/copy.canvas'));
      writeSettings({
        ...saved(),
        'removedBinders': ['a00000000000000f'],
      });
      final again = await restart(nb);
      await expectLater(openExistingFile(again, at('elsewhere/Y/copy.canvas')), throwsA(isA<NotebookException>()));
      expect(again.binders.any((b) => k(b.path) == k(at('elsewhere/Y'))), isFalse);
      expect(saved()['removedBinders'], contains('a00000000000000f'));
    });

    test('14: a conflict copy in a found binder is merged and deleted only if unchanged', () async {
      final codec = modules.codecs.codecFor('noted.note')!;
      BoxRecord noteBox(String text, Bounds b) => commitBox(createBox(codec, b), codec, codec.decode(doc(text), 1));
      await binderAt('binders/Q', a1, pages: ['p1']);
      final st = PageStore(Directory(at('binders/Q')));
      final base = await st.load('p1');
      final first = noteBox('first', const Bounds(400, 10, 200, 40));
      final later = noteBox('later', const Bounds(400, 100, 200, 40));
      final copy = at('binders/Q/p1-PC2.canvas');
      File(copy).writeAsStringSync(writePage(base.insertNode(first)));
      writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
      final nb = make();
      var fired = false;
      nb.syncHook = (point, p) async {
        if (point != 'copy-merged' || fired) return;
        fired = true; // the sync client replaces the copy with a newer one
        File(copy).writeAsStringSync(writePage(base.insertNode(first).insertNode(later)));
      };
      await nb.load();
      await nb.discoveryIdle;
      expect(fired, isTrue);
      expect(File(copy).existsSync(), isFalse);
      final merged = readPage(File(at('binders/Q/p1.canvas')).readAsStringSync());
      expect(merged.nodes.map((n) => n.id).toSet(), {first.id, later.id});
    });

    for (final hand in [false, true]) {
      test(
        '15: ${hand ? 'a hand add sweeps set-aside files, as before' : 'a found add does not sweep set-aside files'}',
        () async {
          await binderAt('binders/Q', a1, pages: ['p1']);
          final aside = File(at('binders/Q/x.canvas.1a2b3c.cas-old'))
            ..writeAsStringSync(writePage(NotedPage.create(PageMeta.create(id: 'x', title: 'X', order: 0))));
          writeSettings({
            'format': 1,
            'binders': <String>[],
            'binderIds': <String, Object?>{},
            if (hand) 'removedBinders': [a1],
          });
          final nb = make();
          // A page whose file name isn't <id>.canvas arrives in the window: it is
          // reconciled through a rescan of the folder.
          nb.binderHook = (point, path) async {
            if (point != 'opened') return;
            File(at('binders/Q/named.canvas'))
                .writeAsStringSync(writePage(NotedPage.create(PageMeta.create(id: 'p2', title: 'Named', order: 1))));
          };
          await nb.load();
          await nb.discoveryIdle;
          if (hand) await nb.addBinder(at('binders/Q'));
          nb.binderHook = null;
          expect(nb.binders, hasLength(1));
          expect(nb.pageTitleOf('p2'), 'Named');
          if (hand) {
            expect(aside.existsSync(), isFalse);
            expect(File(at('binders/Q/x.canvas')).existsSync(), isTrue);
          } else {
            expect(aside.existsSync(), isTrue, reason: 'left for the device that wrote it');
            expect(File(at('binders/Q/x.canvas')).existsSync(), isFalse);
          }
        },
      );
    }

    group('16', () {
      test('a "Can\'t open" row for a set-aside file that vanishes in the window is gone after the add', () async {
        await binderAt('binders/Q', a1, pages: ['p1']);
        final aside = File(at('binders/Q/x.canvas.1a2b3c.cas-old'))
          ..writeAsStringSync(writePage(NotedPage.create(PageMeta.create(id: 'x', title: 'X', order: 0))));
        writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
        final nb = make();
        var sawRow = false;
        nb.binderHook = (point, path) async {
          if (point != 'opened') return;
          sawRow = true;
          aside.deleteSync(); // its writer finished
        };
        await nb.load();
        await nb.discoveryIdle;
        expect(sawRow, isTrue);
        expect(nb.binders.single.unreadable, isEmpty);
      });

      test('a found add between the open check and addBinder still adopts the page file (0137)', () async {
        // Q holds two files of one page id; the page is opened from the second.
        await binderAt('binders/Q', a1, pages: ['p1']);
        final orig = at('binders/Q/p1.canvas');
        final second = at('binders/Q/second.canvas');
        File(second).writeAsStringSync(File(orig).readAsStringSync().replaceFirst('Page p1', 'Second'));
        writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
        final nb = make();
        final held = Completer<void>();
        final reached = Completer<void>();
        nb.binderHook = (point, path) async {
          if (point == 'job' && !held.isCompleted) {
            reached.complete();
            await held.future;
          }
        };
        await nb.load();
        await reached.future;
        final open = openExistingFile(nb, second);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        held.complete();
        await open;
        expect(nb.currentId, 'p1');
        expect(nb.pageTitleOf('p1'), 'Second');
      });
    });

    group('review fixes', () {
      const a5 = 'a000000000000005';

      test('an undone found add puts back only the removed ids it took out; one recorded meanwhile stays', () async {
        final r = await binderAt('binders/R', a2);
        await binderAt('binders/Q', a1, pages: ['p1']);
        // a3 was removed before; the other binder file Q turns into holds it.
        writeSettings({
          'format': 1,
          'binders': [r],
          'binderIds': {r: a2},
          'removedBinders': [a3],
        });
        final nb = make();
        nb.binderHook = (point, path) async {
          if (point != 'opened') return;
          // Another device replaces Q's file by one holding a3, and this device
          // removes R, both while Q is being added.
          File(at('binders/Q/$binderFileName')).writeAsStringSync(mkBinder(title: 'Other', id: a3).write());
          await nb.removeBinder(r);
        };
        await nb.load();
        await nb.discoveryIdle;
        nb.binderHook = null;
        expect(nb.binders, isEmpty);
        expect(saved()['removedBinders'], unorderedEquals([a2, a3]));
        // A later pass and a restart leave both out.
        await nb.discoverBinders();
        expect(nb.binders, isEmpty);
        final again = await restart(nb);
        expect(again.binders, isEmpty);
      });

      test('binders.json never lists a found binder with another id while it is being reconciled', () async {
        await binderAt('binders/Q', a1, pages: ['p1']);
        writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
        final nb = make();
        final seen = <String>[];
        nb.binderHook = (point, path) async {
          if (point == 'opened') {
            File(at('binders/Q/$binderFileName')).writeAsStringSync(mkBinder(title: 'Other', id: a3).write());
          }
          if (point == 'adopted') seen.add(settingsFile().readAsStringSync());
        };
        await nb.load();
        await nb.discoveryIdle;
        nb.binderHook = null;
        expect(seen, isNotEmpty, reason: 'the adoption happened');
        for (final text in seen) {
          expect(text, isNot(contains(a3)));
        }
        expect(nb.binders, isEmpty);
        expect(saved()['binderIds'], isEmpty);
      });

      for (final cut in ['roots', 'folders']) {
        test(
          'an upgrade closes in one uncapped pass when a $cut cap would have cut it, and records everything',
          () async {
            await binderAt('binders/U1', a1);
            await binderAt(cut == 'roots' ? 'pages/U2' : 'binders/U2', a2);
            writeSettings({'format': 1, 'binders': <String>[]});
            final nb = make();
            nb.setDiscoveryLimitsForTest(roots: cut == 'roots' ? 1 : null, folders: cut == 'folders' ? 1 : null);
            await nb.load();
            await nb.discoveryIdle;
            expect(saved()['binderIds'], isEmpty, reason: 'the upgrade closed');
            expect(saved()['removedBinders'], unorderedEquals([a1, a2]));
            expect(nb.binders, isEmpty);
          },
        );

        test(
          'after the upgrade a $cut cap cuts the pass but found binders are still added, and a note says so',
          () async {
            await binderAt('binders/U1', a1);
            await binderAt('binders/U2', a2);
            writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
            final nb = make();
            nb.setDiscoveryLimitsForTest(roots: cut == 'roots' ? 1 : null, folders: cut == 'folders' ? 1 : null);
            await nb.load();
            await nb.discoveryIdle;
            if (cut == 'folders') {
              expect(idsOf(nb), [a1], reason: 'the first folder is read and added; the second is past the cap');
              expect(nb.discoveryNotes.single.reason, contains('only the first 1 folders'));
            } else {
              expect(idsOf(nb), [a1, a2]);
              expect(nb.discoveryNotes.single.reason, contains('only the first 1 places'));
            }
          },
        );
      }

      test('an upgrade with more unlisted binders than the removed cap stays open and adds none', () async {
        await binderAt('binders/U1', a1);
        await binderAt('binders/U2', a2);
        await binderAt('binders/U3', a3);
        writeSettings({'format': 1, 'binders': <String>[]});
        final nb = make();
        nb.setDiscoveryLimitsForTest(removed: 2);
        await nb.load();
        await nb.discoveryIdle;
        expect(saved().containsKey('binderIds'), isFalse, reason: 'the upgrade stays open');
        expect(saved()['removedBinders'], hasLength(2));
        expect(nb.binders, isEmpty);
        expect(nb.discoveryNotes.any((n) => n.reason.contains('too many binders')), isTrue);
        await nb.discoverBinders();
        expect(nb.binders, isEmpty, reason: 'a later pass adds none');
        final again = await restart(nb, removedCap: 2);
        expect(again.binders, isEmpty, reason: 'nor on the reload pass');
        expect(saved().containsKey('binderIds'), isFalse, reason: 'the upgrade is still open after a reload');
        await again.discoverBinders();
        expect(again.binders, isEmpty, reason: 'nor on a later pass after a reload');
      });

      test('a root that fails to list keeps the upgrade open; a root refused for permission does not', () async {
        await binderAt('binders/U1', a1);
        await binderAt('pages/U2', a2);
        writeSettings({'format': 1, 'binders': <String>[]});
        final nb = make();
        nb.binderHook = (point, path) async {
          if (point == 'root-list' && path.contains('pages')) throw const FileSystemException('disk error');
        };
        await nb.load();
        await nb.discoveryIdle;
        expect(saved().containsKey('binderIds'), isFalse, reason: 'a failed listing keeps it open');
        expect(saved()['removedBinders'], [a1]);
        // Refused for permission: skipped, and it holds nothing up.
        nb.binderHook = (point, path) async {
          if (point == 'root-list' && path.contains('pages')) {
            throw FileSystemException('denied', path, OSError('denied', Platform.isWindows ? 5 : 13));
          }
        };
        await nb.discoverBinders();
        expect(saved()['binderIds'], isEmpty, reason: 'the upgrade closed');
        expect(saved()['removedBinders'], [a1], reason: 'the refused root was not read');
      });

      test('a hand add waits for at most one found add of a pass', () async {
        for (final n in ['Q1', 'Q2', 'Q3']) {
          await binderAt('binders/$n', 'a00000000000010${n.substring(1)}');
        }
        final hand = await binderAt('other/H', a5);
        writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
        final nb = make();
        final gates = <Completer<void>>[];
        nb.binderHook = (point, path) async {
          if (point != 'job') return;
          final g = Completer<void>();
          gates.add(g);
          await g.future;
        };
        await nb.load();
        while (gates.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final adding = nb.addBinderChecked(hand);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        gates.first.complete(); // only the first found add may go
        final r = await adding.timeout(const Duration(seconds: 10));
        expect(r.added, isTrue);
        for (final g in gates) {
          if (!g.isCompleted) g.complete();
        }
        nb.binderHook = null;
        // Later jobs of the chain open their gates too.
        nb.binderHook = (point, path) async {};
        await nb.discoveryIdle;
        expect(nb.binders, hasLength(4));
      });

      for (final routed in ['a root watcher', 'the page folder watcher']) {
        test('$routed lists a binder that arrives, with no backstop', () async {
          Directory(at('binders')).createSync();
          writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
          final nb = make(watch: true, interval: const Duration(hours: 1));
          await nb.load();
          await nb.discoveryIdle;
          expect(nb.binders, isEmpty);
          // Made whole elsewhere and moved in: the event names a folder that
          // already holds its binder file.
          await binderAt('staging/Arrived', a1);
          final target = routed == 'a root watcher' ? at('binders/Arrived') : at('pages/Arrived');
          Directory(at('staging/Arrived')).renameSync(target);
          final end = DateTime.now().add(const Duration(seconds: 15));
          while (nb.binders.isEmpty && DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await nb.discoveryIdle;
          expect(idsOf(nb), [a1]);
        });
      }

      test('a slow pass stretches the backstop; a fast one resets it', () async {
        await binderAt('binders/B1', a1);
        final nb = make();
        nb.setDiscoveryLimitsForTest(slowPass: const Duration(milliseconds: -1));
        await nb.load();
        await nb.discoveryIdle;
        expect(nb.backstopTicksForTest, 20);
        await nb.discoverBinders();
        expect(nb.backstopTicksForTest, 40);
        nb.setDiscoveryLimitsForTest(slowPass: const Duration(hours: 1));
        await nb.discoverBinders();
        expect(nb.backstopTicksForTest, 10);
      });
    });

    group('Codex round 1 fixes', () {
      test(
        'R-1: a root whose listing failed admits nothing; once it lists, both copies are flagged duplicates',
        () async {
          writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
          await binderAt('binders/D1', a1, title: 'Twin');
          await binderAt('pages/D2', a1, title: 'Twin');
          await binderAt('binders/Control', a2);
          final nb = make();
          nb.binderHook = (point, path) async {
            if (point == 'root-list' && path.contains('pages')) throw const FileSystemException('disk error');
          };
          await nb.load();
          await nb.discoveryIdle;
          // The visible copy and the control are both left alone: the hidden root
          // might hold more.
          expect(nb.binders, isEmpty);
          nb.binderHook = null;
          await nb.discoverBinders();
          expect(idsOf(nb), [a2], reason: 'the control is added; neither twin is');
          expect(nb.discoveryNotes, hasLength(1));
          expect(nb.discoveryNotes.single.reason, contains('more than one folder'));
        },
      );

      test('R-2: a conflict copy merged in a found add does not sweep a set-aside file', () async {
        final codec = modules.codecs.codecFor('noted.note')!;
        BoxRecord noteBox(String text, Bounds b) => commitBox(createBox(codec, b), codec, codec.decode(doc(text), 1));
        await binderAt('binders/Q', a1);
        final aside = File(at('binders/Q/x.canvas.1a2b3c.cas-old'))
          ..writeAsStringSync(writePage(NotedPage.create(PageMeta.create(id: 'x', title: 'X', order: 0))));
        writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
        final base = NotedPage.create(PageMeta.create(id: 'p9', title: 'Named', order: 0));
        final extra = noteBox('theirs', const Bounds(400, 10, 200, 40));
        final nb = make();
        // After the scan, a page whose file name isn't its id arrives with a
        // conflict copy; the copy sorts first, so it is reconciled first.
        nb.binderHook = (point, path) async {
          if (point != 'opened') return;
          File(at('binders/Q/orig.canvas')).writeAsStringSync(writePage(base));
          File(at('binders/Q/orig-PC2.canvas')).writeAsStringSync(writePage(base.insertNode(extra)));
        };
        await nb.load();
        await nb.discoveryIdle;
        expect(nb.binders, hasLength(1));
        expect(aside.existsSync(), isTrue, reason: 'left for the device that wrote it');
        expect(File(at('binders/Q/x.canvas')).existsSync(), isFalse);
        expect(File(at('binders/Q/orig-PC2.canvas')).existsSync(), isFalse, reason: 'the copy was merged and removed');
        expect(readPage(File(at('binders/Q/orig.canvas')).readAsStringSync()).node(extra.id), isNotNull);
      });

      for (final variant in ['damaged', 'otherId']) {
        test('earlier R-1: the binder file replaced between its parse and its cache is noticed ($variant)', () async {
          await binderAt('binders/Q', a1, pages: ['p1']);
          writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}});
          final nb = make();
          nb.binderHook = (point, path) async {
            if (point != 'parsed') return;
            final f = File(at('binders/Q/$binderFileName'));
            if (variant == 'damaged') {
              f.writeAsStringSync('{oops');
            } else {
              f.writeAsStringSync(mkBinder(title: 'Other', id: a3).write());
            }
          };
          await nb.load();
          await nb.discoveryIdle;
          nb.binderHook = null;
          if (variant == 'damaged') {
            expect(nb.binders.single.status, BinderStatus.unreadable);
          } else {
            expect(nb.binders, isEmpty, reason: 'the found add is undone');
          }
        });
      }
    });

    test(
      'invalid UTF-8 in noted-binder.json on a hand add is a damaged file: listed read-only, not unavailable',
      () async {
        final dir = await Directory(at('other/Bad')).create(recursive: true);
        await PageStore(dir).save(NotedPage.create(PageMeta.create(id: 'p1', title: 'Page', order: 0)));
        final bytes = [0x7b, 0xff, 0xfe, 0x7d]; // not UTF-8
        File('${dir.path}/$binderFileName').writeAsBytesSync(bytes);
        final nb = await start();
        final section = await nb.addBinder(dir.path);
        expect(section.status, BinderStatus.unreadable);
        expect(nb.binders.single.status, BinderStatus.unreadable, reason: 'not made unavailable by the reconcile');
        expect(nb.pageTitleOf('p1'), 'Page', reason: 'its pages are listed, read-only');
        expect(File('${dir.path}/$binderFileName').readAsBytesSync(), bytes, reason: 'the file is never written');
      },
    );
  });

  group('an unreadable binders.json is held, never written', () {
    const loadingMsg = 'Noted is still loading its binder list. Try again in a moment.';
    const lockedMsg = "Noted can't read its binder list right now. Try again in a moment.";
    const lockedNote =
        "Noted can't read its binder list (binders.json) right now, so binders and extra page folders are "
        'hidden. They will appear when it can be read.';
    const checkingNote = 'Noted is checking whether its binder list was deleted.';
    const mobileNote =
        "Noted can't read its binder list. Binders and extra page folders stay hidden until it can be read.";
    const emptyList = '{"format":1,"binders":[],"binderIds":{}}';

    String damagedNote([File? f]) =>
        "Noted's binder list (binders.json in ${(f ?? settingsFile()).parent.path}) is damaged, so binders and "
        "extra page folders are hidden and can't be added or removed. Put back a readable copy, or delete the "
        'file to start a new list; your binder and page folders are not changed.';

    List<String> heldNotes(Notebook nb) => [
      for (final n in nb.discoveryNotes)
        if (n.path.endsWith('binders.json')) n.reason,
    ];

    Future<void> refused(Future<Object?> Function() action, [String msg = lockedMsg]) => expectLater(
      action(),
      throwsA(isA<NotebookException>().having((e) => e.message, 'message', msg)),
    );

    Future<void> until(bool Function() done, {String? what}) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'a condition'}');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    // The settings file lists B1 (a1) with an id for it, a removed id (a2) and an
    // unknown field; R1 (a2, removed) and U (a3, not listed) sit in the default
    // binder folder.
    Future<String> lockedSetup() async {
      final b1 = await binderAt('other/B1', a1, pages: ['b1p']);
      await binderAt('binders/R1', a2);
      await binderAt('binders/U', a3);
      writeSettings({
        'format': 1,
        'binders': [b1],
        'binderIds': {b1: a1},
        'removedBinders': [a2],
        'x': 'keep',
      });
      return b1;
    }

    Future<(Notebook, _Hooks)> startHeld({
      bool locked = true,
      File? file,
      AppSettings? settings,
      Duration? retryFirst,
      Duration? interval,
      Future<String?> Function()? pick,
    }) async {
      final hooks = _Hooks()..locked = locked;
      final nb = make(file: file, settings: settings, retryFirst: retryFirst, interval: interval, pick: pick);
      nb.binderHook = hooks.call;
      await nb.load();
      await nb.discoveryIdle;
      return (nb, hooks);
    }

    List<String> tmpFiles() => [
      for (final e in root.listSync())
        if (e.path.endsWith('.tmp')) e.path,
    ];

    test('1: a locked list: no binder is listed, changes are refused, the file is never written', () async {
      await lockedSetup();
      Directory(at('chosen')).createSync();
      Directory(at('existing')).createSync();
      final before = settingsFile().readAsBytesSync();
      var picked = 0;
      final settings = AppSettings(null)..defaultPageFolder = at('chosen');
      final (nb, hooks) = await startHeld(
        settings: settings,
        pick: () async {
          picked++;
          return at('other/B2');
        },
      );
      expect(hooks.count('settings-read'), 1, reason: 'the hook fired');
      expect(nb.binders, isEmpty);
      expect(heldNotes(nb), [lockedNote]);
      await refused(() => nb.createBinder());
      await refused(() => nb.openBinder());
      await refused(() => nb.newBinderInFolder());
      await refused(() => nb.addBinder(at('other/B2')));
      await refused(() => nb.addStandaloneFolder(at('newfolder')));
      await refused(() => nb.removeStandaloneFolder(nb.standaloneFolders.single.path));
      await refused(() => nb.createPage(folderPath: at('newfolder')));
      await refused(() => nb.setDefaultPageFolder(at('existing')));
      expect(settings.defaultPageFolder, at('chosen'), reason: 'refused before settings.json changes');
      expect(picked, 0);
      expect(Directory(at('binders/New binder')).existsSync(), isFalse);
      expect(Directory(at('newfolder')).existsSync(), isFalse);
      await nb.discoverBinders();
      expect(nb.binders, isEmpty);
      expect(hooks.count('settings-read'), greaterThan(1), reason: 'each refusal started a retry');
      nb.dispose();
      opened.remove(nb);
      expect(settingsFile().readAsBytesSync(), before);
      // Control: readable, the same file lists B1 and finds U (R1 stays removed).
      final ok = await start();
      expect(idsOf(ok), [a1, a3]);
      expect(saved()['x'], 'keep');
    });

    test('1: a locked file object (the unlocked switch hands reads to the real file)', () async {
      await lockedSetup();
      final before = settingsFile().readAsBytesSync();
      final locked = _LockedFile(settingsFile());
      final nb = await start(file: locked);
      expect(nb.binders, isEmpty);
      expect(heldNotes(nb), [lockedNote]);
      await refused(() => nb.addBinder(at('other/B2')));
      expect(settingsFile().readAsBytesSync(), before);
      locked.unlocked = true;
      expect(await nb.retrySettings(), isTrue);
      expect(idsOf(nb), contains(a1));
    });

    test('1: a real lock held by another handle', () async {
      await lockedSetup();
      final before = settingsFile().readAsBytesSync();
      final raf = settingsFile().openSync(mode: FileMode.append);
      raf.lockSync(FileLock.exclusive);
      try {
        final nb = await start();
        expect(nb.binders, isEmpty);
        await refused(() => nb.addBinder(at('other/B2')));
        raf.unlockSync();
        expect(await nb.retrySettings(), isTrue);
        expect(idsOf(nb), contains(a1));
        expect(settingsFile().readAsBytesSync().take(before.length), before);
      } finally {
        raf.closeSync();
      }
    }, skip: !Platform.isWindows ? 'a lock stops reads only on Windows' : null);

    for (final (name, bytes) in [
      ('{oops', utf8.encode('{oops')),
      ('invalid UTF-8', [0xff, 0xfe, 0x7b]),
    ]) {
      test('2: a damaged list ($name) is never renamed or replaced, and discovery records nothing', () async {
        await binderAt('binders/U', a1);
        settingsFile().writeAsBytesSync(bytes);
        final (nb, hooks) = await startHeld(locked: false, interval: const Duration(milliseconds: 20));
        expect(hooks.count('settings-read'), 1, reason: 'the hook fired');
        expect(nb.settingsHoldForTest, 'damaged');
        expect(nb.binders, isEmpty);
        expect(heldNotes(nb), [damagedNote()]);
        await refused(() => nb.createBinder());
        await refused(() => nb.addBinder(at('other/B2')));
        await Future<void>.delayed(const Duration(milliseconds: 150)); // folder ticks
        await nb.discoverBinders();
        expect(nb.binders, isEmpty);
        expect(File(at('binders.json.bad')).existsSync(), isFalse);
        expect(settingsFile().readAsBytesSync(), bytes);
        nb.dispose();
        opened.remove(nb);
        expect(settingsFile().readAsBytesSync(), bytes);
        expect([for (final e in root.listSync()) e.path.split(RegExp(r'[\\/]')).last], isNot(contains(startsWith('binders.json.'))));
      });
    }

    test('2: a damaged list under a mobile platform has a factual notice only', () async {
      settingsFile().writeAsStringSync('{oops');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final (nb, _) = await startHeld(locked: false);
        expect(heldNotes(nb), [mobileNote]);
        final text = heldNotes(nb).single.toLowerCase();
        for (final word in ['reinstall', 'not changed', 'unchanged', 'kept', 'safe']) {
          expect(text, isNot(contains(word)));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    group('2: the list is deleted', () {
      Future<(Notebook, _Hooks, DateTime Function())> deleted({String settingsName = 'binders.json'}) async {
        await binderAt('binders/U', a1);
        final file = File(at(settingsName));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('{oops');
        final (nb, hooks) = await startHeld(locked: false, file: file);
        final t = DateTime(2030);
        nb.now = () => t;
        file.deleteSync();
        return (nb, hooks, () => t);
      }

      test('held at first, then a new empty list is published exclusively and U is found', () async {
        var t = DateTime(2030);
        await binderAt('binders/U', a1);
        settingsFile().writeAsStringSync('{oops');
        final (nb, hooks) = await startHeld(locked: false);
        nb.now = () => t;
        settingsFile().deleteSync();
        expect(await nb.retrySettings(), isFalse);
        expect(nb.settingsHoldForTest, 'damaged');
        expect(heldNotes(nb), [checkingNote]);
        t = t.add(const Duration(seconds: 2));
        expect(await nb.retrySettings(), isFalse, reason: 'a second not-found within the window confirms nothing');
        expect(settingsFile().existsSync(), isFalse);
        expect(hooks.count('settings-publish'), 0);
        await refused(() => nb.addBinder(at('other/B2')));
        t = t.add(const Duration(seconds: 30));
        expect(await nb.retrySettings(), isTrue);
        expect(hooks.count('settings-publish'), 1, reason: 'the hook fired');
        expect(settingsFile().readAsStringSync(), emptyList);
        expect(tmpFiles(), isEmpty);
        await nb.discoveryIdle;
        expect(idsOf(nb), [a1], reason: 'U is added as found');
        expect(heldNotes(nb), isEmpty);
        // A restart reads the new file as current: a binder found later is listed.
        final again = await restart(nb);
        await binderAt('binders/W', a2);
        await again.discoverBinders();
        expect(idsOf(again), [a1, a2]);
      });

      test('with the folder gone it stays held and nothing is created', () async {
        final (nb, hooks, now) = await deleted(settingsName: 'app/binders.json');
        Directory(at('app')).deleteSync(recursive: true);
        var t = now();
        for (var i = 0; i < 3; i++) {
          t = t.add(const Duration(seconds: 40));
          final at0 = t;
          nb.now = () => at0;
          expect(await nb.retrySettings(), isFalse);
        }
        expect(nb.settingsHoldForTest, 'damaged');
        expect(Directory(at('app')).existsSync(), isFalse);
        expect(hooks.count('settings-publish'), 0);
      });

      test('a file that arrives at the publish is never replaced; the next retry adopts it', () async {
        final b1 = await binderAt('other/B1', a1);
        final (nb, hooks, now) = await deleted();
        const arrival = '{"format":1,"binders":[],"binderIds":{},"x":"arrived"}';
        hooks.on['settings-publish'] = (_) async => settingsFile().writeAsStringSync(arrival);
        var t = now();
        expect(await nb.retrySettings(), isFalse);
        t = t.add(const Duration(seconds: 31));
        nb.now = () => t;
        expect(await nb.retrySettings(), isFalse);
        expect(hooks.count('settings-publish'), 1, reason: 'the hook fired');
        expect(settingsFile().readAsStringSync(), arrival, reason: 'nothing was replaced');
        expect(tmpFiles(), isEmpty, reason: 'the temp of the lost race is gone');
        expect(nb.settingsHoldForTest, 'damaged');
        writeSettings({
          'format': 1,
          'binders': [b1],
          'binderIds': {b1: a1},
          'x': 'arrived',
        });
        expect(await nb.retrySettings(), isTrue);
        expect(idsOf(nb), contains(a1));
        expect(saved()['x'], 'arrived');
      });

      test('a publish that throws deletes its temp, keeps the hold and says so', () async {
        final (nb, hooks, now) = await deleted();
        hooks.on['settings-publish'] = (p) async => throw FileSystemException('disk full', p);
        expect(await nb.retrySettings(), isFalse);
        nb.now = () => now().add(const Duration(seconds: 31));
        expect(await nb.retrySettings(), isFalse);
        expect(hooks.count('settings-publish'), 1, reason: 'the hook fired');
        expect(tmpFiles(), isEmpty);
        expect(settingsFile().existsSync(), isFalse);
        expect(nb.settingsHoldForTest, 'locked');
        expect(heldNotes(nb).single, startsWith(lockedNote));
        expect(heldNotes(nb).single, contains('disk full'));
        await refused(() => nb.addBinder(at('other/B2')));
      });

      test('not found once, then a valid file reappears: it is adopted and no empty list is written', () async {
        final b1 = await binderAt('other/B1', a1);
        final (nb, hooks, _) = await deleted();
        expect(await nb.retrySettings(), isFalse);
        expect(heldNotes(nb), [checkingNote]);
        writeSettings({
          'format': 1,
          'binders': [b1],
          'binderIds': {b1: a1},
          'x': 'back',
        });
        final bytes = settingsFile().readAsBytesSync();
        expect(await nb.retrySettings(), isTrue);
        expect(idsOf(nb), contains(a1));
        expect(hooks.count('settings-publish'), 0);
        expect(settingsFile().readAsBytesSync(), bytes);
      });
    });

    group('3: a retry that succeeds', () {
      for (final trigger in ['the timer', 'retrySettings()', 'a refused hand change']) {
        test('by $trigger: B1 is listed, U is found, r1 and x are kept, and reads stop', () async {
          final b1 = await lockedSetup();
          final (nb, hooks) = await startHeld(retryFirst: const Duration(milliseconds: 40));
          expect(nb.binders, isEmpty);
          hooks.locked = false;
          switch (trigger) {
            case 'the timer':
              await until(() => nb.settingsHoldForTest == null, what: 'the timer to retry');
            case 'retrySettings()':
              expect(await nb.retrySettings(), isTrue);
            default:
              await refused(() => nb.createBinder());
              await until(() => nb.settingsHoldForTest == null, what: 'the refusal to retry');
          }
          await nb.discoveryIdle;
          expect(idsOf(nb), [a1, a3], reason: 'R1 stays removed');
          expect(nb.binders.firstWhere((b) => k(b.path) == k(b1)).available, isTrue);
          expect(heldNotes(nb), isEmpty);
          expect(saved()['x'], 'keep');
          expect(saved()['removedBinders'], contains(a2));
          final reads = hooks.count('settings-read');
          await Future<void>.delayed(const Duration(milliseconds: 250));
          expect(hooks.count('settings-read'), reads, reason: 'no read after success');
        });
      }

      test('a damaged list, then repaired: adopted, and no .bad exists', () async {
        final b1 = await binderAt('other/B1', a1);
        settingsFile().writeAsStringSync('{oops');
        final (nb, _) = await startHeld(locked: false);
        expect(nb.settingsHoldForTest, 'damaged');
        writeSettings({
          'format': 1,
          'binders': [b1],
          'binderIds': {b1: a1},
        });
        expect(await nb.retrySettings(), isTrue);
        expect(idsOf(nb), [a1]);
        expect(File(at('binders.json.bad')).existsSync(), isFalse);
      });

      test('the chosen default page folder listed as a binder becomes a binder, not a folder', () async {
        final c = await binderAt('chosen', a4, pages: ['cp']);
        final settings = AppSettings(null)..defaultPageFolder = c;
        writeSettings({
          'format': 1,
          'binders': [c],
          'binderIds': {c: a4},
        });
        final (nb, hooks) = await startHeld(settings: settings);
        expect(nb.binders, isEmpty);
        hooks.locked = false;
        expect(nb.standaloneFolders.map((f) => k(f.path)), [k(c)], reason: 'held: the chosen folder only');
        expect(await nb.retrySettings(), isTrue);
        expect(nb.standaloneFolders, isEmpty);
        expect(idsOf(nb), [a4]);
        expect(nb.pageTitleOf('cp'), 'Page cp');
      });
    });

    test('4: a change refused while locked is accepted after the retry; nothing is lost', () async {
      final b1 = await lockedSetup();
      final b2 = await binderAt('other/B2', a4);
      final (nb, hooks) = await startHeld();
      await refused(() => nb.addBinder(b2));
      hooks.locked = false;
      expect(await nb.retrySettings(), isTrue);
      await nb.addBinder(b2);
      final s = saved();
      expect((s['binders'] as List).map((p) => k(p as String)), [k(b1), k(b2)]);
      expect((s['binderIds'] as Map).values, [a1, a4]);
      expect(s['removedBinders'], [a2]);
      expect(s['x'], 'keep');
      final again = await restart(nb);
      expect(idsOf(again), [a1, a3, a4]);
    });

    test('5: while a retry opens binders, hand changes are refused; afterwards they succeed', () async {
      await lockedSetup();
      final b2 = await binderAt('other/B2', a4);
      Directory(at('sa')).createSync();
      final (nb, hooks) = await startHeld();
      hooks.locked = false;
      final gate = Completer<void>();
      hooks.on['settings-adopt'] = (_) => gate.future;
      final retry = nb.retrySettings();
      await until(() => hooks.count('settings-adopt') == 1, what: 'the retry to reach B1');
      await refused(() => nb.addBinder(b2));
      await refused(() => nb.removeStandaloneFolder(at('sa')));
      gate.complete();
      expect(await retry, isTrue);
      await nb.addBinder(b2);
      await nb.addStandaloneFolder(at('sa'));
      await nb.removeStandaloneFolder(nb.standaloneFolders.single.path);
      expect(idsOf(nb), contains(a4));
    });

    test('6: the backstop: a held list is never saved', () async {
      await lockedSetup();
      final before = settingsFile().readAsBytesSync();
      final (nb, _) = await startHeld();
      await nb.saveSettingsForTest();
      expect(settingsFile().readAsBytesSync(), before);
      expect(tmpFiles(), isEmpty);
      expect(nb.everythingReadable, isFalse, reason: 'held');
    });

    group('7: a retry waits for load', () {
      test('it does not read until load ends, then adopts the list', () async {
        await lockedSetup();
        final hooks = _Hooks()..locked = true;
        final nb = make();
        nb.binderHook = hooks.call;
        final gate = Completer<void>();
        hooks.on['settings-loaded'] = (_) => gate.future;
        final loading = nb.load();
        await until(() => hooks.count('settings-loaded') == 1, what: 'load to settle the hold');
        expect(nb.settingsHoldForTest, 'locked');
        hooks.locked = false;
        final retry = nb.retrySettings();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(hooks.count('settings-read'), 1, reason: 'no second read during load');
        gate.complete();
        await loading;
        expect(await retry, isTrue);
        expect(hooks.count('settings-read'), 2);
        expect(idsOf(nb), contains(a1));
      });

      test('conflict copies queued by load do not deadlock a retry started during load', () async {
        await lockedSetup();
        final codec = modules.codecs.codecFor('noted.note')!;
        BoxRecord noteBox(String text, Bounds b) => commitBox(createBox(codec, b), codec, codec.decode(doc(text), 1));
        final st = PageStore(Directory(at('pages')));
        for (final id in ['c1', 'c2']) {
          final page = NotedPage.create(PageMeta.create(id: id, title: id, order: 0));
          await st.save(page);
          File(at('pages/$id-PC2.canvas')).writeAsStringSync(
            writePage(page.insertNode(noteBox('copy of $id', const Bounds(400, 10, 200, 40)))),
          );
        }
        final hooks = _Hooks()..locked = true;
        final nb = make();
        nb.binderHook = hooks.call;
        final gate = Completer<void>();
        hooks.on['settings-loaded'] = (_) => gate.future;
        final loading = nb.load();
        await until(() => hooks.count('settings-loaded') == 1, what: 'load to settle the hold');
        hooks.locked = false;
        final retry = nb.retrySettings();
        gate.complete();
        await Future.wait([loading, retry]).timeout(const Duration(seconds: 20));
        expect(File(at('pages/c1-PC2.canvas')).existsSync(), isFalse, reason: 'merged by load');
        expect(idsOf(nb), contains(a1));
      });
    });

    test('8: a hand add before the launch read is refused; the file is byte-identical after load', () async {
      writeSettings({'format': 1, 'binders': <String>[], 'binderIds': <String, Object?>{}, 'x': 1});
      final before = settingsFile().readAsBytesSync();
      final nb = make();
      await refused(() => nb.createBinder(), loadingMsg);
      expect(Directory(at('binders/New binder')).existsSync(), isFalse);
      await nb.load();
      await nb.discoveryIdle;
      expect(settingsFile().readAsBytesSync(), before);
    });

    test('9: the cause changes between retries: the notice follows it, the refusal stays', () async {
      settingsFile().writeAsStringSync('{"format":1,"binders":[]}');
      final (nb, hooks) = await startHeld();
      expect(heldNotes(nb), [lockedNote]);
      hooks.locked = false;
      settingsFile().writeAsStringSync('{oops');
      expect(await nb.retrySettings(), isFalse);
      expect(heldNotes(nb), [damagedNote()]);
      await refused(() => nb.addBinder(at('other/B2')));
      settingsFile().writeAsStringSync('{"format":1,"binders":[]}');
      expect(await nb.retrySettings(), isTrue);
      expect(heldNotes(nb), isEmpty);
    });

    test('12: a hand add while load opens binders is refused with the loading message', () async {
      final b1 = await binderAt('other/B1', a1);
      final b2 = await binderAt('other/B2', a4);
      writeSettings({
        'format': 1,
        'binders': [b1],
        'binderIds': {b1: a1},
      });
      final before = settingsFile().readAsBytesSync();
      final hooks = _Hooks();
      final nb = make();
      nb.binderHook = hooks.call;
      final gate = Completer<void>();
      hooks.on['load-open'] = (_) => gate.future;
      final loading = nb.load();
      await until(() => hooks.count('load-open') == 1, what: 'load to reach B1');
      await refused(() => nb.addBinder(b2), loadingMsg);
      expect(settingsFile().readAsBytesSync(), before);
      gate.complete();
      await loading;
      await nb.addBinder(b2);
      expect(saved()['binders'], hasLength(2));
    });

    test('F6: load throws before the list is settled: the hold becomes locked and a retry is armed', () async {
      final b1 = await binderAt('other/B1', a1);
      writeSettings({
        'format': 1,
        'binders': [b1],
        'binderIds': {b1: a1},
      });
      final before = settingsFile().readAsBytesSync();
      final hooks = _Hooks();
      final nb = make();
      nb.binderHook = hooks.call;
      hooks.on['load-open'] = (p) async => throw StateError('stop');
      await expectLater(nb.load(), throwsA(isA<StateError>()));
      expect(hooks.count('load-open'), 1, reason: 'the hook fired');
      expect(nb.settingsHoldForTest, 'locked');
      expect(nb.settingsDelayForTest, isNotNull, reason: 'the timer is armed');
      await refused(() => nb.addBinder(at('other/B2')));
      expect(settingsFile().readAsBytesSync(), before);
    });

    test('a retry after a partial load lists each binder and page once', () async {
      final b1 = await binderAt('other/B1', a1, pages: ['b1p', 'b1q']);
      final b2 = await binderAt('other/B2', a4, pages: ['b2p']);
      writeSettings({
        'format': 1,
        'binders': [b1, b2],
        'binderIds': {b1: a1, b2: a4},
      });
      final hooks = _Hooks();
      final nb = make();
      nb.binderHook = hooks.call;
      var failing = true;
      hooks.on['load-open'] = (p) async {
        if (failing && k(p) == k(b2)) throw StateError('stop');
      };
      await expectLater(nb.load(), throwsA(isA<StateError>()));
      expect(hooks.count('load-open'), 2, reason: 'the hook fired for both');
      failing = false;
      expect(await nb.retrySettings(), isTrue);
      expect(nb.binders.map((b) => k(b.path)), [k(b1), k(b2)]);
      expect(treeOf(nb.binders.first), ['b1p:Page b1p', 'b1q:Page b1q']);
      for (final b in nb.binders) {
        expect(b.unreadable, isEmpty, reason: 'no false duplicates');
      }
      expect([for (final u in nb.unreadable) u.reason], isEmpty);
    });

    group('backoff, single flight and dispose', () {
      test('the wait doubles up to 60 s and stays there', () {
        var d = const Duration(seconds: 2);
        final seen = <int>[];
        for (var i = 0; i < 8; i++) {
          seen.add(d.inSeconds);
          d = Notebook.nextSettingsDelay(d);
        }
        expect(seen, [2, 4, 8, 16, 32, 60, 60, 60]);
      });

      test('failed retries double the armed wait', () async {
        await lockedSetup();
        final (nb, hooks) = await startHeld(retryFirst: const Duration(milliseconds: 10));
        final seen = <int>{};
        await until(() {
          final d = nb.settingsDelayForTest;
          if (d != null) seen.add(d.inMilliseconds);
          return seen.contains(80);
        }, what: 'the wait to reach 80 ms');
        expect(seen.every((m) => const [10, 20, 40, 80, 160].contains(m)), isTrue, reason: '$seen');
        expect(hooks.count('settings-read'), greaterThan(2));
      });

      test('two calls at once run one read and share the result', () async {
        await lockedSetup();
        final (nb, hooks) = await startHeld();
        hooks.locked = false;
        final before = hooks.count('settings-read');
        final a = nb.retrySettings();
        final b = nb.retrySettings();
        expect(identical(a, b), isTrue);
        expect(await a, isTrue);
        expect(hooks.count('settings-read'), before + 1);
      });

      test('dispose cancels the timer', () async {
        await lockedSetup();
        final (nb, hooks) = await startHeld(retryFirst: const Duration(milliseconds: 40));
        nb.dispose();
        opened.remove(nb);
        final reads = hooks.count('settings-read');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(hooks.count('settings-read'), reads);
      });
    });

    test('F4: everythingReadable is false while the list is held and true after', () async {
      await lockedSetup();
      final (nb, hooks) = await startHeld();
      expect(nb.everythingReadable, isFalse);
      hooks.locked = false;
      expect(await nb.retrySettings(), isTrue);
      expect(nb.everythingReadable, isTrue);
    });

    test('14: a retry that restores only a folder builds the tree, watches it, merges copies and replays recovery', () async {
      final codec = modules.codecs.codecFor('noted.note')!;
      BoxRecord noteBox(String text, Bounds b) => commitBox(createBox(codec, b), codec, codec.decode(doc(text), 1));
      final s = Directory(at('S'))..createSync();
      final page = NotedPage.create(PageMeta.create(id: 'sp', title: 'SP', order: 0));
      await PageStore(s).save(page);
      final copyBox = noteBox('from the copy', const Bounds(400, 10, 200, 40));
      final keptBox = noteBox('kept edit', const Bounds(400, 100, 200, 40));
      File(at('S/sp-PC2.canvas')).writeAsStringSync(writePage(page.insertNode(copyBox)));
      final rec = defaultRecoveryDirectory(settingsFile());
      await RecoveryStore(rec).write(
        folder: s.path,
        page: page.insertNode(keptBox),
        baseText: writePage(page),
        time: DateTime.now(),
      );
      writeSettings({
        'format': 1,
        'binders': <String>[],
        'binderIds': <String, Object?>{},
        'standaloneFolders': [s.path],
      });
      final hooks = _Hooks()..locked = true;
      final nb = make(watch: true);
      nb.binderHook = hooks.call;
      await nb.load();
      await nb.discoveryIdle;
      expect(nb.pageTitleOf('sp'), isNull, reason: 'hidden while held');
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      hooks.locked = false;
      expect(await nb.retrySettings(), isTrue);
      expect(nb.tree.roots.map((m) => m.id), contains('sp'), reason: 'P is in the tree');
      expect(File(at('S/sp-PC2.canvas')).existsSync(), isFalse, reason: 'the copy is merged and removed');
      expect((await nb.pendingRecovery()).entries, isEmpty, reason: 'the entry is replayed and retired');
      await nb.flush();
      final merged = await PageStore(s).load('sp');
      expect(merged.node(copyBox.id), isNotNull);
      expect(merged.node(keptBox.id), isNotNull);
      // The folder is watched: an outside edit of the page is merged.
      await PageStore(s).save(merged.withMeta(merged.meta.withTitle('Edited outside')));
      await until(() => nb.pageTitleOf('sp') == 'Edited outside', what: 'the watcher to see the edit');
    });

    test('15: a page in a binder and in the chosen folder is chosen as after a restart', () async {
      final b1 = await binderAt('other/B1', a1, pages: ['p']);
      final c = Directory(at('chosen'))..createSync();
      await PageStore(c).save(NotedPage.create(PageMeta.create(id: 'p', title: 'Copy in folder', order: 0)));
      writeSettings({
        'format': 1,
        'binders': [b1],
        'binderIds': {b1: a1},
      });
      final settings = AppSettings(null)..defaultPageFolder = c.path;
      final hooks = _Hooks()..locked = true;
      final nb = make(settings: settings);
      nb.binderHook = hooks.call;
      await nb.load();
      await nb.discoveryIdle;
      expect(nb.pageTitleOf('p'), 'Copy in folder', reason: 'held: only the folder is open');
      expect(nb.currentId, 'p');
      hooks.locked = false;
      expect(await nb.retrySettings(), isTrue);
      expect(nb.pageTitleOf('p'), 'Page p', reason: 'the binder copy wins, as in load');
      expect(nb.currentId, 'p', reason: 'the page the user was on stays open');
      List<String> problems(Notebook n) => [
        for (final u in n.unreadable) u.reason,
        for (final b in n.binders) ...[for (final u in b.unreadable) u.reason],
      ];
      final afterRetry = problems(nb);
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      expect((await PageStore(Directory(b1)).load('p')).nodes.whereType<BoxRecord>(), hasLength(1));
      expect((await PageStore(c).load('p')).nodes.whereType<BoxRecord>(), isEmpty);
      // The same choice after a restart.
      nb.dispose();
      opened.remove(nb);
      final again = make(settings: settings);
      await again.load();
      await again.discoveryIdle;
      expect(again.pageTitleOf('p'), 'Page p');
      expect(problems(again), afterRetry);
    });

    test('N-4: kept files of a page in a hidden binder are not called pageless, and land after the retry', () async {
      final b1 = await binderAt('other/B1', a1, pages: ['kp']);
      writeSettings({
        'format': 1,
        'binders': [b1],
        'binderIds': {b1: a1},
      });
      final bytes = utf8.encode('kept file');
      final name = '${contentHash(bytes)}.txt';
      final kept = Directory('${defaultRecoveryDirectory(settingsFile()).path}/kp.assets')..createSync(recursive: true);
      File('${kept.path}/$name').writeAsBytesSync(bytes);
      final hooks = _Hooks()..locked = true;
      final nb = make();
      nb.binderHook = hooks.call;
      await nb.load();
      await nb.discoveryIdle;
      expect(hooks.count('settings-read'), 1, reason: 'the hook fired');
      expect(nb.recoveryProblems.where((p) => p.contains('no page to go with')), isEmpty);
      await nb.checkFolders();
      expect(nb.recoveryProblems.where((p) => p.contains('no page to go with')), isEmpty);
      hooks.locked = false;
      expect(await nb.retrySettings(), isTrue);
      expect(File('$b1/kp.assets/$name').readAsBytesSync(), bytes);
      expect(kept.existsSync(), isFalse);
      expect(nb.recoveryProblems, isEmpty);
    });
  });
}
