// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// A box's `file` value is joined onto the assets folder only if it is
// `<64 lowercase hex>[.<1-10 lowercase letters or digits>]`; anything else is
// a missing file that is never read, opened, verified or embedded (0098).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'fake_store.dart';

/// A store that has a file under every name it is given, and records each
/// time it is asked for one.
class _Trip extends FakeStore implements VerifyingAttachmentStore {
  final List<String> asked = [];
  final Uint8List content;

  _Trip(this.content);

  @override
  Future<Uint8List?> read(String fileName) async {
    asked.add('read $fileName');
    return content;
  }

  @override
  bool exists(String fileName) {
    asked.add('exists $fileName');
    return true;
  }

  @override
  Future<VerifiedAttachment> readVerified(String fileName, {required int size}) async {
    asked.add('readVerified $fileName');
    return VerifiedAttachment(AttachmentState.ok, bytes: content);
  }

  @override
  Future<VerifiedAttachment> verify(String fileName, {required int size}) async {
    asked.add('verify $fileName');
    return const VerifiedAttachment(AttachmentState.ok);
  }

  @override
  Future<void> open(String name, {String? fileName, Uint8List? bytes}) async {
    asked.add('open $fileName');
    await super.open(name, fileName: fileName, bytes: bytes);
  }
}

void main() {
  final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7 names'));
  final hash = contentHash(pdf);
  final good = '$hash.pdf';

  final bad = <String, String>{
    'empty': '',
    'dot dot slash': '../$good',
    'dot dot backslash': '..\\$good',
    'nested dot dot': '$hash/../$good',
    'absolute posix': '/etc/passwd',
    'absolute windows': 'C:\\Windows\\win.ini',
    'drive letter': 'C:$good',
    'UNC': '\\\\server\\share\\$good',
    'extension over 10': '$hash.abcdefghijk',
    'uppercase extension': '$hash.PDF',
    'uppercase hash': '${hash.toUpperCase()}.pdf',
    'hash too short': '${hash.substring(1)}.pdf',
    'hash too long': '${hash}0.pdf',
    'no hash': 'plan.pdf',
    'empty extension': '$hash.',
    'trailing newline': '$good\n',
    'a path after the name': '$good/x',
  };

  AttachmentRef refFor(String file) => AttachmentRef(name: 'Plan.pdf', size: pdf.length, hash: hash, file: file);

  group('isAttachmentFileName', () {
    test('accepts the names the app writes', () {
      expect(isAttachmentFileName(hash), isTrue);
      expect(isAttachmentFileName(good), isTrue);
      expect(isAttachmentFileName('$hash.abcdefghij'), isTrue);
      expect(isAttachmentFileName('$hash.7z'), isTrue);
      expect(isAttachmentFileName(attachmentFileName(hash, 'PDF')), isTrue);
    });

    test('refuses everything else', () {
      for (final e in bad.entries) {
        expect(isAttachmentFileName(e.value), isFalse, reason: e.key);
      }
    });
  });

  group('a file value that is not an attachment name', () {
    for (final e in bad.entries) {
      test('${e.key} is missing and never reaches the store', () async {
        final store = _Trip(pdf);
        final ref = refFor(e.value);

        expect(attachmentMissing(ref, store), isTrue);
        final read = await readAttachment(ref, store);
        expect(read.bytes, isNull);
        expect(read.state, AttachmentState.syncing);
        expect(await loadAttachment(ref, store), isNull);
        expect(await verifyAttachment(ref, store), AttachmentState.syncing);
        final overLimit = <String>[];
        expect(await convertAttachment(ref, AttachmentStorage.embedded, store, overLimit), isNull);
        expect((await loadDisplayCopyChecked(ref, store)).bytes, isNull);

        expect(store.asked, isEmpty);
        expect(store.opened, isEmpty);
      });
    }

    test('the same store does serve the plain name', () async {
      final store = _Trip(pdf);
      expect((await readAttachment(refFor(good), store)).bytes, pdf);
      expect(store.asked, isNotEmpty);
    });
  });

  group('the file box', () {
    for (final e in bad.entries) {
      testWidgets('${e.key}: shows it is missing and opening does nothing', (t) async {
        final store = _Trip(pdf);
        t.view.physicalSize = const Size(1200, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        const codec = FileCodec();
        final box = BoxRecord.create(
          id: 'file',
          typeId: codec.typeId,
          dataVersion: codec.dataVersion,
          bounds: const Bounds(40, 40, 280, 64),
          data: RawJson.encode(codec.encode(FileData(ref: refFor(e.value)))),
          snapshotText: '[file: Plan.pdf]',
          rev: 'r',
        ).withFixedHeight(true);
        final modules = ModuleRegistry()..register(const FileModule(), isDefault: true);
        final c = CanvasController(NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0)).insertNode(box), modules);
        await t.pumpWidget(
          MaterialApp(
            theme: notedThemeData(Brightness.light),
            home: Scaffold(body: PageCanvas(controller: c, attachments: store)),
          ),
        );
        await t.pump();

        final finder = find.byKey(const ValueKey('file-box'));
        expect(find.byTooltip('Plan.pdf: still syncing'), findsOneWidget);
        await t.tap(finder);
        await t.pump(const Duration(milliseconds: 50));
        await t.tap(finder);
        await t.pump(const Duration(milliseconds: 400));
        expect(store.opened, isEmpty);
        expect(store.asked.where((a) => a.startsWith('open') || a.startsWith('read')), isEmpty);
      });
    }
  });
}
