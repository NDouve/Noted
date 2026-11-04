// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Run from the repository root:
//   dart .github/scripts/test/test_annotations_test.dart
// Plain checks, so no package is needed.

import 'dart:io';

import '../test_annotations.dart';

void check(bool ok, String what) {
  if (!ok) {
    stderr.writeln('FAILED: $what');
    exit(1);
  }
}

void main() {
  final lines = File('.github/scripts/test/sample_events.jsonl')
      .readAsLinesSync();
  final out = annotations(lines, 'app');
  check(out.length == 2, 'two annotations, got ${out.length}');
  final one = out.firstWhere((l) => l.contains('group fails one'));
  final two = out.firstWhere((l) => l.contains('fails two'));
  check(one.contains('first problem'), 'one has its error');
  check(one.contains('hello from test two'), 'one has its print');
  check(!one.contains('Expected') && !one.contains('stray'), 'one is clean');
  check(
    two.contains('Expected: <2>%0A  Actual: <3>%0A100%25 wrong'),
    'escaping',
  );
  check(!two.contains('first problem') && !two.contains('hello'), 'two clean');
  check(one.contains('file=app/test/a_test.dart,line=12'), 'file and line');
  check(!out.any((l) => l.contains('passes')), 'passing test left out');
  check(out.every((l) => !l.contains('\n')), 'one line each');
  stdout.writeln('ok');
}
