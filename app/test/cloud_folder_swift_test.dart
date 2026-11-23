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

  test('the coordinate accessor compares each intent URL before go', () {
    final code = _read(ios)
        .split('\n')
        .where((l) => !l.trim().startsWith('//'))
        .join('\n');
    final accessor = code.substring(
      code.indexOf('coordinator.coordinate(with: accessIntents'),
    );
    final compare = accessor.indexOf(
      'CloudFolder.normalize(intent.url.path) != CloudFolder.normalize(intents[i].path)',
    );
    final moved = accessor.indexOf('"reason": "moved"');
    final go = accessor.indexOf('self.send("go"');
    expect(compare, greaterThan(-1));
    expect(moved, greaterThan(compare));
    expect(go, greaterThan(moved));
  });
}
