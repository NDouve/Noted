// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/noted_core.dart';
import 'package:noted_sync/noted_sync.dart';

/// Against a real WebDAV server (for example a Nextcloud), read only. Runs
/// only when `NOTED_WEBDAV_URL` (the folder to read), `NOTED_WEBDAV_USER` and
/// `NOTED_WEBDAV_PASSWORD` (an app password) are set in the environment;
/// skipped otherwise. Nothing is ever written to the server, and no
/// credential is kept anywhere.
void main() {
  final env = Platform.environment;
  final url = env['NOTED_WEBDAV_URL'] ?? '';
  final user = env['NOTED_WEBDAV_USER'] ?? '';
  final password = env['NOTED_WEBDAV_PASSWORD'] ?? '';
  final configured = url.isNotEmpty && user.isNotEmpty && password.isNotEmpty;

  group(
    'a real WebDAV server',
    skip: configured
        ? false
        : 'Set NOTED_WEBDAV_URL, NOTED_WEBDAV_USER and NOTED_WEBDAV_PASSWORD',
    () {
      late WebDavClient client;
      late Directory tmp;
      setUp(() {
        client = WebDavClient(
          root: Uri.parse(url),
          user: user,
          password: password,
          allowLoopbackHttp: true,
        );
        tmp = Directory.systemTemp.createTempSync('davserver');
      });
      tearDown(() {
        client.close();
        tmp.deleteSync(recursive: true);
      });

      test('connects, and says what ids and versions it gives', () async {
        final d = await WebDavDriver.connect(client);
        expect(d.provider, 'webdav');
        expect(d.rootId, isNotEmpty);
        // The kind goes in the log of the run, not the credentials.
        // ignore: avoid_print
        print('id kind: ${d.idKind.wire}');
      });

      test('two walks agree, and every file reads back as listed', () async {
        final d = await WebDavDriver.connect(client);
        final one = (await d.fetch({}, null, null, 0))!;
        final two = (await d.fetch(
          one.map,
          one.cursor,
          one.endpoint,
          one.seq,
        ))!;
        expect(two.map.keys.toSet(), one.map.keys.toSet());
        for (final e in one.map.values) {
          expect(two.map[e.id]!.cTag, e.cTag, reason: e.name);
          expect(two.map[e.id]!.seq, e.seq, reason: e.name);
        }
        var read = 0;
        for (final e in one.map.values.where(
          (e) => !e.folder && e.size < (1 << 20),
        )) {
          if (read++ >= 5) break;
          final f = File('${tmp.path}/f$read');
          await d.download(e, f);
          expect(f.lengthSync(), e.size, reason: e.name);
        }
      });

      test('a pull into an empty folder, then a quiet poll', () async {
        final d = await WebDavDriver.connect(client);
        final work = Directory('${tmp.path}/work')..createSync();
        final state = Directory('${tmp.path}/state');
        final engine = PullEngine(
          workingCopy: work,
          stateDir: state,
          locks: FolderLocks(),
          driver: d,
        );
        final first = await engine.runRound();
        expect(first.error, isNull);
        expect(engine.status.state, SyncState.idle);
        final second = await engine.runRound();
        expect(second.error, isNull);
        expect(second.changedPaths, isEmpty);
        engine.dispose();
      });
    },
  );
}
