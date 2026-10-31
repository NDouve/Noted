// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Generates the app icons from the master, docs/design/icon/noted-icon.svg:
// the Windows .ico, the macOS .icns and asset catalog PNGs, and the Android
// and iOS icon sets, all with a transparent background.
//
// Run from the repository root:
//
//   dart run app/scripts/generate_icons.dart
//
// The SVG is rasterized here directly (no image package, no new
// dependency): each pixel is sampled on a grid and the shapes are composited
// in document order, which is exact anti-aliasing for the shapes the master
// uses (straight-line paths and circles, round joins and caps, solid colors
// and two-stop linear gradients). Sizes of 32 px and below are drawn from a
// pixel-fitted variant (see [_fitted]) so they stay sharp instead of being a
// blurred reduction of the large icon.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _master = 'docs/design/icon/noted-icon.svg';
const _windowsIco = 'app/windows/runner/resources/app_icon.ico';
const _outDir = 'app/icons';
const _macosAppIconSet = 'app/macos/Runner/Assets.xcassets/AppIcon.appiconset';

void main(List<String> args) {
  final svg = Svg.parse(File(_master).readAsStringSync());

  Uint8List png(int size) => encodePng(render(svg, size));

  // Windows: 16-256 px. Small sizes as 32-bit BMP entries (read by every
  // Windows tool), 256 as PNG (the usual layout).
  const icoSizes = [16, 24, 32, 48, 64, 128, 256];
  File(_windowsIco).writeAsBytesSync(
    encodeIco([for (final s in icoSizes) (s, render(svg, s))]),
  );

  // macOS: PNG entries from 16 to 1024 px.
  final icns = <(String, Uint8List)>[
    ('icp4', png(16)),
    ('icp5', png(32)),
    ('icp6', png(64)),
    ('ic07', png(128)),
    ('ic08', png(256)),
    ('ic09', png(512)),
    ('ic10', png(1024)),
    ('ic11', png(32)),
    ('ic12', png(64)),
    ('ic13', png(256)),
    ('ic14', png(512)),
  ];
  _write('$_outDir/macos/AppIcon.icns', encodeIcns(icns));

  // The Flutter macOS project's asset catalog (its Contents.json names these
  // files).
  for (final s in const [16, 32, 64, 128, 256, 512, 1024]) {
    _write('$_macosAppIconSet/app_icon_$s.png', png(s));
  }

  // Android launcher icons per density, and the 512 px store icon.
  const android = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final MapEntry(key: density, value: size) in android.entries) {
    _write('$_outDir/android/mipmap-$density/ic_launcher.png', png(size));
  }
  _write('$_outDir/android/ic_launcher-playstore.png', png(512));

  // iOS: the classic AppIcon.appiconset.
  const ios = [
    ('iphone', 20, 2),
    ('iphone', 20, 3),
    ('iphone', 29, 2),
    ('iphone', 29, 3),
    ('iphone', 40, 2),
    ('iphone', 40, 3),
    ('iphone', 60, 2),
    ('iphone', 60, 3),
    ('ipad', 20, 1),
    ('ipad', 20, 2),
    ('ipad', 29, 1),
    ('ipad', 29, 2),
    ('ipad', 40, 1),
    ('ipad', 40, 2),
    ('ipad', 76, 1),
    ('ipad', 76, 2),
    ('ipad', 83.5, 2),
    ('ios-marketing', 1024, 1),
  ];
  final images = <String>[];
  final written = <int>{};
  for (final (idiom, points, scale) in ios) {
    final px = (points * scale).round();
    final name = 'Icon-$px.png';
    if (written.add(px)) {
      _write('$_outDir/ios/AppIcon.appiconset/$name', png(px));
    }
    final pt = points == points.roundToDouble()
        ? '${points.round()}'
        : '$points';
    images.add(
      '    {"filename": "$name", "idiom": "$idiom", '
      '"scale": "${scale}x", "size": "${pt}x$pt"}',
    );
  }
  _write(
    '$_outDir/ios/AppIcon.appiconset/Contents.json',
    Uint8List.fromList(
      '{\n  "images": [\n${images.join(',\n')}\n  ],\n'
              '  "info": {"author": "xcode", "version": 1}\n}\n'
          .codeUnits,
    ),
  );

  // Previews of the small sizes, enlarged without smoothing, for checking
  // sharpness by eye.
  if (args.contains('--preview')) {
    final dir = args[args.indexOf('--preview') + 1];
    for (final s in [16, 20, 24, 32, 48]) {
      _write(
        '$dir/preview-$s.png',
        encodePng(enlarge(render(svg, s), 256 ~/ s)),
      );
    }
  }
}

