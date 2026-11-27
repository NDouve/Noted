// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Sharing a binder as a .zip (design t6 §3, §9 "Share", build rule Z3): only
// the binder set, refusals before anything is read, the metadata check and its
// rounds, Noted's own files read under the folder lock (BL1, real file system),
// attachments held open outside it, and the publish.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/binder_zip/binder_set.dart';
import 'package:noted/src/binder_zip/binder_share.dart';
import 'package:noted/src/binder_zip/binder_zip_flow.dart';
import 'package:noted/src/binder_zip/zip_check.dart';
import 'package:noted/src/binder_zip/zip_writer.dart';
import 'package:noted/src/export/export_targets.dart';
import 'package:noted/src/export/export_write.dart';
import 'package:noted/src/import/import_limits.dart';
import 'package:noted/src/import/zip_reader.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted/src/save_trouble.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/dataless.dart' show debugMarkDataless, debugDatalessPaths;
import 'package:noted_core/src/storage/folder_walk.dart' show debugAppleMode, debugListDir;

import 'support/notebook_folder.dart';
import 'support/trouble_world.dart';

void main() {
  late Directory root;
  late Directory work;
  late List<Notebook> opened;
  final sep = Platform.pathSeparator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_zip_share');
    Directory('${root.path}${sep}app${sep}pages').createSync(recursive: true);
    work = Directory('${root.path}${sep}ziptemp')..createSync();
    opened = [];
  });

  tearDown(() async {
    debugZipPlaceholderState = null;
    debugListDir = null;
    debugAppleMode = null;
    debugDatalessPaths = null;
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    await deleteTestFolder(root);
  });

  Notebook make() {
    final nb = Notebook(
      PageStore(Directory('${root.path}${sep}app${sep}pages')),
      buildModules(),
      saveDelay: Duration.zero,
      bindersFile: File('${root.path}${sep}app${sep}binders.json'),
      cacheDirectory: Directory('${root.path}${sep}cache'),
      folderCheckInterval: Duration.zero,
    );
    opened.add(nb);
    return nb;
  }

  Future<void> attach(Notebook nb, String name, List<int> bytes) async {
    final made = await const FileModule().createFromFile(IncomingFile(name, Uint8List.fromList(bytes)), nb.attachments!);
    final (data, size) = made!;
    const codec = FileCodec();
    nb.current!.insertBox(commitBox(createBox(codec, Bounds(10, 10, size.width, size.height)), codec, data));
    await nb.flush();
  }

  // A notebook with binder "Work" holding one page with one attachment.
  Future<({Notebook nb, BinderSection b, String page, Directory folder})> world() async {
    final folder = Directory('${root.path}${sep}Work')..createSync();
    final nb = make();
    await nb.load();
    final b = await nb.addBinder(folder.path);
    final page = await nb.createPage(binderPath: b.path);
    await nb.open(page);
    await attach(nb, 'a.txt', List<int>.generate(5000, (i) => i & 0xFF));
    await nb.flush();
    return (nb: nb, b: b, page: page, folder: folder);
  }

  Map<String, Uint8List> zipFiles(String path) {
    final r = ZipReader(File(path).readAsBytesSync(), ImportLimits.desktop);
    return {for (final n in r.names) n: r.read(n)!};
  }

  Map<String, Uint8List> diskFiles(Directory d) => {
    for (final f in d.listSync(recursive: true).whereType<File>())
      'Work/${f.path.substring(d.path.length + 1).replaceAll(r'\', '/')}': f.readAsBytesSync(),
  };

  String assetOf(String folder, String page) =>
      Directory('$folder$sep$page.assets').listSync().whereType<File>().single.path;

  BinderZipShare share(Notebook nb, BinderSection b, {Future<void> Function(int)? afterCapture,
      Future<void> Function(List<String>)? beforeOwnRead, ZipReadPause? pause}) =>
      BinderZipShare(nb, b.path, topName: 'Work', workDir: work, afterCapture: afterCapture, beforeOwnRead: beforeOwnRead, readPause: pause);

  test('only the binder set, binder-file copies included', () async {
    final w = await world();
    final f = w.folder.path;
    final asset = assetOf(f, w.page).split(RegExp(r'[\\/]')).last;
    void put(String rel, String text) => File('$f$sep$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    put('noted-binder (1).json', File('$f$sep$binderFileName').readAsStringSync());
    put('noted-binder.json.1732000000000-1.tmp', 'temp');
    put('noted-binder.json.12-ab-cd.cas-old', 'aside');
    put('${w.page}.assets${sep}x.tmp', 'an attachment named x.tmp');
    put('${w.page}.assets${sep}y.png.12-ab-cd.cas-verified', 'aside');
    put('${w.page}.assets$sep.y.png.noted-copy-1.tmp', 'staging');
    put('${w.page}.deleted-0123456789ab.assets${sep}old.png', 'set aside');
    put('templates${sep}t.notedtemplate', '{}');
    put('desktop.ini', 'x');
    put('.DS_Store', 'x');
    put('other${sep}p.canvas', 'x');
    put('notes.txt', 'x');
    final made = await share(w.nb, w.b).run();
    final names = zipFiles(made.path).keys.toSet();
    final page = w.page;
    expect(names, {
      'Work/$binderFileName',
      'Work/noted-binder (1).json',
      'Work/$page.canvas',
      'Work/$page.assets/$asset',
      'Work/$page.assets/x.tmp',
      'Work/templates/t.notedtemplate',
    });
    await made.remove();
    expect(work.listSync(), isEmpty, reason: 'the local temp zip is removed by identity');
  });

  test('the zip equals the binder files, byte for byte', () async {
    final w = await world();
    final made = await share(w.nb, w.b).run();
    final zipped = zipFiles(made.path);
    final disk = diskFiles(w.folder);
    expect(zipped.keys.toSet(), disk.keys.toSet());
    for (final k in disk.keys) {
      expect(zipped[k], disk[k], reason: k);
    }
    await made.remove();
  });

  group('refusals before anything is read', () {
    test('an Apple placeholder', () async {
      final w = await world();
      debugAppleMode = true;
      debugMarkDataless(assetOf(w.folder.path, w.page));
      final asked = <String>[];
      w.nb.askDownload = (p) async {
        asked.add(p);
        return null;
      };
      await expectLater(
        share(w.nb, w.b).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'm', "Some of this binder's files are still downloading. Save it again once they're here.")),
      );
      await pumpEventQueue();
      expect(asked, [assetOf(w.folder.path, w.page)]);
      expect(work.listSync(), isEmpty);
    });

    test('a Windows placeholder, and a placeholder state of unknown', () async {
      final w = await world();
      for (final state in [PlaceholderState.placeholder, PlaceholderState.unknown]) {
        final target = assetOf(w.folder.path, w.page);
        debugZipPlaceholderState = (p) => p == target ? state : PlaceholderState.notPlaceholder;
        await expectLater(
          share(w.nb, w.b).run(),
          throwsA(isA<BinderZipException>().having((e) => e.message, 'm', binderZipDownloadingMessage)),
        );
      }
      expect(binderZipDownloadingMessage, Platform.isMacOS ? contains('still downloading') : 'Make these files available on this device first.');
      expect(work.listSync(), isEmpty);
    });

    test('Z4: a failed listing of an assets folder, or of the binder folder, refuses', () async {
      final w = await world();
      for (final failing in ['${w.folder.path}$sep${w.page}.assets', w.folder.path]) {
        debugListDir = (d) {
          if (File(d).absolute.path == File(failing).absolute.path) throw FileSystemException('denied', d);
          return Directory(d).listSync(followLinks: false);
        };
        await expectLater(
          share(w.nb, w.b).run(),
          throwsA(isA<BinderZipException>().having((e) => e.message, 'm', binderZipDownloadingMessage)),
          reason: failing,
        );
      }
      // A folder outside the binder set that can't be listed is left alone.
      Directory('${w.folder.path}${sep}other').createSync();
      debugListDir = (d) {
        if (d.endsWith('${sep}other')) throw FileSystemException('denied', d);
        return Directory(d).listSync(followLinks: false);
      };
      final made = await share(w.nb, w.b).run();
      await made.remove();
      expect(work.listSync(), isEmpty);
    });
  });

  group('the check and its rounds', () {
    test('R-2: an assets folder removed between the page read and the check is re-captured', () async {
      final w = await world();
      final s = share(w.nb, w.b, afterCapture: (round) async {
        if (round == 1) Directory('${w.folder.path}$sep${w.page}.assets').deleteSync(recursive: true);
      });
      final made = await s.run();
      expect(s.roundsTaken, 2);
      final names = zipFiles(made.path).keys;
      expect(names.where((n) => n.contains('.assets/')), isEmpty, reason: 'the zip is the binder as it was at the check');
      expect(names, contains('Work/${w.page}.canvas'));
      await made.remove();
    });

    test('added, removed and changed files are read again', () async {
      final w = await world();
      final assets = '${w.folder.path}$sep${w.page}.assets';
      File('$assets${sep}gone.bin').writeAsStringSync('gone');
      File('$assets${sep}changes.bin').writeAsStringSync('before');
      final s = share(w.nb, w.b, afterCapture: (round) async {
        if (round != 1) return;
        File('$assets${sep}new.bin').writeAsStringSync('new');
        File('$assets${sep}gone.bin').deleteSync();
        File('$assets${sep}changes.bin').writeAsStringSync('after, longer');
      });
      final made = await s.run();
      expect(s.roundsTaken, 2);
      final z = zipFiles(made.path);
      expect(String.fromCharCodes(z['Work/${w.page}.assets/new.bin']!), 'new');
      expect(z.containsKey('Work/${w.page}.assets/gone.bin'), isFalse);
      expect(String.fromCharCodes(z['Work/${w.page}.assets/changes.bin']!), 'after, longer');
      expect(z.keys.toSet(), diskFiles(w.folder).keys.toSet());
      await made.remove();
      expect(work.listSync(), isEmpty, reason: 'the compacted-away zip went too');
    });

    test('three changing rounds refuse, and nothing is left', () async {
      final w = await world();
      final f = File('${w.folder.path}$sep${w.page}.assets${sep}busy.bin')..writeAsStringSync('0');
      await expectLater(
        share(w.nb, w.b, afterCapture: (round) async => f.writeAsStringSync('round $round')).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'm', 'This binder kept changing. Try again.')),
      );
      expect(work.listSync(), isEmpty);
    });

    test('the temp zip is removed against the identity recorded when it was written, never what is there then', () async {
      final w = await world();
      final f = File('${w.folder.path}$sep${w.page}.assets${sep}busy.bin')..writeAsStringSync('0');
      final zip = File('${work.path}${sep}binder.zip');
      await expectLater(
        share(w.nb, w.b, afterCapture: (round) async {
          f.writeAsStringSync('round $round');
          // Something else writes the share's temp after its last write.
          if (round == 3) zip.writeAsStringSync('not what the share wrote');
        }).run(),
        throwsA(isA<BinderZipException>()),
      );
      expect(zip.readAsStringSync(), 'not what the share wrote', reason: 'a file that changed is kept');
    });

    test('a share that fails on the file system says so, and leaves what it did not make', () async {
      final w = await world();
      final taken = File('${work.path}${sep}binder.zip')..writeAsStringSync('someone else');
      await expectLater(
        BinderZipShare(w.nb, w.b.path, topName: 'Work', zipName: 'Work.zip', workDir: work).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'm', "Couldn't save Work.zip. Nothing was saved.")),
      );
      expect(taken.readAsStringSync(), 'someone else');
    });
  });

  group('the archive limit counts the whole zip', () {
    test('a zip exactly at the limit is made; one byte under, it is refused', () async {
      final w = await world();
      final first = await share(w.nb, w.b).run();
      final size = first.identity.length;
      expect(File(first.path).lengthSync(), size);
      await first.remove();
      final at = await BinderZipShare(w.nb, w.b.path, topName: 'Work', workDir: work, archiveLimit: size).run();
      expect(at.identity.length, size);
      await at.remove();
      // One byte short: the entries fit, the central directory and end record don't.
      await expectLater(
        BinderZipShare(w.nb, w.b.path, topName: 'Work', workDir: work, archiveLimit: size - 1).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'm', binderZipTooLargeMessage)),
      );
      expect(work.listSync(), isEmpty);
    });

    test('a binder that changed near the limit is made when its compacted zip fits', () async {
      final w = await world();
      final busy = File('${w.folder.path}$sep${w.page}.assets${sep}busy.bin')..writeAsStringSync('a' * 4000);
      final first = await share(w.nb, w.b).run();
      final size = first.identity.length;
      await first.remove();
      final s = BinderZipShare(w.nb, w.b.path, topName: 'Work', workDir: work, archiveLimit: size, afterCapture: (round) async {
        // The same length again: the entry read again leaves dead bytes behind.
        if (round == 1) busy.writeAsStringSync('b' * 4000);
      });
      final made = await s.run();
      expect(s.roundsTaken, 2);
      expect(made.identity.length, size);
      expect(String.fromCharCodes(zipFiles(made.path)['Work/${w.page}.assets/busy.bin']!), 'b' * 4000);
      await made.remove();
    });

    test("the append check counts each entry's central record and the end record", () {
      final f = File('${root.path}${sep}a.bin')..writeAsBytesSync(List.filled(100, 7));
      final zip = '${root.path}${sep}z.zip';
      final whole = appendZipEntries(zip, 0, [ZipSource('T/a.bin', f.path, deflate: false)], fileLimit: 1 << 20, archiveLimit: 1 << 30);
      final needed = whole.end + zipCentralBytes('T/a.bin') + zipEndRecordBytes;
      expect(finishZip(zip, whole.end, [whole.added.single.record!]), needed);
      final fits = appendZipEntries(zip, 0, [ZipSource('T/a.bin', f.path, deflate: false)], fileLimit: 1 << 20, archiveLimit: needed);
      expect(fits.overArchive, isFalse);
      final over = appendZipEntries(zip, 0, [ZipSource('T/a.bin', f.path, deflate: false)], fileLimit: 1 << 20, archiveLimit: needed - 1);
      expect(over.overArchive, isTrue);
      final others = appendZipEntries(zip, 0, [ZipSource('T/a.bin', f.path, deflate: false)], fileLimit: 1 << 20, archiveLimit: needed, centralBytes: 1);
      expect(others.overArchive, isTrue, reason: 'the records of entries already in the zip count too');
    });
  });

  group('unsaved edits (R-1)', () {
    late TroubleWorld t;

    setUp(() async {
      t = TroubleWorld();
      await t.init();
    });

    tearDown(() => t.dispose());

    Future<({Notebook nb, BinderSection b, String page})> failing() async {
      final nb = t.make();
      await nb.load();
      final b = await nb.addBinder(t.other.path);
      final page = await nb.createPage(binderPath: b.path);
      await nb.open(page);
      await nb.flush();
      return (nb: nb, b: b, page: page);
    }

    test('a failed save refuses the share, and nothing is published', () async {
      final f = await failing();
      t.storeFor(t.other).failWith = accessDenied();
      f.nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await f.nb.flush();
      expect(f.nb.trouble.kind, isNot(TroubleKind.saved), reason: 'the save failed');
      final out = Directory('${t.root.path}${sep}out')..createSync();
      final target = '${out.path}${sep}Work.zip';
      binderZipSavePicker = (_) async => target;
      final said = await saveBinderZip(
        f.nb,
        f.b,
        roots: () => f.nb.exportRefusedFolders,
        writer: ExportWriter(askReplace: (_) async => true, askPutBack: (_, _) async => false),
      );
      expect(said, "Some edits in this binder aren't saved yet. Nothing was saved.");
      expect(out.listSync(), isEmpty, reason: 'nothing is published');
      t.storeFor(t.other).failWith = null;
    });

    test('a refused cover change (the binder file read-only) refuses the share, and nothing is published', () async {
      final f = await failing();
      final file = File('${t.other.path}$sep$binderFileName');
      if (Platform.isWindows) {
        Process.runSync('attrib', ['+r', file.path]);
      } else {
        Process.runSync('chmod', ['444', file.path]);
      }
      try {
        await f.nb.updateBinder(f.b.path, description: 'not written');
        await f.nb.flush();
        await settleNotebooks(notebooks: [f.nb]);
        expect(f.nb.coverPendingFor(f.b.path), isNotEmpty, reason: 'the change is kept as Not saved yet');
        final out = Directory('${t.root.path}${sep}out')..createSync();
        binderZipSavePicker = (_) async => '${out.path}${sep}Work.zip';
        final said = await saveBinderZip(
          f.nb,
          f.b,
          roots: () => f.nb.exportRefusedFolders,
          writer: ExportWriter(askReplace: (_) async => true, askPutBack: (_, _) async => false),
        );
        expect(said, binderZipUnsavedMessage);
        expect(out.listSync(), isEmpty, reason: 'nothing is published');
      } finally {
        if (Platform.isWindows) {
          Process.runSync('attrib', ['-r', file.path]);
        } else {
          Process.runSync('chmod', ['644', file.path]);
        }
        await f.nb.discardCoverChanges(f.b.path);
      }
    });

    test('a save that fails during the share refuses it at the final check', () async {
      final f = await failing();
      final dir = Directory('${t.root.path}${sep}ziptemp')..createSync();
      await expectLater(
        BinderZipShare(f.nb, f.b.path, topName: 'Work', workDir: dir, afterCapture: (round) async {
          t.storeFor(t.other).failWith = accessDenied();
          f.nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
          await f.nb.flush();
        }).run(),
        throwsA(isA<BinderZipException>().having((e) => e.message, 'm', binderZipUnsavedMessage)),
      );
      expect(dir.listSync(), isEmpty);
      t.storeFor(t.other).failWith = null;
    });
  });

  group('the folder lock', () {
    test('BL1, real file system: a save of page P during the capture of P lands, with no sharing error', () async {
      final w = await world();
      final reached = Completer<void>();
      final saved = Completer<void>();
      var editedTitle = '';
      reached.future.then((_) async {
        editedTitle = 'Saved during the share';
        await w.nb.rename(w.page, editedTitle);
        await w.nb.flush();
        saved.complete();
      });
      final s = share(w.nb, w.b, beforeOwnRead: (rel) async {
        if (rel.single == '${w.page}.canvas' && !reached.isCompleted) {
          reached.complete();
          // Give the save time to reach the folder lock, where it waits.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(saved.isCompleted, isFalse, reason: 'the save waits for the read job');
        }
      });
      final made = await s.run();
      await saved.future;
      expect(w.nb.trouble.kind, TroubleKind.saved);
      final onDisk = File('${w.folder.path}$sep${w.page}.canvas').readAsBytesSync();
      expect(readPage(String.fromCharCodes(onDisk)).meta.title, editedTitle);
      expect(s.roundsTaken, 2, reason: 'the stamp moved, so the page was read again');
      expect(zipFiles(made.path)['Work/${w.page}.canvas'], onDisk);
      await made.remove();
    });

    test('the lock jobs hold no download, flush, queued job or target I/O (asserted)', () async {
      final w = await world();
      await expectLater(
        w.nb.binderZipJob(w.b.path, () => w.nb.flush(), metadataOnly: true),
        throwsA(isA<AssertionError>()),
      );
      await expectLater(
        w.nb.binderZipJob(w.b.path, () => w.nb.binderZipJob(w.b.path, () async {}, metadataOnly: true), metadataOnly: false),
        throwsA(isA<AssertionError>()),
      );
      await expectLater(
        w.nb.binderZipJob(w.b.path, () => w.nb.addBinder('${root.path}${sep}x'), metadataOnly: true),
        throwsA(isA<AssertionError>()),
      );
      // A file evicted just before its read job: nothing is read or asked for
      // inside the job.
      debugAppleMode = true;
      final kinds = <String?>[];
      w.nb.askDownload = (p) async {
        kinds.add(Notebook.binderZipJobKind);
        return null;
      };
      final page = '${w.folder.path}$sep${w.page}.canvas';
      final jobs = <String?>[];
      await expectLater(
        share(w.nb, w.b, beforeOwnRead: (rel) async {
          jobs.add(Notebook.binderZipJobKind);
          if (rel.single == '${w.page}.canvas') debugMarkDataless(page);
        }).run(),
        throwsA(isA<BinderZipException>()),
      );
      await pumpEventQueue();
      expect(jobs, everyElement('read'));
      expect(kinds, isNotEmpty);
      expect(kinds, everyElement(isNull), reason: 'downloads are asked outside the lock');
    });
  });

  group('attachments held open (Windows)', () {
    Future<void> held(
      ({Notebook nb, BinderSection b, String page, Directory folder}) w,
      Future<void> Function() during,
    ) async {
      final asset = assetOf(w.folder.path, w.page);
      final name = 'Work/${w.page}.assets/${asset.split(RegExp(r'[\\/]')).last}';
      final gate = File('${root.path}${sep}gate')..writeAsStringSync('');
      final s = share(w.nb, w.b, pause: ZipReadPause(name, gate.path));
      final run = s.run().then<Object?>((m) => m, onError: (Object e) => e);
      final reached = File('${gate.path}.reached');
      for (var i = 0; i < 1000 && !reached.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(reached.existsSync(), isTrue, reason: 'the share holds the attachment open');
      try {
        await during();
      } finally {
        gate.deleteSync();
      }
      final r = await run;
      if (r is BinderZipMade) await r.remove();
    }

    test('a move that meets a held attachment answers busy for it and keeps its source (0139)', () async {
      final w = await world();
      final other = Directory('${root.path}${sep}Other')..createSync();
      final ob = await w.nb.addBinder(other.path);
      final asset = assetOf(w.folder.path, w.page);
      final bytes = File(asset).readAsBytesSync();
      Object? said;
      await held(w, () async {
        try {
          await w.nb.moveToLocation(w.page, binderPath: ob.path);
        } on NotebookException catch (e) {
          said = e;
        }
        expect(File(asset).readAsBytesSync(), bytes, reason: 'the held file stays where it was, unchanged');
      });
      expect('$said', contains('stayed in Work'), reason: 'the user is told what stayed');
      expect(File(asset).readAsBytesSync(), bytes);
    }, skip: !Platform.isWindows);

    test('Z3: a page delete during an attachment read keeps the attachment, and Undo brings the page back', () async {
      final w = await world();
      final asset = assetOf(w.folder.path, w.page);
      final bytes = File(asset).readAsBytesSync();
      final page = File('${w.folder.path}$sep${w.page}.canvas');
      final text = page.readAsBytesSync();
      DeletedPages? deleted;
      await held(w, () async {
        deleted = await w.nb.delete(w.page);
        expect(File(asset).readAsBytesSync(), bytes, reason: 'its set-aside failed, so it stays (0132, 0155)');
      });
      expect(File(asset).readAsBytesSync(), bytes);
      await w.nb.undoDelete(deleted!);
      await w.nb.flush();
      expect(page.readAsBytesSync(), text, reason: 'put back');
      expect(File(asset).readAsBytesSync(), bytes);
    }, skip: !Platform.isWindows);
  });

  group('the target', () {
    late ({Notebook nb, BinderSection b, String page, Directory folder}) w;
    late String target;
    late List<String> asked;
    var replace = true;

    setUp(() async {
      w = await world();
      Directory('${root.path}${sep}out').createSync();
      target = '${root.path}${sep}out${sep}Work.zip';
      asked = [];
      replace = true;
      binderZipSavePicker = (_) async => target;
    });

    ExportWriter writer() => ExportWriter(
      askReplace: (name) async {
        asked.add('replace $name');
        return replace;
      },
      askPutBack: (name, aside) async {
        asked.add('put back $name');
        return true;
      },
    );

    Future<String?> save() => saveBinderZip(w.nb, w.b, roots: () => w.nb.exportRefusedFolders, writer: writer());

    test('a target in a binder folder is refused', () async {
      target = '${w.folder.path}${sep}Work.zip';
      expect(await save(), exportTargetRefusedMessage);
      expect(File(target).existsSync(), isFalse);
    });

    test('a taken name is replaced after "Replace Work.zip?", or kept', () async {
      File(target).writeAsStringSync('mine');
      replace = false;
      expect(await save(), isNull);
      expect(File(target).readAsStringSync(), 'mine');
      replace = true;
      expect(await save(), startsWith('Saved Work.zip.'));
      expect(asked, ['replace Work.zip', 'replace Work.zip']);
      expect(zipFiles(target).keys, contains('Work/${w.page}.canvas'));
    });

    test('Put back is offered for an aside of the target', () async {
      File('$target.12-ab-cd.cas-old').writeAsStringSync('an older zip');
      await save();
      expect(asked.first, 'put back Work.zip');
    });

    test('a save writes every binder file into the zip at the chosen target', () async {
      expect(await save(), 'Saved Work.zip.');
      final zipped = zipFiles(target);
      expect(zipped.keys.toSet(), diskFiles(w.folder).keys.toSet());
    });
  });

  test('the limits', () {
    expect(BinderZipLimits.entries, 20000);
    expect(BinderZipLimits.archiveBytes, 1 << 30);
    expect(BinderZipLimits.totalBytes, 2 << 30);
    expect(BinderZipLimits.fileBytes, 256 << 20);
    expect(isNotedOwnFile(['p.canvas']), isTrue);
  });
}
