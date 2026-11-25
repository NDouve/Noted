// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The folder access of cloud parity R5.3: pick, bookmark, resolve before the
// load, `folder-access.json` and its unreadable-copy rule, and pruning (Codex
// design review 2026-11-16 R-2), against the fake channel.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/fake_cloud_folder_channel.dart';
import 'support/notebook_folder.dart';

void main() {
  late Directory root;
  late File access;
  late FakeCloudFolderChannel channel;
  late List<IcloudFolders> folders;
  late List<Notebook> notebooks;

  Directory dir(String name) => Directory('${root.path}/$name')..createSync(recursive: true);
  String real(Directory d) => d.resolveSymbolicLinksSync();

  IcloudFolders make({CloudPlatform platform = CloudPlatform.macos}) {
    final f = IcloudFolders(
      channel: channel,
      file: access,
      platform: platform,
      coordinationTimeout: const Duration(seconds: 5),
    );
    folders.add(f);
    return f;
  }

  List<Map<String, Object?>> entries() {
    if (!access.existsSync()) return [];
    final j = jsonDecode(access.readAsStringSync()) as Map;
    return [for (final e in j['folders'] as List) (e as Map).cast<String, Object?>()];
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_icloud');
    access = File('${root.path}/state/folder-access.json');
    channel = FakeCloudFolderChannel();
    folders = [];
    notebooks = [];
  });
  tearDown(() async {
    for (final n in notebooks) {
      await n.flush();
      n.dispose();
    }
    for (final f in folders) {
      f.dispose();
    }
    await deleteTestFolder(root);
  });

  group('pick', () {
    test('iOS: the picked folder gets an entry, is registered and tested, and its real path is returned', () async {
      final f = make(platform: CloudPlatform.ios);
      final d = dir('Drive');
      channel.picked = d.path;
      channel.ubiquitous.add(real(d));
      final p = await f.pick();
      expect(p, real(d));
      expect(entries().single['path'], real(d));
      expect(entries().single['bookmark'], isNotEmpty);
      expect(entries().single.containsKey('probe'), isFalse, reason: 'the probe record goes after a pass');
      expect(f.checkOf(real(d)), CloudRootCheck.passed);
      expect(channel.methods.where((m) => m == 'isUbiquitous'), isNotEmpty);
      expect(channel.callsOf('coordinate'), isNotEmpty, reason: 'the probe is coordinated');
      expect(d.listSync(), isEmpty, reason: 'no probe file is left');
    });

    test('iOS: a folder outside iCloud Drive is refused with the design\'s words', () async {
      final f = make(platform: CloudPlatform.ios);
      channel.pickRefused = true;
      await expectLater(
        f.pick(),
        throwsA(isA<CloudPickRefused>().having((e) => e.message, 'message', 'Choose a folder in iCloud Drive')),
      );
      expect(entries(), isEmpty);
    });

    test('iOS: a cancelled pick returns null', () async {
      final f = make(platform: CloudPlatform.ios);
      expect(await f.pick(), isNull);
    });

    test('macOS: the usual picker, then a bookmark; a folder outside iCloud is not registered or probed', () async {
      final f = make();
      final d = dir('Plain');
      final p = await f.pick(pickDirectory: () async => d.path);
      expect(p, real(d));
      expect(entries().single['path'], real(d));
      expect(channel.callsOf('bookmark'), hasLength(1));
      expect(channel.callsOf('coordinate'), isEmpty);
      expect(f.checkOf(real(d)), isNull);
    });

    test('macOS: a bookmark that can\'t be made still returns the folder, with no entry', () async {
      final f = make();
      final d = dir('Plain');
      channel.bookmarkFails = true;
      expect(await f.pick(pickDirectory: () async => d.path), real(d));
      expect(entries(), isEmpty);
    });

    test('macOS: an iCloud folder whose bookmark fails is still coordinated and read-only; no entry is kept', () async {
      final f = make();
      final d = dir('Drive');
      channel.ubiquitous.add(real(d));
      channel.bookmarkFails = true;
      final writable = <bool>[];
      f.onRootWritable = (_, w) => writable.add(w);
      expect(await f.pick(pickDirectory: () async => d.path), real(d));
      expect(entries(), isEmpty);
      expect(underCoordination([d.path]), isTrue, reason: 'never uncoordinated');
      expect(writable, everyElement(isFalse), reason: 'read-only without a record');
      expect(f.checkOf(d.path), isNull, reason: 'no entry holds it');
      expect(f.statusOf(d.path), 'Choose the folder again');
    });

    test('a pick that fails for another reason says so in short', () async {
      final f = make(platform: CloudPlatform.ios);
      channel.pickErrorCode = 'picker';
      await expectLater(
        f.pick(),
        throwsA(isA<CloudPickRefused>().having((e) => e.message, 'message', contains('it broke'))),
      );
    });

    test('picking a folder again keeps the probe on record, so its leftover is still removed by nonce', () async {
      final d = dir('Drive');
      channel.ubiquitous.add(real(d));
      final f1 = make(platform: CloudPlatform.ios);
      channel.picked = d.path;
      await f1.pick();
      final nonce = base64Encode(List.generate(32, (i) => i + 1));
      final left = File('${d.path}/.noted-probe-cccccccccccccccc.tmp')..writeAsBytesSync(base64Decode(nonce));
      final j = jsonDecode(access.readAsStringSync()) as Map;
      (j['folders'] as List).first['probe'] = {'name': '.noted-probe-cccccccccccccccc.tmp', 'nonce': nonce};
      access.writeAsStringSync(jsonEncode(j));
      f1.dispose();
      folders.remove(f1);
      final f2 = make(platform: CloudPlatform.ios);
      await f2.start();
      // A probe was on record and is gone with its file after the launch.
      expect(left.existsSync(), isFalse);
      // Now it is picked once more with another leftover on record.
      final left2 = File('${d.path}/.noted-probe-dddddddddddddddd.tmp')..writeAsBytesSync(base64Decode(nonce));
      final j2 = jsonDecode(access.readAsStringSync()) as Map;
      (j2['folders'] as List).first['probe'] = {'name': '.noted-probe-dddddddddddddddd.tmp', 'nonce': nonce};
      access.writeAsStringSync(jsonEncode(j2));
      await f2.pick();
      expect(left2.existsSync(), isFalse, reason: 'the replaced entry carried the record over');
    });

    test('other platforms: the usual picker only, nothing on record', () async {
      final f = make(platform: CloudPlatform.other);
      final d = dir('Plain');
      expect(await f.pick(pickDirectory: () async => d.path), d.path);
      expect(channel.calls, isEmpty);
      expect(access.existsSync(), isFalse);
    });
  });

  group('resolve at launch', () {
    test('a bookmark resolves and its folder is live; isUbiquitous is read, never stored', () async {
      final d = dir('Drive');
      channel.ubiquitous.add(real(d));
      final first = make();
      await first.pick(pickDirectory: () async => d.path);
      first.dispose();
      folders.remove(first);
      channel.calls.clear();
      final second = make();
      await second.start();
      expect(second.accessOf(real(d)), CloudAccess.live);
      expect(channel.methods.indexOf('reset'), lessThan(channel.methods.indexOf('resolve')));
      expect(channel.methods.indexOf('resolve'), lessThan(channel.methods.indexOf('isUbiquitous')));
      expect(entries().single.keys, unorderedEquals(['path', 'bookmark']), reason: 'no iCloud flag is stored');
    });

    test('a stale bookmark is renewed when it resolves to the same path', () async {
      final d = dir('Drive');
      final f1 = make();
      await f1.pick(pickDirectory: () async => d.path);
      final old = entries().single['bookmark'];
      f1.dispose();
      folders.remove(f1);
      channel.stale.add(old! as String);
      final f2 = make();
      await f2.start();
      expect(entries().single['bookmark'], isNot(old));
      expect(f2.accessOf(real(d)), CloudAccess.live);
    });

    test('a bookmark that resolves to another path is "On another device", and that access is stopped', () async {
      final d = dir('Drive');
      final other = dir('Other');
      final f1 = make();
      await f1.pick(pickDirectory: () async => d.path);
      final bm = entries().single['bookmark']! as String;
      f1.dispose();
      folders.remove(f1);
      channel.movedTo[bm] = real(other);
      channel.stale.add(bm);
      final f2 = make();
      await f2.start();
      expect(f2.accessOf(real(d)), CloudAccess.anotherDevice);
      expect(f2.statusOf(d.path), 'On another device');
      expect(f2.accessLost(d.path), isTrue);
      expect(channel.callsOf('stopAccess').single.args['path'], real(other));
      expect(entries().single['bookmark'], bm, reason: 'a stale renewal only to the same path');
    });

    test('a bookmark that fails to resolve is "On another device"', () async {
      final d = dir('Drive');
      final f1 = make();
      await f1.pick(pickDirectory: () async => d.path);
      channel.failing.add(entries().single['bookmark']! as String);
      f1.dispose();
      folders.remove(f1);
      final f2 = make();
      await f2.start();
      expect(f2.statusOf(d.path), 'On another device');
    });

    test('a bookmark whose access could not be started is "On another device"', () async {
      final d = dir('Drive');
      final f1 = make();
      await f1.pick(pickDirectory: () async => d.path);
      channel.noAccess.add(entries().single['bookmark']! as String);
      f1.dispose();
      folders.remove(f1);
      final f2 = make();
      await f2.start();
      expect(f2.accessOf(d.path), CloudAccess.anotherDevice);
      expect(f2.accessLost(d.path), isTrue);
      expect(channel.callsOf('stopAccess').single.args['path'], real(d), reason: 'the presenter is removed');
    });

    test('a release queued before a pick of the same folder drops neither the new entry nor its root', () async {
      final d = dir('Drive');
      channel.ubiquitous.add(real(d));
      channel.picked = d.path;
      final f = make(platform: CloudPlatform.ios);
      await f.pick();
      final gate = Completer<void>();
      f.beforeListWrite = () => gate.future;
      final release = f.released(d.path, () => const []); // queued: nothing retains it
      final again = f.pick(); // the same folder, picked while the release waits
      await Future<void>.delayed(const Duration(milliseconds: 50));
      f.beforeListWrite = null;
      gate.complete();
      await release;
      await again;
      expect(entries(), hasLength(1));
      expect(f.accessOf(d.path), CloudAccess.live);
      expect(underCoordination([d.path]), isTrue, reason: 'the root was not unregistered');
      expect(f.checkOf(d.path), CloudRootCheck.passed);
    });

    test('the notebook asks the platform to download through startDownloading', () async {
      final f = make();
      final nb = Notebook(PageStore(dir('pages')), buildModules(), icloud: f);
      notebooks.add(nb);
      final file = '${dir('Drive').path}/x.canvas';
      nb.requestDownload!(file);
      await Future<void>.delayed(Duration.zero);
      expect(channel.callsOf('startDownloading').single.args['path'], file);
      final plain = Notebook(PageStore(dir('pages2')), buildModules());
      notebooks.add(plain);
      expect(plain.requestDownload, isNull);
    });

    test('a probe whose entry is no longer in the list is not on record: the root stays read-only', () async {
      final d = dir('Drive');
      channel.ubiquitous.add(real(d));
      final f1 = make();
      await f1.pick(pickDirectory: () async => d.path);
      f1.dispose();
      folders.remove(f1);
      final f2 = make();
      final seen = <bool>[];
      f2.onRootWritable = (_, w) {
        seen.add(w);
        // The list loses the entry just before the probe is recorded.
        if (!w && access.existsSync()) access.writeAsStringSync('{"version":1,"folders":[]}');
      };
      await f2.start();
      expect(seen, isNotEmpty);
      expect(seen, everyElement(isFalse), reason: 'never writable');
    });

    test('an Apple folder with no entry says "Choose the folder again"; one in the app\'s own storage does not', () async {
      final own = dir('own');
      final f = IcloudFolders(channel: channel, file: access, platform: CloudPlatform.macos, ownFolders: [own.path]);
      folders.add(f);
      await f.start();
      expect(f.statusOf(dir('Elsewhere').path), 'Choose the folder again');
      expect(f.statusOf(dir('own/sub').path), isNull);
    });
  });

  group('folder-access.json', () {
    test('an unreadable file is copied (read back equal) before a new one starts', () async {
      access.parent.createSync(recursive: true);
      access.writeAsStringSync('{ not json');
      final d = dir('Drive');
      final f = make();
      await f.start();
      expect(f.listState, CloudListState.restarted);
      final copies = [
        for (final e in access.parent.listSync())
          if (e.path.contains('folder-access-unreadable-')) e as File,
      ];
      expect(copies, hasLength(1));
      expect(RegExp(r'folder-access-unreadable-[0-9a-f]{16}\.json$').hasMatch(copies.single.path), isTrue);
      expect(copies.single.readAsStringSync(), '{ not json');
      expect(jsonDecode(access.readAsStringSync()), {'version': 1, 'folders': <Object>[]});
      // A pick still works against the new file.
      await f.pick(pickDirectory: () async => d.path);
      expect(entries(), hasLength(1));
    });

    test('a file of another version counts as unreadable and is kept', () async {
      access.parent.createSync(recursive: true);
      access.writeAsStringSync('{"version":2,"folders":[]}');
      final f = make();
      await f.start();
      expect(f.listState, CloudListState.restarted);
      expect(
        access.parent.listSync().whereType<File>().any((e) => e.readAsStringSync() == '{"version":2,"folders":[]}'),
        isTrue,
      );
    });

    test('with no copy possible, nothing is written and the folders say "On another device"', () async {
      access.parent.createSync(recursive: true);
      access.writeAsStringSync('{ not json');
      // A directory sits where the copy would be published? The copy name is
      // random, so block the publish by making the parent read-only is not
      // portable: use a list that can't be read at all instead.
      access.deleteSync();
      Directory(access.path).createSync(); // a folder where the file should be
      final f = make();
      await f.start();
      expect(f.listState, CloudListState.unavailable);
      expect(f.statusOf(dir('Elsewhere').path), 'On another device');
      expect(Directory(access.path).existsSync(), isTrue);
    });
  });

  group('pruning (R-2) and the retained locations', () {
    late Directory pages;
    late File binders;
    late File settingsFile;

    Notebook open(IcloudFolders f) {
      final s = AppSettings(settingsFile);
      final nb = buildAppNotebook(
        settings: s,
        pagesDirectory: pages,
        bindersFile: binders,
        icloud: f,
      );
      notebooks.add(nb);
      return nb;
    }

    // Closes the notebook and its access, as a quit does.
    Future<void> quit(Notebook nb, IcloudFolders f) async {
      await nb.flush();
      nb.dispose();
      notebooks.remove(nb);
      f.dispose();
      folders.remove(f);
    }

    setUp(() {
      pages = dir('pages');
      binders = File('${root.path}/app/binders.json');
      settingsFile = File('${root.path}/app/settings.json');
      settingsFile.parent.createSync(recursive: true);
    });

    // Picks [d] (macOS style) through the notebook's picker.
    Future<String> pickInto(Notebook nb, Directory d) async {
      final f = nb.icloud!;
      final p = await f.pick(pickDirectory: () async => d.path);
      return p!;
    }

    Future<IcloudFolders> relaunch(Notebook nb, IcloudFolders f, void Function(Notebook) check) async {
      await quit(nb, f);
      final f2 = make();
      final nb2 = open(f2);
      await nb2.loadChecked();
      expect(nb2.loadError, isNull);
      await nb2.cloudAccessIdle;
      check(nb2);
      return f2;
    }

    test('(i) a standalone page folder only in standaloneFolders keeps its entry and resolves after relaunch', () async {
      final d = dir('Pages2');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await nb.addStandaloneFolder(d.path);
      await nb.cloudAccessIdle;
      expect(AppSettings(settingsFile).defaultPageFolder, isNull);
      final f2 = await relaunch(nb, f, (n) {
        expect(n.standaloneFolders.single.available, isTrue);
      });
      expect(entries().single['path'], real(d));
      expect(f2.accessOf(d.path), CloudAccess.live);
    });

    test('(ii) only the defaultPageFolder setting keeps its entry', () async {
      final d = dir('Pages2');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await nb.setDefaultPageFolder(d.path);
      // Removing the standalone folder that is also the default keeps its entry.
      await nb.removeStandaloneFolder(nb.standaloneFolders.single.path);
      await nb.cloudAccessIdle;
      expect(entries(), hasLength(1), reason: 'still the default page folder');
      final listed = (jsonDecode(binders.readAsStringSync()) as Map)['standaloneFolders'];
      expect(listed ?? <Object>[], isEmpty);
      final f2 = await relaunch(nb, f, (n) {
        expect(n.standaloneFolders.single.available, isTrue, reason: 'the default folder is opened from the setting');
      });
      expect(entries().single['path'], real(d));
      expect(f2.accessOf(d.path), CloudAccess.live);
    });

    test('(iii) only the defaultBinderFolder setting keeps its entry; after relaunch a binder is created and found there', () async {
      final d = dir('Binders2');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await nb.setDefaultBinderFolder(d.path);
      await nb.cloudAccessIdle; // as the other cases: nothing of this launch is still pruning
      final f2 = await relaunch(nb, f, (_) {});
      expect(entries().single['path'], real(d));
      final nb2 = notebooks.last;
      final b = await nb2.createBinder(name: 'Fresh');
      expect(b.available, isTrue);
      expect(b.path.replaceAll(r'\', '/'), startsWith(d.path.replaceAll(r'\', '/')));
      await nb2.cloudAccessIdle;
      // A second launch finds the binder in the default folder's list too.
      await quit(nb2, f2);
      final f3 = make();
      final nb3 = open(f3);
      await nb3.loadChecked();
      await nb3.cloudAccessIdle;
      expect(nb3.binders.single.available, isTrue);
    });

    test('a binder created in the picked default binder folder resolves after the setting changed and a relaunch (N1)', () async {
      final d = dir('Binders2');
      final other = dir('Binders3');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await pickInto(nb, other);
      await nb.setDefaultBinderFolder(d.path);
      final b = await nb.createBinder(name: 'Made here');
      // Its own bookmark was written before binders.json lists it.
      expect(entries().map((e) => e['path']), contains(real(Directory(b.path))));
      expect(jsonDecode(binders.readAsStringSync())['binders'], isNotEmpty);
      await nb.setDefaultBinderFolder(other.path);
      await nb.cloudAccessIdle;
      final f2 = await relaunch(nb, f, (n) {
        expect(n.binders.single.available, isTrue);
      });
      expect(f2.accessOf(b.path), CloudAccess.live);
      expect(entries().map((e) => e['path']), containsAll([real(Directory(b.path)), real(d), real(other)]));
    });

    test('an entry no location needs is pruned after a successful load', () async {
      final d = dir('Unused');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      expect(entries(), hasLength(1));
      await relaunch(nb, f, (_) {});
      expect(entries(), isEmpty);
    });

    test('an unreadable settings.json prunes nothing', () async {
      final d = dir('Unused');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await quit(nb, f);
      settingsFile.writeAsStringSync('{ not json');
      final f2 = make();
      final nb2 = open(f2);
      await nb2.loadChecked();
      await nb2.cloudAccessIdle;
      expect(entries(), hasLength(1));
    });

    test('an unreadable binders.json prunes nothing', () async {
      final d = dir('Unused');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await nb.addStandaloneFolder(d.path);
      await quit(nb, f);
      binders.writeAsStringSync('{ not json');
      final f2 = make();
      final nb2 = open(f2);
      await nb2.loadChecked();
      await nb2.cloudAccessIdle;
      expect(entries(), hasLength(1));
    });

    test('a failed load prunes nothing', () async {
      final d = dir('Unused');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await quit(nb, f);
      final f2 = make();
      final nb2 = Notebook(
        _FailingStore(pages),
        buildModules(),
        bindersFile: binders,
        settings: AppSettings(settingsFile),
        icloud: f2,
      );
      notebooks.add(nb2);
      await nb2.loadChecked();
      expect(nb2.loadError, isNotNull);
      await nb2.cloudAccessIdle;
      expect(entries(), hasLength(1), reason: 'an unused entry is pruned only after a successful load');
    });

    test('released reads what is retained when it runs: a folder kept again meanwhile keeps its entry and its coordination', () async {
      final d = dir('Drive');
      channel.ubiquitous.add(real(d));
      final f = make();
      await f.pick(pickDirectory: () async => d.path);
      var keep = false;
      final run = f.released(d.path, () => keep ? [d.path] : const []);
      keep = true; // listed again before the write ran
      await run;
      expect(entries(), hasLength(1));
      expect(underCoordination([d.path]), isTrue);
      // Not retained any more: the entry goes and the root is let go of.
      await f.released(d.path, () => const []);
      expect(entries(), isEmpty);
      expect(underCoordination([d.path]), isFalse);
    });

    test('removing a folder while settings.json can\'t be read removes nothing', () async {
      final d = dir('Pages2');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await nb.addStandaloneFolder(d.path);
      await quit(nb, f);
      settingsFile.writeAsStringSync('{ not json');
      final f2 = make();
      final nb2 = open(f2);
      await nb2.loadChecked();
      await nb2.removeStandaloneFolder(nb2.standaloneFolders.single.path);
      await nb2.cloudAccessIdle;
      expect(entries(), hasLength(1));
      expect(channel.callsOf('stopAccess'), isEmpty);
    });

    test('removing the folder from Noted removes its entry', () async {
      final d = dir('Pages2');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await pickInto(nb, d);
      await nb.addStandaloneFolder(d.path);
      await nb.cloudAccessIdle;
      expect(entries(), hasLength(1));
      await nb.removeStandaloneFolder(nb.standaloneFolders.single.path);
      await nb.cloudAccessIdle;
      expect(entries(), isEmpty);
      expect(channel.callsOf('stopAccess').single.args['path'], real(d));
    });

    test('a macOS folder with no entry stays in binders.json', () async {
      final d = dir('Old');
      final f = make();
      final nb = open(f);
      await nb.loadChecked();
      await nb.addStandaloneFolder(d.path);
      await quit(nb, f);
      expect(entries(), isEmpty);
      final f2 = make();
      final nb2 = open(f2);
      await nb2.loadChecked();
      await nb2.cloudAccessIdle;
      expect((jsonDecode(binders.readAsStringSync()) as Map)['standaloneFolders'], isNotEmpty);
      expect(nb2.cloudStatusOf(d.path), 'Choose the folder again');
    });
  });
}

/// A store whose scan fails, so the load fails.
class _FailingStore extends PageStore {
  _FailingStore(super.directory);

  @override
  Future<List<PageEntry>> scan({
    bool createFolder = true,
    bool sweep = true,
    bool stamps = false,
    void Function(String path)? afterFileRead,
  }) async => throw const FileSystemException('disk said no');
}
