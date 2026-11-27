// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The binder .zip writer and reader, the binder set (A1) and the entry rules
// (A4): one crafted archive per rule, each refused by a real open that leaves
// nothing on disk (design t6 §9).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_zip/binder_open.dart';
import 'package:noted/src/binder_zip/binder_set.dart';
import 'package:noted/src/binder_zip/zip_check.dart';
import 'package:noted/src/binder_zip/zip_writer.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/import/zip_reader.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/exclusive_publish.dart' show checkWindowsName;

import 'support/crafted_zip.dart';
import 'support/notebook_folder.dart';
import 'support/zip_builder.dart' show buildZip;

void main() {
  late Directory root;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_zip_rules');
  });

  tearDown(() async {
    await deleteTestFolder(root);
  });

  group('the writer', () {
    test('a byte-for-byte round trip, stored and deflated, with UTF-8 names', () async {
      final src = Directory('${root.path}/src')..createSync();
      final files = <String, List<int>>{
        'p.canvas': utf8.encode('{"page": "${'x' * 5000}"}\n'),
        'noted-binder.json': utf8.encode(binderJson()),
        'p.assets/Ünïcødé ✓ 名前.bin': List<int>.generate(200000, (i) => (i * 7919) & 0xFF),
        'p.assets/empty.txt': const [],
      };
      final sources = <ZipSource>[];
      for (final e in files.entries) {
        final f = File('${src.path}/${e.key}')..createSync(recursive: true);
        f.writeAsBytesSync(e.value);
        sources.add(ZipSource('Top/${e.key}', f.path, deflate: e.key.endsWith('.canvas') || e.key.endsWith('.json')));
      }
      final zip = '${root.path}${sep}out.zip';
      final r = appendZipEntries(zip, 0, sources, fileLimit: 1 << 30, archiveLimit: 1 << 30);
      expect([for (final a in r.added) a.state], everyElement(ZipAddState.added));
      expect([for (final a in r.added) a.stamp], everyElement(isNotNull));
      finishZip(zip, r.end, [for (final a in r.added) a.record!]);

      final reader = ZipReader(File(zip).readAsBytesSync(), ImportLimits.desktop);
      expect(reader.names.toSet(), {for (final k in files.keys) 'Top/$k'});
      for (final e in files.entries) {
        expect(reader.read('Top/${e.key}'), e.value, reason: e.key);
      }
      final byName = {for (final e in reader.entries) e.name: e};
      expect(byName['Top/p.canvas']!.method, 8);
      expect(byName['Top/noted-binder.json']!.method, 8);
      expect(byName['Top/p.assets/Ünïcødé ✓ 名前.bin']!.method, 0);
      expect(reader.entries.every((e) => e.utf8Name), isTrue);
      // What it writes passes its own checks.
      final plan = checkBinderZip(File(zip).readAsBytesSync());
      expect(plan.top, 'Top');
      expect(plan.files.map((f) => f.relative.join('/')).toSet(), {
        'p.canvas',
        'p.assets/Ünïcødé ✓ 名前.bin',
        'p.assets/empty.txt',
      });
    });

    test('a file over the per-file limit is not written, and the zip is cut back', () async {
      final f = File('${root.path}/big.bin')..writeAsBytesSync(List.filled(1000, 1));
      final zip = '${root.path}${sep}out.zip';
      final r = appendZipEntries(zip, 0, [ZipSource('T/big.bin', f.path, deflate: false)], fileLimit: 999, archiveLimit: 1 << 30);
      expect(r.added.single.state, ZipAddState.tooLarge);
      expect(r.end, 0);
      expect(File(zip).lengthSync(), 0);
    });

    test('compacting keeps only the live entries, readable', () async {
      final a = File('${root.path}/a.txt')..writeAsStringSync('aaa');
      final b = File('${root.path}/b.txt')..writeAsStringSync('bbb');
      final zip = '${root.path}${sep}out.zip';
      final r = appendZipEntries(zip, 0, [
        ZipSource('T/a.txt', a.path, deflate: false),
        ZipSource('T/b.txt', b.path, deflate: true),
      ], fileLimit: 1 << 20, archiveLimit: 1 << 30);
      final to = '${root.path}${sep}compact.zip';
      final live = compactZip(zip, to, [r.added[1].record!]);
      finishZip(to, live.last.end, live);
      final reader = ZipReader(File(to).readAsBytesSync(), ImportLimits.desktop);
      expect(reader.names.toList(), ['T/b.txt']);
      expect(utf8.decode(reader.read('T/b.txt')!), 'bbb');
    });
  });

  group('the binder set (A1)', () {
    test("Noted's own temporaries", () {
      for (final n in [
        'p.canvas.1732000000000000-3.tmp',
        '.x.png.noted-copy-1234.tmp',
        '.Work.zip.noted-export-00ff.tmp',
        'p.canvas.12-ab-cd.cas-old',
        'abc.png.12-ab-cd.cas-verified',
      ]) {
        expect(isNotedTemp(n), isTrue, reason: n);
      }
      for (final n in ['x.tmp', 'p.canvas', 'notes.txt', 'abc.png', '.hidden']) {
        expect(isNotedTemp(n), isFalse, reason: n);
      }
    });

    test('what is in it', () {
      expect(inBinderSet(['noted-binder.json']), isTrue);
      expect(inBinderSet(['noted-binder (1).json']), isTrue, reason: 'a conflict copy');
      expect(inBinderSet(['noted-binder-LAPTOP.json']), isTrue, reason: 'a conflict copy');
      expect(inBinderSet(['noted-binder.json.1732-1.tmp']), isFalse, reason: 'a temporary');
      expect(inBinderSet(['noted-binder.json.12-ab-cd.cas-old']), isFalse, reason: 'an aside');
      expect(inBinderSet(['p.canvas']), isTrue);
      expect(inBinderSet(['p-LAPTOP.canvas']), isTrue);
      expect(inBinderSet(['p.assets', 'abc.png']), isTrue);
      expect(inBinderSet(['p.assets', 'x.tmp']), isTrue, reason: 'an attachment named x.tmp');
      expect(inBinderSet(['p.assets', 'abc.png.12-ab-cd.cas-old']), isFalse);
      expect(inBinderSet(['p.deleted-0123456789ab.assets', 'abc.png']), isFalse, reason: 'a set-aside');
      expect(inBinderSet(['templates', 't.notedtemplate']), isTrue);
      expect(inBinderSet(['templates', 't.assets', 'abc.png']), isTrue);
      for (final n in ['desktop.ini', '.DS_Store', 'notes.txt', 'deleted-attachments']) {
        expect(inBinderSet([n]), isFalse, reason: n);
      }
      expect(inBinderSet(['other', 'p.canvas']), isFalse);
    });

    test("which files are Noted's own (read under the lock)", () {
      expect(isNotedOwnFile(['p.canvas']), isTrue);
      expect(isNotedOwnFile(['noted-binder.json']), isTrue);
      expect(isNotedOwnFile(['templates', 't.notedtemplate']), isTrue);
      expect(isNotedOwnFile(['templates', 't.assets', 'a.png']), isTrue);
      expect(isNotedOwnFile(['p.assets', 'a.png']), isFalse);
    });
  });

  test('the component rule covers checkWindowsName', () {
    for (final n in ['CON', 'con.txt', 'NUL', 'Aux.json', 'COM1', 'LPT9.x', 'a.', 'a ', 'fine', 'a.b', 'COM10', 'CONX']) {
      var windows = false;
      try {
        checkWindowsName('C:\\x\\$n');
      } on FileSystemException {
        windows = true;
      }
      if (windows) expect(componentProblem(n), isNotNull, reason: n);
    }
  });

  group('entry rules (A4): each refusal leaves nothing on disk', () {
    late Notebook nb;
    late Directory parent;

    setUp(() async {
      Directory('${root.path}/app/pages').createSync(recursive: true);
      parent = Directory('${root.path}/into')..createSync();
      nb = Notebook(
        PageStore(Directory('${root.path}/app/pages')),
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${root.path}/app/binders.json'),
        cacheDirectory: Directory('${root.path}/cache'),
        folderCheckInterval: Duration.zero,
      );
      await nb.load();
    });

    tearDown(() async {
      await nb.flush();
      nb.dispose();
    });

    CraftedEntry binder() => CraftedEntry('B/noted-binder.json', binderJson());

    Future<String> refused(Uint8List zip) async {
      final f = File('${root.path}${sep}in.zip')..writeAsBytesSync(zip);
      try {
        await BinderZipOpen(nb, zipPath: f.path, parent: parent.path, roots: () => nb.exportRefusedFolders).run();
      } on BinderZipException catch (e) {
        expect(parent.listSync(), isEmpty, reason: 'nothing is left in the parent');
        return e.message;
      }
      fail('the archive was opened');
    }

    Future<void> expectRefused(List<CraftedEntry> extra, Object reason) async {
      expect(await refused(craftZip([binder(), ...extra])), reason);
    }

    const cant = "This .zip can't be opened as a binder: ";

    test('encrypted, zip64, multi-disk and other methods (the reader rules)', () async {
      await expectRefused([CraftedEntry('B/p.canvas', '{}', flags: 0x0801)], '${cant}it is encrypted.');
      await expectRefused([CraftedEntry('B/p.canvas', '{}', flags: 0x0840)], '${cant}it is encrypted.');
      expect(
        await refused(buildZip({'B/noted-binder.json': binderJson()}, zip64: true)),
        "${cant}it can't be read.",
      );
      await expectRefused([CraftedEntry('B/p.canvas', '{}', diskStart: 1)], '${cant}it spans several disks.');
      await expectRefused(
        [CraftedEntry('B/p.canvas', '{}', deflate: false, method: 12)],
        "${cant}it uses a compression Noted can't read.",
      );
    });

    test('a name without bit 11 that has a byte of 0x80 or more', () async {
      await expectRefused([
        CraftedEntry('B/x.canvas', '{}', flags: 0, rawName: [...utf8.encode('B/caf'), 0xE9, ...utf8.encode('.canvas')]),
      ], '${cant}a name in it is not UTF-8.');
      // Bit 11 with the same name in UTF-8 is fine, and so is plain ASCII without it.
      final f = File('${root.path}${sep}ok.zip')
        ..writeAsBytesSync(craftZip([binder(), CraftedEntry('B/café.canvas', '{}'), CraftedEntry('B/a.canvas', '{}', flags: 0)]));
      expect(checkBinderZip(f.readAsBytesSync()).files, hasLength(2));
    });

    test('absolute names, drive letters, colons and empty, . or .. components', () async {
      for (final n in ['/B/p.canvas', r'\B\p.canvas', '//server/B/p.canvas', 'C:/B/p.canvas', 'B/a:b.canvas', 'B/./p.canvas', 'B/../p.canvas', 'B//p.canvas', r'B\..\..\p.canvas']) {
        await expectRefused([CraftedEntry(n, '{}')], contains('is not a name Noted can use'));
      }
    });

    test('control characters and <>"|?*', () async {
      for (final c in ['\u0001', '\u001f', '\u007f', '<', '>', '"', '|', '?', '*']) {
        await expectRefused([CraftedEntry('B/a${c}b.canvas', '{}')], contains('is not a name Noted can use'));
      }
    });

    test('a component ending in a dot or a space', () async {
      await expectRefused([CraftedEntry('B/p.assets./a.png', 'x')], contains('is not a name Noted can use'));
      await expectRefused([CraftedEntry('B/p.assets /a.png', 'x')], contains('is not a name Noted can use'));
      await expectRefused([CraftedEntry('B/p.assets/a.png.', 'x')], contains('is not a name Noted can use'));
    });

    test('reserved names, with any extension', () async {
      for (final n in ['CON', 'prn.canvas', 'Aux.png', 'NUL.tar.gz', 'COM0', 'COM9.txt', 'LPT0', 'lpt5.x', 'COM¹', 'LPT³.a']) {
        await expectRefused([CraftedEntry('B/p.assets/$n', 'x')], contains('is not a name Noted can use'));
      }
    });

    test('a component over 255 UTF-16 units', () async {
      await expectRefused([CraftedEntry('B/p.assets/${'é' * 256}', 'x')], contains('is not a name Noted can use'));
    });

    test('a full path over 259 characters (the staging path with its suffix, or the final one)', () async {
      final parentLen = parent.path.length;
      // Short enough for each component, too long once placed.
      final room = 259 - parentLen - '/B (99)/p.assets/'.length;
      await expectRefused([CraftedEntry('B/p.assets/${'a' * (room + 1).clamp(1, 255)}', 'x')], '${cant}a path in it is too long.');
    });

    test('links and other non-regular entries', () async {
      const unix = (3 << 8) | 20;
      for (final mode in [0xA1FF, 0x1180, 0x2180, 0x6180, 0xC1FF]) {
        await expectRefused([CraftedEntry('B/p.assets/l', 'x', madeBy: unix, external: mode << 16)], contains('is a link or a special file'));
      }
      await expectRefused([CraftedEntry('B/p.assets/l', 'x', external: 0x400)], contains('is a link or a special file'));
      // A Unix regular file and a Unix folder are fine.
      final ok = craftZip([
        binder(),
        CraftedEntry('B/p.canvas', '{}', madeBy: unix, external: 0x81A4 << 16),
        CraftedEntry.dir('B/p.assets', madeBy: unix, external: 0x41ED << 16),
      ]);
      expect(checkBinderZip(ok).folders.map((f) => f.join('/')), ['p.assets']);
    });

    test('twins after case folding, and a file at a folder’s path', () async {
      await expectRefused([CraftedEntry('B/p.canvas', '{}'), CraftedEntry('B/P.CANVAS', '{}')], contains('differ only in case'));
      await expectRefused([CraftedEntry('B/p.canvas', '{}'), CraftedEntry('B/p.canvas', '{}')], contains('is in it twice'));
      await expectRefused([CraftedEntry('B/p.assets', 'x'), CraftedEntry('B/p.assets/a.png', 'x')], contains('is both a file and a folder'));
      await expectRefused([CraftedEntry('B/P.assets', 'x'), CraftedEntry('B/p.assets/a.png', 'x')], contains('is both a file and a folder'));
      await expectRefused([CraftedEntry('B/p.assets', 'x'), CraftedEntry.dir('B/P.ASSETS')], contains('differ only in case'));
    });

    test('Z2: a binder file with a top-level key twice is refused before anything is written', () async {
      expect(
        await refused(craftZip([CraftedEntry('B/noted-binder.json', binderJson(ai: 'guarded', extra: ',"ai":"open"'))])),
        '${cant}its binder file has a field twice.',
      );
    });

    test('no binder, a damaged binder file, and too many entries', () async {
      expect(await refused(craftZip([CraftedEntry('B/p.canvas', '{}')])), 'This .zip has no binder in it.');
      expect(
        await refused(craftZip([CraftedEntry('A/noted-binder.json', binderJson()), CraftedEntry('C/x.canvas', '{}')])),
        'This .zip has no binder in it.',
      );
      expect(await refused(craftZip([CraftedEntry('B/noted-binder.json', '{"format":1')])), "${cant}its binder file can't be read.");
      expect(
        await refused(craftZip([CraftedEntry('B/noted-binder.json', binderJson(), crc: 1)])),
        "${cant}its binder file can't be read.",
      );
      final many = [binder(), for (var i = 0; i < BinderZipLimits.entries; i++) CraftedEntry('B/p.assets/$i', '', deflate: false)];
      expect(await refused(craftZip(many)), '${cant}it has too many files.');
    });
  });
}