void _write(String path, Uint8List bytes) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

// ---------------------------------------------------------------------------
// SVG subset: a viewBox, <path> with absolute M/L/H/V/Z, <circle>; fill,
// stroke, stroke-width, round joins and caps; paints that are a #rrggbb color
// or url(#id) of a <linearGradient> with gradientUnits="userSpaceOnUse" and
// two stops.

/// A fill or stroke paint: a solid color, or a linear gradient between two
/// stops, padded beyond them (SVG's default spreadMethod).
final class Paint {
  const Paint.solid(int color) : this._(color, color, 0, 1, null, null);

  const Paint.linear({
    required math.Point<double> start,
    required math.Point<double> end,
    required int from,
    required int to,
    double fromOffset = 0,
    double toOffset = 1,
  }) : this._(from, to, fromOffset, toOffset, start, end);

  const Paint._(
    this.from,
    this.to,
    this.fromOffset,
    this.toOffset,
    this.start,
    this.end,
  );

  /// The stop colors (opaque ARGB) and their offsets along the gradient.
  final int from, to;
  final double fromOffset, toOffset;

  /// The gradient vector, in the same units as the shapes; null for a solid
  /// color.
  final math.Point<double>? start, end;

  /// The color at (x, y): the stops interpolated per channel in sRGB.
  int at(double x, double y) {
    final a = start, b = end;
    if (a == null || b == null) return from;
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    final g = len2 == 0 ? 0.0 : ((x - a.x) * dx + (y - a.y) * dy) / len2;
    final span = toOffset - fromOffset;
    final t = span <= 0
        ? (g < toOffset ? 0.0 : 1.0)
        : ((g - fromOffset) / span).clamp(0.0, 1.0);
    int channel(int shift) {
      final c0 = (from >> shift) & 0xFF, c1 = (to >> shift) & 0xFF;
      return (c0 + (c1 - c0) * t).round();
    }

    return 0xFF000000 | channel(16) << 16 | channel(8) << 8 | channel(0);
  }

  Paint transformed(math.Point<double> Function(math.Point<double>) f) {
    final a = start, b = end;
    if (a == null || b == null) return this;
    return Paint._(from, to, fromOffset, toOffset, f(a), f(b));
  }
}

Map<String, String> _attributes(String text) => {
  for (final a in RegExp(r'([\w-]+)="([^"]*)"').allMatches(text))
    a.group(1)!: a.group(2)!,
};

final class Shape {
  Shape({
    required this.subpaths,
    required this.closed,
    this.circle,
    this.fill,
    this.stroke,
    this.strokeWidth = 1,
  });

  /// Polylines in viewBox units.
  final List<List<math.Point<double>>> subpaths;
  final List<bool> closed;

  /// (centre, radius) for a circle.
  final (math.Point<double>, double)? circle;
  final Paint? fill;
  final Paint? stroke;
  final double strokeWidth;

  /// This shape moved by [f], which scales lengths by [s]. Gradients move
  /// with it.
  Shape transformed(
    math.Point<double> Function(math.Point<double>) f,
    double s,
  ) => Shape(
    subpaths: [
      for (final p in subpaths) [for (final q in p) f(q)],
    ],
    closed: closed,
    circle: circle == null ? null : (f(circle!.$1), circle!.$2 * s),
    fill: fill?.transformed(f),
    stroke: stroke?.transformed(f),
    strokeWidth: strokeWidth * s,
  );
}

final class Svg {
  Svg(this.minX, this.minY, this.width, this.height, this.shapes);

  final double minX, minY, width, height;
  final List<Shape> shapes;

  static Svg parse(String text) {
    final viewBox = RegExp(r'viewBox="([^"]+)"').firstMatch(text)!.group(1)!;
    final vb = viewBox
        .trim()
        .split(RegExp(r'[\s,]+'))
        .map(double.parse)
        .toList();
    int hex(String v) {
      if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(v)) {
        throw FormatException('unsupported color $v');
      }
      return 0xFF000000 | int.parse(v.substring(1), radix: 16);
    }

