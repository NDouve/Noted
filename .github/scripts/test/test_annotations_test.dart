// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Run with: dart .github/scripts/test/test_annotations_test.dart
// Plain checks, so no package is needed. The fixture is found next to this
// file, so the working directory does not matter.

import 'dart:io';

import '../test_annotations.dart';

void check(bool ok, String what) {
  if (!ok) {
    stderr.writeln('FAILED: $what');
    exit(1);
  }
}

void main() {
  final fixture = File.fromUri(Platform.script.resolve('sample_events.jsonl'));
  final lines = fixture.readAsLinesSync();
  final out = annotations(lines, 'app');
  check(out.length == 5, 'five annotations, got ${out.length}');
  String find(String s) => out.firstWhere((l) => l.contains(s));
  final one = find('group fails one');
  final two = find('fails two');
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

  final late = find('late error');
  check(late.contains('late async failure'), 'error after a successful done');

  final load = find('loading test/broken_test.dart');
  check(load.contains('compile error'), 'hidden load failure is annotated');
  check(load.contains('file=app/test/broken_test.dart'), 'load failure file');
  check(!load.contains('line='), 'load failure has no line');

  final odd = find('odd :: name, 100%25');
  check(odd.contains('odd failure'), 'odd name annotated');
  check(odd.contains('100%25'), 'percent in a name is escaped');
  check(escapeProperty('a::b,c%d') == 'a%3A%3Ab%2Cc%25d', 'property escaping');
  check(
    annotations(['{"type":"testStart","test":{"id":"x"}}'], 'app').isEmpty,
    'malformed event skipped',
  );
  stdout.writeln('ok');
}
