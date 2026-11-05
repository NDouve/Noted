// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart' show saveBeforeExit;
import 'package:noted_core/noted_core.dart';

import 'support/trouble_world.dart';

void main() {
  late TroubleWorld w;

  setUp(() async {
    w = TroubleWorld();
    await w.init();
  });

  tearDown(() => w.dispose());

  test(
    'a cancelled quit keeps the pending delete, so Undo still works',
    () async {
      final nb = w.make();
      await nb.load();
      final gone = nb.currentId!;
      final open = await nb.createPage();
      final deleted = await nb.delete(gone);
      expect(nb.isPendingDelete(deleted), isTrue);
      expect(w.pageFile(gone).existsSync(), isFalse);
      // The open page's save and the recovery write both fail: quitting asks.
      nb.current!.createBoxAt(const Bounds(40, 40, 0, 0));
      await w.rec.parent.create(recursive: true);
      File(w.rec.path).writeAsStringSync('in the way');
      w.storeFor(w.pages).failWith = accessDenied();
      await nb.flush();
      var answer = false;
      nb.questioner = (q, t) async => answer;
      expect(
        await saveBeforeExit(nb),
        isFalse,
        reason: 'Cancel: the exit is cancelled',
      );
      expect(nb.currentId, open);
      expect(
        nb.isPendingDelete(deleted),
        isTrue,
        reason: 'nothing was dropped',
      );
      w.storeFor(w.pages).failWith = null;
      await nb.undoDelete(deleted);
      expect(
        w.pageFile(gone).existsSync(),
        isTrue,
        reason: 'Undo still brings the page back',
      );
      // Quitting anyway drops what Undo could reach.
      final again = await nb.delete(gone);
      w.storeFor(w.pages).failWith = accessDenied();
      nb.current!.createBoxAt(const Bounds(90, 90, 0, 0));
      await nb.flush();
      answer = true;
      expect(await saveBeforeExit(nb), isTrue);
      expect(nb.isPendingDelete(again), isFalse);
    },
  );
}
