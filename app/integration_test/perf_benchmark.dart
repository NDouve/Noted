// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Performance benchmark: a page with 200 note boxes and 20 drawing boxes.
// It is not part of the checklist entry point. Run from `app/`:
//
//     flutter test integration_test/perf_benchmark.dart -d windows
//
// (debug build), or, for numbers that mean something:
//
//     flutter drive --driver=integration_test/perf_driver.dart \
//         --target=integration_test/perf_benchmark.dart -d windows --profile
//
// It prints one `PERF_SUMMARY {json}` line. See
// docs/testing/checklist-coverage.md ("Performance benchmark").
//
// Measured, against a 16 ms frame budget:
//
// * page open: `Notebook.open` to the first frame, and to the frame after
//   which every box is laid out and no box changes its height any more;
// * typing: for each of 200 characters (PERF_KEYSTROKES), the time from
//   applying the editor transaction to the end of the frame that shows it
//   (the build and layout side, on the UI thread), plus the build and raster
//   time of those frames; each keystroke over 50 ms is listed with the number
//   of note editors in the tree, whether one was mounted just before it,
//   and, since the keystroke before, whether the note's height changed and
//   whether the canvas rebuilt the other boxes;
// * panning (mouse wheel) and zooming (Ctrl + wheel): build and raster time of
//   every frame (`FrameTiming`), as average, 90th and 99th percentile, worst,
//   and the number of frames over 16 ms.
//
// Typing goes through the editor's transaction, as the other integration
// tests do: synthetic key events do not produce IME text. The transaction is
// what the IME's text input ends in, so the rebuild, layout and paint that a
// keystroke causes are the same; only the platform text-input hop is missing.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'support/harness.dart';
import 'support/note_helpers.dart';
import 'support/semantics_guard.dart';

const int noteCount = 200;
const int drawingCount = 20;
const int columns = 22;
const double cellW = 420;
const double cellH = 250;
const double frameBudgetMs = 16;

/// Characters typed in the typing measurement. Override with
/// `--dart-define=PERF_KEYSTROKES=<n>`.
const int _keystrokes = int.fromEnvironment('PERF_KEYSTROKES', defaultValue: 200);

/// The note editors (`AppFlowyEditor`) in the tree. By type name: the app
/// doesn't depend on appflowy_editor directly.
int _editorCount() =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == 'AppFlowyEditor').evaluate().length;

/// The kind of note at slot [i]: mostly one paragraph, some several, one in
/// ten with a 3 x 3 table with formulas.
String _kind(int i) => switch (i % 10) {
  6 || 7 || 8 => 'multi',
  9 => 'table',
  _ => 'plain',
};

List<Map<String, Object?>> _noteContent(int i) {
  switch (_kind(i)) {
    case 'multi':
      return [
        for (var p = 0; p < 5; p++)
          para('Note $i, paragraph ${p + 1}: the quick brown fox jumps over the lazy dog, and then once more over the sleeping cat by the door.'),
      ];
    case 'table':
      return [
        para('Table $i'),
        table([
          ['1', '2', '=A1+B1'],
          ['3', '4', '=A2*B2'],
          ['5', '6', '=SUM(A1:A3)'],
        ]),
      ];
    default:
      return [para('Note $i: a short line of plain text for the benchmark.')];
  }
}

double _noteHeight(int i) => switch (_kind(i)) {
  'multi' => 190,
  'table' => 190,
  _ => 62,
};

DrawingData _drawing(int seed) {
  final rnd = math.Random(seed);
  final strokes = <Stroke>[];
  for (var s = 0; s < 36; s++) {
    final n = 30 + rnd.nextInt(30);
    var x = 20 + rnd.nextDouble() * 300;
    var y = 20 + rnd.nextDouble() * 160;
    var a = rnd.nextDouble() * math.pi * 2;
    final pts = <double>[];
    for (var k = 0; k < n; k++) {
      a += (rnd.nextDouble() - 0.5) * 0.6;
      x = (x + math.cos(a) * 4).clamp(8, 350).toDouble();
      y = (y + math.sin(a) * 4).clamp(8, 210).toDouble();
      pts.addAll([x, y, 0.5, k * 8.0]);
    }
    strokes.add(Stroke(id: 'd$seed-$s', points: Float64List.fromList(pts), t0: s));
  }
  return DrawingData(strokes: strokes);
}

