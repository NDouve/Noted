// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Cloud parity step 6: landing the iCloud versions of a file (R5.8), the
// `pending` answer and the busy paths that retry after it (R5.4, R5.16), the
// versions that can't be landed, and the attachment and template rules, against
// the fake channel (versions are associated with file paths).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/icloud_folders.dart';
import 'package:noted_core/noted_core.dart';

import 'support/fake_cloud_folder_channel.dart';
import 'support/icloud_world.dart';

void main() {
  late IcloudWorld w;
  late FakeCloudFolderChannel channel;

  setUp(() async {
    w = IcloudWorld();
    await w.init();
    channel = w.channel;
  });
  tearDown(() => w.dispose());

  List<int> b(String s) => utf8.encode(s);
  String slashes(String s) => s.replaceAll(r'\', '/');
  String h8(String s) => contentHash(b(s)).substring(0, 8);
  String h16(String s) => contentHash(b(s)).substring(0, 16);
  List<String> temps() => [for (final n in w.names()) if (n.contains('.noted-version-')) n];
  String text(String relative) => File(w.path(relative)).readAsStringSync();

  group('landing a version (R5.8)', () {
    test('it is copied to a temp in the target\'s folder, published by its hash, verified, then resolved', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      final seen = <String>[];
      channel.onVersions = (path, tmps) => seen.addAll(tmps);
      final landed = <VersionLanding>[];
      f.onLanded = landed.add;
      f.landingStep = (step, path) async {
        if (step == 'resolved') {
          expect(File(w.path('p1-icloud-${h8('theirs')}.canvas')).readAsStringSync(), 'theirs', reason: 'published before it is resolved');
        }
      };
      await f.landVersions([file.path]);
      expect(text('p1-icloud-${h8('theirs')}.canvas'), 'theirs');
      expect(text('p1.canvas'), 'current');
      expect(channel.unresolvedOf(file.path), isEmpty);
      expect(seen.single, matches(RegExp(r'[\\/]\.p1\.canvas\.noted-version-[0-9a-f]{16}\.tmp$')));
      expect(File(seen.single).parent.path, w.drive.path, reason: 'the temp is in the target\'s own folder');
      expect(temps(), isEmpty);
      expect(landed.single.published.map(slashes), [slashes(w.path('p1-icloud-${h8('theirs')}.canvas'))]);
      expect(landed.single.resolved, 1);
      expect(channel.methods, isNot(contains('removeOtherVersions')));
      expect(f.versionIssues, isEmpty);
    });

    test('a binder file lands as noted-binder-icloud-<h>.json', () async {
      final f = await w.picked();
      final file = w.write('noted-binder.json', 'binder A');
      channel.addVersion(file.path, b('binder B'));
      await f.landVersions([file.path]);
      expect(text('noted-binder-icloud-${h8('binder B')}.json'), 'binder B');
      expect(channel.unresolvedOf(file.path), isEmpty);
    });

    test('a version equal to the current file is resolved with no copy', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'same');
      channel.addVersion(file.path, b('same'));
      await f.landVersions([file.path]);
      expect(w.names(), ['p1.canvas']);
      expect(channel.unresolvedOf(file.path), isEmpty);
    });

    test('an equal file already under the name is adopted and the temp removed', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      w.write('p1-icloud-${h8('theirs')}.canvas', 'theirs');
      channel.addVersion(file.path, b('theirs'));
      await f.landVersions([file.path]);
      expect(w.names(), unorderedEquals(['p1-icloud-${h8('theirs')}.canvas', 'p1.canvas']));
      expect(channel.unresolvedOf(file.path), isEmpty);
    });

    test('an unequal file under the 8-hex name sends it to the 16-hex name', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      w.write('p1-icloud-${h8('theirs')}.canvas', 'something else');
      channel.addVersion(file.path, b('theirs'));
      await f.landVersions([file.path]);
      expect(text('p1-icloud-${h16('theirs')}.canvas'), 'theirs');
      expect(text('p1-icloud-${h8('theirs')}.canvas'), 'something else');
      expect(channel.unresolvedOf(file.path), isEmpty);
    });

    test('a version is resolved only after the copy is read back equal', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      f.landingStep = (step, path) async {
        if (step == 'published') File(w.path('p1-icloud-${h8('theirs')}.canvas')).writeAsStringSync('changed meanwhile');
      };
      await f.landVersions([file.path]);
      expect(channel.unresolvedOf(file.path), hasLength(1), reason: 'not resolved: the copy did not verify');
      expect(channel.callsOf('resolveVersion'), isEmpty);
    });

    test('the same version landed again gives the same copy (a restart)', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      final id = channel.addVersion(file.path, b('theirs'));
      channel.resolveFails = true;
      await f.landVersions([file.path]);
      expect(channel.unresolvedOf(file.path).single.id, id);
      expect(w.names(), unorderedEquals(['p1-icloud-${h8('theirs')}.canvas', 'p1.canvas']));
      channel.resolveFails = false;
      await f.landVersions([file.path]);
      expect(w.names(), unorderedEquals(['p1-icloud-${h8('theirs')}.canvas', 'p1.canvas']), reason: 'one copy, adopted');
      expect(channel.unresolvedOf(file.path), isEmpty);
    });

    test('a failed copy is not resolved and leaves nothing', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      channel.versionsOf(file.path).single.copyFails = true;
      final landed = <VersionLanding>[];
      f.onLanded = landed.add;
      await f.landVersions([file.path]);
      expect(w.names(), ['p1.canvas']);
      expect(channel.unresolvedOf(file.path), hasLength(1));
      expect(landed, isEmpty);
    });
  });

  group('leftover version temps', () {
    test('a temp equal to its copy is removed (checked), any other is published by its own hash', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      w.write('p1-icloud-${h8('theirs')}.canvas', 'theirs');
      w.write('.p1.canvas.noted-version-0123456789abcdef.tmp', 'theirs');
      w.write('.p1.canvas.noted-version-fedcba9876543210.tmp', 'another');
      await f.landVersions([file.path]);
      expect(w.names(), unorderedEquals(['p1-icloud-${h8('another')}.canvas', 'p1-icloud-${h8('theirs')}.canvas', 'p1.canvas']));
      expect(text('p1-icloud-${h8('another')}.canvas'), 'another');
    });

    test('a temp holding the current file\'s bytes is removed', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      w.write('.p1.canvas.noted-version-0123456789abcdef.tmp', 'current');
      await f.landVersions([file.path]);
      expect(w.names(), ['p1.canvas']);
    });

    test('a temp is kept and listed when both copy names are taken by unequal files', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      w.write('p1-icloud-${h8('theirs')}.canvas', 'x');
      w.write('p1-icloud-${h16('theirs')}.canvas', 'y');
      w.write('.p1.canvas.noted-version-0123456789abcdef.tmp', 'theirs');
      await f.landVersions([file.path]);
      expect(temps(), hasLength(1));
      expect(f.versionIssues.single.text, "iCloud holds versions of p1.canvas that Noted can't keep yet");
    });

    test('a crash after the copy leaves a temp that the next landing publishes by its hash', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      f.landingStep = (step, path) async {
        if (step == 'copied') throw StateError('killed');
      };
      await f.landVersions([file.path]);
      expect(temps(), hasLength(1));
      f.dispose();
      final g = await w.relaunched();
      await g.landVersions([file.path]);
      expect(temps(), isEmpty);
      expect(text('p1-icloud-${h8('theirs')}.canvas'), 'theirs');
      expect(channel.unresolvedOf(file.path), isEmpty);
    });
  });

  group('crash at each landing step, then a reload: every version is a page or a listed copy', () {
    for (final step in ['copied', 'published', 'verified', 'resolved']) {
      test('killed after $step', () async {
        final f = await w.picked();
        final file = w.write('p1.canvas', 'current');
        channel.addVersion(file.path, b('theirs'));
        f.landingStep = (s, path) async {
          if (s == step) throw StateError('killed');
        };
        await f.landVersions([file.path]);
        // Whatever stopped: a resolved version always has its copy.
        if (channel.unresolvedOf(file.path).isEmpty) {
          expect(text('p1-icloud-${h8('theirs')}.canvas'), 'theirs');
        }
        f.dispose();
        final g = await w.relaunched();
        await g.landAllVersions();
        expect(channel.unresolvedOf(file.path), isEmpty);
        expect(text('p1-icloud-${h8('theirs')}.canvas'), 'theirs');
        expect(w.names().where((n) => n.contains('-icloud-')), hasLength(1));
        expect(temps(), isEmpty);
        expect(text('p1.canvas'), 'current');
      });
    }
  });

  group('a leftover\'s versions (B2)', () {
    test('the copy is named after the leftover\'s target, and the folder is swept again only after one resolved', () async {
      final f = await w.picked();
      w.write('p1.canvas', 'newer');
      final left = w.write('p1.canvas.1a2b3c.cas-old', 'older');
      channel.addVersion(left.path, b('theirs'));
      final landed = <VersionLanding>[];
      f.onLanded = landed.add;
      // The sweep names the leftover as a move and is told `pending`.
      expect(await sweepAsideFiles(w.drive), isEmpty);
      expect(left.existsSync(), isTrue, reason: 'nothing consumed');
      await waitFor(() => channel.unresolvedOf(left.path).isEmpty, what: 'the landing');
      expect(text('p1-icloud-${h8('theirs')}.canvas'), 'theirs');
      expect(landed.single.leftover, isTrue);
      expect(landed.single.resolved, 1);
      // Now the leftover can be consumed.
      final out = await sweepAsideFiles(w.drive);
      expect(out, isNotEmpty);
      expect(left.existsSync(), isFalse);
      expect(w.names().where((n) => n.contains('-recovered-')), hasLength(1));
    });

    test('a landing that resolved nothing does not ask for another sweep', () async {
      final f = await w.picked();
      w.write('p1.canvas', 'newer');
      final left = w.write('p1.canvas.1a2b3c.cas-old', 'older');
      channel.addVersion(left.path, b('theirs'));
      channel.versionsOf(left.path).single.copyFails = true;
      final landed = <VersionLanding>[];
      f.onLanded = landed.add;
      await f.landVersions([left.path]);
      expect(landed, isEmpty);
    });

    test('a leftover appearing between the listing and the call waits for the next sweep', () async {
      await w.picked();
      w.write('p1.canvas', 'newer');
      final left = w.write('p1.canvas.1a2b3c.cas-old', 'older');
      final other = File(w.path('p2.canvas.4d5e6f.cas-old'));
      channel.onCoordinate = (id, intents) {
        if (!other.existsSync()) other.writeAsStringSync('late');
      };
      final out = await sweepAsideFiles(w.drive);
      expect(out, isNotEmpty);
      expect(left.existsSync(), isFalse);
      expect(other.existsSync(), isTrue, reason: 'left for the next sweep');
    });
  });

  group('pending: the busy path retries after the landing (R5.4, R5.8)', () {
    test('a delete is refused while a version is unresolved, nothing is lost, and it succeeds after the landing', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      await expectLater(
        deleteFileIfMatches(file.path, bytes: b('current')),
        throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.versionsPending)),
      );
      expect(file.existsSync(), isTrue);
      await waitFor(() => channel.unresolvedOf(file.path).isEmpty, what: 'the landing');
      expect(f.versionIssues, isEmpty);
      final r = await deleteFileIfMatches(file.path, bytes: b('current'));
      expect(r.outcome, DeleteOutcome.deleted);
      expect(text('p1-icloud-${h8('theirs')}.canvas'), 'theirs', reason: 'the version is a page copy');
    });

    test('replaceIfUnchanged is pending, then lands after the landing', () async {
      await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      final tmp = w.write('p1.tmp-new', 'next');
      await expectLater(
        replaceIfUnchanged(tmp, file.path, b('current')),
        throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.versionsPending)),
      );
      expect(text('p1.canvas'), 'current');
      await waitFor(() => channel.unresolvedOf(file.path).isEmpty, what: 'the landing');
      final r = await replaceIfUnchanged(tmp, file.path, b('current'));
      expect(r.outcome, ReplaceOutcome.replaced);
      expect(text('p1.canvas'), 'next');
    });

    test('the landing is its own later turn: it never runs inside the refused call\'s turn', () async {
      await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      await w.locks.run(w.drive, () async {
        await expectLater(
          deleteFileIfMatches(file.path, bytes: b('current')),
          throwsA(isA<StorageBusy>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(channel.callsOf('versions'), isEmpty, reason: 'it waits for the caller\'s turn to end');
      });
      await waitFor(() => channel.unresolvedOf(file.path).isEmpty, what: 'the landing');
    });

    test('a whole-folder move is pending while a nested attachment has a version, and keeps everything', () async {
      final f = await w.picked();
      final good = 'attachment bytes';
      final name = '${contentHash(b(good))}.png';
      w.write('p1.canvas', 'page');
      final att = w.write('p1.assets/$name', good);
      channel.addVersion(att.path, b(good));
      final from = w.path('p1.assets');
      final to = w.path('moved.assets');
      expect(
        await moveExclusive(from, to, alsoMoved: [att.path]),
        MoveOutcome.busy,
      );
      expect(Directory(from).existsSync(), isTrue);
      expect(Directory(to).existsSync(), isFalse);
      await waitFor(() => channel.unresolvedOf(att.path).isEmpty, what: 'the landing');
      expect(await moveExclusive(from, to, alsoMoved: [att.path]), MoveOutcome.moved);
      expect(File('$to/$name').readAsStringSync(), good);
      expect(f.versionIssues, isEmpty);
    });
  });

  group('versions that can\'t be landed', () {
    test('both names taken by unequal files: listed, stays pending, and an open page\'s edit is kept in recovery', () async {
      final f = await w.picked();
      final nb = w.notebook(f);
      await nb.load();
      final id = nb.currentId!;
      await nb.flush();
      final file = File(w.path('$id.canvas'));
      final current = file.readAsStringSync();
      final theirs = 'theirs: not a page';
      w.write('$id-icloud-${h8(theirs)}.canvas', 'x');
      w.write('$id-icloud-${h16(theirs)}.canvas', 'y');
      channel.addVersion(file.path, b(theirs));
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await nb.flush();
      await waitFor(() => f.versionsStuck(file.path), what: 'the row');
      await nb.retrySave();
      expect(f.versionIssues.single.text, "iCloud holds versions of $id.canvas that Noted can't keep yet");
      expect(nb.discoveryNotes.map((n) => n.reason), contains("iCloud holds versions of $id.canvas that Noted can't keep yet"));
      expect(nb.trouble.isTrouble, isTrue);
      expect(nb.trouble.reason, "iCloud holds versions of $id.canvas that Noted can't keep yet");
      expect((await nb.pendingRecovery()).entries, hasLength(1));
      expect(file.readAsStringSync(), current, reason: 'nothing written over it');
      expect(channel.unresolvedOf(file.path), hasLength(1));
      // Every delete stays pending.
      await expectLater(
        deleteFileIfMatches(file.path, bytes: b(current)),
        throwsA(isA<StorageBusy>().having((e) => e.reason, 'reason', StorageBusyReason.versionsPending)),
      );
      expect(file.existsSync(), isTrue);
    });

    test('each change event and each launch try the landing again; a freed name lands it and clears the row', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      w.write('p1-icloud-${h8('theirs')}.canvas', 'x');
      final blocker = w.write('p1-icloud-${h16('theirs')}.canvas', 'y');
      channel.addVersion(file.path, b('theirs'));
      await f.landVersions([file.path]);
      expect(f.versionIssues, hasLength(1));
      final tries = channel.callsOf('versions').length;
      blocker.deleteSync();
      await channel.emit('changed', {'path': file.path});
      await waitFor(() => f.versionIssues.isEmpty, what: 'the row to go');
      expect(channel.callsOf('versions').length, greaterThan(tries));
      expect(text('p1-icloud-${h16('theirs')}.canvas'), 'theirs');
      expect(channel.unresolvedOf(file.path), isEmpty);

      // A launch: still stuck, listed again, nothing deleted.
      final other = w.write('p2.canvas', 'current 2');
      w.write('p2-icloud-${h8('t2')}.canvas', 'x');
      w.write('p2-icloud-${h16('t2')}.canvas', 'y');
      channel.addVersion(other.path, b('t2'));
      f.dispose();
      final g = await w.relaunched();
      await g.landAllVersions();
      expect(slashes(g.versionIssues.single.path), slashes(other.path));
      expect(other.existsSync(), isTrue);
    });

    test('a landing refused three times in a row makes the row, one that works clears it', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      channel.resolveFails = true;
      await f.landVersions([file.path]);
      await f.landVersions([file.path]);
      expect(f.versionIssues, isEmpty);
      await f.landVersions([file.path]);
      expect(f.versionsStuck(file.path), isTrue);
      channel.resolveFails = false;
      await f.landVersions([file.path]);
      expect(f.versionIssues, isEmpty);
      expect(channel.unresolvedOf(file.path), isEmpty);
    });

    test('a failing versions call is a refusal, never a throw', () async {
      final f = await w.picked();
      final file = w.write('p1.canvas', 'current');
      channel.addVersion(file.path, b('theirs'));
      channel.versionsFails = true;
      await f.landVersions([file.path]);
      expect(file.existsSync(), isTrue);
    });
  });

  group('attachments by hash', () {
    final good = 'attachment bytes';
    String name() => '${contentHash(b(good))}.png';

    test('a version holding the bytes of the name replaces a damaged file; the damaged one is kept', () async {
      final f = await w.picked();
      final att = w.write('p1.assets/${name()}', 'damaged');
      channel.addVersion(att.path, b(good));
      await f.landVersions([att.path]);
      expect(text('p1.assets/${name()}'), good);
      final kept = w.names('p1.assets').where((n) => n.contains('.damaged-'));
      expect(kept, hasLength(1));
      expect(text('p1.assets/${kept.single}'), 'damaged');
      expect(channel.unresolvedOf(att.path), isEmpty);
      expect(w.names('p1.assets').where((n) => n.contains('noted-version')), isEmpty);
      expect(f.versionIssues, isEmpty);
    });

    test('a version that matches the name while the file does too is resolved, nothing else happens', () async {
      final f = await w.picked();
      final att = w.write('p1.assets/${name()}', good);
      channel.addVersion(att.path, b(good));
      await f.landVersions([att.path]);
      expect(w.names('p1.assets'), [name()]);
      expect(channel.unresolvedOf(att.path), isEmpty);
    });

    test('any other version stays unresolved; its row has the action, which hides it until the version changes', () async {
      final f = await w.picked();
      final att = w.write('p1.assets/${name()}', good);
      channel.addVersion(att.path, b('some other bytes'));
      await f.landVersions([att.path]);
      expect(channel.unresolvedOf(att.path), hasLength(1));
      expect(w.names('p1.assets'), [name()], reason: 'no temp is left');
      final row = f.versionIssues.single;
      expect(row.text, 'iCloud holds another version of ${name()}');
      expect(row.keepable, isTrue);
      expect(keepInICloudText, 'Keep it in iCloud');
      f.keepInICloud(att.path);
      expect(f.versionIssues, isEmpty);
      // The same version again: still hidden.
      await f.landVersions([att.path]);
      expect(f.versionIssues, isEmpty);
      // A new version: the row is back.
      channel.addVersion(att.path, b('yet another'));
      await f.landVersions([att.path]);
      expect(f.versionIssues, hasLength(1));
    });

    test('a leftover temp holding the name\'s bytes is published when the file is missing', () async {
      final f = await w.picked();
      Directory(w.path('p1.assets')).createSync();
      w.write('p1.assets/.${name()}.noted-version-0123456789abcdef.tmp', good);
      w.write('p1.canvas', 'page');
      await f.landVersions([w.path('p1.canvas')]);
      // The temps of every file in the folder are looked at when its file is landed; the assets folder is its own.
      await f.landVersions([w.path('p1.assets/${name()}')]);
      expect(w.names('p1.assets'), [name()]);
      expect(text('p1.assets/${name()}'), good);
    });
  });

  group('templates', () {
    test('are listed with no action and left unresolved', () async {
      final f = await w.picked();
      final t = w.write('Meeting.notedtemplate', 'template');
      channel.addVersion(t.path, b('other template'));
      await f.landVersions([t.path]);
      expect(channel.unresolvedOf(t.path), hasLength(1));
      expect(w.names(), ['Meeting.notedtemplate'], reason: 'no copy and no temp');
      final row = f.versionIssues.single;
      expect(row.text, 'iCloud holds another version of Meeting.notedtemplate');
      expect(row.keepable, isFalse);
    });
  });

  group('the launch pass', () {
    test('lands the versions of every page and binder file in a root, nested folders included', () async {
      (await w.picked()).dispose();
      final a = w.write('a.canvas', 'a');
      final c = w.write('Binder/c.canvas', 'c');
      final bf = w.write('Binder/noted-binder.json', 'binder');
      for (final p in [a, c, bf]) {
        channel.addVersion(p.path, b('v of ${p.uri.pathSegments.last}'));
      }
      final g = await w.relaunched();
      await g.landAllVersions();
      for (final p in [a, c, bf]) {
        expect(channel.unresolvedOf(p.path), isEmpty);
      }
      expect(w.names('Binder').where((n) => n.contains('-icloud-')), hasLength(2));
    });
  });

  test('the notebook looks at the landed copy: its box is merged into the page (0053)', () async {
    final f = await w.picked();
    final nb = w.notebook(f);
    await nb.load();
    final id = nb.currentId!;
    await nb.flush();
    final file = File(w.path('$id.canvas'));
    // The other version is the same page with a box the page doesn't have.
    final box = BoxRecord.create(
      id: '00000000000000b1',
      typeId: 'x.unregistered',
      dataVersion: 1,
      bounds: const Bounds(300, 300, 10, 10),
      data: const RawJson.trusted('{"k":1}'),
      snapshotText: 's',
      rev: 'r',
    );
    final theirs = writePage(readPage(file.readAsStringSync()).insertNode(box));
    expect(nb.current!.page.node(box.id), isNull);
    channel.addVersion(file.path, b(theirs));
    await f.landVersions([file.path]);
    expect(w.names().where((n) => n.contains('-icloud-')), hasLength(1));
    // Only the notebook's look at the new copy can bring the box in.
    await waitFor(() => nb.current!.page.node(box.id) != null, what: 'the copy to be merged');
  });
}
