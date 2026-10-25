// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted_canvas/noted_canvas.dart';

void main() {
  const viewport = Size(1000, 600);

  bool inside(Rect outer, Rect inner) =>
      inner.left >= outer.left - 1e-6 &&
      inner.top >= outer.top - 1e-6 &&
      inner.right <= outer.right + 1e-6 &&
      inner.bottom <= outer.bottom + 1e-6;

  test('panning stops one viewport beyond the content', () {
    const content = Rect.fromLTWH(0, 0, 400, 300);
    final g = CanvasGeometry.compute(content: content, viewport: viewport);
    final far = g.pan(CanvasView.identity, const Offset(1e6, 1e6));
    expect(inside(g.boundary, far.visible(viewport)), isTrue);
    final farOther = g.pan(CanvasView.identity, const Offset(-1e6, -1e6));
    expect(inside(g.boundary, farOther.visible(viewport)), isTrue);
  });

  test('zoom stays within limits and keeps the focal point fixed', () {
    const content = Rect.fromLTWH(0, 0, 5000, 5000);
    final g = CanvasGeometry.compute(content: content, viewport: viewport);
    const focal = Offset(300, 200);
    final start = g.initial(content);
    final z = g.zoomAt(start, focal, 2);
    expect(z.scale, 2);
    expect(z.toWorld(focal).dx, closeTo(start.toWorld(focal).dx, 1e-6));
    expect(g.zoomAt(start, focal, 1000).scale, canvasMaxScale);
    final out = g.zoomAt(start, focal, 1e-6);
    expect(out.scale, g.minScale);
    expect(inside(g.boundary, out.visible(viewport)), isTrue);
  });

  test('Fit all shows all content, never above 100%', () {
    const big = Rect.fromLTWH(-2000, 100, 6000, 900);
    final g = CanvasGeometry.compute(content: big, viewport: viewport);
    final fit = g.fitAll(big);
    expect(fit.scale, lessThan(1));
    expect(inside(fit.visible(viewport), big), isTrue);

    const small = Rect.fromLTWH(50, 50, 100, 40);
    final g2 = CanvasGeometry.compute(content: small, viewport: viewport);
    expect(g2.fitAll(small).scale, 1);
  });

  test('creating a box on an empty page never moves the view', () {
    final empty = CanvasGeometry.compute(content: null, viewport: viewport);
    final v = empty.initial(null);
    // A box in the bottom-right corner of the visible area.
    final box = Rect.fromLTWH(
      viewport.width - 50,
      viewport.height - 30,
      360,
      40,
    );
    final g = CanvasGeometry.compute(content: box, viewport: viewport);
    expect(g.clamp(v), v);
  });

  test('matrix maps world points to screen points', () {
    const content = Rect.fromLTWH(-300, -100, 400, 300);
    final g = CanvasGeometry.compute(content: content, viewport: viewport);
    const v = CanvasView(1.5, Offset(700, 400));
    final m = g.matrixFor(v);
    const world = Offset(-250, -60);
    final local = world - g.child.topLeft;
    expect(MatrixUtils.transformPoint(m, local), v.toScreen(world));
  });
}
