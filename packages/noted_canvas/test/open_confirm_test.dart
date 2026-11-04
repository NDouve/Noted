// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  const win = RunnablePlatform.windows;
  const mac = RunnablePlatform.macos;
  const lin = RunnablePlatform.linux;
  const and = RunnablePlatform.android;

  bool run(String n, RunnablePlatform p, {String? pathExt}) =>
      isRunnableFileName(n, platform: p, pathExt: pathExt ?? '');

  group('Windows', () {
    test('the fixed list, in any case', () {
      final all =
          ('exe bat cmd com ps1 vbs vbe js jse wsf wsh msc lnk url msi msp scr cpl hta pif reg jar '
                  'appref-ms application xbap settingcontent-ms scf chm inf ws wsc sct shb shs psm1 psd1 '
                  'ps1xml psc1 msix msixbundle appx appxbundle diagcab library-ms search-ms website xll '
                  'iso img vhd vhdx')
              .split(' ');
      for (final e in all) {
        expect(run('x.$e', win), isTrue, reason: e);
        expect(run('X.${e.toUpperCase()}', win), isTrue, reason: e);
      }
    });
    test('PATHEXT adds extensions, parsed defensively', () {
      expect(run('x.py', win), isFalse);
      expect(run('x.py', win, pathExt: '.COM;.EXE;.PY'), isTrue);
      expect(run('x.rb', win, pathExt: ' ; .exe;;rb ;..;a b;.x/y'), isTrue);
      expect(run('x.xy', win, pathExt: ';.x/y;.a b'), isFalse);
      expect(pathExtExtensions(null), isEmpty);
    });
    test('a missing PATHEXT still uses the fixed list', () {
      expect(isRunnableFileName('a.exe', platform: win, pathExt: ''), isTrue);
    });
    test('trailing dots and spaces are stripped', () {
      expect(run('x.exe.', win), isTrue);
      expect(run('x.exe ', win), isTrue);
      expect(run('x.exe. . ', win), isTrue);
    });
    test('trailing separators are ignored', () {
      expect(lastExtension('Evil.app/'), 'app');
      expect(lastExtension('dir\\Evil.app\\'), 'app');
      expect(run('Evil.app/', mac), isTrue);
      expect(run('x.exe/ /', win), isTrue);
    });
    test('only the last extension counts', () {
      expect(run('report.pdf.exe', win), isTrue);
      expect(run('report.exe.pdf', win), isFalse);
    });
    test('documents and no extension are not runnable', () {
      expect(run('plan.pdf', win), isFalse);
      expect(run('README', win), isFalse);
      expect(run('', win), isFalse);
      expect(run('dir.exe/plan', win), isFalse);
    });
  });

  test('macOS list', () {
    const all =
        'app command tool sh pkg mpkg dmg terminal workflow jar scpt applescript fileloc inetloc webloc jnlp scptd';
    for (final e in all.split(' ')) {
      expect(run('x.$e', mac), isTrue, reason: e);
    }
    expect(run('x.APP', mac), isTrue);
    expect(run('x.exe', mac), isFalse);
    expect(run('x.pdf', mac), isFalse);
  });

  test('Linux and Android lists', () {
    for (final e in 'sh run bin appimage desktop jar py pl'.split(' ')) {
      expect(run('x.$e', lin), isTrue, reason: e);
      expect(run('x.$e', and), isTrue, reason: e);
    }
    expect(run('x.AppImage', lin), isTrue);
    expect(run('x.exe', lin), isFalse);
    expect(run('x.pdf', lin), isFalse);
    expect(run('x.apk', and), isTrue);
    expect(run('x.apk', lin), isFalse);
  });

  test('either the shown name or the stored name asks', () {
    bool ask(String shown, String? stored) => needsOpenConfirmation(
      displayName: shown,
      storedName: stored,
      platform: win,
      pathExt: '',
    );
    expect(ask('a.exe', 'h.pdf'), isTrue);
    expect(ask('a.pdf', 'h.exe'), isTrue);
    expect(ask('a.pdf', 'h.pdf'), isFalse);
    expect(ask('a.pdf', null), isFalse);
  });

  test('cleanNameForDisplay replaces bidi and control characters', () {
    final clean = cleanNameForDisplay('a\u202Efdp.exe\u2066\u200F\u061C\n');
    expect(clean, isNot(contains('\u202E')));
    expect(clean, isNot(contains('\u2066')));
    expect(clean, isNot(contains('\u200F')));
    expect(clean, isNot(contains('\u061C')));
    expect(clean, isNot(contains('\n')));
    expect(clean, contains('.exe'));
  });

  test(
    'cleanNameForDisplay shortens in the middle and keeps the extension',
    () {
      final clean = cleanNameForDisplay('${'a' * 5000}.exe');
      expect(clean.length, lessThanOrEqualTo(80));
      expect(clean, endsWith('.exe'));
      expect(clean, contains('…'));
      expect(clean, contains('… .exe'));
      expect(cleanNameForDisplay('short.exe'), 'short.exe');
    },
  );

  group('the dialog', () {
    Future<void> show(WidgetTester t, String name, List<bool> answers) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  answers.add(await confirmOpenRunnable(context, name)),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
    }

    testWidgets(
      'names the file, the type and the warning separately; Cancel is false',
      (t) async {
        final answers = <bool>[];
        await show(t, 'tool.jar', answers);
        expect(
          find.byKey(const ValueKey('open-confirm-dialog')),
          findsOneWidget,
        );
        expect(find.text('tool.jar'), findsOneWidget);
        expect(find.text('Type: .jar'), findsOneWidget);
        expect(find.byKey(const ValueKey('open-confirm-text')), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('open-confirm-cancel')));
        await t.pumpAndSettle();
        expect(answers, [false]);
      },
    );

    testWidgets('the dialog stays narrow for a long name', (t) async {
      await show(t, '${'a' * 5000}.exe', <bool>[]);
      final w = t
          .getSize(find.byKey(const ValueKey('open-confirm-text')))
          .width;
      expect(w, lessThanOrEqualTo(600));
    });

    testWidgets('the type shown is the one that raised the question', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => confirmOpenRunnable(context, 'a.pdf', storedName: 'h.jar'),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Type: .jar'), findsOneWidget);
    });

    testWidgets('Escape is false, Open is true', (t) async {
      final answers = <bool>[];
      await show(t, 'tool.jar', answers);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('open-confirm-open')));
      await t.pumpAndSettle();
      expect(answers, [false, true]);
    });

    testWidgets('a right-to-left override name is shown cleaned', (t) async {
      final answers = <bool>[];
      await show(t, 'invoice\u202Efdp.exe', answers);
      final shown = (t.widget(
        find.byKey(const ValueKey('open-confirm-name')),
      ) as Text).data!;
      expect(shown, isNot(contains('\u202E')));
      expect(find.text('Type: .exe'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-confirm-text')), findsOneWidget);
    });

    testWidgets(
      'a 5000-character name is shortened; warning and type stay visible',
      (t) async {
        final answers = <bool>[];
        await show(t, '${'a' * 5000}.exe', answers);
        final shown = (t.widget(
          find.byKey(const ValueKey('open-confirm-name')),
        ) as Text).data!;
        expect(shown.length, lessThanOrEqualTo(80));
        expect(shown, endsWith('.exe'));
        expect(find.text('Type: .exe'), findsOneWidget);
        expect(find.byKey(const ValueKey('open-confirm-text')), findsOneWidget);
        expect(find.byKey(const ValueKey('open-confirm-open')), findsOneWidget);
      },
    );
  });
}
