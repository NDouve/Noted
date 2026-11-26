// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' show expect, isEmpty;
import 'package:noted/main.dart' show buildModules;
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_cloud_folder_channel.dart';
import 'notebook_folder.dart';

/// An iCloud root on a temp folder, the fake channel, and the folder access
/// and notebooks of a test, cleaned up after it (cloud parity step 6).
class IcloudWorld {
  late Directory root;

  /// The iCloud root, by its real path.
  late Directory drive;
  late File access;
  late FakeCloudFolderChannel channel;
  late FolderLocks locks;

  /// The clock the folder accesses use; null is the real one.
  FakeClock? clock;

  /// How long a folder access gathers change events before it asks the platform.
  Duration askDelay = const Duration(milliseconds: 20);

  /// The least time between two scans for versions (the backstop).
  Duration scanAfter = const Duration(minutes: 1);
  final List<IcloudFolders> folders = [];
  final List<Notebook> notebooks = [];

  Future<void> init() async {
    root = await Directory.systemTemp.createTemp('noted_icloud_v');
    final made = Directory('${root.path}/Drive')..createSync(recursive: true);
    drive = Directory(made.resolveSymbolicLinksSync());
    access = File('${root.path}/state/folder-access.json');
    channel = FakeCloudFolderChannel()..tempHeldAtResolve = true;
    channel.ubiquitous.add(drive.path);
    locks = FolderLocks();
  }

  IcloudFolders make({CloudPlatform platform = CloudPlatform.macos, Duration retryAfter = Duration.zero}) {
    final f = IcloudFolders(
      channel: channel,
      file: access,
      platform: platform,
      locks: locks,
      coordinationTimeout: const Duration(seconds: 5),
      versionRetryAfter: retryAfter,
      versionAskDelay: askDelay,
      tempScanAfter: scanAfter,
      now: clock?.call,
    );
    folders.add(f);
    return f;
  }

  /// A folder access with the drive picked, registered and self-tested.
  Future<IcloudFolders> picked({CloudPlatform platform = CloudPlatform.macos, Duration retryAfter = Duration.zero}) async {
    final f = make(platform: platform, retryAfter: retryAfter);
    channel.picked = drive.path; // the iOS picker
    await f.pick(pickDirectory: () async => drive.path);
    return f;
  }

  /// A folder access that starts from what an earlier one recorded (a launch).
  Future<IcloudFolders> relaunched({CloudPlatform platform = CloudPlatform.macos, Duration retryAfter = Duration.zero}) async {
    final f = make(platform: platform, retryAfter: retryAfter);
    await f.start();
    return f;
  }

  String path(String relative) => '${drive.path}/$relative';

  File write(String relative, String text) {
    final f = File(path(relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
    return f;
  }

  /// The files of the drive (relative names), sorted.
  List<String> names([String relative = '']) {
    final d = Directory(relative.isEmpty ? drive.path : path(relative));
    return [for (final e in d.listSync()) e.uri.pathSegments.where((s) => s.isNotEmpty).last]..sort();
  }

  Notebook notebook(
    IcloudFolders f, {
    Directory? pages,
    bool watchFiles = false,
    Duration folderCheck = Duration.zero,
    Duration backoff = const Duration(hours: 1),
  }) {
    // The drive is the default page folder, so nothing prunes its access.
    final settings = AppSettings(File('${root.path}/app/settings.json'))..defaultPageFolder = (pages ?? drive).path;
    final nb = Notebook(
      PageStore(pages ?? drive),
      buildModules(),
      saveDelay: const Duration(hours: 1),
      bindersFile: File('${root.path}/app/binders.json'),
      recoveryDirectory: Directory('${root.path}/app/recovery'),
      folderCheckInterval: folderCheck,
      watchFiles: watchFiles,
      watchDebounce: const Duration(milliseconds: 20),
      backoffFirst: backoff,
      backoffMax: backoff,
      icloud: f,
      settings: settings,
      folderLocks: locks,
    );
    notebooks.add(nb);
    return nb;
  }

  Future<void> dispose() async {
    // A change event at the end of a test starts recovery and landing work that
    // the notebook runs on its own: it is let finish before the folder goes.
    for (final n in notebooks) {
      try {
        await n.discoveryIdle;
        await n.cloudAccessIdle;
        await n.pendingRecovery(); // a listing queues behind the replay's turn
        await n.flush();
      } on Object {
        // A test that broke the folder.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final n in notebooks) {
      try {
        await n.flush();
      } on Object {
        // A test that broke the folder.
      }
      n.dispose();
    }
    for (final f in folders) {
      f.dispose();
    }
    await deleteTestFolder(root);
    // t3c: no version was resolved without its temp holding the bytes.
    expect(channel.resolveViolations, isEmpty);
  }
}

/// Waits until [done], or throws.
Future<void> waitFor(bool Function() done, {String? what, Duration within = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for ${what ?? 'a condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A clock a test moves by hand.
class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 25, 12);

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}
