// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/attachment_platform.dart';
import 'package:noted_canvas/noted_canvas.dart';

Future<Uint8List?> _noImage() async => null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('on Android a content URI is read through the platform with its name', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final asked = <String>[];
    final out = await readClipboardFiles(
      imageReader: _noImage,
      filesReader: () async => ['content://media/external/file/7'],
      contentReader: (uri) async {
        asked.add(uri);
        return IncomingFile('report.pdf', Uint8List.fromList([1, 2, 3]));
      },
    );
    expect(asked, ['content://media/external/file/7']);
    expect(out.single.name, 'report.pdf');
    expect(out.single.bytes, [1, 2, 3]);
  });

  test('the channel result is turned into a file with a sanitized name', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('noted/content'), (call) async {
      expect(call.method, 'read');
      return {
        'name': '../../etc/passwd',
        'bytes': Uint8List.fromList([9]),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('noted/content'), null));
    final f = await readContentUri('content://x/1');
    expect(f!.name, 'passwd');
    expect(f.bytes, [9]);
  });

  test('dangerous display names are sanitized', () {
    expect(safeAttachmentName('..\\..\\evil.txt'), 'evil.txt');
    expect(safeAttachmentName('..'), 'Pasted file');
    expect(safeAttachmentName(''), 'Pasted file');
    expect(safeAttachmentName(null), 'Pasted file');
    expect(safeAttachmentName('a/b/'), 'Pasted file');
    expect(safeAttachmentName('.pdf'), 'Pasted file.pdf');
    expect(safeAttachmentName('a\u007fb‮c.txt'), 'a_b_c.txt');
    expect(safeAttachmentName('x​.txt'), 'x_.txt');
    final long = safeAttachmentName('${'a' * 300}.pdf');
    expect(long.length, 255);
    expect(long.endsWith('.pdf'), isTrue);
    expect(safeAttachmentName('a:b?.txt'), 'a_b_.txt');
  });

  test('a plain path is still read from disk', () async {
    final dir = Directory.systemTemp.createTempSync('clip');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}${Platform.pathSeparator}n.txt')..writeAsBytesSync([5, 6]);
    final out = await readClipboardFiles(
      imageReader: _noImage,
      filesReader: () async => [f.path],
      contentReader: (_) async => fail('not a content URI'),
    );
    expect(out.single.name, 'n.txt');
    expect(out.single.bytes, [5, 6]);
  });

  test('a failing or refused platform read is skipped, not fatal', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final out = await readClipboardFiles(
      imageReader: _noImage,
      filesReader: () async => ['content://a/1', 'content://a/2', 'content://a/3'],
      contentReader: (uri) async {
        if (uri.endsWith('1')) throw PlatformException(code: 'read_failed');
        if (uri.endsWith('2')) return null;
        return IncomingFile('ok.txt', Uint8List(1));
      },
    );
    expect(out.map((f) => f.name), ['ok.txt']);
  });

  test('on desktop a content URI is never handed to the platform reader', () async {
    final out = await readClipboardFiles(
      imageReader: _noImage,
      filesReader: () async => ['content://x/1'],
      contentReader: (_) async => fail('desktop must not use the content reader'),
    );
    expect(out, isEmpty);
  });

  test('a null from the channel gives no file', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('noted/content'), (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('noted/content'), null));
    expect(await readContentUri('content://x/1'), isNull);
  });
}
