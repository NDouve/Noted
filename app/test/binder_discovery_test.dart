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
import 'package:noted/main.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/open_files.dart';
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

// A settings file that exists but can't be read (a lock).
class _LockedFile implements File {
  _LockedFile(this.real);

  final File real;

  @override
  Future<bool> exists() async => true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      throw FileSystemException('locked by another program', real.path);

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

      test('a damaged binders.json is an upgrade', () async {
        await binderAt('binders/U', a1);
        settingsFile().writeAsStringSync('{oops');
        final nb = await start();
        expect(nb.binders, isEmpty);
        expect(saved()['removedBinders'], [a1]);
        expect(File(at('binders.json.bad')).existsSync(), isTrue);
      });
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

      test('a binders.json that can\'t be read at launch: no discovery and the file is left alone', () async {
        await binderAt('binders/U', a1);
        writeSettings({'format': 1, 'binders': <String>[]});
        final before = settingsFile().readAsBytesSync();
        final nb = await start(file: _LockedFile(settingsFile()));
        await nb.discoverBinders();
        expect(nb.binders, isEmpty);
        nb.dispose();
        opened.remove(nb);
        expect(settingsFile().readAsBytesSync(), before);
        // Control: readable, the same state is an upgrade that records it.
        final ok = await start();
        expect(ok.binders, isEmpty);
        expect(saved()['removedBinders'], [a1]);
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
}
