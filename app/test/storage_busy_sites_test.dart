// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The N4 sites and the C2 handlers (cloud parity R5.4): every create, remove
// and write of a notebook folder that is not a primitive goes through
// `coordinated()`, and a coordinator that refuses (`StorageBusy`) never makes a
// handler fall back to an uncoordinated write. Each test registers a coordinator
// over the test folder that refuses one kind of call, and checks that nothing
// was written another way and the folder is as it was.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/attachment_copy.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_core/noted_core.dart';

import 'support/scripted_coordinator.dart';

void main() {
  late Directory root;
  late Directory pages;
  late List<Notebook> opened;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('noted_busy');
    pages = await Directory('${root.path}/pages').create();
    opened = [];
  });
  tearDown(() async {
    attachmentPublishHook = null;
    for (final nb in opened) {
      await nb.flush();
      nb.dispose();
    }
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  final name = attachmentFileName(contentHash(bytes), 'txt');
  final hash = contentHash(bytes);

  bool isWriteOn(CoordinatedWrite w, String path) => isOneWriteOn(w, path);

  group(
    'attachment_copy.dart (C2: a refusal is never a failure to fall back from)',
    () {
      test('a publish the folder refused is not a volume without hard links: no create-and-fill follows', () async {
        final dir = Directory('${root.path}/f')..createSync();
        final c = ScriptedCoordinator();
        registerScripted(root, c);
        attachmentPublishHook = (tmp, target) async =>
            throw StorageBusy(StorageBusyReason.coordination, [target]);
        await expectLater(
          writeNewAttachmentFile(File('${dir.path}/$name'), bytes, hash),
          throwsA(isA<StorageBusy>()),
        );
        expect(
          File('${dir.path}/$name').existsSync(),
          isFalse,
          reason: 'nothing was created at the name',
        );
        expect(
          dir.listSync(),
          isEmpty,
          reason: 'the temporary file is removed',
        );
        expect(c.calls, isEmpty, reason: 'no other call was tried');
      });

      test('_createExclusive: the create is one write on the folder, and a refusal makes nothing', () async {
        final dir = Directory('${root.path}/f')..createSync();
        final c = ScriptedCoordinator()..refuse = (w) => isWriteOn(w, dir.path);
        registerScripted(root, c);
        // A volume without hard links: the publish fails, the create-and-fill runs.
        attachmentPublishHook = (tmp, target) async =>
            throw const FileSystemException('no hard links');
        await expectLater(
          writeNewAttachmentFile(File('${dir.path}/$name'), bytes, hash),
          throwsA(isA<StorageBusy>()),
        );
        expect(File('${dir.path}/$name').existsSync(), isFalse);
        expect(dir.listSync(), isEmpty);
        expect(c.calls.where((w) => isWriteOn(w, dir.path)), hasLength(1));
      });

      test(
        '_createExclusive: a refused fill takes the empty file away again',
        () async {
          final dir = Directory('${root.path}/f')..createSync();
          final c = ScriptedCoordinator();
          c.refuse = (w) =>
              isWriteOn(w, dir.path) &&
              c.calls.where((x) => isWriteOn(x, dir.path)).length == 2;
          registerScripted(root, c);
          attachmentPublishHook = (tmp, target) async =>
              throw const FileSystemException('no hard links');
          await expectLater(
            writeNewAttachmentFile(File('${dir.path}/$name'), bytes, hash),
            throwsA(isA<StorageBusy>()),
          );
          expect(
            File('${dir.path}/$name').existsSync(),
            isFalse,
            reason: 'an empty file is not left at the hash name',
          );
          expect(dir.listSync(), isEmpty);
        },
      );

      test('copyAttachmentTree: a refused create of the target folder makes nothing and copies nothing', () async {
        final from = Directory('${root.path}/from')..createSync();
        File('${from.path}/$name').writeAsBytesSync(bytes);
        final to = Directory('${root.path}/to');
        final c = ScriptedCoordinator()
          ..refuse = (w) => isWriteOn(w, root.path);
        registerScripted(root, c);
        await expectLater(
          copyAttachmentTree(from, to, AttachmentCopy(), sweepSource: false),
          throwsA(isA<StorageBusy>()),
        );
        expect(to.existsSync(), isFalse);
        expect(File('${from.path}/$name').readAsBytesSync(), bytes);
      });

      test('removeCreated: a refused folder remove keeps the folder and says something was kept', () async {
        final made = Directory('${root.path}/made')..createSync();
        final copy = AttachmentCopy()..created.add(made.path);
        final c = ScriptedCoordinator()
          ..refuse = (w) => isWriteOn(w, root.path);
        registerScripted(root, c);
        expect(await removeCreated(copy), isFalse);
        expect(made.existsSync(), isTrue);
        c.refuse = null;
        expect(await removeCreated(copy), isTrue);
        expect(made.existsSync(), isFalse);
      });
    },
  );

  group('the folder helpers', () {
    test('createFolderCoordinated is one write on the parent; a folder that is there costs no call', () async {
      final c = ScriptedCoordinator();
      registerScripted(root, c);
      final d = Directory('${root.path}/a/b');
      await createFolderCoordinated(d);
      expect(d.existsSync(), isTrue);
      expect(c.calls, hasLength(1));
      expect(
        c.calls.single.intents.single,
        CoordinationIntent('${root.path}/a', CoordinationKind.write),
      );
      await createFolderCoordinated(d);
      expect(c.calls, hasLength(1));
    });

    test('createFolderCoordinated and removeFolderCoordinated throw StorageBusy on a refusal and change nothing', () async {
      final c = ScriptedCoordinator()..refuse = (_) => true;
      registerScripted(root, c);
      final d = Directory('${root.path}/a');
      await expectLater(
        createFolderCoordinated(d),
        throwsA(isA<StorageBusy>()),
      );
      expect(d.existsSync(), isFalse);
      d.createSync();
      await expectLater(
        removeFolderCoordinated(d),
        throwsA(isA<StorageBusy>()),
      );
      expect(d.existsSync(), isTrue);
      c.refuse = null;
      await removeFolderCoordinated(d);
      expect(d.existsSync(), isFalse);
    });
  });

  group('the notebook', () {
    late Directory app;
    late PageStore store;

    Notebook make() {
      final nb = Notebook(
        store,
        buildModules(),
        saveDelay: Duration.zero,
        bindersFile: File('${app.path}/binders.json'),
      );
      opened.add(nb);
      return nb;
    }

    setUp(() async {
      app = await Directory('${root.path}/app').create();
      store = PageStore(pages);
    });

    test('createBinder: a refused create of the default binder folder is "busy", and nothing is made', () async {
      final nb = make();
      await nb.load();
      final binders = Directory('${app.path}/binders');
      expect(binders.existsSync(), isFalse);
      final c = ScriptedCoordinator()..refuse = (w) => isWriteOn(w, app.path);
      registerScripted(root, c);
      final e = await _failure(nb.createBinder());
      expect(e, isA<NotebookException>());
      expect(
        (e! as NotebookException).message,
        allOf(contains('Could not create the binder'), contains('busy')),
      );
      expect(binders.existsSync(), isFalse);
      expect(c.calls.where((w) => isWriteOn(w, app.path)), hasLength(1));
    });

    test('createBinder: a refused create of the binder\'s own folder is "busy", and nothing is made', () async {
      final nb = make();
      await nb.load();
      final binders = Directory('${app.path}/binders')..createSync();
      final c = ScriptedCoordinator()
        ..refuse = (w) => isWriteOn(w, binders.path);
      registerScripted(root, c);
      final e = await _failure(nb.createBinder());
      expect(e, isA<NotebookException>());
      expect((e! as NotebookException).message, contains('busy'));
      expect(binders.listSync(), isEmpty);
    });

    test('savePageAsTemplate: a refused create of the templates folder is "busy", and no template is written', () async {
      final nb = make();
      await nb.load();
      final id = nb.currentId!;
      await nb.flush();
      final c = ScriptedCoordinator()
        ..refuse = (w) =>
            w.intents.length == 1 &&
            w.intents.single.path.endsWith('templates');
      registerScripted(root, c);
      final e = await _failure(nb.savePageAsTemplate(id, name: 'T'));
      expect(e, isA<NotebookException>());
      expect(
        (e! as NotebookException).message,
        allOf(contains('Could not save the template'), contains('busy')),
      );
      expect(
        c.calls.where((w) => w.intents.single.path.endsWith('templates')),
        isNotEmpty,
      );
      expect(Directory('${app.path}/templates').existsSync(), isFalse);
    });

    test('savePageAsTemplate: a refused create of the template\'s assets folder copies nothing', () async {
      final nb = make();
      await nb.load();
      final id = nb.currentId!;
      await nb.flush();
      final assets = Directory('${pages.path}/${assetsFolderName(id)}')
        ..createSync();
      File('${assets.path}/$name').writeAsBytesSync(bytes);
      final c = ScriptedCoordinator()
        ..refuse = (w) =>
            w.intents.length == 1 && w.intents.single.path.endsWith('.assets');
      registerScripted(root, c);
      final e = await _failure(nb.savePageAsTemplate(id, name: 'T'));
      expect(
        e,
        isA<StorageBusy>(),
        reason: 'the copy\'s own failure path: the call fails',
      );
      expect(File('${assets.path}/$name').readAsBytesSync(), bytes);
      final templates = Directory('${app.path}/templates');
      expect(
        templates.existsSync()
            ? templates
                  .listSync(recursive: true)
                  .where((f) => f.path.contains('.assets'))
            : const [],
        isEmpty,
        reason: 'no assets folder of the template was made',
      );
    });

    test('the settings write is one coordinated call: move the temp, write the folder (outside every root, so direct)', () async {
      final nb = make();
      await nb.load();
      final c = ScriptedCoordinator();
      registerScripted(root, c);
      final extra = await Directory('${root.path}/Elsewhere').create();
      await nb.addStandaloneFolder(extra.path);
      final settings = File('${app.path}/binders.json');
      final writes = c.calls
          .where(
            (w) => w.intents.any(
              (i) => i.kind == CoordinationKind.move && i.path.endsWith('.tmp'),
            ),
          )
          .toList();
      expect(writes, isNotEmpty);
      expect(writes.last.intents.map((i) => i.kind), [
        CoordinationKind.move,
        CoordinationKind.write,
      ]);
      expect(writes.last.intents.last.path, app.path);
      expect(settings.readAsStringSync(), contains('Elsewhere'));
    });

    test('the settings write: a refusal leaves the file as it was, and writes no other way', () async {
      final nb = make();
      await nb.load();
      final extra = await Directory('${root.path}/Elsewhere').create();
      await nb.addStandaloneFolder(extra.path);
      await nb.flush();
      final settings = File('${app.path}/binders.json');
      final before = settings.readAsStringSync();
      final more = await Directory('${root.path}/More').create();
      final c = ScriptedCoordinator()
        ..refuse = (w) => w.intents.any(
          (i) => i.kind == CoordinationKind.move && i.path.endsWith('.tmp'),
        );
      registerScripted(root, c);
      await nb.addStandaloneFolder(more.path);
      expect(
        c.calls.any((w) => w.intents.any((i) => i.path.endsWith('.tmp'))),
        isTrue,
      );
      expect(settings.readAsStringSync(), before);
    });
  });
}

Future<Object?> _failure(Future<Object?> f) async {
  try {
    await f;
  } on Object catch (e) {
    return e;
  }
  return null;
}
