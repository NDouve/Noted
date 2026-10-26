// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/main.dart';
import 'package:noted/src/app_settings.dart';
import 'package:noted/src/app_theme.dart';
import 'package:noted/src/binder_colors.dart';
import 'package:noted/src/binder_cover.dart';
import 'package:noted/src/notebook.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

BoxRecord _note(String id, Map<String, Object?> doc, Bounds at) {
  const codec = NoteCodec();
  final data = NoteData({'document': doc});
  return BoxRecord.create(
    id: id,
    typeId: NoteCodec.id,
    dataVersion: 1,
    bounds: at,
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: 'r-$id',
  );
}

Map<String, Object?> _para(String text) => {
  'type': 'paragraph',
  'data': {
    'delta': [
      {'insert': text},
    ],
  },
};

Map<String, Object?> _table() => {
  'type': 'table',
  'data': {
    'colsLen': 2,
    'rowsLen': 1,
    'colDefaultWidth': 80.0,
    'rowDefaultHeight': 40.0,
    'colMinimumWidth': 40.0,
    'borderWidth': 2.0,
  },
  'children': [
    for (var c = 0; c < 2; c++)
      {
        'type': 'table/cell',
        'data': {'colPosition': c, 'rowPosition': 0},
        'children': [_para(c == 0 ? '4' : '=A1*2')],
      },
  ],
};

Stroke _stroke(String id, int color, double y) => Stroke(
  id: id,
  color: color,
  size: 4,
  points: Float64List.fromList([
    for (var i = 0; i < 5; i++) ...[10.0 + i * 20, y, 0.5, i * 10.0],
  ]),
);

BoxRecord _drawing() {
  const codec = DrawingCodec();
  final data = DrawingData(
    strokes: [
      _stroke('a-default', defaultInkValue, 20),
      _stroke('b-blue', 0xFF1F5FD6, 50),
    ],
  );
  return BoxRecord.create(
    id: 'draw',
    typeId: DrawingCodec.id,
    dataVersion: 1,
    bounds: Bounds(100, 400, 200, 100),
    data: RawJson.encode(codec.encode(data)),
    snapshotText: codec.snapshotText(data),
    rev: 'r-draw',
  );
}

CanvasController _page() {
  final plain = _note('plain', {
    'type': 'page',
    'children': [_para('hello'), _table()],
  }, Bounds(100, 100, 400, 40));
  final math = _note('math', {
    'type': 'page',
    'children': [
      {
        'type': 'math_equation',
        'data': {'formula': 'x^2'},
      },
    ],
  }, Bounds(550, 100, 300, 60));
  final theirs = _note('mine', {
    'type': 'page',
    'children': [_para('theirs')],
  }, Bounds(550, 300, 300, 60));
  final mine = _note('mine', {
    'type': 'page',
    'children': [_para('mine')],
  }, Bounds(550, 300, 300, 60)).withConflict(
    BoxConflict.other(node: theirs.toRaw(), at: 1000),
  );
  var page = NotedPage.create(PageMeta.create(id: 'p', title: '', order: 0));
  for (final b in [plain, math, _drawing(), mine]) {
    page = page.insertNode(b);
  }
  return CanvasController(page, buildModules());
}

Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