    final gradients = <String, Paint>{};
    for (final m in RegExp(
      r'<linearGradient\b([^>]*)>(.*?)</linearGradient>',
      dotAll: true,
    ).allMatches(text)) {
      final attrs = _attributes(m.group(1)!);
      final id = attrs['id'];
      if (id == null) continue;
      if (attrs['gradientUnits'] != 'userSpaceOnUse') {
        throw FormatException('gradient $id: only userSpaceOnUse is supported');
      }
      for (final k in ['gradientTransform', 'href', 'xlink:href']) {
        if (attrs.containsKey(k)) throw FormatException('gradient $id: $k');
      }
      if ((attrs['spreadMethod'] ?? 'pad') != 'pad') {
        throw FormatException('gradient $id: spreadMethod');
      }
      final stops = [
        for (final s in RegExp(r'<stop\b([^>]*)/?>').allMatches(m.group(2)!))
          _attributes(s.group(1)!),
      ];
      if (stops.length != 2) {
        throw FormatException('gradient $id: ${stops.length} stops, not 2');
      }
      double offset(Map<String, String> stop) {
        final v = stop['offset'] ?? '0';
        return v.endsWith('%')
            ? double.parse(v.substring(0, v.length - 1)) / 100
            : double.parse(v);
      }

      for (final s in stops) {
        if (s.containsKey('stop-opacity') || s.containsKey('style')) {
          throw FormatException('gradient $id: stop-opacity or style');
        }
      }
      double coord(String k) => double.parse(attrs[k]!);
      gradients[id] = Paint.linear(
        start: math.Point(coord('x1'), coord('y1')),
        end: math.Point(coord('x2'), coord('y2')),
        from: hex(stops[0]['stop-color']!),
        to: hex(stops[1]['stop-color']!),
        fromOffset: offset(stops[0]),
        toOffset: math.max(offset(stops[0]), offset(stops[1])),
      );
    }

    final shapes = <Shape>[];
    for (final m in RegExp(r'<(path|circle)\b([^>]*)/?>').allMatches(text)) {
      final tag = m.group(1)!;
      final attrs = _attributes(m.group(2)!);
      Paint? color(String? v) {
        if (v == null || v == 'none') return null;
        final url = RegExp(r'^url\(#([^)]+)\)$').firstMatch(v);
        if (url != null) {
          return gradients[url.group(1)!] ??
              (throw FormatException('no gradient ${url.group(1)}'));
        }
        return Paint.solid(hex(v));
      }

      final stroke = color(attrs['stroke']);
      final width = double.parse(attrs['stroke-width'] ?? '1');
      if (stroke != null) {
        for (final k in ['stroke-linejoin', 'stroke-linecap']) {
          final v = attrs[k];
          if (v != null && v != 'round') throw FormatException('$k=$v');
        }
      }
      if (tag == 'circle') {
        shapes.add(
          Shape(
            subpaths: const [],
            closed: const [],
            circle: (
              math.Point(
                double.parse(attrs['cx']!),
                double.parse(attrs['cy']!),
              ),
              double.parse(attrs['r']!),
            ),
            fill: color(attrs['fill'] ?? '#000000'),
            stroke: stroke,
            strokeWidth: width,
          ),
        );
        continue;
      }
      final subpaths = <List<math.Point<double>>>[];
      final closed = <bool>[];
      var x = 0.0, y = 0.0;
      final tokens = RegExp(r'[MLHVZmlhvz]|-?\d*\.?\d+')
          .allMatches(attrs['d']!)
          .map((t) => t.group(0)!)
          .toList();
      var i = 0;
      String? cmd;
      while (i < tokens.length) {
        final t = tokens[i];
        if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
          cmd = t;
          i++;
          if (t == 'Z' || t == 'z') {
            closed[closed.length - 1] = true;
            x = subpaths.last.first.x;
            y = subpaths.last.first.y;
          }
          continue;
        }
        double next() => double.parse(tokens[i++]);
        switch (cmd) {
          case 'M':
            x = next();
            y = next();
            subpaths.add([math.Point(x, y)]);
            closed.add(false);
            cmd = 'L';
          case 'L':
            x = next();
            y = next();
            subpaths.last.add(math.Point(x, y));
          case 'H':
            x = next();
            subpaths.last.add(math.Point(x, y));
          case 'V':
            y = next();
            subpaths.last.add(math.Point(x, y));
          default:
            throw FormatException('unsupported path command $cmd');
        }
      }
      final joins = [
        for (var k = 0; k < subpaths.length; k++)
          if (closed[k] || subpaths[k].length > 2) k,
      ];
      if (stroke != null &&
          joins.isNotEmpty &&
          attrs['stroke-linejoin'] != 'round') {
        throw const FormatException('strokes need round joins');
      }
      if (stroke != null &&
          closed.contains(false) &&
          attrs['stroke-linecap'] != 'round') {
        throw const FormatException('open strokes need round caps');
      }
      shapes.add(
        Shape(
          subpaths: subpaths,
          closed: closed,
          fill: color(attrs['fill'] ?? '#000000'),
          stroke: stroke,
          strokeWidth: width,
        ),
      );
    }
    return Svg(vb[0], vb[1], vb[2], vb[3], shapes);
  }
}

