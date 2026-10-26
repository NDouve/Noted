// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Generates packages/noted_canvas/lib/src/design_tokens.g.dart from
// docs/design/tokens.json. Run from the repository root:
//
//   dart run app/scripts/generate_tokens.dart
//
// tokens.json is the single source of the design tokens; never edit the
// generated file by hand.

import 'dart:convert';
import 'dart:io';

const String tokensPath = 'docs/design/tokens.json';
const String outputPath = 'packages/noted_canvas/lib/src/design_tokens.g.dart';

void main() {
  final json = File(tokensPath).readAsStringSync();
  File(outputPath).writeAsStringSync(generateTokens(json));
  stdout.writeln('Wrote $outputPath');
}

String _camel(String name) {
  final parts = name.split('-');
  return parts.first +
      parts
          .skip(1)
          .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1))
          .join();
}

/// `#rrggbb` as a Dart `Color` literal.
String _color(String hex) {
  final h = hex.replaceFirst('#', '').toUpperCase();
  if (h.length != 6 && h.length != 8) throw FormatException('Bad color $hex');
  return 'Color(0x${h.length == 6 ? 'FF$h' : h})';
}

String _px(String value) {
  final m = RegExp(r'^(-?[0-9.]+)px$').firstMatch(value.trim());
  if (m == null) throw FormatException('Bad length $value');
  return _num(double.parse(m.group(1)!));
}

String _num(num n) {
  final d = n.toDouble();
  return d == d.roundToDouble() ? d.toInt().toString() : '$d';
}

/// A CSS color: `#rrggbb` or `rgba(r, g, b, a)`.
String _cssColor(String css) {
  css = css.trim();
  if (css.startsWith('#')) return _color(css);
  final m = RegExp(
    r'^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)$',
  ).firstMatch(css);
  if (m == null) throw FormatException('Bad color $css');
  return 'Color.fromRGBO(${m.group(1)}, ${m.group(2)}, ${m.group(3)}, ${m.group(4)})';
}

/// A CSS shadow `x y blur [spread] color` as a Flutter `BoxShadow` literal.
String _shadow(String css) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  for (final ch in css.trim().split('')) {
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ' ' && depth == 0) {
      if (buffer.isNotEmpty) tokens.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  final color = tokens.removeLast();
  num len(String t) => t == '0' ? 0 : double.parse(_px(t));
  if (tokens.length < 3 || tokens.length > 4) {
    throw FormatException('Bad shadow $css');
  }
  final x = len(tokens[0]);
  final y = len(tokens[1]);
  final blur = len(tokens[2]);
  final spread = tokens.length == 4 ? len(tokens[3]) : 0;
  return 'BoxShadow(color: ${_cssColor(color)}, '
      'offset: Offset(${_num(x)}, ${_num(y)}), '
      'blurRadius: ${_num(blur)}, spreadRadius: ${_num(spread)})';
}

