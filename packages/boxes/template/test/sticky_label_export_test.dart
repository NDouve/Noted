// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted_box_template/noted_box_template.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  const module = StickyLabelModule();
  const context = ExportContext(size: Size(100, 40));

  test('the example module lists plain text, the label\'s text', () async {
    const data = StickyLabelData(text: 'Buy milk');
    expect([for (final f in module.exportFormats(data)) f.id], ['text']);
    final f = await module.export(data, ExportFormat.text, context);
    expect(utf8.decode(f!.bytes), 'Buy milk');
    expect(await module.export(data, ExportFormat.markdown, context), isNull);
  });
}
