// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Keeps Windows accessibility clients from failing integration tests.
///
/// `testWidgets` records the number of outstanding `SemanticsHandle`s when a
/// test starts and fails with "A SemanticsHandle was active at the end of the
/// test" if there are more when it ends. When a UI Automation client (a
/// screen reader, an automation or screen-capture tool) connects to the
/// window during a test, the engine reports `semanticsEnabled`, and
/// `SemanticsBinding` answers by opening one handle of its own
/// (`_handleSemanticsEnabledChanged`). Nothing in the test leaked, but the
/// count went up, so the test failed at random.
///
/// [ignorePlatformSemantics] replaces only that one callback,
/// `PlatformDispatcher.onSemanticsEnabledChanged`, so the framework no longer
/// opens a handle for the platform. Handles that a test opens itself
/// (`tester.ensureSemantics()`, `SemanticsBinding.instance.ensureSemantics()`,
/// the one `testWidgets` opens for `semanticsEnabled: true`) do not go through
/// that callback, so they are still counted and a test that leaks one still
/// fails. Nothing here touches the count or the check.
library;

import 'package:flutter/widgets.dart';

/// Number of times the platform changed its semantics request while the guard
/// was installed (for the log; the requests themselves are ignored).
int platformSemanticsRequests = 0;

/// Ignores the platform's semantics requests. Returns a function that puts the
/// previous callback back. Call it once, from `main()`, after
/// `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` (or, in a unit
/// test, after the binding is created).
VoidCallback ignorePlatformSemantics() {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final original = dispatcher.onSemanticsEnabledChanged;
  dispatcher.onSemanticsEnabledChanged = () => platformSemanticsRequests++;
  return () => dispatcher.onSemanticsEnabledChanged = original;
}
