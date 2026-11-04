// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Turns a `flutter test --file-reporter json:<file>` stream into GitHub
// workflow-command annotations, one `::error` per failed test.
//
// Usage: dart .github/scripts/test_annotations.dart <json file> <package dir>
//
// Output of each test (its error, stack trace and print events) is collected
// by testID, so an annotation never carries another test's text.

import 'dart:convert';
import 'dart:io';

const int maxLines = 30;
const int maxChars = 4000;
const int maxAnnotations = 10;

class _Test {
  _Test(this.name, this.url, this.line);
  final String name;
  final String? url;
  final int? line;
  final List<String> errors = [];
  final List<String> stacks = [];
  final List<String> prints = [];
  bool failed = false;
}

/// Escapes [s] for the message part of a workflow command.
String escapeData(String s) =>
    s.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');

/// Escapes [s] for a property value (title, file) of a workflow command.
String escapeProperty(String s) =>
    escapeData(s).replaceAll(':', '%3A').replaceAll(',', '%2C');

String _bound(String text) {
  var lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  var cut = false;
  if (lines.length > maxLines) {
    lines = lines.sublist(0, maxLines);
    cut = true;
  }
  var out = lines.join('\n');
  if (out.length > maxChars) {
    out = out.substring(0, maxChars);
    cut = true;
  }
  return cut ? '$out\n...' : out;
}

/// Returns the annotation lines for the failed tests in [jsonLines].
List<String> annotations(Iterable<String> jsonLines, String dir) {
  final tests = <int, _Test>{};
  for (final raw in jsonLines) {
    final Object? event;
    try {
      event = jsonDecode(raw);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, dynamic>) continue;
    switch (event['type']) {
      case 'testStart':
        final t = event['test'] as Map<String, dynamic>;
        final line = t['root_line'] ?? t['line'];
        final url = (t['root_url'] ?? t['url']) as String?;
        tests[t['id'] as int] = _Test(
          t['name'] as String,
          url,
          line is int ? line : null,
        );
      case 'error':
        final t = tests[event['testID']];
        if (t == null) break;
        t.failed = true;
        t.errors.add('${event['error']}');
        t.stacks.add('${event['stackTrace']}');
      case 'print':
        tests[event['testID']]?.prints.add('${event['message']}');
      case 'testDone':
        final t = tests[event['testID']];
        if (t != null && event['hidden'] != true) {
          if (event['result'] == 'failure' || event['result'] == 'error') {
            t.failed = true;
          }
        }
    }
  }
  final out = <String>[];
  for (final t in tests.values) {
    if (!t.failed) continue;
    final body = StringBuffer(t.errors.join('\n'));
    if (t.stacks.any((s) => s.trim().isNotEmpty)) {
      body.write('\n${t.stacks.join('\n')}');
    }
    final message = StringBuffer(t.name);
    final text = _bound(body.toString());
    if (text.isNotEmpty) message.write('\n$text');
    if (t.prints.isNotEmpty) {
      message.write('\nOutput:\n${_bound(t.prints.join('\n'))}');
    }
    final props = StringBuffer(
      'title=${escapeProperty('Test failed in $dir')}',
    );
    final file = _repoFile(t.url, dir);
    if (file != null) {
      props.write(',file=${escapeProperty(file)}');
      if (t.line != null) props.write(',line=${t.line}');
    }
    out.add('::error $props::${escapeData(_bound(message.toString()))}');
    if (out.length >= maxAnnotations) break;
  }
  return out;
}

/// The repository-relative path of a test file URL, when it can be told.
String? _repoFile(String? url, String dir) {
  if (url == null || !url.startsWith('file:')) return null;
  final path = Uri.parse(url).toFilePath().replaceAll('\\', '/');
  final marker = '/$dir/test/';
  final i = path.lastIndexOf(marker);
  if (i < 0) return null;
  return path.substring(i + 1);
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: test_annotations.dart <json file> <package dir>');
    exit(2);
  }
  final file = File(args[0]);
  if (!file.existsSync()) exit(0);
  annotations(file.readAsLinesSync(), args[1]).forEach(stdout.writeln);
}
