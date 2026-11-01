// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noted/src/ai/ai_approval_dialog.dart';
import 'package:noted/src/ai/ai_link_authority.dart';
import 'package:noted/src/app_theme.dart';

void main() {
  testWidgets('a question that times out closes only its own dialog, never the one on top', (t) async {
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        theme: buildNotedTheme(Brightness.light, touch: false),
        home: const SizedBox(),
      ),
    );
    final lower = Completer<void>();
    final upper = Completer<void>();
    AiApprovalRequest request(String app, Completer<void> expired) => AiApprovalRequest(
      app: app,
      write: true,
      label: 'Chat',
      perWrite: false,
      expired: expired.future,
    );

    final lowerAnswer = showAiApprovalDialog(key, request('Lower', lower));
    await t.pump(const Duration(milliseconds: 400));
    final upperAnswer = showAiApprovalDialog(key, request('Upper', upper));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Lower wants'), findsOneWidget);
    expect(find.textContaining('Upper wants'), findsOneWidget);

    // The lower question times out while the upper one is on top.
    lower.complete();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Upper wants'), findsOneWidget, reason: 'the dialog on top stays');
    expect(find.textContaining('Lower wants'), findsNothing);
    expect(await lowerAnswer, isFalse);

    // The user can still answer the one that is left.
    await t.tap(find.byKey(const ValueKey('ai-approval-allow')));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(await upperAnswer, isTrue);
    expect(find.byType(AiApprovalDialog), findsNothing);
    upper.complete();
  });

  testWidgets('a timeout after the user answered does nothing', (t) async {
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(navigatorKey: key, theme: buildNotedTheme(Brightness.light, touch: false), home: const SizedBox()),
    );
    final expired = Completer<void>();
    final answer = showAiApprovalDialog(
      key,
      AiApprovalRequest(app: 'A', write: false, label: 'L', perWrite: false, expired: expired.future),
    );
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(find.byKey(const ValueKey('ai-approval-deny')));
    await t.pump(const Duration(milliseconds: 400));
    expect(await answer, isFalse);
    expired.complete();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(AiApprovalDialog), findsNothing);
  });
}
