// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A file that is not downloaded (or only its `.<name>.icloud` stub) is present,
// never read and never absent: the attachment store shows it as still syncing.

import 'dart:ffi' show Abi;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/page_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted/src/attachment_copy.dart' show attachmentBeforeCreateHook;
import 'package:noted_core/src/storage/dataless.dart'
    show debugDatalessAbi, debugDatalessPaths, debugMarkDataless, debugResetDataless;

void main() {
  late Directory root;
  late Directory pages;
  late List<String> notices;
  late List<File> opened;
  late PageAttachments store;

  final good = Uint8List.fromList(List.generate(300, (i) => i % 251));
  final name = '${contentHash(good)}.bin';

  File asset(String n) => File('${pages.path}/p.assets/$n');

  setUp(() {
    root = Directory.systemTemp.createTempSync('noted_dataless');
    pages = Directory('${root.path}/pages')..createSync();
    Directory('${pages.path}/p.assets').createSync();
    notices = [];
    opened = [];
    store = PageAttachments(
      pageFolder: pages,
      pageId: 'p',
      storage: () => AttachmentStorage.folder,
      cacheDirectory: Directory('${root.path}/cache'),
      onNotice: notices.add,
      opener: (f) async => opened.add(f),
      watch: false,
    );
    addTearDown(() {
      debugDatalessAbi = null;
      debugResetDataless();
      store.dispose();
      root.deleteSync(recursive: true);
    });
  });

  test('a stub-only attachment exists, is still syncing, is not read and not restored', () async {
    File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
    expect(store.exists(name), isTrue);
    expect((await store.verify(name, size: good.length)).state, AttachmentState.syncing);
    expect((await store.readVerified(name, size: good.length)).state, AttachmentState.syncing);
    expect(await store.read(name), isNull);
    // Nothing was created, moved or set aside.
    expect(Directory('${pages.path}/p.assets').listSync().length, 1);
  });

  test('the stub is never itself an attachment', () async {
    File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
    expect(store.exists('.$name.icloud'), isFalse);
    expect((await store.verify('.$name.icloud', size: 1)).state, AttachmentState.syncing);
    expect(await store.read('.$name.icloud'), isNull);
  });

  test('opening a stub-only attachment opens nothing and says to try again', () async {
    File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
    await store.open('f.bin', fileName: name);
    expect(opened, isEmpty);
    expect(notices.single, contains('right now'));
  });

  test('a dataless attachment is not read; the file stays as it was', () async {
    asset(name).writeAsBytesSync(good);
    expect(store.exists(name), isTrue);
    debugDatalessAbi = Abi.macosX64; // no lstat$INODE64 off Apple: every existing file fails closed
    debugResetDataless();
    expect((await store.readVerified(name, size: good.length)).state, AttachmentState.syncing);
    expect(await store.read(name), isNull);
    await store.open('f.bin', fileName: name);
    expect(opened, isEmpty);
    debugDatalessAbi = null;
    expect(asset(name).readAsBytesSync(), good);
  }, skip: (Platform.isMacOS || Platform.isIOS) ? 'a real lstat exists: nothing fails closed' : null);

  test('a good attachment is still verified and read', () async {
    asset(name).writeAsBytesSync(good);
    expect((await store.readVerified(name, size: good.length)).state, AttachmentState.ok);
    expect(await store.read(name), good);
  });

  // --- t2a: the store asks for what is not downloaded --------------------------

  group('asking for the download (t2a)', () {
    late List<String> asked;
    late DateTime clock;
    late String? answer;
    late PageAttachments asking;
    late Directory recovery;

    Future<String?> ask(String path) async {
      asked.add(path);
      return answer;
    }

    PageAttachments makeAsking() => PageAttachments(
      pageFolder: pages,
      pageId: 'p',
      storage: () => AttachmentStorage.folder,
      cacheDirectory: Directory('${root.path}/cache'),
      recoveryDirectory: recovery,
      onNotice: notices.add,
      opener: (f) async => opened.add(f),
      watch: false,
      requestDownload: ask,
      clock: () => clock,
    );

    setUp(() {
      asked = [];
      answer = null;
      clock = DateTime(2026, 11, 26, 12);
      recovery = Directory('${root.path}/recovery')..createSync();
      asking = makeAsking();
      addTearDown(() {
        debugDatalessPaths = null;
        try {
          asking.dispose();
        } on Object {
          // A test that closed the page itself.
        }
      });
    });

    String folderPath(String n) => '${asking.folder.path}${Platform.pathSeparator}$n';
    final other = '${contentHash(Uint8List.fromList([9, 9, 9]))}.bin';
    List<String> listing() => [
      for (final d in [Directory('${pages.path}/p.assets'), Directory('${recovery.path}/p.assets')])
        if (d.existsSync()) ...(d.listSync().map((e) => e.path).toList()..sort()),
    ];

    test('at construction it asks for a stub and for a dataless file, by name only', () async {
      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      asset(other).writeAsBytesSync([9, 9, 9]);
      debugMarkDataless(folderPath(other));
      final reads = <String>[];
      storedReadObserver = reads.add;
      addTearDown(() => storedReadObserver = null);
      asking.dispose();
      asking = makeAsking();
      await asking.scanIdle;
      expect(asked, unorderedEquals([folderPath(name), folderPath(other)]));
      expect(reads, isEmpty, reason: 'the scan reads nothing');
      expect(asking.download(name), AttachmentDownload.downloading);
      expect(asking.download(other), AttachmentDownload.downloading);
    });

    test('it asks again on a change after 30 s, never before, and at once on Retry', () async {
      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      asking.dispose();
      asking = makeAsking();
      await asking.scanIdle;
      expect(asked, hasLength(1));
      clock = clock.add(const Duration(seconds: 29));
      asking.filesChanged();
      await asking.scanIdle;
      expect(asked, hasLength(1), reason: 'not within 30 s');
      asking.retryDownload(name);
      await Future<void>.delayed(Duration.zero);
      expect(asked, hasLength(2), reason: 'Retry asks at once');
      clock = clock.add(const Duration(seconds: 31));
      asking.rescan();
      await asking.scanIdle;
      expect(asked, hasLength(3), reason: 'after 30 s');
    });

    test('a refusal is failed with its message; Retry goes back to downloading', () async {
      answer = 'the cloud says no';
      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      asking.dispose();
      asking = makeAsking();
      await asking.scanIdle;
      await Future<void>.delayed(Duration.zero);
      expect(asking.download(name), AttachmentDownload.failed);
      expect(asking.downloadError(name), 'the cloud says no');
      answer = null;
      asking.retryDownload(name);
      expect(asking.download(name), AttachmentDownload.downloading);
      await Future<void>.delayed(Duration.zero);
      expect(asking.download(name), AttachmentDownload.downloading);
      expect(asking.downloadError(name), isNull);
    });

    test('a file that arrives is onDevice, and a name that vanished is dropped', () async {
      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      asking.dispose();
      asking = makeAsking();
      await asking.scanIdle;
      expect(asking.download(name), AttachmentDownload.downloading);
      File('${pages.path}/p.assets/.$name.icloud').deleteSync();
      asset(name).writeAsBytesSync(good);
      asking.filesChanged();
      await asking.scanIdle;
      expect(asking.download(name), AttachmentDownload.onDevice);
      // Gone altogether: dropped.
      File('${pages.path}/p.assets/.$other.icloud').writeAsStringSync('');
      asking.filesChanged();
      await asking.scanIdle;
      expect(asking.download(other), AttachmentDownload.downloading);
      File('${pages.path}/p.assets/.$other.icloud').deleteSync();
      asking.filesChanged();
      await asking.scanIdle;
      expect(asking.download(other), AttachmentDownload.onDevice);
    });

    test('download() of a name the scan saw makes no call and never notifies synchronously', () async {
      asset(name).writeAsBytesSync(good);
      File('${pages.path}/p.assets/.$other.icloud').writeAsStringSync('');
      asking.dispose();
      asking = makeAsking();
      await asking.scanIdle;
      final before = asked.length;
      var notified = 0;
      asking.addListener(() => notified++);
      final hit = <String>[];
      storedReadObserver = hit.add;
      addTearDown(() => storedReadObserver = null);
      expect(asking.download(name), AttachmentDownload.onDevice);
      expect(asking.download(other), AttachmentDownload.downloading);
      expect(notified, 0);
      await Future<void>.delayed(Duration.zero);
      expect(asked.length, before);
      expect(hit, isEmpty);
    });

    test('a name the scan has not seen is checked once, and asked for in a microtask', () async {
      await asking.scanIdle;
      asset(name).writeAsBytesSync(good); // arrived after the scan
      debugMarkDataless(folderPath(name));
      var notified = 0;
      asking.addListener(() => notified++);
      expect(asking.download(name), AttachmentDownload.downloading);
      expect(notified, 0, reason: 'not synchronously');
      expect(asked, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(asked, [folderPath(name)]);
      expect(notified, greaterThan(0));
    });

    test('nothing is asked or notified after dispose', () async {
      asking.dispose();
      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      asking.rescan();
      expect(asking.download(name), AttachmentDownload.onDevice);
      await Future<void>.delayed(Duration.zero);
      expect(asked, isEmpty);
      // An ask that completes after dispose changes nothing.
      final late = Completer<String?>();
      final s2 = PageAttachments(
        pageFolder: pages,
        pageId: 'p',
        storage: () => AttachmentStorage.folder,
        cacheDirectory: Directory('${root.path}/cache'),
        watch: false,
        requestDownload: (p) => late.future,
      );
      await s2.scanIdle;
      var notified = 0;
      s2.addListener(() => notified++);
      s2.dispose();
      late.complete('refused');
      await Future<void>.delayed(Duration.zero);
      expect(notified, 0);
    });

    test('stub names that are not an attachment, or are . or .., are ignored', () async {
      for (final n in ['...icloud', '....icloud', '.notes.txt.icloud']) {
        File('${pages.path}/p.assets/$n').writeAsStringSync('');
      }
      // An attachment-shaped name is asked for.
      File('${pages.path}/p.assets/.$name.kept-1.icloud').writeAsStringSync('');
      asking.dispose();
      asking = makeAsking();
      await asking.scanIdle;
      expect(asked, [folderPath('$name.kept-1')]);
    });

    test('a closed page asks for nothing', () async {
      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      asking.dispose();
      asked.clear();
      asking.rescan();
      await Future<void>.delayed(Duration.zero);
      expect(asked, isEmpty);
    });

    test('put and putInPageFolder over a dataless or stub-only target throw StorageBusy and change nothing', () async {
      Future<void> check(String why) async {
        for (final inPage in [false, true]) {
          final before = listing();
          await expectLater(
            inPage ? asking.putInPageFolder(good, extension: 'bin') : asking.put(good, extension: 'bin'),
            throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.dataless)),
            reason: '$why ${inPage ? 'putInPageFolder' : 'put'}',
          );
          expect(listing(), before, reason: why);
        }
        expect(Directory('${recovery.path}/p.assets').existsSync(), isFalse, reason: 'nothing went to recovery');
      }

      File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
      await check('stub only');
      File('${pages.path}/p.assets/.$name.icloud').deleteSync();
      asset(name).writeAsBytesSync(good);
      debugMarkDataless(folderPath(name));
      await check('dataless');
      expect(asked, contains(folderPath(name)));
    });

    test('B3: a stub, or a dataless file, that arrives before the publish is StorageBusy, with no copy kept', () async {
      addTearDown(() => attachmentBeforeCreateHook = null);
      final target = folderPath(name);
      for (final present in [false, true]) {
        attachmentBeforeCreateHook = (path) {
          if (path != target) return;
          attachmentBeforeCreateHook = null;
          if (present) {
            File(target).writeAsBytesSync(good);
            debugMarkDataless(target);
          } else {
            File('${pages.path}/p.assets/.$name.icloud').writeAsStringSync('');
          }
        };
        await expectLater(
          asking.put(good, extension: 'bin'),
          throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.dataless)),
          reason: present ? 'dataless arrival' : 'stub arrival',
        );
        final names = Directory('${pages.path}/p.assets').listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last);
        expect(names.where((n) => n.contains('.kept-')), isEmpty);
        expect(Directory('${recovery.path}/p.assets').existsSync(), isFalse);
        debugDatalessPaths = null;
        for (final e in Directory('${pages.path}/p.assets').listSync()) {
          e.deleteSync();
        }
      }
    });

    test('a dataless .kept- copy is asked for, and keepGoodCopy writes no second one', () async {
      // The target is shorter than the file: syncing, so a good copy is kept beside it.
      asset(name).writeAsBytesSync(good.sublist(0, 10));
      final kept = '$name.kept-1';
      asset(kept).writeAsBytesSync(good);
      debugMarkDataless(folderPath(kept));
      await expectLater(
        asking.put(good, extension: 'bin'),
        throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.dataless)),
      );
      expect(
        Directory('${pages.path}/p.assets').listSync().map((e) => e.path.split(RegExp(r'[\\/]')).last).toList()..sort(),
        ([name, kept]..sort()),
        reason: 'no second kept copy',
      );
      expect(asked, contains(folderPath(kept)));
    });

    test('read and open record a dataless file and ask for it; open says it is downloading', () async {
      asset(name).writeAsBytesSync(good);
      debugMarkDataless(folderPath(name));
      expect(await asking.read(name), isNull);
      expect(asked, [folderPath(name)]);
      await asking.open('f.bin', fileName: name);
      expect(opened, isEmpty);
      expect(notices.single, "This file is still downloading. Open it again once it's here.");
    });

    test('a verified read of a dataless file is syncing, and a good file still reads', () async {
      asset(name).writeAsBytesSync(good);
      expect((await asking.readVerified(name, size: good.length)).state, AttachmentState.ok);
      debugMarkDataless(folderPath(name));
      expect((await asking.readVerified(name, size: good.length)).state, AttachmentState.syncing);
      expect(asking.download(name), AttachmentDownload.downloading);
    });
  });
}
