// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Opening a binder from a .zip (design t6 §4, §9 "Open", build rules Z1 and
// Z2), on the real file system and with no injected opener.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_zip/binder_open.dart';
import 'package:noted/src/binder_zip/zip_check.dart';
import 'package:noted/src/binder_zip/zip_extract.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/crafted_zip.dart';
import 'support/notebook_folder.dart';

const String _pageA = 'a1b2c3d4e5f60718';
const String _pageB = 'b1b2c3d4e5f60718';

String pageText(String id, {String title = 'Page', AiAccess? ai, String? parentId}) {
  var meta = PageMeta.create(id: id, title: title, order: 0, parentId: parentId);
  if (ai != null) meta = meta.withAiAccess(ai);
  return writePage(NotedPage.create(meta));
}

/// Runs the MCP server's library load over [dataDir] in its own process and
/// returns its pages.
Future<List<Map<String, Object?>>> mcpPages(Directory dataDir) async {
  final r = await Process.run(
    'dart',
    ['run', 'test/support/library_probe.dart', dataDir.path],
    workingDirectory: '../packages/noted_mcp',
    runInShell: true,
  ).timeout(const Duration(minutes: 3));
  final line = (r.stdout as String).split(RegExp(r'\r?\n')).firstWhere(
    (l) => l.startsWith('library:'),
    orElse: () => fail('the probe said ${r.stdout} ${r.stderr}'),
  );
  final json = jsonDecode(line.substring('library:'.length)) as Map<String, Object?>;
  return (json['pages']! as List).cast<Map<String, Object?>>();
}

