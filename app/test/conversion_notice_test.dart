// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/settings_panel.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

void main() {
  test('a plain conversion says how many changed', () {
    const r = AttachmentConversion(changed: 2, overLimit: []);
    expect(conversionNotice(r, AttachmentStorage.embedded), 'Embedded 2 attachments.');
    expect(conversionNotice(r, AttachmentStorage.folder), 'Moved 2 attachments to the folder.');
  });

  test('files over the limit are named', () {
    const r = AttachmentConversion(changed: 1, overLimit: ['big.zip']);
    expect(
      conversionNotice(r, AttachmentStorage.embedded),
      'Embedded 1 attachment. Kept in the folder (over 5 MB): big.zip.',
    );
  });

  test('boxes that changed while it ran are reported', () {
    const one = AttachmentConversion(changed: 1, overLimit: [], skipped: ['a']);
    expect(
      conversionNotice(one, AttachmentStorage.embedded),
      'Embedded 1 attachment. 1 box changed while this ran and was left as it was; press Embed attachments again.',
    );
    const two = AttachmentConversion(changed: 0, overLimit: [], skipped: ['a', 'b']);
    expect(
      conversionNotice(two, AttachmentStorage.folder),
      'Moved 0 attachments to the folder. 2 boxes changed while this ran and were left as they were; press Move attachments to folder again.',
    );
  });

  test('file names with dots are kept as they are', () {
    const r = AttachmentConversion(changed: 1, overLimit: ['a..b.zip', 'end.']);
    expect(
      conversionNotice(r, AttachmentStorage.embedded),
      'Embedded 1 attachment. Kept in the folder (over 5 MB): a..b.zip, end.',
    );
    const mid = AttachmentConversion(changed: 1, overLimit: ['end.'], skipped: ['a']);
    expect(
      conversionNotice(mid, AttachmentStorage.folder),
      'Moved 1 attachment to the folder. Kept in the folder (over 5 MB): end. '
      '1 box changed while this ran and was left as it was; press Move attachments to folder again.',
    );
  });

  test('boxes that could not be converted are reported, by direction', () {
    const one = AttachmentConversion(changed: 0, overLimit: [], failed: 1);
    expect(
      conversionNotice(one, AttachmentStorage.folder),
      'Moved 0 attachments to the folder. 1 attachment could not be moved to the folder and stays in the page. '
      'Try Move attachments to folder again later.',
    );
    expect(
      conversionNotice(one, AttachmentStorage.embedded),
      'Embedded 0 attachments. 1 attachment could not be embedded and stays in the folder. '
      'Try Embed attachments again later.',
    );
    const two = AttachmentConversion(changed: 1, overLimit: [], failed: 2);
    expect(
      conversionNotice(two, AttachmentStorage.folder),
      'Moved 1 attachment to the folder. 2 attachments could not be moved to the folder and stay in the page. '
      'Try Move attachments to folder again later.',
    );
  });
}