/// Returns the text of the generated Dart file for the tokens in [source].
String generateTokens(String source) {
  final root = jsonDecode(source) as Map<String, Object?>;
  final out = StringBuffer()
    ..writeln(
      '// This Source Code Form is subject to the terms of the Mozilla Public',
    )
    ..writeln(
      '// License, v. 2.0. If a copy of the MPL was not distributed with this',
    )
    ..writeln('// file, You can obtain one at https://mozilla.org/MPL/2.0/.')
    ..writeln()
    ..writeln('// GENERATED CODE - DO NOT EDIT.')
    ..writeln('// Source: docs/design/tokens.json')
    ..writeln('// Regenerate: dart run app/scripts/generate_tokens.dart')
    ..writeln()
    ..writeln('// ignore_for_file: public_member_api_docs')
    ..writeln()
    ..writeln("import 'package:flutter/painting.dart';");

  // Colors.
  final colors = ((root['color']! as Map)['tokens']! as List)
      .cast<Map<String, Object?>>();
  String colorOf(Map<String, Object?> t, String theme) =>
      _color((t['value']! as Map)[theme]! as String);
  out
    ..writeln()
    ..writeln('/// Every color token in one theme.')
    ..writeln('class DesignColors {')
    ..writeln('  const DesignColors({');
  for (final t in colors) {
    out.writeln('    required this.${_camel(t['name']! as String)},');
  }
  out.writeln('  });');
  for (final theme in ['light', 'dark']) {
    out
      ..writeln()
      ..writeln('  static const DesignColors $theme = DesignColors(');
    for (final t in colors) {
      out.writeln('    ${_camel(t['name']! as String)}: ${colorOf(t, theme)},');
    }
    out.writeln('  );');
  }
  for (final t in colors) {
    out
      ..writeln()
      ..writeln('  /// ${(t['usage']! as String).replaceAll('\n', ' ')}')
      ..writeln('  final Color ${_camel(t['name']! as String)};');
  }
  out.writeln('}');

  // Shadows.
  final shadows = ((root['shadow']! as Map)['tokens']! as List)
      .cast<Map<String, Object?>>();
  out
    ..writeln()
    ..writeln('/// The shadow tokens, per theme.')
    ..writeln('abstract final class DesignShadows {');
  for (final t in shadows) {
    for (final theme in ['light', 'dark']) {
      final name = _camel('${t['name']}-$theme');
      out
        ..writeln('  /// ${t['usage']}')
        ..writeln('  static const List<BoxShadow> $name = [')
        ..writeln('    ${_shadow((t['value']! as Map)[theme]! as String)},')
        ..writeln('  ];');
    }
  }
  out.writeln('}');

  // Spacing, radius, size.
  out
    ..writeln()
    ..writeln('/// The spacing, radius and size tokens, in logical pixels.')
    ..writeln('abstract final class DesignMetrics {');
  for (final group in ['spacing', 'radius', 'size']) {
    for (final t
        in ((root[group]! as Map)['tokens']! as List)
            .cast<Map<String, Object?>>()) {
      out
        ..writeln('  /// ${t['usage']}')
        ..writeln(
          '  static const double ${_camel(t['name']! as String)} = ${_px(t['value']! as String)};',
        );
    }
  }
  out.writeln('}');

  // Type.
  final type = root['type']! as Map<String, Object?>;
  final families = type['families']! as Map<String, Object?>;
  final sans = (families['sans']! as String)
      .split(',')
      .map((f) => f.trim().replaceAll('"', ''))
      .toList();
  const generic = {'system-ui', 'sans-serif', 'serif', 'monospace'};
  final fallback = sans.skip(1).where((f) => !generic.contains(f));
  out
    ..writeln()
    ..writeln('/// The font family and the type styles (without color).')
    ..writeln('abstract final class DesignType {')
    ..writeln("  static const String fontFamily = '${sans.first}';")
    ..writeln(
      '  static const List<String> fontFamilyFallback = '
      "[${fallback.map((f) => "'$f'").join(', ')}];",
    );
  for (final group in (type['groups']! as List).cast<Map<String, Object?>>()) {
    for (final s in (group['styles']! as List).cast<Map<String, Object?>>()) {
      final size = double.parse(_px(s['fontSize']! as String));
      final line = double.parse(_px(s['lineHeight']! as String));
      final weight = s['fontWeight']! as int;
      final em = s['letterSpacing'] as String?;
      final spacing = em == null
          ? null
          : double.parse(
              (double.parse(em.replaceAll('em', '')) * size).toStringAsFixed(4),
            );
      final tabular = (s['usage']! as String).contains('tabular figures');
      out
        ..writeln('  /// ${s['usage']}')
        ..writeln(
          '  static const TextStyle ${_camel(s['name']! as String)} = TextStyle(',
        )
        ..writeln('    fontSize: ${_num(size)},')
        ..writeln('    height: ${_num(line)} / ${_num(size)},')
        ..writeln('    fontWeight: FontWeight.w$weight,');
      if (spacing != null) out.writeln('    letterSpacing: ${_num(spacing)},');
      if (tabular) {
        out.writeln('    fontFeatures: [FontFeature.tabularFigures()],');
      }
      out.writeln('  );');
    }
  }
  out.writeln('}');
  return out.toString();
}
