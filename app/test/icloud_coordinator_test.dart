// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The R5.4 protocol of the channel coordinator, against the fake channel.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted_core/noted_core.dart';

import 'support/fake_cloud_folder_channel.dart';

void main() {
  late FakeCloudFolderChannel channel;
  late ChannelCoordinator coordinator;
  late Directory root;

  CoordinatedWrite one(String path, [CoordinationKind kind = CoordinationKind.write]) =>
      CoordinatedWrite([CoordinationIntent(path, kind)]);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_coord');
    channel = FakeCloudFolderChannel();
    coordinator = ChannelCoordinator(channel, timeout: const Duration(milliseconds: 200));
    channel.onEvent = coordinator.handleEvent;
  });
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('a call sends coordinate, runs its body on go, then sends done', () async {
    var ran = false;
    final r = await coordinator.coordinate(one('/a', CoordinationKind.move), () async {
      ran = true;
      expect(channel.held, hasLength(1), reason: 'the hold lasts while the body runs');
      return 7;
    });
    expect(r, 7);
    expect(ran, isTrue);
    expect(channel.methods, ['coordinate', 'done']);
    final c = channel.callsOf('coordinate').single.args;
    expect(c['intents'], [
      {'path': '/a', 'kind': 'move'},
    ]);
    expect(channel.held, isEmpty);
  });

  test('a throwing body still sends done, and its error is the caller\'s', () async {
    await expectLater(
      coordinator.coordinate<void>(one('/a'), () async => throw const FormatException('x')),
      throwsA(isA<FormatException>()),
    );
    expect(channel.methods, ['coordinate', 'done']);
    expect(channel.held, isEmpty);
  });

  test('no go in time: cancel is sent, the body never runs, and a late go gets done at once', () async {
    channel.mode = CoordinateMode.silent;
    var ran = false;
    await expectLater(
      coordinator.coordinate<void>(one('/a'), () async => ran = true),
      throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.coordination)),
    );
    final id = channel.callsOf('coordinate').single.args['id']! as int;
    expect(channel.methods, ['coordinate', 'cancel']);
    expect(channel.callsOf('cancel').single.args['id'], id);
    await channel.answer(id, 'go');
    expect(channel.methods, ['coordinate', 'cancel', 'done'], reason: 'a late go is answered by done');
    expect(ran, isFalse);
    expect(coordinator.waitingCount, 0);
  });

  test('a go for an unknown id is answered by done', () async {
    await channel.answer(99, 'go');
    expect(channel.methods, ['done']);
    expect(channel.callsOf('done').single.args['id'], 99);
  });

  test('pending is a StorageBusy (versionsPending) and calls the landing hook', () async {
    channel.mode = CoordinateMode.pending;
    final landed = <List<String>>[];
    coordinator.onVersionsPending = landed.add;
    var ran = false;
    await expectLater(
      coordinator.coordinate<void>(one('/a/b.canvas', CoordinationKind.delete), () async => ran = true),
      throwsA(
        isA<StorageBusy>()
            .having((e) => e.reason, 'reason', StorageBusyReason.versionsPending)
            .having((e) => e.paths, 'paths', ['/a/b.canvas']),
      ),
    );
    expect(ran, isFalse);
    expect(landed, [
      ['/a/b.canvas'],
    ]);
    expect(channel.methods, ['coordinate'], reason: 'nothing is held after pending');
  });

  test('failed is a StorageBusy (coordination) with nothing held', () async {
    channel.mode = CoordinateMode.failed;
    await expectLater(
      coordinator.coordinate<void>(one('/a'), () async {}),
      throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.coordination)),
    );
    expect(channel.held, isEmpty);
  });

  test('an unavailable channel is a StorageBusy', () async {
    channel.coordinateThrows = true;
    await expectLater(
      coordinator.coordinate<void>(one('/a'), () async {}),
      throwsA(isA<StorageBusy>()),
    );
  });

  test('reset is the first call at start, before anything resolves', () async {
    final folders = IcloudFolders(
      channel: channel,
      file: File('${root.path}/folder-access.json'),
      platform: CloudPlatform.macos,
    );
    addTearDown(folders.dispose);
    await folders.start();
    expect(channel.methods.first, 'reset');
  });

  test('a coordinated primitive under a registered root goes through the channel once', () async {
    final real = root.resolveSymbolicLinksSync();
    registerCoordinator(real, coordinator);
    addTearDown(() => unregisterCoordinator(real));
    final tmp = File('$real/.t.tmp')..writeAsStringSync('x');
    expect(await publishExclusive(tmp, '$real/out.txt'), isTrue);
    expect(channel.callsOf('coordinate'), hasLength(1));
    expect(channel.callsOf('done'), hasLength(1));
    final kinds = {
      for (final i in channel.intentsById.values.single) i['kind'],
    };
    expect(kinds, {'write', 'move'});
  });

  test('a refusal reaches a primitive as StorageBusy and nothing is written', () async {
    final real = root.resolveSymbolicLinksSync();
    registerCoordinator(real, coordinator);
    addTearDown(() => unregisterCoordinator(real));
    channel.mode = CoordinateMode.failed;
    final tmp = File('$real/.t.tmp')..writeAsStringSync('x');
    await expectLater(publishExclusive(tmp, '$real/out.txt'), throwsA(isA<StorageBusy>()));
    expect(File('$real/out.txt').existsSync(), isFalse);
  });
}
