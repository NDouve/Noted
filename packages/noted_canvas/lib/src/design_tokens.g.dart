// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// GENERATED CODE - DO NOT EDIT.
// Source: docs/design/tokens.json
// Regenerate: dart run app/scripts/generate_tokens.dart

// ignore_for_file: public_member_api_docs

import 'package:flutter/painting.dart';

/// Every color token in one theme.
class DesignColors {
  const DesignColors({
    required this.bgApp,
    required this.bgSidebar,
    required this.bgCanvas,
    required this.surface,
    required this.surfaceHover,
    required this.border,
    required this.borderBox,
    required this.text,
    required this.textMuted,
    required this.textDisabled,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.conflict,
    required this.onConflict,
    required this.conflictSoft,
    required this.error,
    required this.inkDefault,
    required this.inkBlue,
    required this.inkOrange,
    required this.inkGreen,
    required this.inkPurple,
    required this.binderGreen,
    required this.binderOrange,
    required this.binderBlue,
    required this.binderPurple,
    required this.binderTeal,
    required this.paperLine,
    required this.paperDot,
    required this.paperMargin,
  });

  static const DesignColors light = DesignColors(
    bgApp: Color(0xFFF4F5F7),
    bgSidebar: Color(0xFFF4F5F7),
    bgCanvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceHover: Color(0xFFEEF0F3),
    border: Color(0xFFDCDFE4),
    borderBox: Color(0xFFE3E6EA),
    text: Color(0xFF1B1F24),
    textMuted: Color(0xFF5B6470),
    textDisabled: Color(0xFF9AA1AB),
    accent: Color(0xFF1F5FD6),
    accentSoft: Color(0xFFE6EEFD),
    onAccent: Color(0xFFFFFFFF),
    conflict: Color(0xFFB45309),
    onConflict: Color(0xFFFFFFFF),
    conflictSoft: Color(0xFFFDF0E1),
    error: Color(0xFFC62828),
    inkDefault: Color(0xFF202124),
    inkBlue: Color(0xFF1F5FD6),
    inkOrange: Color(0xFFC2410C),
    inkGreen: Color(0xFF2E8B57),
    inkPurple: Color(0xFF7C3AED),
    binderGreen: Color(0xFF2E8B57),
    binderOrange: Color(0xFFC2410C),
    binderBlue: Color(0xFF2563EB),
    binderPurple: Color(0xFF7C3AED),
    binderTeal: Color(0xFF0F766E),
    paperLine: Color(0xFFDBE3EE),
    paperDot: Color(0xFFC6CED9),
    paperMargin: Color(0xFFF2C4C4),
  );

  static const DesignColors dark = DesignColors(
    bgApp: Color(0xFF16181C),
    bgSidebar: Color(0xFF1A1D21),
    bgCanvas: Color(0xFF1E2126),
    surface: Color(0xFF24282E),
    surfaceHover: Color(0xFF2C3138),
    border: Color(0xFF353A42),
    borderBox: Color(0xFF3C424B),
    text: Color(0xFFE6E8EB),
    textMuted: Color(0xFFA0A8B3),
    textDisabled: Color(0xFF6B727C),
    accent: Color(0xFF7AA7FF),
    accentSoft: Color(0xFF22314D),
    onAccent: Color(0xFF0F1A2E),
    conflict: Color(0xFFF0A44B),
    onConflict: Color(0xFF1B1F24),
    conflictSoft: Color(0xFF3A2A14),
    error: Color(0xFFFF8A80),
    inkDefault: Color(0xFFF2F3F5),
    inkBlue: Color(0xFF1F5FD6),
    inkOrange: Color(0xFFC2410C),
    inkGreen: Color(0xFF2E8B57),
    inkPurple: Color(0xFF7C3AED),
    binderGreen: Color(0xFF5CC28C),
    binderOrange: Color(0xFFF08A5D),
    binderBlue: Color(0xFF7AA7FF),
    binderPurple: Color(0xFFB79CFF),
    binderTeal: Color(0xFF3CC8B4),
    paperLine: Color(0xFF2F353D),
    paperDot: Color(0xFF3B424B),
    paperMargin: Color(0xFF5A3434),
  );

  /// Window chrome behind the sidebar and toolbar.
  final Color bgApp;

  /// Sidebar (page tree) background.
  final Color bgSidebar;

  /// The page canvas. Page backgrounds (plain, dots, graph, ruled) draw on this.
  final Color bgCanvas;

  /// Boxes, toolbar, menus, dialogs.
  final Color surface;

  /// Hover fill for rows, menu items and ghost buttons.
  final Color surfaceHover;

  /// Hairlines: toolbar and sidebar edges, table cells, control outlines.
  final Color border;

  /// Idle box frame on the canvas. Quieter than border so content leads.
  final Color borderBox;

  /// Primary text on surface, bg-canvas and bg-app.
  final Color text;

  /// Secondary text, breadcrumbs, grid letters/numbers, group labels. Passes 4.5:1 on every background here.
  final Color textMuted;

  /// Inactive controls and unavailable pages only (WCAG exempts inactive UI). Never for readable content.
  final Color textDisabled;

  /// Selection, the active tool, the active page, focus rings, links. The only brand hue in the chrome.
  final Color accent;

  /// Fill behind the active tool, active page row and selected cells. accent text on it passes 4.5:1.
  final Color accentSoft;

  /// Text and icons on a solid accent fill (primary button).
  final Color onAccent;

