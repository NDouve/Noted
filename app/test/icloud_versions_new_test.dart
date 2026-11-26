// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// iCloud versions that arrive after launch are found (t2b, review
// 2026-11-24-codex-run-diff R-2): the change event, the backstop scan, the
// filter by known ids, the row classes and their retries, and the start-of-turn
// check, against the fake channel.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/attachment_copy.dart' show damagedCopyName;
import 'package:noted/src/icloud_folders.dart';
import 'package:noted_core/noted_core.dart';

import 'support/fake_cloud_folder_channel.dart';
import 'support/icloud_world.dart';

// A folder's lock turns, counted.
class _CountingLocks extends FolderLocks {
  int runs = 0;

  @override
  Future<T> run<T>(Directory folder, Future<T> Function() job) {
    runs++;
    return super.run(folder, job);
  }
}

void main() {
  late IcloudWorld w;
  late FakeCloudFolderChannel channel;
  late FakeClock clock;

  setUp(() async {
    w = IcloudWorld();
    await w.init();
    channel = w.channel;
    clock = w.clock = FakeClock();
    w.scanAfter = const Duration(seconds: 10);
  });
  tearDown(() => w.dispose());

  List<int> b(String s) => utf8.encode(s);
  String h8(String s) => contentHash(b(s)).substring(0, 8);
  String h16(String s) => contentHash(b(s)).substring(0, 16);
  List<String> temps([String rel = '']) => [for (final n in w.names(rel)) if (n.contains('.noted-version-')) n];
  String text(String relative) => File(w.path(relative)).readAsStringSync();
  String copy8(String stem, String s) => '$stem-icloud-${h8(s)}.canvas';
  String copy16(String stem, String s) => '$stem-icloud-${h16(s)}.canvas';
  const good = 'attachment bytes';
  String attName() => '${contentHash(b(good))}.png';

  // An event of [path], and everything it starts, done.
  Future<void> event(IcloudFolders f, String path, {bool version = false}) async {
    await channel.emit('changed', {'path': path, if (version) 'version': true});
    await f.versionAskIdle;
  }

  String slashes(String s) => s.replaceAll(r'\', '/');

  List<VersionLandReason> reasonsOf(IcloudFolders f, String path) => [
    for (final l in f.debugVersionLandings)
      if (slashes(l.path) == slashes(path)) l.reason,
  ];

  group('triggers', () {
    test('a version after launch is landed by its change event alone, with or without version: true', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      final p2 = w.write('p2.canvas', 'current 2');
      await f.landAllVersions();
      expect(f.debugVersionLandings, isEmpty, reason: 'no versions: nothing is landed at launch');
      channel.addVersion(p1.path, b('theirs'));
      await event(f, p1.path);
      expect(channel.unresolvedOf(p1.path), isEmpty);
      expect(text(copy8('p1', 'theirs')), 'theirs');
      expect(reasonsOf(f, p1.path), [VersionLandReason.event]);
      channel.addVersion(p2.path, b('theirs 2'));
      await event(f, p2.path, version: true);
      expect(channel.unresolvedOf(p2.path), isEmpty);
      expect(text(copy8('p2', 'theirs 2')), 'theirs 2');
      expect(reasonsOf(f, p2.path), [VersionLandReason.event]);
    });

    test('a missed event: nothing before the scan interval, the folder tick lands it after, as the backstop', () async {
      final f = await w.picked();
      final nb = w.notebook(f);
      await nb.load();
      await nb.discoveryIdle;
      final id = nb.currentId!;
      await nb.flush();
      final file = File(w.path('$id.canvas'));
      final theirs = readPage(file.readAsStringSync()).insertNode(
        BoxRecord.create(
          id: '00000000000000b2',
          typeId: 'x.unregistered',
          dataVersion: 1,
          bounds: const Bounds(300, 300, 10, 10),
          data: const RawJson.trusted('{"k":1}'),
          snapshotText: 's',
          rev: 'r',
        ),
      );
      await f.landAllVersions(); // the launch scan: the time stamp
      channel.addVersion(file.path, b(writePage(theirs)));
      await nb.folderTickForTest();
      expect(channel.unresolvedOf(file.path), hasLength(1), reason: 'inside the scan interval');
      clock.advance(const Duration(seconds: 30));
      await nb.folderTickForTest();
      await f.versionAskIdle;
      expect(channel.unresolvedOf(file.path), isEmpty);
      expect(reasonsOf(f, file.path), contains(VersionLandReason.backstop));
    });

    test('a file with no versions: one withVersions call, no versions call and no lock turn', () async {
      final counting = w.locks = _CountingLocks();
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      final turns = counting.runs;
      await event(f, p1.path);
      expect(channel.withVersionsCalls, [
        [p1.path],
      ]);
      expect(channel.callsOf('versions'), isEmpty);
      expect(counting.runs, turns, reason: 'no lock turn');
      expect(f.debugVersionLandings, isEmpty);
    });

    test('sibling events do not land a stuck file again (B-1)', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'one');
      final p2 = w.write('p2.canvas', 'two');
      w.write(copy8('p2', 'big'), 'x');
      w.write(copy16('p2', 'big'), 'y');
      channel.addVersion(p2.path, b('big'));
      await f.landVersions([p2.path]);
      expect(f.versionsStuck(p2.path), isTrue);
      final tries = channel.callsOf('versions').length;
      for (var i = 0; i < 4; i++) {
        clock.advance(const Duration(seconds: 6));
        await event(f, p1.path);
        await event(f, w.write('p3.canvas', 'three $i').path);
      }
      expect(channel.callsOf('versions').length, tries, reason: 'p2 is not copied again');
      expect(f.versionsStuck(p2.path), isTrue);
    });

    test('echoes: the events of the landing\'s own copy and resolved target land nothing more', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      channel.addVersion(p1.path, b('theirs'));
      await f.landVersions([p1.path]);
      final copy = w.path(copy8('p1', 'theirs'));
      for (final version in [false, true]) {
        await event(f, copy, version: version);
        await event(f, p1.path, version: version);
      }
      expect(channel.callsOf('versions'), hasLength(1));
      expect(f.debugVersionLandings, hasLength(1));
    });

    test('a landing triggered by events of a file that has no versions after all is cancelled and changes no row', () async {
      final f = await w.picked();
      final t = w.write('Meeting.notedtemplate', 'template');
      channel.addVersion(t.path, b('other template'));
      await f.landVersions([t.path]);
      final row = f.versionIssues.single;
      final second = channel.addVersion(t.path, b('another template'));
      var first = true;
      // The version is gone between the answer and the turn that acts on it.
      channel.onWithVersions = (paths) {
        if (!first) return;
        first = false;
        channel.versionsOf(t.path).firstWhere((v) => v.id == second).resolved = true;
      };
      final tries = channel.callsOf('versions').length;
      await event(f, t.path);
      expect(channel.callsOf('versions').length, tries, reason: 'the turn was cancelled before it copied anything');
      expect(f.debugVersionLandings.last.cancelled, isTrue);
      expect(f.debugVersionLandings.last.reason, VersionLandReason.event);
      expect(f.versionIssues.single.ids, row.ids);
    });
  });

  group('the filter by known ids', () {
    test('a template version and a non-matching attachment version stay listed through three scans and five events, with no new temp; so after "Keep it in iCloud"', () async {
      final f = await w.picked();
      final t = w.write('Meeting.notedtemplate', 'template');
      final att = w.write('p1.assets/${attName()}', good);
      channel.addVersion(t.path, b('other template'));
      channel.addVersion(att.path, b('some other bytes'));
      await f.landVersions([t.path, att.path]);
      expect(f.versionIssues, hasLength(2));
      final made = <String>[];
      channel.onVersions = (path, tmps) => made.addAll(tmps);
      final tries = channel.callsOf('versions').length;
      Future<void> noise() async {
        for (var i = 0; i < 3; i++) {
          clock.advance(const Duration(seconds: 15));
          await f.scanForVersions();
          await f.versionAskIdle;
        }
        for (var i = 0; i < 5; i++) {
          clock.advance(const Duration(seconds: 6));
          await event(f, t.path);
          await event(f, att.path, version: i.isEven);
        }
      }

      await noise();
      expect(channel.callsOf('versions').length, tries, reason: 'nothing is copied again');
      expect(made, isEmpty);
      expect(temps(), isEmpty);
      expect(temps('p1.assets'), isEmpty);
      expect(f.versionIssues, hasLength(2));
      f.keepInICloud(att.path);
      expect(f.versionIssues, hasLength(1));
      await noise();
      expect(channel.callsOf('versions').length, tries);
      expect(f.versionIssues, hasLength(1));
    });

    test('a new id lands only the new version: versions gets known, so one temp is made', () async {
      final f = await w.picked();
      final t = w.write('Meeting.notedtemplate', 'template');
      final first = channel.addVersion(t.path, b('other template'));
      await f.landVersions([t.path]);
      final made = <String>[];
      channel.onVersions = (path, tmps) => made.addAll(tmps);
      final second = channel.addVersion(t.path, b('another template'));
      await event(f, t.path);
      expect(made, hasLength(1));
      expect(channel.callsOf('versions').last.args['known'], [first]);
      expect(f.versionIssues.single.ids, {first, second});
      expect(temps(), isEmpty);
    });

    test('a removed id (R-1): a damaged attachment with two versions is landed when one goes', () async {
      final f = await w.picked();
      final att = w.write('p1.assets/${attName()}', 'damaged');
      channel.addVersion(att.path, b(good));
      final other = channel.addVersion(att.path, b('other bytes'));
      await f.landVersions([att.path]);
      expect(f.versionsStuck(att.path), isTrue);
      expect(f.versionIssues.single.ids, hasLength(2));
      // Another device resolves the other one.
      channel.versionsOf(att.path).firstWhere((v) => v.id == other).resolved = true;
      clock.advance(const Duration(seconds: 6));
      await event(f, att.path);
      expect(text('p1.assets/${attName()}'), good);
      expect(w.names('p1.assets').where((n) => n.contains('.damaged-')), hasLength(1));
      expect(channel.unresolvedOf(att.path), isEmpty);
      expect(f.versionIssues, isEmpty);
      expect(w.names('p1.assets').where((n) => n.contains('noted-version')), isEmpty);
      expect(damagedCopyName(attName(), contentHash(b('damaged'))), isNotEmpty);
    });

    test('a removed obstruction: a taken copy name deleted, with its event, lands the page with no id change', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      w.write(copy8('p1', 'theirs'), 'x');
      final blocker = w.write(copy16('p1', 'theirs'), 'y');
      channel.addVersion(p1.path, b('theirs'));
      await f.landVersions([p1.path]);
      expect(f.versionsStuck(p1.path), isTrue);
      expect(f.versionIssues.single.blocking, hasLength(2));
      blocker.deleteSync();
      clock.advance(const Duration(seconds: 6));
      await channel.emit('changed', {'path': blocker.path});
      await f.versionAskIdle;
      expect(text(copy16('p1', 'theirs')), 'theirs');
      expect(channel.unresolvedOf(p1.path), isEmpty);
      expect(f.versionIssues, isEmpty);
      expect(reasonsOf(f, p1.path), contains(VersionLandReason.rowRetry));
    });

    test('a row with empty ids ignores withVersions: it is retried by the backoff only', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      w.write(copy8('p1', 'theirs'), 'x');
      w.write(copy16('p1', 'theirs'), 'y');
      // A temp that can't be placed raises a row with no ids.
      w.write('.p1.canvas.noted-version-0123456789abcdef.tmp', 'theirs');
      await f.landVersions([w.drive.path]);
      expect(f.versionsStuck(p1.path), isTrue);
      expect(f.versionIssues.single.ids, isEmpty);
      channel.addVersion(p1.path, b('unrelated'));
      for (var i = 0; i < 3; i++) {
        clock.advance(const Duration(seconds: 15));
        await f.scanForVersions();
        await f.versionAskIdle;
      }
      expect(channel.withVersionsCalls.expand((c) => c).map(slashes), isNot(contains(slashes(p1.path))), reason: 'ignored');
      expect(channel.callsOf('versions'), isEmpty, reason: 'inside the first minute');
      clock.advance(const Duration(minutes: 1));
      await f.scanForVersions();
      await f.versionAskIdle;
      expect(channel.callsOf('versions'), hasLength(1), reason: 'the backoff');
      expect(reasonsOf(f, p1.path), contains(VersionLandReason.rowRetry));
      expect(channel.unresolvedOf(p1.path), isEmpty);
      expect(text(copy8('p1', 'unrelated')), 'unrelated');
    });

    test('ids that do not compare as strings (B-3): matching by identity still filters', () async {
      final f = await w.picked();
      channel.idsChange = true;
      final t = w.write('Meeting.notedtemplate', 'template');
      channel.addVersion(t.path, b('other template'));
      await f.landVersions([t.path]);
      final tries = channel.callsOf('versions').length;
      for (var i = 0; i < 3; i++) {
        clock.advance(const Duration(seconds: 15));
        await f.scanForVersions();
        await event(f, t.path);
      }
      expect(channel.callsOf('versions').length, tries);
      expect(f.versionIssues, hasLength(1));
    });

    test('a nil identifier is refused and recorded as ""; nothing is resolved by it', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      channel.addVersion(p1.path, b('theirs'));
      channel.versionsOf(p1.path).single.nilIdentifier = true;
      for (var i = 0; i < 3; i++) {
        await f.landVersions([p1.path]);
      }
      expect(f.versionsStuck(p1.path), isTrue);
      expect(f.versionIssues.single.ids, {''});
      expect(channel.callsOf('resolveVersion'), isEmpty);
      expect(temps(), isEmpty);
    });

    test('a retry on the backoff, or by a freed blocking name, passes the start-of-turn check (B-A)', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      w.write(copy8('p1', 'theirs'), 'x');
      w.write(copy16('p1', 'theirs'), 'y');
      channel.addVersion(p1.path, b('theirs'));
      await f.landVersions([p1.path]);
      final tries = channel.callsOf('versions').length;
      // Inside the first minute nothing retries it.
      clock.advance(const Duration(seconds: 15));
      await f.scanForVersions();
      await f.versionAskIdle;
      expect(channel.callsOf('versions').length, tries);
      // Due: withVersions has nothing new to say, the row is retried all the same.
      clock.advance(const Duration(minutes: 2));
      channel.withVersionsCalls.clear();
      await f.scanForVersions();
      await f.versionAskIdle;
      expect(channel.callsOf('versions').length, tries + 1);
      expect(reasonsOf(f, p1.path), contains(VersionLandReason.rowRetry));
      expect(f.debugVersionLandings.where((l) => l.cancelled), isEmpty);
    });

    test('versions(known) answers a known version as {id, known: true}, copies nothing, and a mistyped known is an arguments error', () async {
      final p1 = w.write('p1.canvas', 'current');
      final id = channel.addVersion(p1.path, b('theirs'));
      final out = await channel.invoke('versions', {'path': p1.path, 'known': [id]});
      expect(out, [
        {'id': id, 'known': true},
      ]);
      expect(temps(), isEmpty);
      await expectLater(
        channel.invoke('versions', {'path': p1.path, 'known': 'x'}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'arguments')),
      );
      await expectLater(
        channel.invoke('withVersions', {'items': [{'path': p1.path}]}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'arguments')),
      );
      final answer = await channel.invoke('withVersions', {'items': [{'path': p1.path, 'known': <String>[]}, {'path': w.path('p2.canvas'), 'known': <String>[]}]});
      expect(answer, {p1.path: {'fresh': [id], 'shrank': false}}, reason: 'only paths with news, under the request\'s string');
    });

    test('an attachment with one known and one matching version is not sole: nothing is resolved', () async {
      final f = await w.picked();
      final att = w.write('p1.assets/${attName()}', good);
      channel.addVersion(att.path, b('some other bytes'));
      await f.landVersions([att.path]);
      expect(f.versionIssues.single.kind, CloudVersionIssueKind.otherVersion);
      // The file is damaged and a version with the good bytes arrives.
      att.writeAsStringSync('damaged');
      channel.addVersion(att.path, b(good));
      await event(f, att.path);
      expect(channel.unresolvedOf(att.path), hasLength(2), reason: 'two versions: the set-aside would be pending for good');
      expect(att.readAsStringSync(), 'damaged');
      expect(w.names('p1.assets'), [attName()]);
      expect(f.versionsStuck(att.path), isTrue);
    });
  });

  group('other cases', () {
    test('a version on a dataless page is not landed at the event; the materialise event lands it', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      channel.addVersion(p1.path, b('theirs'));
      p1.deleteSync();
      File(w.path('.p1.canvas.icloud')).writeAsStringSync('');
      await event(f, p1.path);
      expect(channel.callsOf('versions'), isEmpty);
      expect(channel.callsOf('startDownloading'), isNotEmpty);
      // It arrives.
      p1.writeAsStringSync('current');
      File(w.path('.p1.canvas.icloud')).deleteSync();
      clock.advance(const Duration(seconds: 6));
      await event(f, p1.path);
      expect(channel.unresolvedOf(p1.path), isEmpty);
      expect(text(copy8('p1', 'theirs')), 'theirs');
    });

    test('a re-pick of a root lands a version that was already there', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      channel.addVersion(p1.path, b('theirs'));
      channel.picked = w.drive.path;
      await f.pick(pickDirectory: () async => w.drive.path);
      await f.versionAskIdle;
      await waitFor(() => channel.unresolvedOf(p1.path).isEmpty, what: 'the catch-up');
      expect(reasonsOf(f, p1.path), [VersionLandReason.catchUp]);
    });

    test('withVersions failing: launch lands the chunk unfiltered, an event lands nothing, the turn check lets a landing go on', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      final p2 = w.write('p2.canvas', 'no versions');
      channel.addVersion(p1.path, b('theirs'));
      channel.withVersionsFails = true;
      await event(f, p1.path);
      expect(channel.unresolvedOf(p1.path), hasLength(1), reason: 'an event lands nothing');
      await f.landAllVersions();
      expect(channel.unresolvedOf(p1.path), isEmpty, reason: 'launch lands unfiltered');
      expect(channel.callsOf('versions').map((c) => slashes('${c.args['path']}')), containsAll([slashes(p1.path), slashes(p2.path)]));
      // The turn check: an event-reason landing goes on when its call fails.
      channel.addVersion(p2.path, b('theirs 2'));
      await f.landVersions([p2.path], reason: VersionLandReason.event);
      expect(channel.unresolvedOf(p2.path), isEmpty);
    });

    test('a scan over 5,000 files makes 25 withVersions calls and no versions call', () async {
      final f = await w.picked();
      for (var i = 0; i < 5000; i++) {
        File(w.path('p${i.toString().padLeft(4, '0')}.canvas')).writeAsStringSync('page $i');
      }
      await f.scanForVersions();
      expect(channel.withVersionsCalls, hasLength(25));
      expect(channel.withVersionsCalls.every((c) => c.length <= 200), isTrue);
      expect(channel.callsOf('versions'), isEmpty);
    });

    test('the reasons in the queue: an unchecked reason upgrades a queued event', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      channel.addVersion(p1.path, b('theirs'));
      final a = f.landVersions([p1.path], reason: VersionLandReason.event);
      final c = f.landVersions([p1.path], reason: VersionLandReason.pending);
      await Future.wait([a, c]);
      expect(reasonsOf(f, p1.path), [VersionLandReason.pending]);
    });

    test('the event trigger off lands nothing by events; the filter off lands every asked file', () async {
      final f = await w.picked();
      final p1 = w.write('p1.canvas', 'current');
      channel.addVersion(p1.path, b('theirs'));
      f.debugVersionTriggers = {'backstop', 'filter'};
      await event(f, p1.path);
      expect(channel.unresolvedOf(p1.path), hasLength(1));
      f.debugVersionTriggers = {'event', 'backstop'};
      await event(f, p1.path);
      expect(channel.withVersionsCalls, isEmpty, reason: 'unfiltered: no ask');
      expect(channel.unresolvedOf(p1.path), isEmpty);
    });
  });
}
