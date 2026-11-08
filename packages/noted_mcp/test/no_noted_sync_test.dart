// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Invariant 4: the MCP server has no sync engine or Graph code, and neither does
// the core it is built on. The OneDrive pull engine lives in noted_sync. This test
// fails if noted_sync is reachable from this package: it walks this package's
// pubspec.yaml and, recursively, the pubspec.yaml of every dependency given
// by a path (dependencies, dev_dependencies and dependency_overrides alike;
// in a pub workspace the members are path dependencies too), and fails if any
// of them names noted_sync. It also fails if a file under lib/ imports it.
// (pubspec.lock is no use here: a workspace lock doesn't list path packages.)
void main() {
  // flutter test runs from the package folder.
  final named = RegExp(r'(^|[^A-Za-z0-9_])noted_sync([^A-Za-z0-9_]|$)');
  final pathDep = RegExp(
    r'^\s+path:\s*[\x27"]?([^\x27"\s#]+)',
    multiLine: true,
  );

  /// Every pubspec.yaml reachable from [start] through path dependencies.
  List<File> reachable(File start) {
    final seen = <String>{};
    final files = <File>[];
    final todo = [start];
    while (todo.isNotEmpty) {
      final f = todo.removeLast();
      if (!seen.add(f.absolute.path) || !f.existsSync()) continue;
      files.add(f);
      for (final m in pathDep.allMatches(f.readAsStringSync())) {
        todo.add(File('${f.parent.path}/${m.group(1)}/pubspec.yaml'));
      }
    }
    return files;
  }

  test('noted_sync is not reachable through any pubspec.yaml', () {
    final files = reachable(File('pubspec.yaml'));
    expect(files, isNotEmpty);
    final offenders = [
      for (final f in files)
        if (named.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('nothing under lib/ imports package:noted_sync', () {
    final offenders = [
      for (final f in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && named.hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
  });
}
