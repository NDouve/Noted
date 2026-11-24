// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The PDFKit renderer can't be compiled here; CI's macOS and iOS builds do.
// These checks keep the two copies identical and wired in.

String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  const ios = 'ios/Runner/DocumentRender.swift';
  const mac = 'macos/Runner/DocumentRender.swift';

  test('the two Swift files are identical', () {
    expect(_read(mac), _read(ios));
  });

  test('the file carries the MPL-2.0 header', () {
    expect(
      _read(ios),
      startsWith(
        '// This Source Code Form is subject to the terms of the Mozilla Public\n'
        '// License, v. 2.0. If a copy of the MPL was not distributed with this\n'
        '// file, You can obtain one at https://mozilla.org/MPL/2.0/.\n',
      ),
    );
  });

  for (final dir in ['ios', 'macos']) {
    test('$dir project lists DocumentRender.swift in its Sources phase', () {
      final text = _read('$dir/Runner.xcodeproj/project.pbxproj');
      final ref = RegExp(r'(\w{24}) /\* DocumentRender\.swift \*/ = \{isa = PBXFileReference;').firstMatch(text);
      expect(ref, isNotNull);
      final build = RegExp(
        r'(\w{24}) /\* DocumentRender\.swift in Sources \*/ = \{isa = PBXBuildFile; fileRef = ' + ref!.group(1)!,
      ).firstMatch(text);
      expect(build, isNotNull);
      final phases = RegExp(r'isa = PBXSourcesBuildPhase;[\s\S]*?files = \(([\s\S]*?)\);').allMatches(text).map((m) => m.group(1)!);
      expect(phases.firstWhere((p) => p.contains('AppDelegate.swift')), contains(build!.group(1)!));
      expect(text, contains('${ref.group(1)} /* DocumentRender.swift */,'));
    });
  }

  for (final f in ['ios/Runner/AppDelegate.swift', 'macos/Runner/MainFlutterWindow.swift']) {
    test('$f creates the DocumentRender', () {
      final code = _read(f).split('\n').where((l) => !l.trim().startsWith('//')).join('\n');
      expect(code, contains('DocumentRender(messenger:'));
    });
  }

  test('the macOS AppDelegate has no applicationDidFinishLaunching override', () {
    expect(_read('macos/Runner/AppDelegate.swift'), isNot(contains('applicationDidFinishLaunching')));
  });
}