void main() {
  group('themed page', () {
    for (final brightness in Brightness.values) {
      testWidgets('renders in ${brightness.name} mode', (t) async {
        t.view.physicalSize = const Size(1200, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final c = _page();
        final mode = brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light;
        await t.pumpWidget(
          MaterialApp(
            theme: buildNotedTheme(Brightness.light),
            darkTheme: buildNotedTheme(Brightness.dark),
            themeMode: mode,
            localizationsDelegates: noteLocalizationsDelegates,
            home: Scaffold(body: PageCanvas(controller: c)),
          ),
        );
        await t.pumpAndSettle();
        final theme = buildNotedTheme(brightness);
        final scheme = theme.colorScheme;
        final noted = theme.extension<NotedColors>()!;

        // Drawing: default ink adapts; a chosen color is kept (lifted on the
        // dark canvas when it would be too faint).
        final painterFinder = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is StrokesPainter,
        );
        expect(painterFinder, findsOneWidget);
        final painter =
            t.widget<CustomPaint>(painterFinder).painter! as StrokesPainter;
        expect(painter.resolvedColors, [
          brightness == Brightness.dark
              ? DesignColors.dark.inkDefault
              : DesignColors.light.inkDefault,
          displayInkColor(0xFF1F5FD6, brightness),
        ]);
        expect(
          painter.resolvedColors[1],
          brightness == Brightness.dark
              ? isNot(const Color(0xFF1F5FD6))
              : const Color(0xFF1F5FD6),
        );
        expect(painter.resolvedColors.first, noted.inkDefault);

        // Formula result and equation are drawn.
        expect(find.byKey(const ValueKey('formula-value')), findsOneWidget);
        expect(
          t.widget<Text>(find.byKey(const ValueKey('formula-value'))).style?.color,
          scheme.onSurface,
        );

        // Conflict badge and frame use the theme's conflict colors.
        final badge = t.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const ValueKey('conflict-badge-mine')),
            matching: find.byType(DecoratedBox),
          ),
        );
        expect((badge.decoration as BoxDecoration).color, noted.conflict);
        final badgeText = t.widget<Text>(find.text('Conflict'));
        expect(badgeText.style?.color, noted.onConflict);
        final frame = t.widget<DecoratedBox>(
          find.byKey(const ValueKey('conflict-frame')),
        );
        expect(
          ((frame.decoration as BoxDecoration).border! as Border).top.color,
          noted.conflict,
        );

        // Box border and grip while selected come from the color scheme.
        c.select('plain');
        await t.pump();
        final borders = t
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .where((d) {
              final dec = d.decoration;
              return dec is BoxDecoration &&
                  dec.border is Border &&
                  (dec.border! as Border).top.color == scheme.primary &&
                  (dec.border! as Border).top.width == 1;
            });
        expect(borders, isNotEmpty);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('a theme change repaints the same page', (t) async {
      t.view.physicalSize = const Size(1200, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = _page();
      Widget app(ThemeMode mode) => MaterialApp(
        theme: buildNotedTheme(Brightness.light),
        darkTheme: buildNotedTheme(Brightness.dark),
        themeMode: mode,
        localizationsDelegates: noteLocalizationsDelegates,
        home: Scaffold(body: PageCanvas(controller: c)),
      );
      List<Color> colors() {
        final f = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is StrokesPainter,
        );
        return (t.widget<CustomPaint>(f).painter! as StrokesPainter)
            .resolvedColors;
      }

      await t.pumpWidget(app(ThemeMode.light));
      await t.pumpAndSettle();
      expect(colors().first, DesignColors.light.inkDefault);
      await t.pumpWidget(app(ThemeMode.dark));
      await t.pumpAndSettle();
      expect(colors().first, DesignColors.dark.inkDefault);

      // Follow system reacts to the OS changing while running.
      t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      await t.pumpWidget(app(ThemeMode.system));
      await t.pumpAndSettle();
      expect(colors().first, DesignColors.light.inkDefault);
      t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await t.pumpAndSettle();
      expect(colors().first, DesignColors.dark.inkDefault);
    });
  });

  group('ink', () {
    test('default ink follows the theme; swatch inks show as stored in light', () {
      expect(displayInkColor(defaultInkValue, Brightness.light), DesignColors.light.inkDefault);
      expect(displayInkColor(defaultInkValue, Brightness.dark), DesignColors.dark.inkDefault);
      for (final v in PenSettings.colors.skip(1)) {
        expect(displayInkColor(v, Brightness.light), Color(v));
      }
      expect(defaultInkValue, PenSettings.colors.first);
      expect(displayInkColor(0xFF202125, Brightness.dark), const Color(0xFF202125));
    });

    test('every swatch ink is at least 3:1 against bg-canvas in both themes', () {
      for (final v in PenSettings.colors) {
        expect(
          contrastRatio(displayInkColor(v, Brightness.light), DesignColors.light.bgCanvas),
          greaterThanOrEqualTo(3),
          reason: 'light ${v.toRadixString(16)}',
        );
        expect(
          contrastRatio(displayInkColor(v, Brightness.dark), DesignColors.dark.bgCanvas),
          greaterThanOrEqualTo(3),
          reason: 'dark ${v.toRadixString(16)}',
        );
      }
    });

    test('purple and blue are lifted on the dark canvas only; the others stay', () {
      final purple = DesignColors.light.inkPurple;
      final blue = DesignColors.light.inkBlue;
      final shownPurple = displayInkColor(purple.toARGB32(), Brightness.dark);
      expect(shownPurple, isNot(purple));
      expect(HSLColor.fromColor(shownPurple).hue, closeTo(HSLColor.fromColor(purple).hue, 1));
      expect(HSLColor.fromColor(shownPurple).lightness, greaterThan(HSLColor.fromColor(purple).lightness));
      expect(displayInkColor(blue.toARGB32(), Brightness.dark), isNot(blue));
      for (final ink in [DesignColors.light.inkOrange, DesignColors.light.inkGreen]) {
        expect(displayInkColor(ink.toARGB32(), Brightness.dark), ink);
      }
    });
  });

  group('contrast', () {
    for (final brightness in Brightness.values) {
      test('key pairs meet WCAG AA in ${brightness.name} mode', () {
        final theme = buildNotedTheme(brightness);
        final s = theme.colorScheme;
        final n = theme.extension<NotedColors>()!;
        final readout = _over(n.readoutBackground, s.surface);
        // (name, foreground, background, minimum)
        final pairs = <(String, Color, Color, double)>[
          ('body text / canvas', s.onSurface, s.surface, 4.5),
          ('default ink / canvas', n.inkDefault, s.surface, 7),
          ('link / canvas', s.primary, s.surface, 4.5),
          ('error text / dialog', s.error, s.surfaceContainerHigh, 4.5),
          ('conflict badge text', n.onConflict, n.conflict, 4.5),
          ('readout text', n.onReadout, readout, 4.5),
          ('selected box border, cursor / canvas', s.primary, s.surface, 3),
          // border and border-box are hairlines (about 1.3:1) by design; see
          // docs/design/README.md. Not asserted at 3:1.
          ('conflict frame / canvas', n.conflict, s.surface, 3),
          ('conflict marker / sidebar', n.conflict, s.surfaceContainerLow, 3),
          ('eraser ring / canvas', n.toolRing, s.surface, 3),
          ('toolbar icon / toolbar', s.onSurfaceVariant, s.surfaceContainer, 4.5),
          ('slash menu text', s.onSurface, s.surfaceContainerHigh, 4.5),
          ('slash menu selected', s.onSecondaryContainer, s.secondaryContainer, 4.5),
          ('menu / selected row text', s.onSecondaryContainer, s.secondaryContainer, 4.5),
          ('todo checkbox / canvas', s.primary, s.surface, 3),
        ];
        for (final (name, fg, bg, min) in pairs) {
          final r = contrastRatio(fg, bg);
          // ignore: avoid_print
          print('${brightness.name} | $name | ${r.toStringAsFixed(2)} (min $min)');
          expect(r, greaterThanOrEqualTo(min), reason: name);
        }
      });
    }

    test('contrastRatio matches known values', () {
      expect(
        contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21, 0.001),
      );
      expect(
        contrastRatio(const Color(0xFF777777), const Color(0xFFFFFFFF)),
        closeTo(4.48, 0.02),
      );
    });
  });

  group('binder colors', () {
    for (final brightness in Brightness.values) {
      test('every palette color reaches 3:1 in ${brightness.name} mode', () {
        final s = buildNotedTheme(brightness).colorScheme;
        for (final hex in binderPalette) {
          final stored = parseBinderColor(hex);
          for (final surface in [s.surfaceContainerLow, s.surface]) {
            final shown = binderDisplayColor(stored, surface, brightness);
            final r = contrastRatio(shown, surface);
            // ignore: avoid_print
            print('${brightness.name} | binder $hex | ${r.toStringAsFixed(2)}');
            expect(r, greaterThanOrEqualTo(3.0), reason: hex);
            // The hue stays recognizable.
            final a = HSLColor.fromColor(stored).hue;
            final b = HSLColor.fromColor(shown).hue;
            expect((a - b).abs() < 8 || (a - b).abs() > 352, isTrue, reason: hex);
          }
          // The stored value is untouched.
          expect(parseBinderColor(hex), stored);
        }
      });
    }

    test('a color that already contrasts is shown as stored', () {
      const dark = Color(0xFF101010);
      expect(binderDisplayColor(const Color(0xFFFFFF00), dark, Brightness.dark), const Color(0xFFFFFF00));
    });
  });

  group('settings', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('noted_settings');
      file = File('${dir.path}/sub/settings.json');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('default is Follow system and nothing is written', () {
      final s = AppSettings(file);
      expect(s.theme, ThemeSetting.system);
      expect(s.themeMode, ThemeMode.system);
      expect(file.existsSync(), isFalse);
    });

    test('Dark and Light persist and survive a new instance', () {
      final s = AppSettings(file);
      s.theme = ThemeSetting.dark;
      expect(jsonDecode(file.readAsStringSync()), {'format': 1, 'theme': 'dark'});
      expect(AppSettings(file).theme, ThemeSetting.dark);
      s.theme = ThemeSetting.light;
      expect(AppSettings(file).theme, ThemeSetting.light);
      expect(AppSettings(file).themeMode, ThemeMode.light);
    });

    test('unknown fields are kept', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"format":1,"theme":"light","future":{"a":[1,2]}}');
      final s = AppSettings(file);
      expect(s.theme, ThemeSetting.light);
      s.theme = ThemeSetting.dark;
      expect(jsonDecode(file.readAsStringSync()), {
        'format': 1,
        'theme': 'dark',
        'future': {
          'a': [1, 2],
        },
      });
    });

    test('a corrupt file gives the defaults and is not touched', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{not json');
      final s = AppSettings(file);
      expect(s.theme, ThemeSetting.system);
      expect(file.readAsStringSync(), '{not json');
      s.theme = ThemeSetting.dark;
      expect(AppSettings(file).theme, ThemeSetting.dark);
    });

    test('an unknown theme value reads as Follow system', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{"format":1,"theme":"sepia"}');
      expect(AppSettings(file).theme, ThemeSetting.system);
    });
  });

  group('settings menu', () {
    testWidgets('choosing Dark applies at once and is saved', (t) async {
      late Directory dir;
      late Notebook nb;
      late File file;
      await t.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('noted_settings_ui');
        file = File('${dir.path}/settings.json');
        nb = Notebook(
          PageStore(Directory('${dir.path}/pages')..createSync()),
          buildModules(),
          saveDelay: Duration.zero,
        );
        await nb.load();
      });
      t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      final settings = AppSettings(file);
      await t.pumpWidget(NotedApp(notebook: nb, settings: settings));
      await t.pump();
      Brightness shown() =>
          Theme.of(t.element(find.byKey(const ValueKey('settings-menu')))).brightness;
      expect(shown(), Brightness.light);

      await t.tap(find.byKey(const ValueKey('settings-menu')));
      await t.pumpAndSettle();
      expect(find.text('Follow system'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('theme-dark')));
      await t.pumpAndSettle();
      expect(shown(), Brightness.dark);
      expect(settings.theme, ThemeSetting.dark);
      expect(jsonDecode(file.readAsStringSync()), {'format': 1, 'theme': 'dark'});

      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await nb.flush();
        nb.dispose();
        await dir.delete(recursive: true);
      });
    });
  });
}
