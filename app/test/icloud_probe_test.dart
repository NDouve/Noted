// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The self-test of cloud parity R5.9: its order, the first load waiting for
// it, the probe record and its leftovers, and `_untestedRoots` gating writes.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/fake_cloud_folder_channel.dart';

void main() {
  late Directory root;
  late File access;
  late Directory drive;
  late FakeCloudFolderChannel channel;
  late List<IcloudFolders> folders;
  late List<Notebook> notebooks;
  late DateTime clock;

  IcloudFolders make({
    Duration timeout = const Duration(seconds: 5),
    Future<bool> Function(File, String)? publish,
  }) {
    final f = IcloudFolders(
      channel: channel,
      file: access,
      platform: CloudPlatform.macos,
      coordinationTimeout: timeout,
      now: () => clock,
      publishProbe: publish ?? (t, p) => publishExclusive(t, p),
    );
    folders.add(f);
    return f;
  }

  // An entry for [drive] on record, as an earlier pick leaves it.
  void recordEntry({Map<String, Object?>? probe}) {
    access.parent.createSync(recursive: true);
    final real = drive.resolveSymbolicLinksSync();
    access.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'folders': [
          {'path': real, 'bookmark': channel.bookmarkFor(real), 'probe': ?probe},
        ],
      }),
    );
    channel.ubiquitous.add(real);
  }

  Map<String, Object?> record() => (jsonDecode(access.readAsStringSync()) as Map)['folders'][0] as Map<String, Object?>;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_probe');
    access = File('${root.path}/state/folder-access.json');
    drive = Directory('${root.path}/Drive')..createSync();
    channel = FakeCloudFolderChannel();
    folders = [];
    notebooks = [];
    clock = DateTime(2026, 11, 23, 12);
  });
  tearDown(() async {
    for (final n in notebooks) {
      await n.flush();
      n.dispose();
    }
    for (final f in folders) {
      f.dispose();
    }
    for (var i = 0; i < 20 && root.existsSync(); i++) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('the order: reset, resolve, isUbiquitous, then the coordinated probe; the root is writable after a pass', () async {
    recordEntry();
    final writable = <bool>[];
    final f = make()..onRootWritable = (_, w) => writable.add(w);
    await f.start();
    final m = channel.methods;
    expect(m.take(3), ['reset', 'resolve', 'isUbiquitous']);
    expect(m.indexOf('coordinate'), greaterThan(2));
    expect(m.last, 'done');
    expect(writable, [false, false, true], reason: 'registered, checking, passed');
    expect(f.checkOf(drive.path), CloudRootCheck.passed);
    expect(drive.listSync(), isEmpty);
    expect(record().containsKey('probe'), isFalse);
  });

  test('the probe is recorded before it is published, and removed by its nonce', () async {
    recordEntry();
    Map<String, Object?>? seen;
    final f = make(
      publish: (t, p) async {
        seen = Map.of(record()['probe']! as Map<String, Object?>);
        return publishExclusive(t, p);
      },
    );
    await f.start();
    expect(seen, isNotNull);
    expect(RegExp(r'^\.noted-probe-[0-9a-f]{16}\.tmp$').hasMatch(seen!['name']! as String), isTrue);
    expect(base64Decode(seen!['nonce']! as String), hasLength(32));
    expect(channel.callsOf('coordinate').length, greaterThanOrEqualTo(2), reason: 'the publish and the delete');
  });

  test('a vanished probe still passes and its record goes', () async {
    recordEntry();
    final f = make(
      publish: (t, p) async {
        final ok = await publishExclusive(t, p);
        File(p).deleteSync(); // another device took it
        return ok;
      },
    );
    await f.start();
    expect(f.checkOf(drive.path), CloudRootCheck.passed);
    expect(record().containsKey('probe'), isFalse);
  });

  test('a leftover probe holding its nonce is deleted at the next launch; any other file is left', () async {
    final nonce = Uint8List.fromList(List.generate(32, (i) => i));
    final mine = File('${drive.path}/.noted-probe-aaaaaaaaaaaaaaaa.tmp')..writeAsBytesSync(nonce);
    recordEntry(probe: {'name': '.noted-probe-aaaaaaaaaaaaaaaa.tmp', 'nonce': base64Encode(nonce)});
    final once = make();
    await once.start();
    once.dispose();
    folders.remove(once);
    expect(mine.existsSync(), isFalse);

    final other = File('${drive.path}/.noted-probe-bbbbbbbbbbbbbbbb.tmp')..writeAsStringSync('someone else\'s');
    recordEntry(probe: {'name': '.noted-probe-bbbbbbbbbbbbbbbb.tmp', 'nonce': base64Encode(nonce)});
    final twice = make();
    await twice.start();
    twice.dispose();
    folders.remove(twice);
    expect(other.existsSync(), isTrue, reason: 'it doesn\'t hold the nonce');
    expect(drive.listSync().length, 1);
  });

  test('a failed publish puts the root among the read-only ones with the design\'s words; the registration stays', () async {
    recordEntry();
    final f = make(publish: (t, p) async => throw const FileSystemException('no hard links'));
    final writable = <bool>[];
    f.onRootWritable = (_, w) => writable.add(w);
    await f.start();
    expect(f.checkOf(drive.path), CloudRootCheck.unsafe);
    expect(f.statusOf(drive.path), "This iCloud folder can't be written safely on this device.");
    expect(writable.last, isFalse);
    expect(underCoordination([drive.path]), isTrue, reason: 'no write there is ever uncoordinated');
    expect(drive.listSync(), isEmpty, reason: 'the probe source is removed');
  });

  test('a timeout is not a failure: busy, with its words, retried at most once a minute', () async {
    recordEntry();
    channel.mode = CoordinateMode.silent;
    final f = make(timeout: const Duration(milliseconds: 100));
    await f.start();
    expect(f.checkOf(drive.path), CloudRootCheck.busy);
    expect(f.statusOf(drive.path), 'iCloud is busy; Noted will try again');
    final tried = channel.callsOf('coordinate').length;
    channel.mode = CoordinateMode.go;
    await f.retryBusy();
    expect(channel.callsOf('coordinate').length, tried, reason: 'not again within a minute');
    clock = clock.add(const Duration(minutes: 1, seconds: 1));
    await f.retryBusy();
    expect(f.checkOf(drive.path), CloudRootCheck.passed);
    expect(channel.held, isEmpty);
  });

  group('the notebook', () {
    late Directory pages;
    late File binders;

    Notebook open(IcloudFolders f) {
      final nb = buildAppNotebook(
        pagesDirectory: pages,
        bindersFile: binders,
        icloud: f,
      );
      notebooks.add(nb);
      return nb;
    }

    setUp(() {
      pages = Directory('${root.path}/pages')..createSync();
      binders = File('${root.path}/app/binders.json');
    });

    test('the first load waits for the self-test, showing "Checking the iCloud folder…"', () async {
      recordEntry();
      channel.mode = CoordinateMode.silent;
      final f = make();
      final nb = open(f);
      final load = nb.loadChecked();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(nb.firstLoadSucceeded, isFalse, reason: 'waiting for the probe');
      expect(nb.checkingICloud, isTrue);
      final id = channel.callsOf('coordinate').first.args['id']! as int;
      channel.mode = CoordinateMode.go;
      await channel.answer(id, 'go');
      await load;
      expect(nb.firstLoadSucceeded, isTrue);
      expect(nb.checkingICloud, isFalse);
    });

    test('while untested (busy) the root\'s binder is read-only and nothing is swept there', () async {
      final bdir = Directory('${drive.path}/Work')..createSync();
      File('${bdir.path}/.x.cas-old').writeAsStringSync('left over');
      binders.parent.createSync(recursive: true);
      recordEntry();
      // A binder listed in binders.json inside the root.
      final seed = Notebook(PageStore(pages), buildModules(), bindersFile: binders);
      await seed.load();
      final section = await seed.addBinder(bdir.path);
      await seed.flush();
      seed.dispose();
      expect(section.available, isTrue);

      channel.mode = CoordinateMode.silent;
      final f = make(timeout: const Duration(milliseconds: 100));
      final nb = open(f);
      await nb.loadChecked();
      expect(f.checkOf(drive.path), CloudRootCheck.busy);
      final b = nb.binders.single;
      expect(b.available, isTrue, reason: 'listed and readable');
      await expectLater(nb.createPage(binderPath: b.path), throwsA(isA<NotebookException>()));
      expect(File('${bdir.path}/.x.cas-old').existsSync(), isTrue, reason: 'no sweep ran');
      expect(nb.cloudStatusOf(bdir.path), 'iCloud is busy; Noted will try again');

      // The retry passes: writable again.
      channel.mode = CoordinateMode.go;
      clock = clock.add(const Duration(minutes: 2));
      await f.retryBusy();
      final id = await nb.createPage(binderPath: b.path);
      expect(bdir.listSync().any((e) => e.path.endsWith('$id.canvas')), isTrue);
    });

    // R5.9: a root that isn't tested (failed or timed out) is written by
    // nothing: not a swept leftover, not a created binder, not a saved copy.
    for (final busy in [false, true]) {
      final text = busy ? 'iCloud is busy; Noted will try again' : "This iCloud folder can't be written safely on this device.";
      test('an untested root (${busy ? 'busy' : 'unsafe'}) is refused with its text at every write path, and nothing is written', () async {
        final bdir = Directory('${drive.path}/Work')..createSync();
        final leftover = File('${bdir.path}/.x.cas-old')..writeAsStringSync('left over');
        binders.parent.createSync(recursive: true);
        recordEntry();
        final seed = Notebook(PageStore(pages), buildModules(), bindersFile: binders);
        await seed.load();
        await seed.addBinder(bdir.path);
        await seed.flush();
        seed.dispose();
        final plain = Directory('${drive.path}/Plain')..createSync();
        final before = {for (final e in drive.listSync(recursive: true)) e.path};

        // The platform answers `go` at once (pass-through) unless the root is busy.
        if (busy) channel.mode = CoordinateMode.silent;
        final f = make(
          timeout: const Duration(milliseconds: 100),
          publish: busy ? null : (t, p) async => throw const FileSystemException('no hard links'),
        );
        final settings = AppSettings(File('${root.path}/app/settings.json'))..defaultBinderFolder = drive.path;
        final nb = Notebook(
          PageStore(pages),
          buildModules(),
          bindersFile: binders,
          settings: settings,
          icloud: f,
          pickFolder: () async => drive.path,
        );
        notebooks.add(nb);
        await nb.loadChecked();
        expect(f.checkOf(drive.path), busy ? CloudRootCheck.busy : CloudRootCheck.unsafe);
        expect(leftover.existsSync(), isTrue, reason: 'the sweep did not run, although the platform would have said go');
        // The platform would answer now: only the gating stands in the way.
        channel.mode = CoordinateMode.go;

        await expectLater(nb.createBinder(), throwsA(isA<NotebookException>().having((e) => e.message, 'message', text)));
        await expectLater(nb.addBinder(plain.path), throwsA(isA<NotebookException>().having((e) => e.message, 'message', text)));
        await expectLater(nb.saveCopyElsewhere(), throwsA(isA<NotebookException>().having((e) => e.message, 'message', text)));
        await expectLater(nb.createPage(binderPath: bdir.path), throwsA(isA<NotebookException>()));
        // The probe's own source (recorded, removed by its nonce at the retry) is the one allowed file.
        final after = {for (final e in drive.listSync(recursive: true)) if (!e.path.contains('.noted-probe-')) e.path};
        expect(after, before, reason: 'nothing was written in the root');
      });
    }

    test('a failed probe leaves the root read-only for the session', () async {
      recordEntry();
      final f = make(publish: (t, p) async => throw const FileSystemException('no'));
      final nb = open(f);
      await nb.loadChecked();
      expect(f.checkOf(drive.path), CloudRootCheck.unsafe);
      await expectLater(nb.createPage(folderPath: drive.path), throwsA(isA<NotebookException>()));
    });
  });
}
