// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// noted_core must stay pure Dart so the future MCP server, a separate
/// executable (invariant 4), can use it without any UI code.
void main() {
  test('lib/ imports neither Flutter nor dart:ui', () {
    // Works whether tests run from the package or from the workspace root.
    final lib = [
      Directory('lib'),
      Directory('packages/noted_core/lib'),
    ].firstWhere((d) => File('${d.path}/noted_core.dart').existsSync());
    final offenders = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) {
          final s = f.readAsStringSync();
          return s.contains("'package:flutter") || s.contains("'dart:ui'");
        })
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });
}