// ---------------------------------------------------------------------------
// Rendering.

/// An RGBA image, straight (not premultiplied) alpha.
final class Image {
  Image(this.size) : rgba = Uint8List(size * size * 4);
  final int size;
  final Uint8List rgba;
}

/// The shapes of [svg] in pixel units for a [size] px icon. From 32 px down
/// the geometry is fitted to the pixel grid ([_fitted]).
List<Shape> _shapesAt(Svg svg, int size) {
  final s = size / svg.width;
  math.Point<double> f(math.Point<double> p) =>
      math.Point((p.x - svg.minX) * s, (p.y - svg.minY) * s);
  final shapes = [for (final sh in svg.shapes) sh.transformed(f, s)];
  return size <= 32 ? _fitted(shapes, size) : shapes;
}

/// The largest size drawn with the N only ([_fitted]).
const nOnlyMaxSize = 20;

/// The clear margin, in pixels, around the N at [nOnlyMaxSize] and below.
const nMargin = 1;

/// Pixel fitting for small sizes:
/// - at [nOnlyMaxSize] px and below only the N is drawn (the shapes with the
///   widest stroke), scaled to fill the icon less [nMargin] on every side:
///   the superscript d would be a smudge of one or two pixels there. From
///   24 px the d is kept;
/// - every path vertex snaps so that a stroke's edges fall on pixel
///   boundaries (to a pixel edge for even pixel widths, a pixel centre for
///   odd ones), which keeps the N's stems sharp;
/// - stroke widths round to whole pixels, at least 1.
List<Shape> _fitted(List<Shape> shapes, int size) {
  if (size <= nOnlyMaxSize) {
    final widest = shapes.map((sh) => sh.strokeWidth).reduce(math.max);
    final n = [
      for (final sh in shapes)
        if (sh.stroke != null && sh.strokeWidth == widest) sh,
    ];
    final pts = [
      for (final sh in n)
        for (final p in sh.subpaths) ...p,
    ];
    final x0 = pts.map((q) => q.x).reduce(math.min);
    final x1 = pts.map((q) => q.x).reduce(math.max);
    final y0 = pts.map((q) => q.y).reduce(math.min);
    final y1 = pts.map((q) => q.y).reduce(math.max);
    // The stroke grows with the height; the outline then spans the square
    // less the margin both ways (wider than the master's proportions).
    final w = math
        .max(1, (widest * (size - 2 * nMargin) / (y1 - y0 + widest)).round())
        .toDouble();
    final lo = nMargin + w / 2, hi = size - nMargin - w / 2;
    math.Point<double> fit(math.Point<double> p) => math.Point(
      lo + (p.x - x0) / (x1 - x0) * (hi - lo),
      lo + (p.y - y0) / (y1 - y0) * (hi - lo),
    );
    shapes = [
      for (final sh in n)
        Shape(
          subpaths: [
            for (final p in sh.subpaths) [for (final q in p) fit(q)],
          ],
          closed: sh.closed,
          fill: sh.fill?.transformed(fit),
          stroke: sh.stroke?.transformed(fit),
          strokeWidth: w,
        ),
    ];
  }
  final out = <Shape>[];
  for (final sh in shapes) {
    final w = sh.stroke == null
        ? 0.0
        : math.max(1, sh.strokeWidth.round()).toDouble();
    final odd = w.round().isOdd;
    double snap(double v) => odd ? v.floorToDouble() + 0.5 : v.roundToDouble();
    out.add(
      Shape(
        subpaths: [
          for (final p in sh.subpaths)
            [for (final q in p) math.Point(snap(q.x), snap(q.y))],
        ],
        closed: sh.closed,
        circle: switch (sh.circle) {
          (final c, final r) => (
            math.Point(snap(c.x), snap(c.y)),
            math.max(1, r.round()).toDouble(),
          ),
          null => null,
        },
        fill: sh.fill,
        stroke: sh.stroke,
        strokeWidth: sh.stroke == null ? sh.strokeWidth : w,
      ),
    );
  }
  return _separated(out, size);
}

