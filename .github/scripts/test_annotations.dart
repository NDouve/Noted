// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Turns a `flutter test --file-reporter json:<file>` stream into GitHub
// workflow-command annotations, one `::error` per failed test.
//
// Usage: dart .github/scripts/test_annotations.dart <json file> <package dir>
//        [--summary]
//
// Output of each test (its error, stack trace and print events) is collected
// by testID, so an annotation never carries another test's text.
//
// With --summary it prints Markdown for the job summary instead: every failed
// test, with room for far more output than an annotation holds and no limit of
// ten annotations.
//
// Each failed test carries: a "Cause" line (the exception, operation, errno
// and file, read from its error); the lines the test helpers printed for a
// sharing violation (they start with `[io-trace]`, see
// app/test/support/io_trace.dart), kept whole; and the LAST lines it printed,
// the ones nearest the failure.

import 'dart:convert';
import 'dart:io';

const int maxLines = 30;
const int maxChars = 4000;
const int maxAnnotations = 5;

/// Lines that start a report of the test I/O tracing.
const String traceMarker = '[io-trace]';

// Limits for the job summary, which can hold much more than an annotation.
const int summaryLines = 120;
const int summaryChars = 24000;

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

/// [text] cut to at most [lines] lines and [chars] characters. The start is
/// kept, or with [tail] the end (the lines nearest a failure).
String _bound(
  String text, {
  int lines = maxLines,
  int chars = maxChars,
  bool tail = false,
}) {
  var all = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  while (all.isNotEmpty && all.last.trim().isEmpty) {
    all.removeLast();
  }
  var cut = false;
  if (all.length > lines) {
    all = tail ? all.sublist(all.length - lines) : all.sublist(0, lines);
    cut = true;
  }
  var out = all.join('\n');
  if (out.length > chars) {
    out = tail ? out.substring(out.length - chars) : out.substring(0, chars);
    cut = true;
  }
  if (!cut) return out;
  return tail ? '...\n$out' : '$out\n...';
}

/// One line saying what failed, read from a test's error text: the exception,
/// its operation, the errno and the file (its last two path segments, so no
/// folder of the runner's user). Null when the error names none of them.
String? cause(String error) {
  final errno = RegExp(r'errno = (\d+)').firstMatch(error)?.group(1);
  final kind = RegExp(
    r'\b(Path\w*Exception|FileSystemException)\b',
  ).firstMatch(error)?.group(1);
  if (errno == null && kind == null) return null;
  final op = RegExp(
    r'\b(Cannot \w+(?: \w+)?|Creation failed|Deletion failed|Rename failed|'
    r'Directory listing failed|Reading \w+ failed)',
  ).firstMatch(error)?.group(1);
  final path = RegExp(r"path = '([^']*)'").firstMatch(error)?.group(1);
  final parts = <String>[
    ?kind,
    ?op,
    if (errno != null) 'errno $errno',
    if (path != null) 'file ${_lastSegments(path)}',
  ];
  return parts.join(', ');
}

String _lastSegments(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
  final list = parts.toList();
  return list.length <= 2 ? path : list.sublist(list.length - 2).join('/');
}

/// The parts of a failed test's message, as plain text.
String _body(
  _Test t, {
  required int lines,
  required int chars,
}) {
  final out = StringBuffer(t.name);
  final all = t.errors.join('\n');
  final why = cause(all);
  if (why != null) out.write('\nCause: $why');
  final body = StringBuffer(all);
  if (t.stacks.any((s) => s.trim().isNotEmpty)) {
    body.write('\n${t.stacks.join('\n')}');
  }
  final text = _bound(body.toString(), lines: lines, chars: chars);
  if (text.isNotEmpty) out.write('\n$text');
  final trace = [
    for (final p in t.prints)
      for (final l in p.split('\n'))
        if (l.startsWith(traceMarker)) l,
  ];
  final other = [
    for (final p in t.prints)
      if (!p.startsWith(traceMarker)) p,
  ];
  if (trace.isNotEmpty) {
    out.write(
      '\nFile operations around the failure:\n'
      '${_bound(trace.join('\n'), lines: lines, chars: chars)}',
    );
  }
  if (other.isNotEmpty) {
    out.write(
      '\nOutput (the last lines):\n'
      '${_bound(other.join('\n'), lines: lines, chars: chars, tail: true)}',
    );
  }
  return out.toString();
}

/// Returns the annotation lines for the failed tests in [jsonLines].
List<String> annotations(Iterable<String> jsonLines, String dir) =>
    _render(_collect(jsonLines), dir);

Map<int, _Test> _collect(Iterable<String> jsonLines) {
  final tests = <int, _Test>{};
  for (final raw in jsonLines) {
    final Object? event;
    try {
      event = jsonDecode(raw);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, dynamic>) continue;
    try {
      _apply(event, tests);
    } on TypeError {
      continue; // a malformed event: skip it
    }
  }
  return tests;
}

void _apply(Map<String, dynamic> event, Map<int, _Test> tests) {
  {
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
}

List<String> _render(Map<int, _Test> tests, String dir) {
  final out = <String>[];
  for (final t in tests.values) {
    if (!t.failed) continue;
    final message = _body(t, lines: maxLines, chars: maxChars);
    final props = StringBuffer(
      'title=${escapeProperty('Test failed in $dir')}',
    );
    var file = _repoFile(t.url, dir);
    // A load failure has no url; its name is "loading <path>".
    if (file == null && t.url == null && t.name.startsWith('loading ')) {
      file = _loadFile(t.name.substring('loading '.length), dir);
    }
    if (file != null) {
      props.write(',file=${escapeProperty(file)}');
      if (t.line != null) props.write(',line=${t.line}');
    }
    out.add('::error $props::${escapeData(_bound(message, lines: 4 * maxLines, chars: 3 * maxChars))}');
    if (out.length >= maxAnnotations) break;
  }
  return out;
}

/// Markdown for the job summary: every failed test of [jsonLines], each with
/// its file and line, in a code block. Far larger limits than an annotation.
String summary(Iterable<String> jsonLines, String dir) {
  final out = StringBuffer();
  for (final t in _collect(jsonLines).values) {
    if (!t.failed) continue;
    final file = _repoFile(t.url, dir);
    final where = file == null ? '' : ' (`$file${t.line == null ? '' : ':${t.line}'}`)';
    out.writeln('#### Failed in $dir$where\n');
    // Four backticks: the output may hold three.
    out.writeln('````');
    out.writeln(
      _bound(
        _body(t, lines: summaryLines, chars: summaryChars),
        lines: 4 * summaryLines,
        chars: 3 * summaryChars,
      ),
    );
    out.writeln('````\n');
  }
  return out.toString();
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

/// The repository-relative file of a "loading <path>" test name. The path is
/// absolute or relative to the package directory.
String? _loadFile(String path, String dir) {
  path = path.trim().replaceAll('\\', '/');
  if (path.isEmpty) return null;
  final i = path.lastIndexOf('/$dir/');
  if (i >= 0) return path.substring(i + 1);
  if (path.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(path)) {
    return null;
  }
  return '$dir/$path';
}

void main(List<String> args) {
  final asSummary = args.length == 3 && args[2] == '--summary';
  if (args.length != 2 && !asSummary) {
    stderr.writeln(
      'usage: test_annotations.dart <json file> <package dir> [--summary]',
    );
    exit(2);
  }
  final file = File(args[0]);
  if (!file.existsSync()) exit(0);
  final lines = file.readAsLinesSync();
  if (asSummary) {
    stdout.write(summary(lines, args[1]));
  } else {
    annotations(lines, args[1]).forEach(stdout.writeln);
  }
}
