// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/semantics_guard.dart';

/// The guard used by the integration suite: a Windows accessibility client
/// that connects mid-test must not open a SemanticsHandle, and a handle a
/// test opens itself must still be counted.
void main() {
  int handles() => SemanticsBinding.instance.debugOutstandingSemanticsHandles;

  testWidgets('without the guard, the platform asking for semantics opens a handle', (t) async {
    final before = handles();
    final d = t.binding.platformDispatcher;
    d.semanticsEnabledTestValue = true;
    expect(handles(), before + 1, reason: 'this is the flake: the count goes up with nothing leaked');
    d.semanticsEnabledTestValue = false;
    expect(handles(), before);
    d.clearSemanticsEnabledTestValue();
  });

  testWidgets('with the guard, the platform asking for semantics opens none', (t) async {
    final restore = ignorePlatformSemantics();
    addTearDown(restore);
    final before = handles();
    final requests = platformSemanticsRequests;
    final d = t.binding.platformDispatcher;
    d.semanticsEnabledTestValue = true;
    expect(handles(), before);
    expect(platformSemanticsRequests, requests + 1);
    d.clearSemanticsEnabledTestValue();
  });

  testWidgets('with the guard, a handle the test opens itself is still counted', (t) async {
    final restore = ignorePlatformSemantics();
    addTearDown(restore);
    final before = handles();
    final own = SemanticsBinding.instance.ensureSemantics();
    expect(handles(), before + 1, reason: 'a leaked handle would fail the end-of-test check');
    final viaTester = t.ensureSemantics();
    expect(handles(), before + 2);
    own.dispose();
    viaTester.dispose();
    expect(handles(), before);
  });
}
