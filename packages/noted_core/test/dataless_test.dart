// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_core/src/storage/dataless.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('noted_dataless'));
  tearDown(() async {
    debugDatalessAbi = null;
    debugResetDataless();
    await dir.delete(recursive: true);
  });

  String p(String n) => '${dir.path}${Platform.pathSeparator}$n';

  group('the seam', () {
    test('SF_DATALESS in the flags makes an existing file dataless; other flags do not', () {
      File(p('a')).writeAsStringSync('x');
      expect(isDataless(p('a'), statFlags: sfDataless), isTrue);
      expect(isDataless(p('a'), statFlags: sfDataless | 0x20), isTrue);
      expect(isDataless(p('a'), statFlags: 0), isFalse);
      expect(isDataless(p('a'), statFlags: 0x3FFFFFFF), isFalse);
    });

    test('a missing file is not dataless, whatever the flags', () {
      expect(isDataless(p('nope')), isFalse);
      expect(isDataless(p('nope'), statFlags: sfDataless), isFalse);
    });

    test('a real file is not dataless on this platform', () {
      File(p('a')).writeAsStringSync('x');
      if (Platform.isMacOS || Platform.isIOS) return;
      expect(isDataless(p('a')), isFalse);
      expect(isDataless(dir.path), isFalse);
    });
  });

  group('stubs', () {
    test('names', () {
      expect(stubNameOf('a.canvas'), '.a.canvas.icloud');
      expect(stubTargetName('.a.canvas.icloud'), 'a.canvas');
      expect(stubTargetName('.icloud'), isNull);
      expect(stubTargetName('..icloud'), isNull);
      expect(stubTargetName('a.canvas.icloud'), isNull);
      expect(stubTargetName('.a.canvas'), isNull);
    });

    test('a stub with no file beside it makes the name dataless', () {
      File(p('.a.canvas.icloud')).writeAsStringSync('');
      expect(hasStub(p('a.canvas')), isTrue);
      expect(isDataless(p('a.canvas')), isTrue);
      expect(isDataless(p('b.canvas')), isFalse);
    });

    test('with the file beside it, the file speaks for itself', () {
      File(p('.a.canvas.icloud')).writeAsStringSync('');
      File(p('a.canvas')).writeAsStringSync('x');
      expect(isDataless(p('a.canvas')), isFalse);
      expect(isDataless(p('a.canvas'), statFlags: sfDataless), isTrue);
    });
  });

  group('the Apple lookup', () {
    test('each Abi names its own symbol; the others make no lookup', () {
      File(p('a')).writeAsStringSync('x');
      if (Platform.isMacOS || Platform.isIOS) return; // a real lstat exists
      final expected = {
        Abi.macosArm64: 'lstat',
        Abi.iosArm64: 'lstat',
        Abi.iosX64: 'lstat',
        Abi.macosX64: r'lstat$INODE64',
      };
      for (final e in expected.entries) {
        debugDatalessAbi = e.key;
        debugResetDataless();
        isDataless(p('a'));
        final failure = debugDatalessLookupFailure;
        expect(failure, isNotNull, reason: '${e.key}: no lstat in this process');
        expect(failure.toString(), contains(e.value), reason: '${e.key}');
        if (e.value == 'lstat') {
          expect(failure.toString(), isNot(contains(r'$INODE64')), reason: '${e.key}');
        }
      }
      for (final abi in [Abi.linuxX64, Abi.linuxArm64, Abi.windowsX64, Abi.androidArm64]) {
        debugDatalessAbi = abi;
        debugResetDataless();
        expect(isDataless(p('a')), isFalse, reason: '$abi');
        expect(debugDatalessLookupFailure, isNull, reason: '$abi');
      }
    });

    test('a failed lookup is remembered and every existing file then counts as dataless', () {
      File(p('a')).writeAsStringSync('x');
      if (Platform.isMacOS || Platform.isIOS) return;
      debugDatalessAbi = Abi.macosArm64;
      debugResetDataless();
      expect(isDataless(p('a')), isTrue, reason: 'fails closed');
      final first = debugDatalessLookupFailure;
      expect(first, isNotNull);
      expect(isDataless(p('a')), isTrue);
      expect(identical(debugDatalessLookupFailure, first), isTrue, reason: 'caught once and remembered');
      // A missing file is still not dataless; the seam still works.
      expect(isDataless(p('nope')), isFalse);
      expect(isDataless(p('a'), statFlags: 0), isFalse);
      debugResetDataless();
      expect(debugDatalessLookupFailure, isNull);
    });
  });
}
