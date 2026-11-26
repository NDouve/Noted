// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The Apple side of the iCloud driver can't be compiled here; CI's macOS and
// iOS builds do. These checks keep the two copies identical and wired in.

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  const ios = 'ios/Runner/CloudFolder.swift';
  const mac = 'macos/Runner/CloudFolder.swift';

  test('the two Swift files are identical', () {
    expect(_read(mac), _read(ios));
  });

  test('the file carries the MPL-2.0 header', () {
    final text = _read(ios);
    expect(
      text,
      startsWith(
        '// This Source Code Form is subject to the terms of the Mozilla Public\n'
        '// License, v. 2.0. If a copy of the MPL was not distributed with this\n'
        '// file, You can obtain one at https://mozilla.org/MPL/2.0/.\n',
      ),
    );
  });

  test('UIKit and AppKit imports and types stay inside platform guards', () {
    // Lines (outside comments) that name a platform-only framework or type.
    final iosOnly = RegExp(
      r'\bUIKit\b|\bUI[A-Z]\w+|\bUniformTypeIdentifiers\b|import Flutter$',
    );
    final macOnly = RegExp(
      r'\bCocoa\b|\bAppKit\b|\bNS(Application|Window|Panel|OpenPanel)\b|\bFlutterMacOS\b',
    );
    var guard = ''; // '', 'ios', 'mac' or 'other'
    var depth = 0;
    final bad = <String>[];
    final lines = _read(ios).split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#if os(iOS)')) {
        depth++;
        guard = 'ios';
        continue;
      }
      if (line.startsWith('#elseif os(macOS)')) {
        guard = 'mac';
        continue;
      }
      if (line.startsWith('#if os(macOS)')) {
        depth++;
        guard = 'mac';
        continue;
      }
      if (line.startsWith('#if ')) {
        depth++;
        guard = 'other';
        continue;
      }
      if (line.startsWith('#else')) {
        guard = guard == 'ios' ? 'mac' : 'ios';
        continue;
      }
      if (line.startsWith('#endif')) {
        depth--;
        guard = '';
        continue;
      }
      if (line.startsWith('//')) continue;
      if (depth == 0 || guard == 'other') {
        if (iosOnly.hasMatch(line) || macOnly.hasMatch(line)) {
          bad.add('line ${i + 1}: $line');
        }
      } else if (guard == 'ios' && macOnly.hasMatch(line)) {
        bad.add('line ${i + 1} (iOS guard): $line');
      } else if (guard == 'mac' && iosOnly.hasMatch(line)) {
        bad.add('line ${i + 1} (macOS guard): $line');
      }
    }
    expect(depth, 0);
    expect(bad, isEmpty);
    final text = _read(ios);
    expect(text, contains('#if os(iOS)'));
    expect(text, contains('#elseif os(macOS)'));
  });

  test('the channel name and every method are documented in the header', () {
    final text = _read(ios);
    expect(text, contains('noted/cloud_folder'));
    for (final m in [
      'pick',
      'bookmark',
      'resolve',
      'isUbiquitous',
      'stopAccess',
      'reset',
      'coordinate',
      'versions',
      'resolveVersion',
      'withVersions',
      'startDownloading',
      'changed',
      'failed',
    ]) {
      expect(text, contains('//   $m'), reason: m);
    }
    final code = text
        .split('\n')
        .where((l) => !l.trim().startsWith('//'))
        .join('\n');
    expect(code, isNot(contains('removeOtherVersionsOfItem')));
    // isResolved is assigned in one place only.
    expect(RegExp(r'\.isResolved\s*=[^=]').allMatches(code), hasLength(1));
    expect(
      code.substring(code.indexOf('func resolveVersion')),
      contains('.isResolved = true'),
    );
  });

  for (final dir in ['ios', 'macos']) {
    test('$dir project lists CloudFolder.swift in its Sources phase', () {
      final text = _read('$dir/Runner.xcodeproj/project.pbxproj');
      final ref = RegExp(
        r'(\w{24}) /\* CloudFolder\.swift \*/ = \{isa = PBXFileReference;',
      ).firstMatch(text);
      expect(ref, isNotNull);
      final build = RegExp(
        r'(\w{24}) /\* CloudFolder\.swift in Sources \*/ = \{isa = PBXBuildFile; fileRef = ' +
            ref!.group(1)!,
      ).firstMatch(text);
      expect(build, isNotNull);
      // The Runner target's phase (the one with AppDelegate.swift), not the
      // test target's.
      final phases = RegExp(
        r'isa = PBXSourcesBuildPhase;[\s\S]*?files = \(([\s\S]*?)\);',
      ).allMatches(text).map((m) => m.group(1)!);
      final runner = phases.firstWhere((p) => p.contains('AppDelegate.swift'));
      expect(runner, contains(build!.group(1)!));
      // The file is also a child of the Runner group.
      expect(
        RegExp('${ref.group(1)} /\\* CloudFolder\\.swift \\*/,').hasMatch(text),
        isTrue,
      );
    });
  }

  for (final f in ['Release', 'DebugProfile']) {
    test('macOS $f.entitlements has the bookmark entitlement', () {
      expect(
        _read('macos/Runner/$f.entitlements'),
        contains(
          '<key>com.apple.security.files.bookmarks.app-scope</key>\n\t<true/>',
        ),
      );
    });
  }

  for (final f in [
    'ios/Runner/AppDelegate.swift',
    'macos/Runner/MainFlutterWindow.swift',
  ]) {
    test('$f creates the CloudFolder', () {
      final code = _read(f)
          .split('\n')
          .where((l) => !l.trim().startsWith('//'))
          .join('\n');
      expect(code, contains('CloudFolder(messenger:'));
    });
  }

  test('the coordination block decides moved, then pending, then go', () {
    final code = _read(ios)
        .split('\n')
        .where((l) => !l.trim().startsWith('//'))
        .join('\n');
    // The decision: a moved item is refused before versions are looked at.
    final decide = code.substring(code.indexOf('static func outcome('));
    final failed = decide.indexOf('if failed { return .failed }');
    final compare = decide.indexOf(
      'CloudFolder.normalize(url.path) != CloudFolder.normalize(requested[i].path)',
    );
    final moved = decide.indexOf('return .moved(moved)');
    final versions = decide.indexOf('hasUnresolvedVersions(url)');
    final pending = decide.indexOf('return .pending(pending)');
    final go = decide.indexOf('return .go');
    expect(failed, greaterThan(-1));
    expect(compare, greaterThan(failed));
    expect(moved, greaterThan(compare));
    expect(versions, greaterThan(moved));
    expect(pending, greaterThan(versions));
    expect(go, greaterThan(pending));
    // The block sends the event of that decision, and holds only for go.
    final block = code.substring(code.indexOf('static func runBlock('));
    expect(block.indexOf('send("go"'), lessThan(block.indexOf('holdUntilReleased')));
    final accessor = code.substring(
      code.indexOf('coordinator.coordinate(with: accessIntents'),
    );
    expect(accessor, contains('CloudFolder.outcome('));
    expect(accessor, contains('CloudFolder.runBlock('));
  });

  String code() => _read(ios).split('\n').where((l) => !l.trim().startsWith('//')).join('\n');

  // The body of the `case "<name>":` of the channel's switch, up to the next case.
  String caseOf(String name) {
    final text = code();
    final start = text.indexOf('case "$name":');
    expect(start, greaterThan(-1), reason: name);
    final next = text.indexOf(RegExp(r'\n    case "'), start + 1);
    return text.substring(start, next);
  }

  test('withVersions is documented, reads metadata on a global queue, answers on main and matches by `matches`', () {
    expect(_read(ios), contains('//   withVersions({items})'));
    final call = caseOf('withVersions');
    expect(call, contains('DispatchQueue.global(qos: .userInitiated).async'));
    expect(call, contains('DispatchQueue.main.async { result(out) }'));
    expect(call, contains('bad(result, "items")'));
    final text = code();
    final changes = text.substring(text.indexOf('static func changes<V>('));
    expect(changes.substring(0, changes.indexOf('\n  }\n')), contains('matches('));
    // It is metadata only: no coordination, no copy, no resolve.
    final list = text.substring(text.indexOf('private func versionChanges('));
    final body = list.substring(0, list.indexOf('\n  }\n'));
    expect(body, isNot(contains('NSFileCoordinator')));
    expect(body, isNot(contains('copyVersion')));
    expect(body, isNot(contains('isResolved')));
    // The one matching rule is shared by resolveVersion, versions and withVersions.
    final resolve = text.substring(text.indexOf('static func resolveMatching<V>('));
    expect(resolve.substring(0, resolve.indexOf('\n  }\n')), contains('CloudFolder.matches('));
  });

  test('versions reads known, and a known that is not a list of strings is an arguments error', () {
    final call = caseOf('versions');
    expect(call, contains('args["known"]'));
    expect(call, contains('raw as? [String]'));
    expect(call, contains('bad(result, "known")'));
    expect(call, contains('copyVersions(path: path, known: known)'));
    final text = code();
    final collect = text.substring(text.indexOf('static func collectVersions<V>('));
    final body = collect.substring(0, collect.indexOf('\n  }\n'));
    expect(body, contains('knownOf'));
    expect(body, contains('"known": true'));
    // The known match runs before the nil identifier guard.
    expect(body.indexOf('knownOf(version)'), lessThan(body.indexOf('guard let id = idOf(version)')));
    // "" matches only a version with no identifier, and resolveVersion refuses it.
    final matches = text.substring(text.indexOf('static func matches<V>('));
    expect(matches.substring(0, matches.indexOf('\n  }\n')), contains('if id.isEmpty { return own == nil }'));
    final resolve = text.substring(text.indexOf('private func resolveVersion('));
    expect(resolve.substring(0, resolve.indexOf('let url')), contains('if id.isEmpty { return false }'));
  });

  test('didGain sends changed with version: true, and no other presenter callback does', () {
    final text = code();
    final gain = RegExp(r'func presentedSubitem\(at url: URL, didGain version: NSFileVersion\) \{ emit\(url\.path, nil, true\) \}');
    expect(gain.hasMatch(text), isTrue);
    expect(RegExp(r'emit\([^)]*, true\)').allMatches(text), hasLength(1));
    expect(text, contains('if version { args["version"] = true }'));
    expect(_read(ios), contains('//   changed({path, to?, version?})'));
  });

  test('the two RunnerTests files differ only in their imports', () {
    String body(String path) {
      final text = _read(path);
      return text.substring(text.indexOf('private final class Recorder'));
    }

    expect(
      body('macos/RunnerTests/RunnerTests.swift'),
      body('ios/RunnerTests/RunnerTests.swift'),
    );
    for (final dir in ['ios', 'macos']) {
      final text = _read('$dir/RunnerTests/RunnerTests.swift');
      expect(text, startsWith('// This Source Code Form is subject'));
      expect(text, contains('@testable import'));
    }
  });
}
