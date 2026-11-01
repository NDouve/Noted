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

  test('no encryption, key, crypto, FFI or Flutter library is reachable', () {
    final forbiddenPackages = RegExp(r'^package:(flutter|flutter_\w+|crypto|cryptography\w*|pointycastle|encrypt\w*|\w*sodium\w*|\w*secure_storage\w*)/');
    final forbiddenWords = RegExp(r'crypt|cipher|keystore|key_store|keychain|secret|password', caseSensitive: false);
    final bad = [
      for (final lib in graph)
        if (forbiddenPackages.hasMatch(lib) ||
            lib == 'dart:ffi' ||
            lib == 'dart:ui' ||
            forbiddenWords.hasMatch(lib.split('/').skip(1).join('/')))
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

  test('the source scan covers the server, the link client and the core', () {
    final names = notedSources().keys;
    expect(names, contains(linkClient));
    expect(names, contains('package:noted_mcp/src/library.dart'));
    expect(names, contains('package:noted_core/src/ai/ai_link.dart'));
    expect(names.where((n) => n.startsWith('file:')), isNotEmpty, reason: 'the executable\'s entry');
  });

  test('the server never writes a file: no file-writing API in any Noted library it reaches', () {
    final writes = {
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
      'rename': RegExp(r'\.rename(Sync)?\s*\('),
      'delete': RegExp(r'\.delete(Sync)?\s*\('),
      'Link': RegExp(r'(?<![A-Za-z0-9_])Link\s*\('),
      'Process': RegExp(r'\bProcess\.(run|start|runSync)\b'),
    };
    // Known: noted_core's binder.dart holds BinderStore, which writes
    // binder.noted. It is in the import graph but the server never uses it
    // (checked below). Move it out of the read-only part of the core, then
    // delete this exception.
    const knownCoreWriter = 'package:noted_core/src/binder/binder.dart';
    final sources = notedSources();
    final bad = [
      for (final e in sources.entries)
        if (e.key != knownCoreWriter)
          for (final w in writes.entries)
            if (w.value.hasMatch(e.value)) '${e.key}: ${w.key}',
    ];
    expect(bad, isEmpty);
    final users = [
      for (final e in sources.entries)
        if (e.key != knownCoreWriter && e.value.contains('BinderStore')) e.key,
    ];
    expect(users, isEmpty, reason: 'nothing the server runs may use BinderStore');
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