/// The build, raster and total time of every frame the engine reports.
class _Frames {
  final List<double> build = [];
  final List<double> raster = [];
  final List<double> total = [];

  void add(List<FrameTiming> timings) {
    for (final t in timings) {
      build.add(t.buildDuration.inMicroseconds / 1000);
      raster.add(t.rasterDuration.inMicroseconds / 1000);
      total.add(t.totalSpan.inMicroseconds / 1000);
    }
  }
}

Map<String, Object> _stats(List<double> v) {
  if (v.isEmpty) return {'count': 0};
  final s = [...v]..sort();
  double pct(double p) => s[((s.length - 1) * p).round()];
  double r(double x) => (x * 100).round() / 100;
  return {
    'count': s.length,
    'avg': r(s.reduce((a, b) => a + b) / s.length),
    'p90': r(pct(0.9)),
    'p99': r(pct(0.99)),
    'worst': r(s.last),
    'over16': s.where((x) => x > frameBudgetMs).length,
    // Spikes the user feels as a stutter while typing.
    'over50': s.where((x) => x > 50).length,
    'over50Pct': r(100 * s.where((x) => x > 50).length / s.length),
  };
}

Map<String, Object> _frameStats(_Frames f) => {'build': _stats(f.build), 'raster': _stats(f.raster), 'total': _stats(f.total)};

/// Runs [action] while collecting the frame timings it causes. The engine
/// batches timings and reports them about once a second, so wait before (to
/// drop old ones) and after (to receive the new ones), as `watchPerformance`
/// does.
Future<_Frames> _watch(Future<void> Function() action) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  final frames = _Frames();
  SchedulerBinding.instance.addTimingsCallback(frames.add);
  try {
    await action();
    await Future<void>.delayed(const Duration(seconds: 2));
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(frames.add);
  }
  return frames;
}

