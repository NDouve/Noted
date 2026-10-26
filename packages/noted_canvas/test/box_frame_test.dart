// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The BoxFrame guidelines (docs/design/components/BoxFrame), state by state,
// in both themes: values are read back from the widget tree and compared with
// the design tokens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

class _Codec extends BoxCodec<String> {
  const _Codec(this.typeId);
  @override
  final String typeId;
  @override
  int get dataVersion => 1;
  @override
  BoxApiVersion get apiVersion => boxApiVersion;
  @override
  BoxSizing get sizing => BoxSizing.fixed;
  @override
  String create() => '';
  @override
  String decode(Object? json, int storedVersion) => json! as String;
  @override
  Object? encode(String data) => data;
  @override
  String snapshotText(String data) => data;
  @override
  AiExposure aiExposure(String data) => AiText(data);
}

class _Module extends BoxModule<String> {
  const _Module(this.id);
  final String id;
  @override
  BoxCodec<String> get codec => _Codec(id);
  @override
  Widget buildEditor(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
  @override
  Widget buildView(BuildContext context, BoxContext<String> box) =>
      Text(box.data);
}

/// Like the drawing box: no idle frame.
class _Frameless extends _Module implements FramelessBoxModule {
  const _Frameless() : super('test.ink');
}

BoxRecord _box(String id, String type, {Bounds? at}) => BoxRecord.create(
  id: id,
  typeId: type,
  dataVersion: 1,
  bounds: at ?? const Bounds(100, 100, 200, 80),
  data: RawJson.encode('text'),
  snapshotText: 'text',
  rev: 'r-$id',
);

void main() {
  for (final brightness in Brightness.values) {
    group('in ${brightness.name} mode', () {
      final theme = notedThemeData(brightness);
      final scheme = theme.colorScheme;
      final colors = NotedColors.forBrightness(brightness);
      final metrics = NotedMetrics.forBrightness(brightness);
      final type = NotedTypography.withColor(scheme.onSurface);

      late ModuleRegistry modules;

      setUp(() {
        modules = ModuleRegistry()
          ..register(const _Module('test.text'), alwaysOn: true, isDefault: true)
          ..register(const _Frameless(), alwaysOn: true);
      });

      Future<CanvasController> pump(
        WidgetTester t,
        BoxRecord box, {
        bool select = false,
        bool readOnly = false,
      }) async {
        t.view.physicalSize = const Size(1200, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final c = CanvasController(
          NotedPage.create(
            PageMeta.create(id: 'p', title: '', order: 0),
          ).insertNode(box),
          modules,
        );
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: PageCanvas(controller: c, readOnly: readOnly),
            ),
          ),
        );
        await t.pump();
        if (select) {
          c.select(box.id);
          await t.pump();
        }
        return c;
      }

      BoxDecoration decorationOf(WidgetTester t, String key) =>
          t.widget<DecoratedBox>(find.byKey(ValueKey(key))).decoration
              as BoxDecoration;

      Border borderOf(WidgetTester t, String key) =>
          decorationOf(t, key).border! as Border;

      List<String> handles() => [
        'left',
        'right',
        'bottom',
        'bottomLeft',
        'bottomRight',
      ];

      testWidgets('idle: surface fill, 1px border-box, radius-lg, no shadow', (
        t,
      ) async {
        await pump(t, _box('a', 'test.text'));
        final fill = decorationOf(t, 'box-frame-fill');
        expect(fill.color, scheme.surface);
        expect(fill.borderRadius, BorderRadius.circular(metrics.radiusLg));
        expect(fill.boxShadow, isNull, reason: 'boxes have no drop shadow');
        final border = decorationOf(t, 'box-frame-border');
        final side = (border.border! as Border).top;
        expect(side.color, scheme.outlineVariant);
        expect(side.width, 1);
        expect(border.borderRadius, BorderRadius.circular(metrics.radiusLg));
        // No handles while idle.
        for (final h in handles()) {
          expect(find.byKey(ValueKey('box-handle-$h')), findsNothing);
        }
        expect(find.byKey(const ValueKey('conflict-badge')), findsNothing);
      });

      testWidgets('selected: accent border, shadow-selected, 8px handles', (
        t,
      ) async {
        await pump(t, _box('a', 'test.text'), select: true);
        final side = borderOf(t, 'box-frame-border').top;
        expect(side.color, scheme.primary);
        expect(side.width, 1);
        expect(
          decorationOf(t, 'box-frame-fill').boxShadow,
          metrics.shadowSelected,
        );
        for (final h in handles()) {
          final key = find.byKey(ValueKey('box-handle-$h'));
          expect(key, findsOneWidget, reason: h);
          expect(t.getSize(key), Size.square(metrics.handle));
          final d = decorationOf(t, 'box-handle-$h');
          expect(d.color, scheme.surface);
          expect((d.border! as Border).top.color, scheme.primary);
          expect((d.border! as Border).top.width, 1);
        }
        // On the left, right and bottom edges and the bottom corners.
        final frame = t.getRect(find.byKey(const ValueKey('box-frame-border')));
        expect(
          t.getCenter(find.byKey(const ValueKey('box-handle-left'))),
          Offset(frame.left, frame.center.dy),
        );
        expect(
          t.getCenter(find.byKey(const ValueKey('box-handle-right'))),
          Offset(frame.right, frame.center.dy),
        );
        expect(
          t.getCenter(find.byKey(const ValueKey('box-handle-bottom'))),
          Offset(frame.center.dx, frame.bottom),
        );
        expect(
          t.getCenter(find.byKey(const ValueKey('box-handle-bottomLeft'))),
          frame.bottomLeft,
        );
        expect(
          t.getCenter(find.byKey(const ValueKey('box-handle-bottomRight'))),
          frame.bottomRight,
        );
      });

      testWidgets('the larger invisible drag areas stay', (t) async {
        await pump(t, _box('a', 'test.text'), select: true);
        final handle = t.getRect(
          find.byKey(const ValueKey('box-handle-bottomRight')),
        );
        // A drag area of boxHandleSize is hit at the corner.
        final hits = find.byType(GestureDetector).evaluate().where((e) {
          final r = t.getRect(find.byWidget(e.widget));
          return r.size == const Size(boxHandleSize, boxHandleSize) &&
              r.contains(handle.center);
        });
        expect(hits, isNotEmpty);
      });

      testWidgets('drawing box: no fill and no frame while idle', (t) async {
        await pump(t, _box('a', 'test.ink'));
        expect(find.byKey(const ValueKey('box-frame-fill')), findsNothing);
        expect(find.byKey(const ValueKey('box-frame-border')), findsNothing);
        expect(find.byKey(const ValueKey('box-frame-dashed')), findsNothing);
      });

      testWidgets('drawing box: dashed accent outline and handles selected', (
        t,
      ) async {
        await pump(t, _box('a', 'test.ink'), select: true);
        expect(find.byKey(const ValueKey('box-frame-fill')), findsNothing);
        expect(find.byKey(const ValueKey('box-frame-border')), findsNothing);
        final paint = t.widget<CustomPaint>(
          find.byKey(const ValueKey('box-frame-dashed')),
        );
        final painter = paint.painter! as DashedOutlinePainter;
        expect(painter.color, scheme.primary);
        expect(painter.radius, metrics.radiusLg);
        for (final h in handles()) {
          expect(find.byKey(ValueKey('box-handle-$h')), findsOneWidget);
        }
      });

      testWidgets('conflict: 2px conflict border and a Conflict badge', (
        t,
      ) async {
        final box = _box('a', 'test.text').withConflict(
          BoxConflict.other(node: _box('a', 'test.text').toRaw(), at: 5),
        );
        await pump(t, box);
        final border = decorationOf(t, 'conflict-frame');
        expect((border.border! as Border).top.color, colors.conflict);
        expect((border.border! as Border).top.width, 2);
        final badge = decorationOf(t, 'conflict-badge');
        expect(badge.color, colors.conflict);
        expect(badge.borderRadius, metrics.borderFull);
        final text = t.widget<Text>(find.text('Conflict'));
        expect(text.style!.color, colors.onConflict);
        expect(text.style!.fontSize, type.small.fontSize);
        expect(text.style!.fontWeight, FontWeight.w600);
        // The badge overlaps the top edge of the frame, at the right.
        final frame = t.getRect(find.byKey(const ValueKey('conflict-frame')));
        final b = t.getRect(find.byKey(const ValueKey('conflict-badge')));
        expect(b.top, lessThan(frame.top));
        expect(b.bottom, greaterThan(frame.top));
        expect(b.center.dx, greaterThan(frame.center.dx));
      });

      testWidgets('read-only banner: conflict-soft, small text, why', (
        t,
      ) async {
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: ReadOnlyBanner(reason: 'The binder file was damaged.'),
            ),
          ),
        );
        final banner = t.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(ReadOnlyBanner),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect((banner.decoration as BoxDecoration).color, colors.conflictSoft);
        final why = t.widget<Text>(find.text('The binder file was damaged.'));
        expect(why.style!.fontSize, type.small.fontSize);
        expect(find.text(ReadOnlyBanner.paused), findsOneWidget);
        // Readable: text on conflict-soft passes AA.
        expect(
          contrastRatio(scheme.onSurface, colors.conflictSoft),
          greaterThanOrEqualTo(4.5),
        );
      });
    });
  }
}
