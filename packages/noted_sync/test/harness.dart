// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_graph.dart';
import 'fake_webdav.dart';
import 'helpers.dart';
import 'remote_fake.dart';

/// Thrown by a test seam to stand for the process being killed there.
class Killed extends Error {
  Killed(this.step);
  final String step;
  @override
  String toString() => 'Killed at $step';
}

/// Which fake store a harness runs on. The engine tests that don't depend on a
/// provider run on every kind.
enum RemoteKind {
  graph('OneDrive'),
  davPath('WebDAV, path ids'),
  davFileId('WebDAV, oc:fileid');

  const RemoteKind(this.label);
  final String label;
}

/// A fake remote store, a working copy and a state folder, with engines that
/// can be rebuilt on the same folders (a restart).
class Harness {
  Harness._(this.remote, this.base, this.clock, this.kind, this.rootName);

  final RemoteFake remote;
  final RemoteKind kind;
  final String rootName;

  /// The Graph fake, for the cases that only OneDrive has (delta pages, hashes).
  FakeGraph get fake => remote as FakeGraph;

  /// The WebDAV fake, for the cases that only WebDAV has.
  FakeWebDav get dav => remote as FakeWebDav;
  final Directory base;
  final FakeClock clock;
  late final Directory work = Directory('${base.path}/work');
  late final Directory state = Directory('${base.path}/state');
  FolderLocks locks = FolderLocks();
  late PullEngine engine;
  late String rootId;

  static Future<Harness> create({
    String rootName = 'Noted',
    RemoteKind kind = RemoteKind.graph,
  }) async {
    final RemoteFake remote = switch (kind) {
      RemoteKind.graph => await FakeGraph.start(),
      RemoteKind.davPath => await FakeWebDav.start(ids: FakeDavIds.path),
      RemoteKind.davFileId => await FakeWebDav.start(ids: FakeDavIds.ocFileId),
    };
    final base = await Directory.systemTemp.createTemp('engine');
    final h = Harness._(remote, base, FakeClock(), kind, rootName);
    final id = remote.addFolder(rootName);
    h.rootId = kind == RemoteKind.davPath ? '/' : id;
    await h.work.create();
    h.engine = h.newEngine();
    return h;
  }

  /// The WebDAV driver for the fake's synced folder.
  WebDavDriver newDavDriver() => WebDavDriver(
    client: WebDavClient(
      root: dav.urlOf(rootName),
      user: FakeWebDav.user,
      password: dav.password,
      clock: clock,
      allowLoopbackHttp: true,
    ),
    idKind: kind == RemoteKind.davPath ? DavIdKind.path : DavIdKind.fileId,
    rootId: rootId,
  );

  GraphClient newGraph() => GraphClient(
    origin: fake.origin,
    clock: clock,
    token: ({bool forceRefresh = false}) async => fake.expectedToken,
  );

  PullEngine newEngine({
    void Function(String step)? onStep,
    String? root,
    RemoteDriver? driver,
  }) =>
      PullEngine(
        workingCopy: work,
        stateDir: state,
        locks: locks,
        driver:
            driver ??
            (kind == RemoteKind.graph
                ? GraphDriver(
                    graph: newGraph(),
                    driveId: FakeGraph.driveId,
                    rootItemId: root ?? rootId,
                  )
                : newDavDriver()),
        clock: clock,
        onStep: onStep,
      );

  /// An engine that throws [Killed] at [step] (the [nth] time it is reached).
  PullEngine killAt(String step, {int nth = 1}) {
    var seen = 0;
    return engine = newEngine(
      onStep: (s) {
        if (s == step && ++seen == nth) throw Killed(step);
      },
    );
  }

  void restart() => engine = newEngine();

  Future<RoundResult> round() => engine.runRound();

  /// A round, then 31 s later another, so a delete has lasted.
  Future<RoundResult> roundsWithDelay() async {
    await round();
    clock.advance(const Duration(seconds: 31));
    return round();
  }

  Future<void> close() async {
    await remote.close();
    await base.delete(recursive: true);
  }

  // --- Local files ---
  String path(String rel) => '${work.path}/$rel';
  File file(String rel) => File(path(rel));
  bool has(String rel) => file(rel).existsSync();
  String read(String rel) => file(rel).readAsStringSync();
  void write(String rel, String text) {
    file(rel).parent.createSync(recursive: true);
    file(rel).writeAsStringSync(text);
  }

  /// Every file below the working copy, as relative paths, sorted.
  List<String> tree() {
    final out = <String>[];
    for (final e in work.listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        out.add(e.path.substring(work.path.length + 1).replaceAll(r'\', '/'));
      }
    }
    return out..sort();
  }

  List<String> stateFiles(String sub) {
    final d = Directory('${state.path}/$sub');
    if (!d.existsSync()) return [];
    return [for (final e in d.listSync()) e.path.split(RegExp(r'[\/]')).last]
      ..sort();
  }

  // --- Remote files ---
  static List<int> b(String s) => utf8.encode(s);

  int contentRequests() => remote.downloadCount;

  List<String> issueText() => [for (final i in engine.issues) '$i'];
}

Matcher hasIssue(String path) => predicate<List<SyncIssue>>(
  (l) => l.any((i) => i.path == path),
  'has an issue for $path',
);

ContentIdentity identityOf(String s) => ContentIdentity.ofBytes(utf8.encode(s));

/// The paths a round changed, relative to the working copy, with `/`.
List<String> changedRel(Harness h, RoundResult r) => [
  for (final p in r.changedPaths)
    p.substring(h.work.absolute.path.length + 1).replaceAll(r'\', '/'),
];