/// [shapes] with the thinner ones (the d) moved right by whole pixels until
/// a clear pixel column separates them from the widest stroke (the N), as far
/// as the icon's edge allows. At small sizes the master's gap between the
/// two is under a pixel, so they would merge.
List<Shape> _separated(List<Shape> shapes, int size) {
  final widest = shapes.map((sh) => sh.strokeWidth).reduce(math.max);
  bool isN(Shape sh) => sh.strokeWidth == widest;
  (double, double) extent(Iterable<Shape> group) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final sh in group) {
      final half = sh.stroke == null ? 0.0 : sh.strokeWidth / 2;
      if (sh.circle case (final c, final r)) {
        lo = math.min(lo, c.x - r - half);
        hi = math.max(hi, c.x + r + half);
      }
      for (final p in sh.subpaths) {
        for (final q in p) {
          lo = math.min(lo, q.x - half);
          hi = math.max(hi, q.x + half);
        }
      }
    }
    return (lo, hi);
  }

  final d = shapes.where((sh) => !isN(sh));
  if (d.isEmpty) return shapes;
  final (_, nRight) = extent(shapes.where(isN));
  final (dLeft, dRight) = extent(d);
  var dx = 0;
  while (dLeft + dx - nRight < 1 && dRight + dx + 1 <= size) {
    dx++;
  }
  return [
    for (final sh in shapes)
      isN(sh) ? sh : sh.transformed((p) => math.Point(p.x + dx, p.y), 1),
  ];
}

double _segDist(
  math.Point<double> p,
  math.Point<double> a,
  math.Point<double> b,
) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y;
  return math.sqrt(ex * ex + ey * ey);
}

bool _inside(List<math.Point<double>> poly, double x, double y) {
  var winding = 0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    if (a.y <= y) {
      if (b.y > y && (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) > 0) {
        winding++;
      }
    } else if (b.y <= y &&
        (b.x - a.x) * (y - a.y) - (x - a.x) * (b.y - a.y) < 0) {
      winding--;
    }
  }
  return winding != 0;
}

/// The color of [sh] at (x, y), or null where it paints nothing.
int? _paint(Shape sh, double x, double y) {
  final p = math.Point(x, y);
  final half = sh.strokeWidth / 2;
  if (sh.circle case (final c, final r)) {
    final d = p.distanceTo(c);
    if (sh.stroke != null && (d - r).abs() <= half) return sh.stroke!.at(x, y);
    if (sh.fill != null && d <= r) return sh.fill!.at(x, y);
    return null;
  }
  if (sh.stroke case final stroke?) {
    for (var k = 0; k < sh.subpaths.length; k++) {
      final pts = sh.subpaths[k];
      final n = sh.closed[k] ? pts.length : pts.length - 1;
      for (var i = 0; i < n; i++) {
        if (_segDist(p, pts[i], pts[(i + 1) % pts.length]) <= half) {
          return stroke.at(x, y);
        }
      }
    }
  }
  if (sh.fill case final fill?) {
    for (final pts in sh.subpaths) {
      if (_inside(pts, x, y)) return fill.at(x, y);
    }
  }
  return null;
}

