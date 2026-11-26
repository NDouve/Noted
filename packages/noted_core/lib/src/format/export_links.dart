// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

final RegExp _scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):');

/// The link targets an export keeps: `http`, `https` and `mailto`.
const Set<String> exportLinkSchemes = {'http', 'https', 'mailto'};

/// The target an export may write for [href]: trimmed, with its scheme read
/// in lowercase, or null when the scheme isn't `http`, `https` or `mailto`
/// (including no scheme, `noted:`, `javascript:` and `data:`), in which case
/// the link keeps only its text.
String? exportLinkTarget(String href) {
  final t = href.trim();
  final m = _scheme.firstMatch(t);
  if (m == null) return null;
  return exportLinkSchemes.contains(m.group(1)!.toLowerCase()) ? t : null;
}

/// [target] made safe inside a markdown link's parentheses: `(`, `)`, `<`,
/// `>`, `\`, spaces and control characters are percent-encoded (as UTF-8
/// where they are not ASCII).
String markdownLinkTarget(String target) {
  final b = StringBuffer();
  for (final rune in target.runes) {
    if (rune <= 0x20 ||
        rune == 0x7F ||
        (rune >= 0x80 && rune <= 0x9F) ||
        rune == 0x28 ||
        rune == 0x29 ||
        rune == 0x3C ||
        rune == 0x3E ||
        rune == 0x5C) {
      if (rune < 0x80) {
        b.write('%${rune.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      } else {
        // C1 controls: U+0080..U+009F are two bytes in UTF-8.
        b.write('%C2%${rune.toRadixString(16).toUpperCase()}');
      }
    } else {
      b.writeCharCode(rune);
    }
  }
  return b.toString();
}
