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

  test('the package depends on dart_mcp and noted_core only', () {
    // Line endings follow the checkout (CRLF on a Windows runner).
    final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
    final deps = RegExp(r'^dependencies:\n((?:  .*\n|\s*#.*\n|\n)*)', multiLine: true).firstMatch(pubspec)!.group(1)!;
    final names = RegExp(r'^  (\w+):', multiLine: true).allMatches(deps).map((m) => m.group(1)).toSet();
    expect(names, {'dart_mcp', 'noted_core'});
  });
}