  /// Sync conflicts only: box frame, badge, sidebar dot. Never decorative.
  final Color conflict;

  /// Text on a solid conflict fill (the Conflict badge).
  final Color onConflict;

  /// Read-only and recovery banners; conflict view header.
  final Color conflictSoft;

  /// Formula errors (#DIV/0!, #REF!), failed saves, destructive actions.
  final Color error;

  /// Display colour of default ink (stored as #FF202124). Flips with the theme; picked ink colours never do.
  final Color inkDefault;

  /// Ink swatch. Fixed in both themes.
  final Color inkBlue;

  /// Ink swatch. Fixed in both themes.
  final Color inkOrange;

  /// Ink swatch. Fixed in both themes.
  final Color inkGreen;

  /// Ink swatch. Fixed in both themes.
  final Color inkPurple;

  /// Binder colour chip and stripe. Stored value is the light one; dark shows the lifted shade.
  final Color binderGreen;

  /// Binder colour chip and stripe.
  final Color binderOrange;

  /// Binder colour chip and stripe.
  final Color binderBlue;

  /// Binder colour chip and stripe.
  final Color binderPurple;

  /// Binder colour chip and stripe.
  final Color binderTeal;

  /// Graph and ruled page-background lines. Decoration: stays below text contrast on purpose.
  final Color paperLine;

  /// Dot-grid page background.
  final Color paperDot;

  /// The left margin rule on the ruled page background.
  final Color paperMargin;
}

/// The shadow tokens, per theme.
abstract final class DesignShadows {
  /// Ring outside a selected box (with an accent border). Boxes have no drop shadow.
  static const List<BoxShadow> shadowSelectedLight = [
    BoxShadow(color: Color(0xFFE6EEFD), offset: Offset(0, 0), blurRadius: 0, spreadRadius: 3),
  ];
  /// Ring outside a selected box (with an accent border). Boxes have no drop shadow.
  static const List<BoxShadow> shadowSelectedDark = [
    BoxShadow(color: Color(0xFF22314D), offset: Offset(0, 0), blurRadius: 0, spreadRadius: 3),
  ];
  /// Menus, the / menu, tooltips, dialogs. The only drop shadow in the system.
  static const List<BoxShadow> shadowPopoverLight = [
    BoxShadow(color: Color.fromRGBO(16, 24, 40, 0.12), offset: Offset(0, 4), blurRadius: 16, spreadRadius: 0),
  ];
  /// Menus, the / menu, tooltips, dialogs. The only drop shadow in the system.
  static const List<BoxShadow> shadowPopoverDark = [
    BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.5), offset: Offset(0, 4), blurRadius: 16, spreadRadius: 0),
  ];
}

/// The spacing, radius and size tokens, in logical pixels.
abstract final class DesignMetrics {
  /// Gap between toolbar buttons; icon-to-label.
  static const double space1 = 4;
  /// Row padding, gap between related controls.
  static const double space2 = 8;
  /// Sidebar padding; toolbar group separators.
  static const double space3 = 12;
  /// Box padding (horizontal); toolbar side padding.
  static const double space4 = 16;
  /// Gap between sidebar groups; dialog padding.
  static const double space6 = 24;
  /// Page header inset from the canvas edge.
  static const double space8 = 32;
  /// Table cell selection, swatches in a square set, small chips.
  static const double radiusSm = 4;
  /// Buttons, toolbar buttons, sidebar rows, menu items.
  static const double radiusMd = 6;
  /// Boxes on the canvas, menus, dialogs, inputs.
  static const double radiusLg = 8;
  /// Badges, ink swatches, the conflict dot.
  static const double radiusFull = 999;
  /// Top toolbar height (36px buttons + 8px padding).
  static const double toolbarHeight = 52;
  /// Toolbar and icon buttons on desktop.
  static const double control = 36;
  /// Minimum control size on touch devices (iPad, Pixel, Surface in tablet mode).
  static const double touchTarget = 44;
  /// Sidebar row and menu item height on desktop (40px on touch).
  static const double row = 32;
  /// Icon size inside a 36px control.
  static const double icon = 18;
  /// Resize handle squares on a selected box.
  static const double handle = 8;
  /// Default spacing of dot, graph and ruled page backgrounds at 100% zoom.
  static const double paperPitch = 20;
  /// Default sidebar width (resizable 220–360px).
  static const double sidebarWidth = 264;
}

/// The font family and the type styles (without color).
abstract final class DesignType {
  static const String fontFamily = 'Inter';
  static const List<String> fontFamilyFallback = ['Segoe UI'];
  /// Page title above the canvas.
  static const TextStyle pageTitle = TextStyle(
    fontSize: 26,
    height: 32 / 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.52,
  );
  /// Heading 1 inside a box; dialog titles.
  static const TextStyle boxTitle = TextStyle(
    fontSize: 16,
    height: 22 / 16,
    fontWeight: FontWeight.w600,
  );
  /// Note text, menus, sidebar rows, buttons.
  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 22 / 14,
    fontWeight: FontWeight.w400,
  );
  /// Active sidebar row, table header cells.
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 14,
    height: 22 / 14,
    fontWeight: FontWeight.w600,
  );
  /// Breadcrumbs, timestamps, device labels, tooltips.
  static const TextStyle small = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w400,
  );
  /// Sidebar group headers (uppercase).
  static const TextStyle label = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.72,
  );
  /// Table cells and the zoom readout; use tabular figures.
  static const TextStyle numeric = TextStyle(
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}
