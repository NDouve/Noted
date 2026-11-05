// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/link_log.dart';
import 'package:noted_box_note/noted_box_note.dart';

void main() {
  late Directory dir;
  late File file;
  final original = linkLog;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noted-linklog-test');
    file = File('${dir.path}${Platform.pathSeparator}logs${Platform.pathSeparator}link.log');
    installLinkLog(file);
  });

  tearDown(() {
    linkLog = original;
    dir.deleteSync(recursive: true);
  });

  test('a line is appended to the file, creating its folder', () {
    linkLog('insert link: started');
    linkLog('insert link: dialog opened');
    final lines = file.readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines[0], endsWith(' insert link: started'));
    expect(lines[1], endsWith(' insert link: dialog opened'));
  });

  test('the file starts over once it is past the limit', () {
    file.createSync(recursive: true);
    file.writeAsStringSync('x' * (linkLogLimit + 1));
    linkLog('insert link: started');
    expect(file.lengthSync(), lessThan(200));
    expect(file.readAsStringSync(), contains('insert link: started'));
  });

  test('a file that cannot be written does not throw', () {
    // A folder where the file should be.
    Directory(file.path).createSync(recursive: true);
    expect(() => linkLog('insert link: started'), returnsNormally);
  });

  test('the default file is in the local app data, never derived from the pages folder', () {
    final path = defaultLinkLogFile()!.path;
    expect(path, endsWith('logs${Platform.pathSeparator}link.log'));
    if (Platform.isWindows) expect(path, startsWith(Platform.environment['LOCALAPPDATA']!));
  });
}