void main() {
  late Directory root;
  late Directory app;
  late Directory parent;
  late List<Notebook> opened;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_zip_open');
    app = Directory('${root.path}${sep}app')..createSync();
    Directory('${app.path}${sep}pages').createSync();
    parent = Directory('${root.path}${sep}into')..createSync();
    opened = [];
  });

  tearDown(() async {
    for (final nb in opened) {
      nb.binderHook = null;
      await nb.discoveryIdle;
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Notebook make() {
    final nb = Notebook(
      PageStore(Directory('${app.path}${sep}pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${app.path}${sep}binders.json'),
      cacheDirectory: Directory('${root.path}${sep}cache'),
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  Future<Notebook> started() async {
    final nb = make();
    await nb.load();
    await nb.discoveryIdle;
    return nb;
  }

  String zipOf(List<CraftedEntry> entries, {String name = 'Shared.zip'}) {
    final f = File('${root.path}$sep$name')..writeAsBytesSync(craftZip(entries));
    return f.path;
  }

  String standardZip({String? ai = 'open', String extra = ''}) => zipOf([
    CraftedEntry('Shared/noted-binder.json', binderJson(ai: ai, extra: extra)),
    CraftedEntry('Shared/$_pageA.canvas', pageText(_pageA, title: 'First', ai: AiAccess.open)),
    CraftedEntry('Shared/$_pageA.assets/abc.bin', List<int>.generate(3000, (i) => i & 0xFF), deflate: false),
  ]);

  BinderZipOpen opener(Notebook nb, String zip, {String? into, BinderZipMover? mover, Duration? busyFor,
      Future<void> Function(String)? afterExtract, Future<void> Function(ZipExtraction)? beforeRollback,
      Future<void> Function(String)? afterRename}) =>
      BinderZipOpen(
        nb,
        zipPath: zip,
        parent: into ?? parent.path,
        roots: () => nb.exportRefusedFolders,
        mover: mover ?? (from, to, {beforeOsCall}) => moveExclusive(from, to, beforeOsCall: beforeOsCall),
        busyFor: busyFor ?? const Duration(seconds: 5),
        busyStep: const Duration(milliseconds: 20),
        afterExtract: afterExtract,
        beforeRollback: beforeRollback,
        afterRename: afterRename,
      );

  List<String> namesIn(Directory d) => [for (final e in d.listSync()) e.path.split(RegExp(r'[\\/]')).last]..sort();

  group('R-3: no-replace writes on the real file system', () {
    test('an existing name and a case twin each give "not created", and keep their bytes', () {
      final d = Directory('${root.path}${sep}t')..createSync();
      final a = File('${d.path}${sep}a.txt')..writeAsStringSync('mine');
      expect(() => createNewFile(a.path, Uint8List.fromList([1]), (_) {}), throwsA(isA<FileSystemException>()));
      expect(a.readAsStringSync(), 'mine');
      if (Platform.isWindows || Platform.isMacOS) {
        expect(() => createNewFile('${d.path}${sep}A.TXT', Uint8List.fromList([1]), (_) {}), throwsA(isA<FileSystemException>()));
        expect(a.readAsStringSync(), 'mine');
      }
      Directory('${d.path}${sep}sub').createSync();
      expect(() => createNewFile('${d.path}${sep}sub', Uint8List.fromList([1]), (_) {}), throwsA(isA<FileSystemException>()));
      ContentIdentity? last;
      createNewFile('${d.path}${sep}new.bin', Uint8List.fromList([4, 5]), (id) => last = id);
      expect(last, ContentIdentity.ofBytes([4, 5]));
    });

    test('createTemp makes a fresh folder each time, its suffix within the length counted', () async {
      final a = await parent.createTemp('.Shared.noted-open-');
      final b = await parent.createTemp('.Shared.noted-open-');
      expect(a.path, isNot(b.path));
      final suffix = a.path.split(RegExp(r'[\\/]')).last.length - '.Shared.noted-open-'.length;
      expect(suffix, lessThanOrEqualTo(createTempSuffixLength));
      a.deleteSync();
      b.deleteSync();
    });

    test('a file already in the staging folder (a case twin) is not replaced: not created, and kept', () async {
      final zip = zipOf([
        CraftedEntry('Shared/noted-binder.json', binderJson()),
        CraftedEntry('Shared/$_pageA.canvas', pageText(_pageA)),
      ]);
      final plan = checkBinderZip(File(zip).readAsBytesSync());
      final staging = Directory('${root.path}${sep}stage')..createSync();
      final twin = File('${staging.path}$sep${_pageA.toUpperCase()}.CANVAS')..writeAsStringSync('theirs');
      final x = extractBinderZip(zip, staging.path, plan, plan.binderBytes);
      if (Platform.isWindows || Platform.isMacOS) {
        expect(x.failure, '$_pageA.canvas was not created');
        expect(x.files, isEmpty);
      }
      expect(twin.readAsStringSync(), 'theirs');
    });

    test('a round trip: an Open-access zip opens Guarded, its page and attachment byte-equal', () async {
      final nb = await started();
      final zip = standardZip();
      final r = await opener(nb, zip).run();
      expect(r.message, 'Opened "Shared". AI access was set to Guarded.');
      final folder = '${parent.path}${sep}Shared';
      expect(r.path, folder);
      expect(nb.binders.map((b) => b.path), contains(folder));
      expect(nb.binderAiAccess(folder), AiAccess.guarded);
      expect(File('$folder$sep$_pageA.canvas').readAsStringSync(), pageText(_pageA, title: 'First', ai: AiAccess.open));
      expect(File('$folder$sep$_pageA.assets${sep}abc.bin').readAsBytesSync(), List<int>.generate(3000, (i) => i & 0xFF));
      expect(namesIn(parent), ['Shared'], reason: 'no staging folder is left');
    });
  });

  group('rollback (R-1 and CRC)', () {
    List<CraftedEntry> badLast() => [
      CraftedEntry('Shared/noted-binder.json', binderJson()),
      CraftedEntry('Shared/$_pageA.canvas', pageText(_pageA)),
      CraftedEntry('Shared/$_pageB.canvas', pageText(_pageB)),
      CraftedEntry('Shared/$_pageA.assets/x.bin', [1, 2, 3, 4], crc: 12345),
    ];

    test('a CRC mismatch on the last entry rolls back the rest', () async {
      final nb = await started();
      await expectLater(
        opener(nb, zipOf(badLast())).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'message', "This .zip can't be opened as a binder: $_pageA.assets/x.bin is damaged.")),
      );
      expect(parent.listSync(), isEmpty);
      expect(nb.binders, isEmpty);
    });

    test('a created file replaced before the rollback survives, as does an equal-length different file', () async {
      final nb = await started();
      String? staging;
      final e = await opener(
        nb,
        zipOf(badLast()),
        beforeRollback: (made) async {
          staging = made.folders.first;
          File('$staging$sep$_pageA.canvas').writeAsStringSync('another writer, another length');
          final b = File('$staging$sep$_pageB.canvas');
          final same = b.readAsBytesSync();
          b.writeAsBytesSync([for (final x in same) x == 0x7b ? 0x5b : x]);
        },
      ).run().then<Object>((_) => fail('opened'), onError: (Object e) => e);
      expect((e as BinderZipException).message, 'Not opened. Part of it is left in $staging.');
      expect(File('$staging$sep$_pageA.canvas').readAsStringSync(), 'another writer, another length');
      expect(File('$staging$sep$_pageB.canvas').existsSync(), isTrue, reason: 'equal length, other bytes: kept');
      expect(Directory('$staging$sep$_pageA.assets').existsSync(), isFalse, reason: 'its empty folder went');
      expect(nb.binders, isEmpty);
    });
  });

  group('the rename', () {
    test('taken names give " (2)", then " (3)"', () async {
      final nb = await started();
      Directory('${parent.path}${sep}Shared').createSync();
      File('${parent.path}${sep}Shared (2)').writeAsStringSync('a file');
      final r = await opener(nb, standardZip()).run();
      expect(r.path, '${parent.path}${sep}Shared (3)');
      expect(Directory('${parent.path}${sep}Shared').listSync(), isEmpty, reason: 'never written into');
      expect(File('${parent.path}${sep}Shared (2)').readAsStringSync(), 'a file');
    });

    test('a busy rename is tried again', () async {
      final nb = await started();
      var tries = 0;
      final r = await opener(
        nb,
        standardZip(),
        mover: (from, to, {beforeOsCall}) async {
          if (++tries < 3) return MoveOutcome.busy;
          return moveExclusive(from, to, beforeOsCall: beforeOsCall);
        },
      ).run();
      expect(tries, 3);
      expect(r.path, '${parent.path}${sep}Shared');
    });

    test('a rename that stays busy rolls back', () async {
      final nb = await started();
      await expectLater(
        opener(nb, standardZip(), busyFor: const Duration(milliseconds: 200), mover: (from, to, {beforeOsCall}) async => MoveOutcome.busy).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'message', "Couldn't make the binder's folder: the folder is busy.")),
      );
      expect(parent.listSync(), isEmpty);
    });

    test('any other failure of the rename rolls back and says the folder was not made', () async {
      final nb = await started();
      await expectLater(
        opener(nb, standardZip(), mover: (from, to, {beforeOsCall}) async => throw StateError('a bug')).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'message', "Couldn't make the binder's folder: it couldn't be finished.")),
      );
      expect(parent.listSync(), isEmpty, reason: 'everything it made was removed');
    });

    test('Z2: a binder file replaced with Open after it is written rolls back and is never renamed', () async {
      final nb = await started();
      String? staging;
      var moved = false;
      final e = await opener(
        nb,
        standardZip(),
        mover: (from, to, {beforeOsCall}) async {
          moved = true;
          return moveExclusive(from, to, beforeOsCall: beforeOsCall);
        },
        afterExtract: (s) async {
          staging = s;
          File('$s$sep$binderFileName').writeAsStringSync(binderJson(ai: 'open'));
        },
      ).run().then<Object>((_) => fail('opened'), onError: (Object e) => e);
      expect(moved, isFalse);
      expect((e as BinderZipException).message, 'Not opened. Part of it is left in $staging.');
      expect(namesIn(parent), [staging!.split(RegExp(r'[\\/]')).last], reason: 'only the hidden staging folder');
      expect(nb.binders, isEmpty);
    });

    test('Z1: the binder file changed just before the OS rename is never renamed', () async {
      final nb = await started();
      await expectLater(
        opener(
          nb,
          standardZip(),
          mover: (from, to, {beforeOsCall}) async {
            File('$from$sep$binderFileName').writeAsStringSync(binderJson(ai: 'guarded', title: 'Other'));
            return moveExclusive(from, to, beforeOsCall: beforeOsCall);
          },
        ).run(),
        throwsA(isA<BinderZipException>()),
      );
      expect(Directory('${parent.path}${sep}Shared').existsSync(), isFalse);
    });
  });

  group('what is opened', () {
    test('a listed id is refused before anything is written', () async {
      final nb = await started();
      final mine = Directory('${root.path}${sep}Mine')..createSync();
      File('${mine.path}$sep$binderFileName').writeAsStringSync(binderJson(title: 'Mine'));
      await nb.addBinder(mine.path);
      await expectLater(
        opener(nb, standardZip()).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'message', 'You have this binder already: "Mine".')),
      );
      expect(parent.listSync(), isEmpty);
    });

    test('a zip with a top folder and one without both open; __MACOSX is skipped, directory entries accepted', () async {
      final nb = await started();
      final flat = zipOf([
        CraftedEntry('noted-binder.json', binderJson(id: '1111111111111111', title: 'Flat')),
        CraftedEntry('$_pageA.canvas', pageText(_pageA)),
        CraftedEntry.dir('$_pageA.assets'),
        CraftedEntry.dir('$_pageA.assets/sub'),
        CraftedEntry('__MACOSX/._noted-binder.json', 'junk'),
        CraftedEntry('.DS_Store', 'junk'),
        CraftedEntry('notes.txt', 'outside the set'),
      ], name: 'Flat one.zip');
      final r = await opener(nb, flat).run();
      expect(r.message, 'Opened "Flat". 3 other files weren\'t opened.');
      final folder = '${parent.path}${sep}Flat one';
      expect(r.path, folder);
      expect(namesIn(Directory(folder)), ['$_pageA.assets', '$_pageA.canvas', binderFileName]);
      expect(Directory('$folder$sep$_pageA.assets${sep}sub').existsSync(), isTrue);

      final topped = zipOf([
        CraftedEntry.dir('Topped'),
        CraftedEntry('Topped/noted-binder.json', binderJson(id: '2222222222222222', title: 'Topped', ai: 'guarded')),
        CraftedEntry('Topped/$_pageB.canvas', pageText(_pageB)),
        CraftedEntry('__MACOSX/Topped/._x', 'junk'),
      ], name: 'whatever.zip');
      final t = await opener(nb, topped).run();
      expect(t.message, 'Opened "Topped". 1 other file wasn\'t opened.');
      expect(t.path, '${parent.path}${sep}Topped');
    });

    test('nothing is written to a binder whose page id is duplicated', () async {
      final nb = await started();
      final mine = Directory('${root.path}${sep}Mine')..createSync();
      File('${mine.path}$sep$binderFileName').writeAsStringSync(binderJson(id: 'ffffffffffffffff', title: 'Mine'));
      File('${mine.path}$sep$_pageA.canvas').writeAsStringSync(pageText(_pageA, title: 'Mine'));
      await nb.addBinder(mine.path);
      await nb.flush();
      Map<String, List<int>> snapshot() => {
        for (final f in mine.listSync(recursive: true).whereType<File>()) f.path: f.readAsBytesSync(),
      };
      final before = snapshot();
      await opener(nb, standardZip()).run().then<void>((_) {}, onError: (Object _) {});
      await nb.flush();
      await settleNotebooks(notebooks: [nb]);
      expect(snapshot(), before);
    });

    test('the default binder folder is allowed as a parent, a binder inside it is not', () async {
      final nb = await started();
      final def = Directory(nb.defaultBinderFolderPath)..createSync(recursive: true);
      final inside = Directory('${def.path}${sep}Old')..createSync();
      File('${inside.path}$sep$binderFileName').writeAsStringSync(binderJson(id: 'eeeeeeeeeeeeeeee', title: 'Old'));
      await nb.addBinder(inside.path);
      await expectLater(
        opener(nb, standardZip(), into: inside.path).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'message', "Choose a place outside Noted's folders.")),
      );
      await expectLater(
        opener(nb, standardZip(), into: app.path).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'message', "Choose a place outside Noted's folders.")),
      );
      final r = await opener(nb, standardZip(), into: def.path).run();
      expect(r.path, '${def.path}${sep}Shared');
    });
  });

  group('AI access', () {
    test('BL2: a crash between the rename and the add; discovery and the MCP server read it as Guarded', () async {
      final nb = await started();
      final def = Directory(nb.defaultBinderFolderPath)..createSync(recursive: true);
      const unknown = ',"zzFuture":{"a" : [1, 2,3]}';
      final original = binderJson(ai: 'open', extra: unknown);
      final zip = zipOf([
        CraftedEntry('Shared/noted-binder.json', original),
        CraftedEntry('Shared/$_pageA.canvas', pageText(_pageA, ai: AiAccess.open)),
      ]);
      await expectLater(
        opener(nb, zip, into: def.path, afterRename: (_) async => throw const BinderZipException('crash')).run(),
        throwsA(isA<BinderZipException>()),
      );
      final folder = '${def.path}${sep}Shared';
      final onDisk = File('$folder$sep$binderFileName').readAsStringSync();
      expect(onDisk, Binder.parse(original).withAiAccess(AiAccess.guarded).write());
      expect(onDisk, contains('"zzFuture":{"a" : [1, 2,3]}'), reason: 'unknown fields keep their bytes');
      expect(nb.binders, isEmpty);
      // A new notebook's discovery finds it, Guarded.
      await nb.discoveryIdle;
      await nb.flush();
      nb.dispose();
      opened.remove(nb);
      final again = await started();
      await again.discoverBinders();
      await again.discoveryIdle;
      expect(again.binders.map((b) => b.path), contains(folder));
      expect(again.binderAiAccess(folder), AiAccess.guarded);
      await again.flush();
      final pages = await mcpPages(app);
      final mine = pages.where((p) => p['id'] == _pageA).toList();
      expect(mine, isNotEmpty);
      for (final p in mine) {
        expect(p['access'], 'guarded');
        expect(p['binderAi'], 'guarded');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Z2: an MCP load between the saved list and the merges lists none of its pages as readable', () async {
      final nb = await started();
      final zip = zipOf([
        CraftedEntry('Shared/noted-binder.json', binderJson(ai: 'open')),
        CraftedEntry('Shared/$_pageA.canvas', pageText(_pageA, ai: AiAccess.open)),
        CraftedEntry('Shared/$_pageA-LAPTOP.canvas', pageText(_pageA, ai: AiAccess.open, title: 'Copy')),
        CraftedEntry('Shared/$_pageB.canvas', pageText(_pageB, ai: AiAccess.open)),
      ]);
      List<Map<String, Object?>>? seen;
      nb.binderHook = (point, path) async {
        if (point == 'listed' && path.endsWith('${sep}Shared')) seen = await mcpPages(app);
      };
      await opener(nb, zip).run();
      nb.binderHook = null;
      expect(seen, isNotNull, reason: 'the load ran at the seam');
      final ours = seen!.where((p) => (p['folder'] as String).endsWith('Shared')).toList();
      expect(ours, isNotEmpty, reason: 'the binder was listed then');
      for (final p in ours) {
        expect(p['access'], 'guarded', reason: '${p['id']}');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the backstop: a binder file made Open after the rename is set to Guarded by the add', () async {
      final nb = await started();
      final r = await opener(
        nb,
        standardZip(ai: 'guarded'),
        afterRename: (folder) async => File('$folder$sep$binderFileName').writeAsStringSync(binderJson(ai: 'open')),
      ).run();
      expect(r.message, 'Opened "Shared".');
      await nb.flush();
      final folder = '${parent.path}${sep}Shared';
      expect(Binder.parse(File('$folder$sep$binderFileName').readAsStringSync()).aiAccess, AiAccess.guarded);
      expect(nb.binderAiAccess(folder), AiAccess.guarded);
    });

    test('the backstop: when Guarded can\'t be written, the binder is taken out again and its files kept', () async {
      final nb = await started();
      final folder = '${parent.path}${sep}Shared';
      final e = await opener(
        nb,
        standardZip(ai: 'guarded'),
        afterRename: (folder) async {
          final f = File('$folder$sep$binderFileName')..writeAsStringSync(binderJson(ai: 'open'));
          if (Platform.isWindows) {
            Process.runSync('attrib', ['+r', f.path]);
          } else {
            Process.runSync('chmod', ['444', f.path]);
          }
        },
      ).run().then<Object>((_) => fail('opened'), onError: (Object e) => e);
      expect(
        (e as BinderZipException).message,
        "Noted couldn't set AI access to Guarded, so the binder wasn't opened. It is in $folder.",
      );
      expect(nb.binders.map((b) => b.path), isNot(contains(folder)));
      expect(File('$folder$sep$_pageA.canvas').existsSync(), isTrue);
      final f = File('$folder$sep$binderFileName');
      if (Platform.isWindows) {
        Process.runSync('attrib', ['-r', f.path]);
      } else {
        Process.runSync('chmod', ['644', f.path]);
      }
    });
  });
}
