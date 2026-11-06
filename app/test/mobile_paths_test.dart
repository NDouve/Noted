// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/device_storage.dart';

// The mobile relative paths (sync stage 1): the codec, the notebook and the
// recovery store. The codec is tested here with POSIX-shaped iOS paths.
void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    resetDeviceStorage();
  });

  const d = '/var/mobile/Containers/Data/Application/AAAA-1111/Documents';
  const old = '/var/mobile/Containers/Data/Application/BBBB-2222/Documents';

  String stored(String p, {String documents = d}) => storedPath(p, windows: false, documents: documents);
  String resolved(String p, {String documents = d, bool gone = true}) =>
      resolveStoredPath(p, windows: false, documents: documents, exists: (_) => !gone);

  group('codec', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('a path under the documents folder is stored relative and resolves back', () {
      expect(stored('$d/Noted/binders/Work'), '@documents/Noted/binders/Work');
      expect(resolved('@documents/Noted/binders/Work'), '$d/Noted/binders/Work');
      expect(stored(d), '@documents/');
      expect(resolved('@documents/'), d);
      expect(resolved('@documents'), d);
      // Idempotent.
      expect(stored('@documents/Noted/x'), '@documents/Noted/x');
    });

    test('paths outside the documents folder stay absolute', () {
      expect(stored('/Users/me/Notes'), '/Users/me/Notes');
      expect(stored('${d}2/Noted'), '${d}2/Noted');
      expect(resolved('/Users/me/Notes'), '/Users/me/Notes');
    });

    test('a leading /private is ignored on either side', () {
      expect(stored('/private$d/Noted/pages'), '@documents/Noted/pages');
      expect(stored('$d/Noted/pages', documents: '/private$d'), '@documents/Noted/pages');
      expect(resolved('/private$old/Noted/pages'), '$d/Noted/pages');
      expect(resolved('$old/Noted/pages', documents: '/private$d'), '/private$d/Noted/pages');
    });

    test('an absolute path under an old container is re-keyed by position', () {
      expect(resolved('$old/Noted/binders/a'), '$d/Noted/binders/a');
      expect(resolved('$old/Noted'), '$d/Noted');
      // Under the current container: as is.
      expect(resolved('$d/Noted/binders/a'), '$d/Noted/binders/a');
    });

    test('paths that do not match the old-container rule stay as written', () {
      // Two segments differ.
      expect(resolved('/var/mobile/Containers/Data/Other/BBBB-2222/Documents/Noted/x'),
          '/var/mobile/Containers/Data/Other/BBBB-2222/Documents/Noted/x');
      // Segment n is not "Documents".
      const other = '/var/mobile/Containers/Data/Application/BBBB-2222/Library';
      expect(resolved('$other/Noted/x'), '$other/Noted/x');
      // Segment n+1 is not Noted: outside D/Noted.
      expect(resolved('$old/Other/x'), '$old/Other/x');
      expect(resolved('$old'), old);
      // The old path still exists.
      expect(resolved('$old/Noted/x', gone: false), '$old/Noted/x');
      // A shorter prefix.
      expect(resolved('/var/mobile/Noted/x'), '/var/mobile/Noted/x');
    });

    test('a .. segment is refused and kept as written', () {
      expect(resolved('@documents/../etc'), '@documents/../etc');
      expect(resolved('@documents/Noted/../../x'), '@documents/Noted/../../x');
      expect(stored('$d/Noted/../x'), '$d/Noted/../x');
    });

    test('/@documents/ (an older build\'s normalised write) reads back', () {
      expect(resolved('/@documents/Noted/binders/a'), '$d/Noted/binders/a');
      expect(isDocumentsForm('/@documents/Noted'), isTrue);
      expect(isDocumentsForm('$d/Noted'), isFalse);
    });

    test('desktop is the identity', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(stored('$d/Noted/x'), '$d/Noted/x');
      expect(resolved('@documents/Noted/x'), '@documents/Noted/x');
      expect(resolved('$old/Noted/x'), '$old/Noted/x');
    });

    test('without a documents folder (before initDeviceStorage) it is the identity', () {
      expect(storedPath('$d/Noted/x', windows: false), '$d/Noted/x');
      expect(resolveStoredPath('@documents/Noted/x', windows: false), '@documents/Noted/x');
    });

    test('Windows folds case and accepts backslashes', () {
      const w = r'C:\Users\x\Temp\c2\Documents';
      expect(storedPath(r'c:\users\x\temp\c2\documents\Noted\a', windows: true, documents: w),
          '@documents/Noted/a');
      expect(resolveStoredPath('@documents/Noted/a', windows: true, documents: w), r'C:\Users\x\Temp\c2\Documents\Noted\a');
      expect(
        resolveStoredPath(r'C:\Users\x\Temp\c1\Documents\Noted\a', windows: true, documents: w, exists: (_) => false),
        r'C:\Users\x\Temp\c2\Documents\Noted\a',
      );
    });
  });
}
