// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_graph.dart';
import 'helpers.dart';

/// Thrown by a test seam to stand for the process being killed there.
class Killed extends Error {
  Killed(this.step);
  final String step;
  @override
  String toString() => 'Killed at $step';
}

/// A fake drive, a working copy and a state folder, with engines that can be
/// rebuilt on the same folders (a restart).
class Harness {
  Harness._(this.fake, this.base, this.clock);

  final FakeGraph fake;
  final Directory base;
  final FakeClock clock;
  late final Directory work = Directory('${base.path}/work');
  late final Directory state = Directory('${base.path}/state');
  final FolderLocks locks = FolderLocks();
  late PullEngine engine;
  late String rootId;

  static Future<Harness> create({String rootName = 'Noted'}) async {
    final fake = await FakeGraph.start();
    final base = await Directory.systemTemp.createTemp('engine');
    final h = Harness._(fake, base, FakeClock());
    h.rootId = fake.addFolder(rootName);
    await h.work.create();
    h.engine = h.newEngine();
    return h;
  }

  GraphClient newGraph() => GraphClient(
    origin: fake.origin,
    clock: clock,
    token: ({bool forceRefresh = false}) async => fake.expectedToken,
  );

  PullEngine newEngine({void Function(String step)? onStep, String? root}) =>
      PullEngine(
        workingCopy: work,
        stateDir: state,
        locks: locks,
        graph: newGraph(),
        driveId: FakeGraph.driveId,
        rootItemId: root ?? rootId,
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
    await fake.close();
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

  int contentRequests() =>
      fake.requests.where((r) => r.path.endsWith('/content')).length;

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
