// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'design_tokens.g.dart';
import 'noted_colors.dart';

/// The spacing, radius, size and shadow design tokens. Register it in
/// `ThemeData.extensions`; [NotedMetrics.of] falls back to the light set when
/// a theme has none.
@immutable
class NotedMetrics extends ThemeExtension<NotedMetrics> {
  const NotedMetrics({
    this.space1 = DesignMetrics.space1,
    this.space2 = DesignMetrics.space2,
    this.space3 = DesignMetrics.space3,
    this.space4 = DesignMetrics.space4,
    this.space6 = DesignMetrics.space6,
    this.space8 = DesignMetrics.space8,
    this.radiusSm = DesignMetrics.radiusSm,
    this.radiusMd = DesignMetrics.radiusMd,
    this.radiusLg = DesignMetrics.radiusLg,
    this.radiusFull = DesignMetrics.radiusFull,
    this.toolbarHeight = DesignMetrics.toolbarHeight,
    this.control = DesignMetrics.control,
    this.touchTarget = DesignMetrics.touchTarget,
    this.row = DesignMetrics.row,
    this.icon = DesignMetrics.icon,
    this.handle = DesignMetrics.handle,
    this.paperPitch = DesignMetrics.paperPitch,
    this.sidebarWidth = DesignMetrics.sidebarWidth,
    this.shadowSelected = DesignShadows.shadowSelectedLight,
    this.shadowPopover = DesignShadows.shadowPopoverLight,
  });

  /// The metrics for [brightness] (only the shadows differ).
  factory NotedMetrics.forBrightness(Brightness brightness) =>
      brightness == Brightness.dark
      ? const NotedMetrics(
          shadowSelected: DesignShadows.shadowSelectedDark,
          shadowPopover: DesignShadows.shadowPopoverDark,
        )
      : const NotedMetrics();

  /// The theme's, or the token set for its brightness.
  static NotedMetrics of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NotedMetrics>() ??
        NotedMetrics.forBrightness(theme.brightness);
  }

  // Spacing (4px base).
  final double space1;
  final double space2;
  final double space3;
  final double space4;
  final double space6;
  final double space8;

  // Radius.
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusFull;

  // Size.
  final double toolbarHeight;
  final double control;
  final double touchTarget;
  final double row;
  final double icon;
  final double handle;
  final double paperPitch;
  final double sidebarWidth;

  /// Ring outside a selected box (with an accent border).
  final List<BoxShadow> shadowSelected;

  /// The only drop shadow: menus, dialogs, tooltips.
  final List<BoxShadow> shadowPopover;

  /// `BorderRadius.circular` of [radiusSm], [radiusMd], [radiusLg], [radiusFull].
  BorderRadius get borderSm => BorderRadius.circular(radiusSm);
  BorderRadius get borderMd => BorderRadius.circular(radiusMd);
  BorderRadius get borderLg => BorderRadius.circular(radiusLg);
  BorderRadius get borderFull => BorderRadius.circular(radiusFull);

  @override
  NotedMetrics copyWith({
    double? space1,
    double? space2,
    double? space3,
    double? space4,
    double? space6,
    double? space8,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusFull,
    double? toolbarHeight,
    double? control,
    double? touchTarget,
    double? row,
    double? icon,
    double? handle,
    double? paperPitch,
    double? sidebarWidth,
    List<BoxShadow>? shadowSelected,
    List<BoxShadow>? shadowPopover,
  }) => NotedMetrics(
    space1: space1 ?? this.space1,
    space2: space2 ?? this.space2,
    space3: space3 ?? this.space3,
    space4: space4 ?? this.space4,
    space6: space6 ?? this.space6,
    space8: space8 ?? this.space8,
    radiusSm: radiusSm ?? this.radiusSm,
    radiusMd: radiusMd ?? this.radiusMd,
    radiusLg: radiusLg ?? this.radiusLg,
    radiusFull: radiusFull ?? this.radiusFull,
    toolbarHeight: toolbarHeight ?? this.toolbarHeight,
    control: control ?? this.control,
    touchTarget: touchTarget ?? this.touchTarget,
    row: row ?? this.row,
    icon: icon ?? this.icon,
    handle: handle ?? this.handle,
    paperPitch: paperPitch ?? this.paperPitch,
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
    shadowSelected: shadowSelected ?? this.shadowSelected,
    shadowPopover: shadowPopover ?? this.shadowPopover,
  );

  @override
  NotedMetrics lerp(NotedMetrics? other, double t) {
    if (other == null) return this;
    double l(double a, double b) => lerpDouble(a, b, t)!;
    return NotedMetrics(
      space1: l(space1, other.space1),
      space2: l(space2, other.space2),
      space3: l(space3, other.space3),
      space4: l(space4, other.space4),
      space6: l(space6, other.space6),
      space8: l(space8, other.space8),
      radiusSm: l(radiusSm, other.radiusSm),
      radiusMd: l(radiusMd, other.radiusMd),
      radiusLg: l(radiusLg, other.radiusLg),
      radiusFull: l(radiusFull, other.radiusFull),
      toolbarHeight: l(toolbarHeight, other.toolbarHeight),
      control: l(control, other.control),
      touchTarget: l(touchTarget, other.touchTarget),
      row: l(row, other.row),
      icon: l(icon, other.icon),
      handle: l(handle, other.handle),
      paperPitch: l(paperPitch, other.paperPitch),
      sidebarWidth: l(sidebarWidth, other.sidebarWidth),
      shadowSelected: BoxShadow.lerpList(
        shadowSelected,
        other.shadowSelected,
        t,
      )!,
      shadowPopover: BoxShadow.lerpList(shadowPopover, other.shadowPopover, t)!,
    );
  }
}

