// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('the question names what the code reaches, in the dialog', (t) async {
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(navigatorKey: key, theme: buildNotedTheme(Brightness.light, touch: false), home: const SizedBox()),
    );
    final expired = Completer<void>();
    final answer = showAiApprovalDialog(
      key,
      AiApprovalRequest(
        app: 'Claude Code',
        write: false,
        label: 'Research reader',
        perWrite: false,
        reach: 'the AI box',
        reachName: 'Research notes',
        expired: expired.future,
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(
      t.widget<Text>(find.byKey(const ValueKey('ai-approval-message'))).data,
      'Claude Code wants to read the AI box (code "Research reader"). Allow?',
    );
    // The name is apart from the sentence: muted, one line, cut with an ellipsis.
    final name = t.widget<Text>(find.byKey(const ValueKey('ai-approval-reach')));
    expect(name.data, 'Research notes');
    expect(name.maxLines, 1);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(name.style?.color, Theme.of(t.element(find.byType(AiApprovalDialog))).colorScheme.onSurfaceVariant);
    await t.tap(find.byKey(const ValueKey('ai-approval-deny')));
    await t.pump(const Duration(milliseconds: 400));
    expect(await answer, isFalse);
    expired.complete();
  });

  testWidgets('Deny shows a clear accent outline while focused, in the light theme too', (t) async {
    final key = GlobalKey<NavigatorState>();
    final theme = buildNotedTheme(Brightness.light, touch: false);
    await t.pumpWidget(MaterialApp(navigatorKey: key, theme: theme, home: const SizedBox()));
    final expired = Completer<void>();
    final answer = showAiApprovalDialog(
      key,
      AiApprovalRequest(app: 'A', write: false, label: 'L', perWrite: false, expired: expired.future),
    );
    await t.pump(const Duration(milliseconds: 400));
    // The outline is drawn even though the mouse, not the keyboard, last drove
    // focus: Deny has focus by default and the cue says so.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    await t.pump();
    BoxDecoration outline() => t
        .widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const ValueKey('ai-approval-deny-focus')),
            matching: find.byType(DecoratedBox),
          ).first,
        )
        .decoration as BoxDecoration;
    final border = outline().border! as Border;
    expect(border.top.width, 2);
    expect(border.top.color, theme.colorScheme.primary);
    // Not on Allow.
    t.widget<OutlinedButton>(find.byKey(const ValueKey('ai-approval-allow')));
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(outline().border, isNull, reason: 'focus moved to Allow');
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    await t.tap(find.byKey(const ValueKey('ai-approval-deny')));
    await t.pump(const Duration(milliseconds: 400));
    expect(await answer, isFalse);
    expired.complete();
  });

  testWidgets('Deny is the focused default and Allow is not the heavier button', (t) async {
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(navigatorKey: key, theme: buildNotedTheme(Brightness.light, touch: false), home: const SizedBox()),
    );
    final expired = Completer<void>();
    final answer = showAiApprovalDialog(
      key,
      AiApprovalRequest(app: 'A', write: true, label: 'L', perWrite: false, expired: expired.future),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(FilledButton), findsNothing, reason: 'neither answer is the filled one');
    expect(t.widget<OutlinedButton>(find.byKey(const ValueKey('ai-approval-allow'))), isNotNull);
    expect(t.widget<OutlinedButton>(find.byKey(const ValueKey('ai-approval-deny'))).autofocus, isTrue);
    // A stray Enter denies.
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(milliseconds: 400));
    expect(await answer, isFalse);
    expired.complete();
  });
}
