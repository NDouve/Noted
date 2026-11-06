// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Invariant 4: the MCP server has no sign-in or token code, and neither does
// the core it is built on. Microsoft sign-in lives in noted_auth, which
// neither noted_core nor anything it depends on may name. This test fails if
// this package's pubspec.yaml (dependencies, dev_dependencies and
// dependency_overrides alike) or a pubspec.lock beside it or at the
// workspace root names noted_auth, or any file under lib/ imports it.
void main() {
  // flutter test runs from the package folder.
  final lockFiles = [File('pubspec.lock'), File('../../pubspec.lock')];

  test('pubspec.yaml does not name noted_auth', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('noted_auth')),
    );
  });

  test('no pubspec.lock names noted_auth', () {
    for (final f in lockFiles.where((f) => f.existsSync())) {
      expect(
        f.readAsStringSync(),
        isNot(contains('noted_auth')),
        reason: f.path,
      );
    }
  });

  test('nothing under lib/ imports package:noted_auth', () {
    final offenders = [
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            f.readAsStringSync().contains('noted_auth'))
          f.path,
    ];
    expect(offenders, isEmpty);
  });
}
