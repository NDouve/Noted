// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Invariant 4: the MCP server is a separate executable with no key access
// and no decryption code. These tests walk everything the executable can
// import and fail on any library that could hold keys, encryption or the
// live screen.
void main() {
  // flutter test runs from packages/noted_mcp.
  final config = jsonDecode(File('../../.dart_tool/package_config.json').readAsStringSync()) as Map<String, Object?>;
  final configDir = Directory('../../.dart_tool').absolute.uri;
  final packages = <String, Uri>{
    for (final p in (config['packages']! as List).cast<Map<String, Object?>>())
      p['name']! as String: configDir.resolve('${p['rootUri']}/').resolve('${p['packageUri'] ?? 'lib/'}'),
  };

  /// Every library reachable from [entry], as `package:` or file URIs, with
  /// the `dart:` libraries it uses.
  Set<String> reachable(Uri entry) {
    final seen = <String>{};
    final todo = <Uri>[entry];
    final directive = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);
    while (todo.isNotEmpty) {
      final uri = todo.removeLast();
      if (!seen.add(uri.toString())) continue;
      if (uri.scheme == 'dart') continue;
      final file = uri.scheme == 'package'
          ? File.fromUri(packages[uri.pathSegments.first]!.resolve(uri.pathSegments.skip(1).join('/')))
          : File.fromUri(uri);
      for (final m in directive.allMatches(file.readAsStringSync())) {
        final target = Uri.parse(m.group(1)!);
        todo.add(target.hasScheme ? target : (uri.scheme == 'package' ? uri.resolveUri(target) : file.uri.resolveUri(target)));
      }
    }
    return seen;
  }

  final entry = File('bin/noted_mcp.dart').absolute.uri;
  final graph = reachable(entry);

  test('the walk sees the server and the read-only core', () {
    expect(graph, contains('package:noted_mcp/noted_mcp.dart'));
    expect(graph, contains('package:noted_core/noted_core_read.dart'));
    expect(graph, contains('package:dart_mcp/server.dart'));
  });

  test('no encryption, key, FFI or Flutter library is reachable (package:crypto is allowed, SHA-256 only: see below)', () {
    final forbiddenPackages = RegExp(r'^package:(flutter|flutter_\w+|cryptography\w*|pointycastle|encrypt\w*|\w*sodium\w*|\w*secure_storage\w*)/');
    final forbiddenWords = RegExp(r'crypt|cipher|keystore|key_store|keychain|secret|password', caseSensitive: false);
    final bad = [
      for (final lib in graph)
        // package:crypto is allowed (its use is checked in the SHA-256 test).
        if (!lib.startsWith('package:crypto/') &&
            (forbiddenPackages.hasMatch(lib) ||
            lib == 'dart:ffi' ||
            lib == 'dart:ui' ||
            forbiddenWords.hasMatch(lib.split('/').skip(1).join('/'))))
          lib,
    ];
    expect(bad, isEmpty);
  });

  test('of Noted\'s own code only the read-only core and the server itself are reachable', () {
    const allowedCore = {'ai', 'binder', 'format', 'json', 'model', 'search', 'tree'};
    final bad = [
      for (final lib in graph)
        if (lib.startsWith('package:noted') && !lib.startsWith('package:noted_mcp/'))
          if (!lib.startsWith('package:noted_core/') ||
              lib == 'package:noted_core/noted_core.dart' ||
              (lib.startsWith('package:noted_core/src/') && !allowedCore.contains(lib.split('/')[2])))
            lib,
    ];
    expect(bad, isEmpty, reason: 'no canvas, box modules, storage writes, attachments or the full core');
  });

  /// The source of every Noted library in the graph (the server, the
  /// executable's entry and the core files it reaches), with comments cut.
  Map<String, String> notedSources() {
    final out = <String, String>{};
    for (final lib in graph) {
      if (lib.startsWith('dart:')) continue;
      if (!lib.startsWith('package:noted') && !lib.startsWith('file:')) continue;
      final uri = Uri.parse(lib);
      final file = uri.scheme == 'package'
          ? File.fromUri(packages[uri.pathSegments.first]!.resolve(uri.pathSegments.skip(1).join('/')))
          : File.fromUri(uri);
      out[lib] = file.readAsStringSync().split(RegExp(r'\r?\n')).where((l) => !l.trimLeft().startsWith('//')).join('\n');
    }
    return out;
  }

  const linkClient = 'package:noted_mcp/src/link_client.dart';
  const closedWriter = 'package:noted_mcp/src/closed_writer.dart';
  const runningProbe = 'package:noted_mcp/src/running_probe.dart';

  test('crypto is SHA-256 only: one import, `show sha256`, in the core\'s code format, and nothing else hashes', () {
    final sources = notedSources();
    final imports = RegExp(r'''^\s*(?:import|export)\s+['"]package:crypto/[^'"]*['"][^;]*;''', multiLine: true);
    final found = {
      for (final e in sources.entries)
        for (final m in imports.allMatches(e.value)) '${e.key}: ${m.group(0)!.trim()}',
    };
    expect(found, {'package:noted_core/src/ai/ai_code_format.dart: import \'package:crypto/crypto.dart\' show sha256;'});
    // No other digest, MAC or crypto API is named by any Noted library in the graph.
    final other = RegExp(r'\b(md5|sha1|sha224|sha384|sha512|Hmac|Digest|Hash|AccumulatorSink|ByteConversionSink)\b');
    final bad = [
      for (final e in sources.entries)
        if (other.hasMatch(e.value)) e.key,
    ];
    expect(bad, isEmpty);
    // sha256 is used in that one library only.
    expect([for (final e in sources.entries) if (RegExp(r'\bsha256\b').hasMatch(e.value)) e.key], [
      'package:noted_core/src/ai/ai_code_format.dart',
    ]);
  });

  test('randomness: only Random.secure, in the id and session-id helpers', () {
    final bad = [
      for (final e in notedSources().entries)
        if (RegExp(r'\bRandom\s*\(|\bRandom\.(?!secure\b)').hasMatch(e.value)) e.key,
    ];
    expect(bad, isEmpty, reason: 'only Random.secure()');
    final users = [
      for (final e in notedSources().entries)
        if (RegExp(r'\bRandom\b').hasMatch(e.value)) e.key,
    ]..sort();
    expect(users, [
      'package:noted_core/src/model/ids.dart',
      'package:noted_mcp/src/closed_access.dart',
      'package:noted_mcp/src/closed_writer.dart',
      'package:noted_mcp/src/toolbox.dart',
    ]);
  });

  test('the source scan covers the server, the link client and the core', () {
    final names = notedSources().keys;
    expect(names, contains(linkClient));
    expect(names, contains('package:noted_mcp/src/library.dart'));
    expect(names, contains('package:noted_mcp/src/toolbox.dart'));
    expect(names, contains('package:noted_core/src/ai/ai_access.dart'));
    expect(names, contains('package:noted_core/src/ai/ai_link.dart'));
    expect(names.where((n) => n.startsWith('file:')), isNotEmpty, reason: 'the executable\'s entry');
  });

  test('file-writing APIs appear only in the narrow writer: no Noted library it reaches writes a file', () {
    final writes = {
      'open': RegExp(r'\.open(Sync)?\s*\('),
      'RandomAccessFile write': RegExp(r'\.(writeString|writeFrom|writeByte|truncate(Sync)?)\s*\('),
      'writeAsString': RegExp(r'\bwriteAsString(Sync)?\s*\('),
      'writeAsBytes': RegExp(r'\bwriteAsBytes(Sync)?\s*\('),
      'openWrite': RegExp(r'\bopenWrite\s*\('),
      'FileMode.write/append': RegExp(r'\bFileMode\.(write|append|writeOnly|writeOnlyAppend)\b'),
      // Any create/copy/touch call, except a model constructor such as
      // `PageMeta.create(` (a capitalised type name before the dot).
      'create/copy': RegExp(
        r'(?:(?<![A-Za-z0-9_.])(?![A-Z])[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*|\))'
        r'\s*\.(?:create|createTemp|copy|setLastModified)(?:Sync)?\s*\(',
      ),
      'File/Directory create': RegExp(r'\b(File|Directory|Link)\s*\([^)]*\)\s*\.create'),
      'createSync': RegExp(r'\.createSync\s*\('),
      // On any receiver, with a dot or a cascade.
      'createTemp/copy/cascade': RegExp(r'\.\.?(?:createTemp|copy)(?:Sync)?\s*\(|\.\.create(?:Sync)?\s*\('),
      'Isolate': RegExp(r'\bIsolate\.(spawn|spawnUri|run)\b'),
      'rename': RegExp(r'\.rename(Sync)?\s*\('),
      'delete': RegExp(r'\.delete(Sync)?\s*\('),
      'Link': RegExp(r'(?<![A-Za-z0-9_])Link\s*\('),
      'Process': RegExp(r'\bProcess\.(run|start|runSync)\b'),
    };
    final sources = notedSources();
    final bad = [
      for (final e in sources.entries)
        if (e.key != closedWriter)
          for (final w in writes.entries)
            // The running probe opens one file, read-only (checked below).
            if (!(e.key == runningProbe && w.key == 'open') && w.value.hasMatch(e.value)) '${e.key}: ${w.key}',
    ];
    expect(bad, isEmpty);
    // `.create(` / `.createSync(` on any receiver: only these model
    // constructors (`PageMeta.create(`, ...) are allowed, by name.
    const modelConstructors = {'Binder', 'BoxRecord', 'PageMeta', 'NotedPage'};
    final create = RegExp(r'([A-Za-z_][A-Za-z0-9_]*|[)\]])\s*\.create(?:Sync)?\s*\(');
    final badCreate = [
      for (final e in sources.entries)
        if (e.key != closedWriter)
          for (final m in create.allMatches(e.value))
            if (!modelConstructors.contains(m.group(1))) '${e.key}: ${m.group(0)}',
    ];
    expect(badCreate, isEmpty);
    final probe = sources[runningProbe]!;
    expect(writes['open']!.allMatches(probe).length, 1);
    expect(probe, contains('FileMode.read'));
    expect(RegExp(r'FileMode\.(?!read\b)').hasMatch(probe), isFalse, reason: 'read-only');
    expect(probe, contains('FileLock.shared'));
    expect(probe, isNot(contains('FileLock.exclusive')));
    // The narrow writer itself: exactly its two jobs and nothing wider.
    final src = sources[closedWriter]!;
    int count(RegExp r) => r.allMatches(src).length;
    final allowedHere = {
      'open',
      'RandomAccessFile write',
      'writeAsBytes',
      'FileMode.write/append',
      'rename',
      'delete',
      'create/copy',
    };
    expect(count(writes['create/copy']!), 1, reason: 'the exclusive publication of the new page file');
    expect(src, contains('create(exclusive: true)'));
    expect([for (final w in writes.entries) if (!allowedHere.contains(w.key) && w.value.hasMatch(src)) w.key], isEmpty);
    expect(count(writes['open']!), 1, reason: 'one open: the log, for appending');
    expect(count(RegExp(r'\bFileMode\.append\b')), 1);
    expect(count(RegExp(r'\bFileMode\.(write|writeOnly|writeOnlyAppend)\b')), 0);
    expect(count(writes['RandomAccessFile write']!), 1, reason: 'the log line');
    expect(count(writes['writeAsBytes']!), 1, reason: 'the new page file, created exclusively');
    // Move-aside publication: the page file to its aside; the aside back to
    // the page's path (a failed write, or a put-back of a changed page).
    expect(count(writes['rename']!), 3, reason: 'the page aside, and the aside back');
    expect(count(writes['delete']!), 1, reason: 'only its own aside, after the new file is published');
    final deleteAt = RegExp(r'\.delete\s*\(').firstMatch(src)!.start;
    expect(src.substring(src.lastIndexOf('\n', deleteAt - 1) + 1, deleteAt).trim(), 'await aside', reason: 'never anything but the aside');
    // A kept copy is a conflict-copy name the core's scanner reads.
    expect(src, contains(r'$stem-NOTED-MCP-'));
    expect(src, contains('endsWith(pageExtension)'), reason: 'only page files');
    expect(src, contains('followLinks: false'), reason: 'never through a link');
    expect(src, contains('resolveSymbolicLinks'), reason: 'inside a listed folder, by real path');
    expect(src, isNot(contains('Socket')));
    // Nothing else in the package reaches the writer's methods except the
    // closed-app access (and its tests).
    for (final e in sources.entries) {
      if (!e.key.startsWith('package:noted_mcp/') || e.key == closedWriter) continue;
      if (e.value.contains('replacePage(') || e.value.contains('appendLog(')) {
        expect(e.key, 'package:noted_mcp/src/closed_access.dart');
      }
    }
    // The binder file writer lives in the full core only.
    expect(sources.keys, isNot(contains('package:noted_core/src/binder/binder_store.dart')));
    expect(sources.keys, contains('package:noted_core/src/binder/binder.dart'));
  });

  test('only the link client touches a socket, HTTP or WebSocket API', () {
    final net = RegExp(
      r'\b(Socket|ServerSocket|RawSocket|RawServerSocket|SecureSocket|RawSecureSocket|RawDatagramSocket|HttpClient|HttpServer|WebSocket|InternetAddress|NetworkInterface)\b|dart:(io_http|html)',
    );
    final bad = [
      for (final e in notedSources().entries)
        if (e.key != linkClient && net.hasMatch(e.value)) e.key,
    ];
    expect(bad, isEmpty);
  });

  test('the link client connects to the loopback address only', () {
    final src = notedSources()[linkClient]!;
    expect(RegExp(r'Socket\.connect\(\s*InternetAddress\.loopbackIPv4\s*,').allMatches(src), hasLength(1));
    expect(RegExp(r'\.(connect|bind|listen)\(').allMatches(src).length, 1, reason: 'one connect, no listener');
    // The only address the file names is the loopback one: nothing is parsed from a file or an argument.
    expect(RegExp(r'InternetAddress\b').allMatches(src).length, 1);
    expect(src, isNot(contains('InternetAddress(')));
    expect(src, isNot(contains('InternetAddress.anyIPv')));
    expect(src, isNot(contains('lookup')));
    expect(src, isNot(contains('SecurityContext')));
  });

  test('the package depends on dart_mcp and noted_core only', () {
    // Line endings follow the checkout (CRLF on a Windows runner).
    final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
    final deps = RegExp(r'^dependencies:\n((?:  .*\n|\s*#.*\n|\n)*)', multiLine: true).firstMatch(pubspec)!.group(1)!;
    final names = RegExp(r'^  (\w+):', multiLine: true).allMatches(deps).map((m) => m.group(1)).toSet();
    expect(names, {'dart_mcp', 'noted_core'});
  });
}
