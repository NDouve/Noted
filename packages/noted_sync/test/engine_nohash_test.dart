// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_sync/noted_sync.dart';

import 'fake_graph.dart';
import 'harness.dart';

/// A driver with no server hash (what WebDAV is): the Graph fake underneath,
/// with every checksum left out of the listing. The version is the item's
/// cTag, standing for the ETag.
class NoHashDriver implements RemoteDriver {
  NoHashDriver(this.inner);

  final GraphDriver inner;

  /// Makes every download fail as if the version moved meanwhile.
  bool changeDuringDownload = false;

  /// Makes every download fail with this status.
  int? refuseWith;

  @override
  String get provider => 'nohash';
  @override
  String get displayName => 'NoHash';
  @override
  String get rootId => inner.rootId;
  @override
  RemoteCaps get caps => const RemoteCaps(serverHash: false, fullListing: true);
  @override
  Future<RemoteItem> root() => inner.root();
  @override
  Future<List<RemoteItem>> children(String itemId) => inner.children(itemId);
  @override
  Future<List<RemoteItem>> listFolders({String? parentItemId}) =>
      inner.listFolders(parentItemId: parentItemId);
  @override
  Future<FolderHint> folderHint(String itemId) => inner.folderHint(itemId);

  @override
  Future<RemoteFetch?> fetch(
    Map<String, RemoteEntry> map,
    String? cursor,
    String? endpoint,
    int seq,
  ) async {
    final f = await inner.fetch(map, cursor, endpoint, seq);
    if (f == null) return null;
    return RemoteFetch(
      map: {
        for (final e in f.map.entries)
          e.key: RemoteEntry(
            id: e.value.id,
            parent: e.value.parent,
            name: e.value.name,
            folder: e.value.folder,
            special: e.value.special,
            cTag: e.value.cTag,
            size: e.value.size,
            seq: e.value.seq,
          ),
      },
      cursor: f.cursor,
      endpoint: f.endpoint,
      seq: f.seq,
      resync: f.resync,
    );
  }

  @override
  Future<void> download(RemoteEntry entry, File dest) {
    if (changeDuringDownload) {
      throw RemoteChanged('The version moved during the download');
    }
    final status = refuseWith;
    if (status == 401) throw RemoteUnauthorized('Refused');
    if (status != null) {
      throw RemoteException('Refused', statusCode: status);
    }
    return inner.download(entry, dest);
  }
}

/// B1: adopting a file with no server hash, by a version-checked download.
void main() {
  late Harness h;
  late NoHashDriver driver;
  setUp(() async {
    h = await Harness.create();
    driver = NoHashDriver(
      GraphDriver(
        graph: h.newGraph(),
        driveId: FakeGraph.driveId,
        rootItemId: h.rootId,
      ),
    );
    h.engine = h.newEngine(driver: driver);
  });
  tearDown(() => h.close());

  void seedMany(int n) {
    for (var i = 0; i < n; i++) {
      h.fake.addFile('Noted/p$i.canvas', Harness.b('page $i'));
    }
  }

  Map<String, dynamic> journal() =>
      jsonDecode(File('${h.state.path}/journal.json').readAsStringSync())
          as Map<String, dynamic>;

  test('a plain pull works without a server hash', () async {
    seedMany(3);
    final r = await h.round();
    expect(r.error, isNull);
    expect(h.tree(), hasLength(3));
    expect(h.read('p1.canvas'), 'page 1');
    expect(h.engine.issues, isEmpty);
  });

  test('a new file published, journal old: adopted after one download', () async {
    seedMany(3);
    var seen = 0;
    h.engine = h.newEngine(
      driver: driver,
      onStep: (s) {
        if (s == 'published' && ++seen == 1) throw Killed(s);
      },
    );
    final r = await h.round();
    expect(r.error, isA<Killed>());
    expect(h.tree(), hasLength(1));
    h.engine = h.newEngine(driver: driver);
    final before = h.contentRequests();
    await h.round();
    expect(h.tree(), hasLength(3));
    expect(h.engine.issues, isEmpty);
    // One download to compare the file already there, two for the new ones.
    expect(h.contentRequests() - before, 3);
    expect(h.stateFiles('tmp'), isEmpty);
  });

  test('a differing local file is listed, not adopted, and not downloaded again', () async {
    h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
    h.write('a.canvas', 'BBB');
    await h.round();
    expect(h.read('a.canvas'), 'BBB');
    expect(h.engine.issues, hasIssue('a.canvas'));
    expect(h.issueText().single, contains('different file'));
    expect(h.contentRequests(), 1);
    expect(h.stateFiles('tmp'), isEmpty);
    expect((journal()['files'] as Map), isEmpty);

    await h.round();
    await h.round();
    expect(h.contentRequests(), 1, reason: 'same id, ETag and local identity');

    // The local file changes: asked again.
    h.write('a.canvas', 'CCC');
    await h.round();
    expect(h.contentRequests(), 2);
    // The remote changes: asked again.
    h.fake.replaceFile('Noted/a.canvas', Harness.b('DDD'));
    await h.round();
    expect(h.contentRequests(), 3);
    expect(h.read('a.canvas'), 'CCC');
  });

  test('a local file equal to the remote one is adopted once, then nothing is downloaded', () async {
    h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
    h.write('a.canvas', 'AAA');
    await h.round();
    expect(h.engine.issues, isEmpty);
    expect((journal()['files'] as Map).containsKey('a.canvas'), isTrue);
    expect(h.contentRequests(), 1);
    await h.round();
    expect(h.contentRequests(), 1);
  });

  test('a version that moves during the download is retried, listed after 3 in a row, not counted as a mismatch', () async {
    h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
    driver.changeDuringDownload = true;
    await h.round();
    await h.round();
    expect(h.engine.issues, isEmpty);
    expect(h.has('a.canvas'), isFalse);
    expect(h.engine.status.state, SyncState.idle);
    await h.round();
    expect(h.engine.issues, hasIssue('a.canvas'));
    expect(journal()['mismatches'], isEmpty);
    expect(h.engine.status.state, SyncState.idle);
    driver.changeDuringDownload = false;
    await h.round();
    expect(h.read('a.canvas'), 'AAA');
    expect(h.engine.issues, isEmpty);
  });

  test('a per-file refusal skips only that item', () async {
    h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
    driver.refuseWith = 403;
    final r = await h.round();
    expect(r.error, isNull);
    expect(h.engine.issues, hasIssue('a.canvas'));
    expect(h.engine.status.state, SyncState.idle);
  });

  test('a 401 from a driver is signed out', () async {
    h.fake.addFile('Noted/a.canvas', Harness.b('AAA'));
    driver.refuseWith = 401;
    final r = await h.round();
    expect(r.error, isA<RemoteException>());
    expect(h.engine.status.state, SyncState.signedOut);
  });
}
