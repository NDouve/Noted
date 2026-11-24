// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Cloud parity step 6, review fixes: a landing never schedules itself, a
// version is resolved only once placed (and a temp left in `.assets` is found),
// a resolve that finds nothing is a refusal, a dataless file keeps its row.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/attachment_copy.dart' show damagedCopyName;
import 'package:noted/src/icloud_folders.dart';
import 'package:noted_core/noted_core.dart';

import 'support/icloud_world.dart';

void main() {
  late IcloudWorld w;

  setUp(() async {
    w = IcloudWorld();
    await w.init();
  });
  tearDown(() => w.dispose());

  List<int> b(String s) => utf8.encode(s);
  const good = 'attachment bytes';
  String name() => '${contentHash(b(good))}.png';
  List<String> temps(String rel) => [for (final n in w.names(rel)) if (n.contains('.noted-version-')) n];

  test('a damaged attachment with a matching and another version ends in a bounded number of calls, listed, nothing resolved or lost', () async {
    final f = await w.picked();
    final att = w.write('p1.assets/${name()}', 'damaged');
    w.channel.addVersion(att.path, b(good));
    w.channel.addVersion(att.path, b('other'));
    await f.landVersions([att.path]);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(w.channel.callsOf('versions').length, lessThanOrEqualTo(2));
    expect(w.channel.unresolvedOf(att.path), hasLength(2), reason: 'nothing resolved');
    expect(att.readAsStringSync(), 'damaged');
    expect(w.names('p1.assets'), [name()], reason: 'no temp, nothing deleted or moved');
    expect(f.versionIssues.single.text, "iCloud holds versions of ${name()} that Noted can't keep yet");
  });

  test('killed after the resolve in the damaged path: the temp in .assets is found at the next launch and placed', () async {
    final f = await w.picked();
    final att = w.write('p1.assets/${name()}', 'damaged');
    w.channel.addVersion(att.path, b(good));
    f.landingStep = (step, path) async {
      if (step == 'resolved') throw StateError('killed');
    };
    await f.landVersions([att.path]);
    expect(w.channel.unresolvedOf(att.path), isEmpty);
    expect(temps('p1.assets'), hasLength(1), reason: 'the version lives only in the temp');
    f.dispose();
    final g = await w.relaunched();
    await g.landAllVersions();
    expect(att.readAsStringSync(), good);
    expect(temps('p1.assets'), isEmpty);
    expect(w.names('p1.assets').where((n) => n.contains('.damaged-')), hasLength(1));
  });

  test('the folder tick places a temp left in a nested folder, and is throttled', () async {
    (await w.picked()).dispose();
    final g = await w.relaunched();
    Directory(w.path('Binder/p.assets')).createSync(recursive: true);
    w.write('Binder/p.assets/.${name()}.noted-version-0123456789abcdef.tmp', good);
    await g.landLeftoverTemps();
    expect(File(w.path('Binder/p.assets/${name()}')).readAsStringSync(), good);
    expect(temps('Binder/p.assets'), isEmpty);
    w.write('Binder/p.assets/.${name()}x.noted-version-0123456789abcde0.tmp', 'x');
    await g.landLeftoverTemps();
    expect(temps('Binder/p.assets'), hasLength(1), reason: 'once in tempScanAfter');
  });

  test('a leftover attachment temp that can\'t be placed is a refusal, never a loop', () async {
    final f = await w.picked();
    final att = w.write('p1.assets/${name()}', 'damaged');
    w.channel.addVersion(att.path, b('other'));
    w.write('p1.assets/.${name()}.noted-version-0123456789abcdef.tmp', good);
    for (var i = 0; i < 3; i++) {
      await f.landVersions([att.path]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.channel.callsOf('versions').length, 3);
    expect(f.versionsStuck(att.path), isTrue);
    expect(temps('p1.assets'), hasLength(1), reason: 'kept');
  });

  test('a resolve that finds no such version is a refusal, not a resolved version', () async {
    final f = await w.picked();
    final file = w.write('p1.canvas', 'current');
    w.channel.addVersion(file.path, b('theirs'));
    w.channel.onVersions = (p, t) {
      for (final v in w.channel.unresolvedOf(p)) {
        v.resolved = true; // resolved elsewhere meanwhile
      }
    };
    final landed = <VersionLanding>[];
    f.onLanded = landed.add;
    await f.landVersions([file.path]);
    expect(landed.single.resolved, 0);
    expect(landed.single.refused, isTrue);
  });

  test('a file that is not downloaded keeps its row', () async {
    final f = await w.picked();
    final file = w.write('p1.canvas', 'current');
    w.write('p1-icloud-${contentHash(b('theirs')).substring(0, 8)}.canvas', 'x');
    w.write('p1-icloud-${contentHash(b('theirs')).substring(0, 16)}.canvas', 'y');
    w.channel.addVersion(file.path, b('theirs'));
    await f.landVersions([file.path]);
    expect(f.versionIssues, hasLength(1));
    file.deleteSync();
    File(w.path('.p1.canvas.icloud')).writeAsStringSync('');
    await f.landVersions([file.path]);
    expect(f.versionIssues, hasLength(1), reason: 'nothing was learned: the row stays');
    expect(w.channel.callsOf('startDownloading'), isNotEmpty);
  });

  test('an adopted copy with no resolve is not reported as landed; a published one is', () async {
    final f = await w.picked();
    final file = w.write('p1.canvas', 'current');
    final h = contentHash(b('theirs')).substring(0, 8);
    w.write('p1-icloud-$h.canvas', 'theirs'); // already there: adopted
    w.channel.addVersion(file.path, b('theirs'));
    w.channel.resolveFails = true;
    final landed = <VersionLanding>[];
    f.onLanded = landed.add;
    await f.landVersions([file.path]);
    expect(landed, isEmpty, reason: 'nothing published, nothing resolved');
    w.channel.resolveFails = false;
    await f.landVersions([file.path]);
    expect(landed.single.resolved, 1);
    expect(landed.single.published, isEmpty, reason: 'the copy was adopted, not made now');
    // A new version: its copy is published here and reported.
    w.channel.addVersion(file.path, b('another'));
    await f.landVersions([file.path]);
    expect(landed.last.published, hasLength(1));
  });

  test('a row raised for a temp that could not be placed stays while the temp is there; the file\'s own empty landing keeps it', () async {
    final f = await w.picked();
    final att = w.write('p1.assets/${name()}', 'damaged');
    // The set-aside name of the damaged bytes is taken, so the temp can't be placed.
    final blocker = w.write('p1.assets/${damagedCopyName(name(), contentHash(b('damaged')))}', 'x');
    w.write('p1.assets/.${name()}.noted-version-0123456789abcdef.tmp', good);
    for (var i = 0; i < 3; i++) {
      await f.landVersions([att.path]);
    }
    expect(f.versionsStuck(att.path), isTrue);
    // The file has no versions: its own landing finds nothing and keeps the row.
    expect(w.channel.unresolvedOf(att.path), isEmpty);
    await f.landVersions([att.path]);
    expect(f.versionsStuck(att.path), isTrue, reason: 'the temp is still there');
    expect(temps('p1.assets'), hasLength(1));
    // The block goes: the temp is placed, and the row goes with it.
    blocker.deleteSync();
    await f.landVersions([att.path]);
    expect(temps('p1.assets'), isEmpty);
    expect(att.readAsStringSync(), good);
    await f.landVersions([att.path]);
    expect(f.versionIssues, isEmpty);
  });
}
