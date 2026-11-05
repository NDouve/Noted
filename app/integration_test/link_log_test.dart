// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Insert link leaves a trace in the link log (what a release build, which
// prints nowhere, is traced by). Run from `app/`:
//
//     flutter test integration_test/link_log_test.dart -d windows

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noted/src/link_log.dart';

import 'support/harness.dart';
import 'support/note_helpers.dart';
import 'support/semantics_guard.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  ignorePlatformSemantics();

  testWidgets('Ctrl+K, an address and Enter put a link in the note and fixed lines in the log', (t) async {
    final dir = await Directory.systemTemp.createTemp('noted-linklog');
    final log = File('${dir.path}${Platform.pathSeparator}logs${Platform.pathSeparator}link.log');
    installLinkLog(log);
    try {
      await withSession(t, 'linklog', (s) async {
        final id = addNote(s, [para('go: ')]);
        await s.pump(400);
        final editor = await editNote(s, id);
        final sel = editor.selection;
        final at = sel.start.copyWith(path: [0], offset: 4);
        editor.selection = sel.copyWith(start: at, end: at);
        await s.pump(200);
        await s.ctrl(LogicalKeyboardKey.keyK);
        await s.pump(300);
        expect(find.text('Insert link'), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('link-address')), 'https://secret-address.example');
        await t.testTextInput.receiveAction(TextInputAction.done);
        await s.pump(600);

        final ops = (editorState(t).getNodeAtPath([0]).delta.toJson() as List).cast<dynamic>();
        expect(
          ops.any((op) => (op['attributes'] as Map?)?['href'] == 'https://secret-address.example'),
          isTrue,
          reason: 'the link is in the note',
        );
        final text = await log.readAsString();
        for (final line in const [
          'insert link: Ctrl+K reached the editor',
          'insert link: started',
          'insert link: dialog opened',
          'insert link: dialog closed (SetLink)',
          'insert link: inserted at caret',
        ]) {
          expect(text, contains(line));
        }
        // Fixed lines only: neither the address nor the note's text.
        expect(text, isNot(contains('secret-address')));
        expect(text, isNot(contains('go:')));
      });
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