/// The named type styles of the design tokens, in the theme's text color,
/// with the Inter family and its fallbacks. `label` is not uppercased here:
/// the widget uppercases the text. `numeric` has tabular figures.
@immutable
class NotedTypography extends ThemeExtension<NotedTypography> {
  const NotedTypography({
    required this.pageTitle,
    required this.boxTitle,
    required this.body,
    required this.bodyStrong,
    required this.small,
    required this.label,
    required this.numeric,
  });

  /// The styles in [color].
  factory NotedTypography.withColor(Color color) {
    TextStyle s(TextStyle base) => base.copyWith(
      color: color,
      fontFamily: DesignType.fontFamily,
      fontFamilyFallback: DesignType.fontFamilyFallback,
    );
    return NotedTypography(
      pageTitle: s(DesignType.pageTitle),
      boxTitle: s(DesignType.boxTitle),
      body: s(DesignType.body),
      bodyStrong: s(DesignType.bodyStrong),
      small: s(DesignType.small),
      label: s(DesignType.label),
      numeric: s(DesignType.numeric),
    );
  }

  /// The theme's, or the styles for its text color.
  static NotedTypography of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NotedTypography>() ??
        NotedTypography.withColor(theme.colorScheme.onSurface);
  }

  /// Page title above the canvas.
  final TextStyle pageTitle;

  /// Heading 1 inside a box; dialog titles.
  final TextStyle boxTitle;

  /// Note text, menus, sidebar rows, buttons.
  final TextStyle body;

  /// Active sidebar row, table header cells.
  final TextStyle bodyStrong;

  /// Breadcrumbs, timestamps, device labels, tooltips.
  final TextStyle small;

  /// Sidebar group headers (the widget uppercases the text).
  final TextStyle label;

  /// Table cells and the zoom readout (tabular figures).
  final TextStyle numeric;

  @override
  NotedTypography copyWith({
    TextStyle? pageTitle,
    TextStyle? boxTitle,
    TextStyle? body,
    TextStyle? bodyStrong,
    TextStyle? small,
    TextStyle? label,
    TextStyle? numeric,
  }) => NotedTypography(
    pageTitle: pageTitle ?? this.pageTitle,
    boxTitle: boxTitle ?? this.boxTitle,
    body: body ?? this.body,
    bodyStrong: bodyStrong ?? this.bodyStrong,
    small: small ?? this.small,
    label: label ?? this.label,
    numeric: numeric ?? this.numeric,
  );

  @override
  NotedTypography lerp(NotedTypography? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return NotedTypography(
      pageTitle: l(pageTitle, other.pageTitle),
      boxTitle: l(boxTitle, other.boxTitle),
      body: l(body, other.body),
      bodyStrong: l(bodyStrong, other.bodyStrong),
      small: l(small, other.small),
      label: l(label, other.label),
      numeric: l(numeric, other.numeric),
    );
  }
}