double _ms(Stopwatch w) => (w.elapsedMicroseconds / 100).round() / 10;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  ignorePlatformSemantics();

  testWidgets('perf: a page with $noteCount notes and $drawingCount drawings', (t) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final summary = <String, Object?>{
      'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'notes': noteCount,
      'drawings': drawingCount,
      'frameBudgetMs': frameBudgetMs,
    };
    await withSession(t, 'perf', (s) async {
      // Set up: the page, laid out on a grid, saved to disk.
      final pageId = await s.newPage('Benchmark');
      final c = s.nb.current!;
      final noteCodec = c.modules.defaultModule.codec;
      const drawingCodec = DrawingCodec();
      var noteIndex = 0;
      var drawIndex = 0;
      final firstPlain = <String>[];
      for (var slot = 0; slot < noteCount + drawingCount; slot++) {
        final x = (slot % columns) * cellW;
        final y = (slot ~/ columns) * cellH;
        if (slot % 11 == 10 && drawIndex < drawingCount) {
          final box = createBox(drawingCodec, Bounds(x, y, 360, 220));
          c.insertBox(commitBox(box, drawingCodec, _drawing(drawIndex++)));
        } else {
          final i = noteIndex++;
          final box = createBox(noteCodec, Bounds(x, y, 360, _noteHeight(i)));
          final data = noteCodec.decode({
            'document': {'type': 'page', 'children': _noteContent(i)},
          }, 1);
          final rec = commitBox(box, noteCodec, data);
          c.insertBox(rec);
          if (_kind(i) == 'plain' && firstPlain.length < 3) firstPlain.add(rec.id);
        }
      }
      expect(noteIndex, noteCount);
      expect(drawIndex, drawingCount);
      final saveWatch = Stopwatch()..start();
      await s.flush();
      summary['setupFlushMs'] = _ms(saveWatch);
      await s.newPage('Other');
      await s.pump(400);

      // Page open.
      final open = Stopwatch()..start();
      await s.nb.open(pageId);
      final opened = open.elapsed;
      await t.pump();
      final firstFrame = open.elapsed;
      String heights() => [for (final n in s.nb.current!.page.nodes) n.bounds!.height.round()].join(',');
      var last = '';
      var stable = 0;
      var frames = 1;
      while (stable < 3 && frames < 200) {
        await t.pump();
        frames++;
        final h = heights();
        stable = h == last ? stable + 1 : 0;
        last = h;
      }
      final settled = open.elapsed;
      expect(find.byType(BoxHost), findsNWidgets(noteCount + drawingCount));
      summary['open'] = {
        'readAndModelMs': (opened.inMicroseconds / 100).round() / 10,
        'firstFrameMs': (firstFrame.inMicroseconds / 100).round() / 10,
        'settledMs': (settled.inMicroseconds / 100).round() / 10,
        'framesToSettle': frames,
      };
      await s.pump(500);

      // Typing: _keystrokes characters into a plain note.
      final target = firstPlain.first;
      final before = snapshotOf(s, target);
      final editor = await editNote(s, target);
      await s.pump(300);
      final latencies = <double>[];
      final applyTimes = <double>[];
      // Every keystroke over 50 ms, with the number of note editors in the
      // tree before and after it, and whether an editor was mounted since
      // the keystroke before (the first keystroke counts the one editNote
      // mounted). Also, since the previous keystroke's frame: whether the
      // note's height changed, and whether the canvas rebuilt the other boxes
      // (another box's BoxHost widget is a new instance); a box grows after
      // its frame (requestBounds), so the canvas rebuilds in a frame between
      // keystrokes. `canvasRebuiltInFrame` is a rebuild in this keystroke's
      // own frame. Counted outside the timed part.
      final slow = <Map<String, Object>>[];
      var editors = _editorCount();
      var mounted = true;
      var heightChanges = 0;
      var hostRebuilds = 0;
      final other = find.byKey(ValueKey(firstPlain.last));
      double targetHeight() => s.nb.current!.page.node(target)!.bounds!.height;
      var lastHeight = targetHeight();
      var lastHost = t.widget(other);
      late _Frames typing;
      await binding.watchPerformance(() async {
        typing = await _watch(() async {
          for (var k = 0; k < _keystrokes; k++) {
            final node = editor.document.root.children.first;
            final at = (node.delta.toPlainText() as String).length;
            final hostAtStart = t.widget(other);
            final w = Stopwatch()..start();
            await insertTextAt(editor, node, at, String.fromCharCode(97 + k % 26));
            applyTimes.add(w.elapsedMicroseconds / 1000);
            await t.pump();
            w.stop();
            final ms = w.elapsedMicroseconds / 1000;
            latencies.add(ms);
            final now = _editorCount();
            final height = targetHeight();
            final host = t.widget(other);
            final grew = height != lastHeight;
            final rebuilt = !identical(host, lastHost);
            if (grew) heightChanges++;
            if (rebuilt) hostRebuilds++;
            if (ms > 50) {
              slow.add({
                'keystroke': k,
                'ms': (ms * 10).round() / 10,
                'editorsBefore': editors,
                'editorsAfter': now,
                'firstAfterMount': mounted,
                'heightBefore': lastHeight,
                'heightAfter': height,
                'canvasRebuilt': rebuilt,
                'canvasRebuiltInFrame': !identical(host, hostAtStart),
              });
            }
            mounted = now > editors;
            editors = now;
            lastHeight = height;
            lastHost = host;
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        });
      }, reportKey: 'typing');
      final typed = String.fromCharCodes([for (var k = 0; k < _keystrokes; k++) 97 + k % 26]);
      expect(snapshotOf(s, target), contains(typed));
      expect(snapshotOf(s, target).length, before.length + _keystrokes);
      final flush = Stopwatch()..start();
      await s.flush();
      summary['typing'] = {
        'keystrokeToFrameMs': _stats(latencies),
        'applyTransactionMs': _stats(applyTimes),
        'slowKeystrokes': slow,
        // Keystrokes after which the note's height had changed, and those
        // after which the other boxes' widgets had been rebuilt (each since
        // the keystroke before).
        'heightChanges': heightChanges,
        'canvasRebuilds': hostRebuilds,
        'frames': _frameStats(typing),
        'buildMsPerFrame': [for (final b in typing.build) (b * 10).round() / 10],
        'saveAfterTypingMs': _ms(flush),
        // flutter's own summary of the same window (with GC counts).
        'watchPerformance': binding.reportData!['typing'],
      };
      await s.pump(300);

      // Pan with the mouse wheel; zoom with scale events (what Ctrl + wheel
      // and a trackpad pinch both end in: `zoomAt`). No key events: the key
      // simulator does not work in profile builds.
      final pointer = TestPointer(7, PointerDeviceKind.mouse);
      final viewport = t.getSize(find.byType(PageCanvas));
      final mid = Offset(viewport.width / 2, (viewport.height - CommandToolbar.height) / 2);
      await t.sendEventToBinding(pointer.hover(viewportPoint(t, mid)));
      await s.pump(200);

      Future<void> wheel(Offset delta) async {
        await t.sendEventToBinding(pointer.scroll(delta));
        await t.pump();
      }

      Future<void> zoomStep(double scale) async {
        await t.sendEventToBinding(PointerScaleEvent(position: viewportPoint(t, mid), scale: scale));
        await t.pump();
      }

      // At 100%: right and down across the page, then back.
      final pan100 = await _watch(() async {
        for (var i = 0; i < 80; i++) {
          await wheel(const Offset(60, 30));
        }
        for (var i = 0; i < 80; i++) {
          await wheel(const Offset(-60, -30));
        }
      });
      // Zoomed out (the whole page in view) and in.
      await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
      await s.pump(500);
      final fitScale = canvasState(t).view!.scale;
      final panFit = await _watch(() async {
        // Zoom in a little so panning is possible, then pan.
        for (var i = 0; i < 6; i++) {
          await zoomStep(1.143);
        }
        for (var i = 0; i < 60; i++) {
          await wheel(const Offset(80, 0));
        }
        for (var i = 0; i < 60; i++) {
          await wheel(const Offset(-80, 0));
        }
      });
      await t.tap(find.byKey(const ValueKey('canvas.fitAll')));
      await s.pump(500);
      final zoom = await _watch(() async {
        for (var i = 0; i < 30; i++) {
          await zoomStep(1.143);
        }
        for (var i = 0; i < 30; i++) {
          await zoomStep(1 / 1.143);
        }
      });
      summary['fitAllScale'] = (fitScale * 1000).round() / 1000;
      summary['pan100'] = _frameStats(pan100);
      summary['panZoomedOut'] = _frameStats(panFit);
      summary['zoom'] = _frameStats(zoom);
    });

    // ignore: avoid_print
    print('PERF_SUMMARY ${jsonEncode(summary)}');
    binding.reportData = {'perf': summary};

    // Generous sanity bounds only: the numbers are the result.
    final open = summary['open']! as Map;
    expect(open['settledMs'] as double, lessThan(60000), reason: 'page open');
    final typing = summary['typing']! as Map;
    expect(((typing['keystrokeToFrameMs']! as Map)['p90']) as double, lessThan(1000), reason: 'typing');
    for (final k in ['pan100', 'panZoomedOut', 'zoom']) {
      expect((((summary[k]! as Map)['total']! as Map)['count']) as int, greaterThan(20), reason: '$k recorded frames');
      expect((((summary[k]! as Map)['total']! as Map)['p90']) as double, lessThan(1000), reason: k);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