/// Renders [svg] as a [size] px square with a transparent background.
Image render(Svg svg, int size) {
  final shapes = _shapesAt(svg, size);
  final grid = size <= 64 ? 16 : (size <= 256 ? 8 : 4);
  final img = Image(size);
  final n = grid * grid;
  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var sy = 0; sy < grid; sy++) {
        for (var sx = 0; sx < grid; sx++) {
          final x = px + (sx + 0.5) / grid, y = py + (sy + 0.5) / grid;
          int? c;
          for (final sh in shapes) {
            c = _paint(sh, x, y) ?? c;
          }
          if (c != null) {
            r += (c >> 16) & 0xFF;
            g += (c >> 8) & 0xFF;
            b += c & 0xFF;
            a += 1;
          }
        }
      }
      final o = (py * size + px) * 4;
      if (a > 0) {
        img.rgba[o] = (r / a).round();
        img.rgba[o + 1] = (g / a).round();
        img.rgba[o + 2] = (b / a).round();
        img.rgba[o + 3] = (a / n * 255).round();
      }
    }
  }
  return img;
}

/// [img] enlarged [k] times without smoothing.
Image enlarge(Image img, int k) {
  final out = Image(img.size * k);
  for (var y = 0; y < out.size; y++) {
    for (var x = 0; x < out.size; x++) {
      final i = ((y ~/ k) * img.size + x ~/ k) * 4, o = (y * out.size + x) * 4;
      out.rgba.setRange(o, o + 4, img.rgba, i);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Encoders.

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

Uint8List encodePng(Image img) {
  final raw = BytesBuilder();
  for (var y = 0; y < img.size; y++) {
    raw.addByte(0);
    raw.add(
      Uint8List.sublistView(img.rgba, y * img.size * 4, (y + 1) * img.size * 4),
    );
  }
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_be32(data.length))
      ..add(body)
      ..add(_be32(_crc(body)));
  }

  chunk('IHDR', [..._be32(img.size), ..._be32(img.size), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibCodec(level: 9).encode(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

Uint8List encodeIco(List<(int, Image)> images) {
  final entries = <Uint8List>[];
  for (final (size, img) in images) {
    if (size >= 256) {
      entries.add(encodePng(img));
      continue;
    }
    // BITMAPINFOHEADER, bottom-up BGRA rows, then a 1-bit AND mask.
    final b = BytesBuilder()
      ..add(_le32(40))
      ..add(_le32(size))
      ..add(_le32(size * 2))
      ..add(_le16(1))
      ..add(_le16(32))
      ..add(_le32(0))
      ..add(_le32(0))
      ..add(_le32(0))
      ..add(_le32(0))
      ..add(_le32(0))
      ..add(_le32(0));
    for (var y = size - 1; y >= 0; y--) {
      for (var x = 0; x < size; x++) {
        final o = (y * size + x) * 4;
        b.add([img.rgba[o + 2], img.rgba[o + 1], img.rgba[o], img.rgba[o + 3]]);
      }
    }
    final maskRow = ((size + 31) ~/ 32) * 4;
    for (var y = size - 1; y >= 0; y--) {
      final row = Uint8List(maskRow);
      for (var x = 0; x < size; x++) {
        if (img.rgba[(y * size + x) * 4 + 3] == 0) {
          row[x >> 3] |= 0x80 >> (x & 7);
        }
      }
      b.add(row);
    }
    entries.add(b.toBytes());
  }
  final out = BytesBuilder()
    ..add(_le16(0))
    ..add(_le16(1))
    ..add(_le16(images.length));
  var offset = 6 + 16 * images.length;
  for (var i = 0; i < images.length; i++) {
    final size = images[i].$1;
    out
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(size >= 256 ? 0 : size)
      ..addByte(0)
      ..addByte(0)
      ..add(_le16(1))
      ..add(_le16(32))
      ..add(_le32(entries[i].length))
      ..add(_le32(offset));
    offset += entries[i].length;
  }
  for (final e in entries) {
    out.add(e);
  }
  return out.toBytes();
}

Uint8List encodeIcns(List<(String, Uint8List)> entries) {
  final body = BytesBuilder();
  for (final (type, data) in entries) {
    body
      ..add(type.codeUnits)
      ..add(_be32(data.length + 8))
      ..add(data);
  }
  return (BytesBuilder()
        ..add('icns'.codeUnits)
        ..add(_be32(body.length + 8))
        ..add(body.toBytes()))
      .toBytes();
}

List<int> _be32(int v) => [
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];
List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];
List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