/// The color scheme of the design tokens [c] (README, "Mapping to Flutter").
///
/// Slots the README names: primary = accent, onPrimary = on-accent,
/// primaryContainer = accent-soft, onPrimaryContainer = accent, surface =
/// surface, onSurface = text, onSurfaceVariant = text-muted, outline = border,
/// outlineVariant = border-box, error = error, surfaceContainerLowest =
/// bg-canvas, surfaceContainerLow = bg-app.
///
/// Remaining slots, filled from the same tokens:
/// - secondary / tertiary = accent, onSecondary / onTertiary = on-accent,
///   secondaryContainer / tertiaryContainer = accent-soft, onSecondaryContainer
///   / onTertiaryContainer = accent (the active-row look, so selected menu
///   items and rows match);
/// - onError = on-accent; errorContainer = surface-hover, onErrorContainer =
///   error;
/// - surfaceDim = bg-app, surfaceBright = surface, surfaceContainer and
///   surfaceContainerHigh = surface (toolbar, menus, dialogs),
///   surfaceContainerHighest = surface-hover;
/// - inverseSurface = text, onInverseSurface = surface, inversePrimary =
///   accent; surfaceTint = transparent (no Material elevation tint);
/// - shadow and scrim = black.
ColorScheme notedColorScheme(Brightness brightness) {
  final c = brightness == Brightness.dark
      ? DesignColors.dark
      : DesignColors.light;
  return ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.accent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    secondaryContainer: c.accentSoft,
    onSecondaryContainer: c.accent,
    tertiary: c.accent,
    onTertiary: c.onAccent,
    tertiaryContainer: c.accentSoft,
    onTertiaryContainer: c.accent,
    error: c.error,
    onError: c.onAccent,
    errorContainer: c.surfaceHover,
    onErrorContainer: c.error,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.textMuted,
    outline: c.border,
    outlineVariant: c.borderBox,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    inverseSurface: c.text,
    onInverseSurface: c.surface,
    inversePrimary: c.accent,
    surfaceTint: const Color(0x00000000),
    surfaceDim: c.bgApp,
    surfaceBright: c.surface,
    surfaceContainerLowest: c.bgCanvas,
    surfaceContainerLow: c.bgApp,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.surfaceHover,
  );
}

/// The `TextTheme` of the design tokens in [color]: page-title = headlineSmall,
/// box-title = titleMedium, body-strong = titleSmall, body = bodyLarge,
/// bodyMedium and labelLarge, small = bodySmall and labelMedium, label =
/// labelSmall. Other slots keep Material's defaults (in the Inter family).
TextTheme notedTextTheme(Color color) {
  final t = NotedTypography.withColor(color);
  return TextTheme(
    headlineSmall: t.pageTitle,
    titleMedium: t.boxTitle,
    titleSmall: t.bodyStrong,
    bodyLarge: t.body,
    bodyMedium: t.body,
    bodySmall: t.small,
    labelLarge: t.body,
    labelMedium: t.small,
    labelSmall: t.label,
  );
}

/// The app theme in [brightness], built from the design tokens: the
/// [ColorScheme] of [notedColorScheme], the [TextTheme] of [notedTextTheme]
/// (Inter, falling back to Segoe UI), and the [NotedColors], [NotedMetrics]
/// and [NotedTypography] extensions.
ThemeData notedThemeData(Brightness brightness) {
  final scheme = notedColorScheme(brightness);
  final colors = NotedColors.forBrightness(brightness);
  final dark = brightness == Brightness.dark;
  final tokens = dark ? DesignColors.dark : DesignColors.light;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: DesignType.fontFamily,
    fontFamilyFallback: DesignType.fontFamilyFallback,
    textTheme: notedTextTheme(tokens.text),
    scaffoldBackgroundColor: tokens.bgCanvas,
    canvasColor: tokens.surface,
    dividerColor: tokens.border,
    hoverColor: tokens.surfaceHover,
    disabledColor: tokens.textDisabled,
    extensions: [
      colors,
      NotedMetrics.forBrightness(brightness),
      NotedTypography.withColor(tokens.text),
    ],
  );
}
