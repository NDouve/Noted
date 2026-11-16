// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// The reply isn't XML this parser accepts. Never carries the text itself.
class XmlParseException extends FormatException {
  XmlParseException(super.message, [super.source, super.offset]);
  @override
  String toString() => 'XmlParseException: $message';
}

/// One element: its namespace (empty when none), local name, attributes, child
/// elements and the text directly inside it.
class XmlNode {
  XmlNode(this.ns, this.name, this.attributes);

  final String ns;
  final String name;

  /// By local name for an attribute with no namespace, else `{ns}local`.
  final Map<String, String> attributes;
  final List<XmlNode> children = [];
  final StringBuffer _text = StringBuffer();

  /// Character data and CDATA directly inside, in order.
  String get text => _text.toString();

  /// The text of this element and of everything inside it, in order.
  String get deepText {
    if (children.isEmpty) return text;
    final out = StringBuffer(text);
    for (final c in children) {
      out.write(c.deepText);
    }
    return out.toString();
  }

  /// `{ns}name`.
  String get qname => '{$ns}$name';

  bool named(String ns, String name) => this.ns == ns && this.name == name;

  XmlNode? child(String ns, String name) {
    for (final c in children) {
      if (c.named(ns, name)) return c;
    }
    return null;
  }

  Iterable<XmlNode> childrenNamed(String ns, String name) =>
      children.where((c) => c.named(ns, name));
}

/// A small XML parser of our own (no `xml` package), for WebDAV replies:
/// namespace-aware, UTF-8 only, the five predefined entities and numeric
/// references. A DOCTYPE or an entity declaration is refused, so no entity can
/// expand into more text. Nesting deeper than [maxDepth] is refused.
///
/// Throws [XmlParseException] and nothing else for any input.
XmlNode parseXml(List<int> bytes, {int maxDepth = 64}) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw XmlParseException('The reply is not UTF-8');
  }
  return _Parser(text, maxDepth).parse();
}

const String _xmlNs = 'http://www.w3.org/XML/1998/namespace';

class _Open {
  _Open(this.node, this.raw, this.scope);
  final XmlNode node;
  final String raw;
  final Map<String, String> scope;
}

class _Parser {
  _Parser(String text, this.maxDepth)
    : s = text.startsWith('﻿') ? text.substring(1) : text;

  final String s;
  final int maxDepth;
  int i = 0;

  Never fail(String why) => throw XmlParseException(why, null, i);

  bool at(String lit) => s.startsWith(lit, i);

  void skipWs() {
    while (i < s.length && _isWs(s.codeUnitAt(i))) {
      i++;
    }
  }

  static bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

  static bool _nameStart(int c) =>
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      c == 0x5f ||
      c == 0x3a ||
      c > 0x7f;

  static bool _nameChar(int c) =>
      _nameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x2e;

  String readName() {
    final start = i;
    if (i >= s.length || !_nameStart(s.codeUnitAt(i))) fail('Bad name');
    while (i < s.length && _nameChar(s.codeUnitAt(i))) {
      i++;
    }
    return s.substring(start, i);
  }

  /// Skips a comment or a processing instruction (and refuses a DOCTYPE or
  /// any other declaration). Returns whether something was skipped.
  bool skipMisc() {
    if (at('<!--')) {
      final end = s.indexOf('-->', i + 4);
      if (end < 0) fail('Unclosed comment');
      i = end + 3;
      return true;
    }
    if (at('<?')) {
      final end = s.indexOf('?>', i + 2);
      if (end < 0) fail('Unclosed instruction');
      final decl = s.substring(i, end);
      final enc = RegExp(r'''encoding\s*=\s*["']([^"']*)["']''')
          .firstMatch(decl);
      if (enc != null && enc.group(1)!.toLowerCase() != 'utf-8') {
        fail('Only UTF-8 is accepted');
      }
      i = end + 2;
      return true;
    }
    if (at('<!') && !at('<![CDATA[')) {
      fail('A DOCTYPE or declaration is refused');
    }
    return false;
  }

  XmlNode parse() {
    XmlNode? root;
    final stack = <_Open>[];
    while (true) {
      if (stack.isEmpty) {
        skipWs();
        if (i >= s.length) break;
        if (skipMisc()) continue;
        if (root != null) fail('Content after the root element');
        if (!at('<') || at('</') || at('<![CDATA[')) fail('No root element');
      } else if (i >= s.length) {
        fail('Unclosed element');
      }
      final top = stack.isEmpty ? null : stack.last;
      if (s.codeUnitAt(i) != 0x3c) {
        // Character data.
        final end = s.indexOf('<', i);
        final stop = end < 0 ? s.length : end;
        top!.node._text.write(_decode(s.substring(i, stop)));
        i = stop;
        continue;
      }
      if (at('<![CDATA[')) {
        final end = s.indexOf(']]>', i + 9);
        if (end < 0) fail('Unclosed CDATA');
        top!.node._text.write(s.substring(i + 9, end));
        i = end + 3;
        continue;
      }
      if (at('<!') || at('<?')) {
        skipMisc();
        continue;
      }
      if (at('</')) {
        i += 2;
        final raw = readName();
        skipWs();
        if (i >= s.length || s.codeUnitAt(i) != 0x3e) fail('Bad end tag');
        i++;
        if (top == null || top.raw != raw) fail('Mismatched end tag');
        stack.removeLast();
        continue;
      }
      // A start tag.
      i++;
      final raw = readName();
      final attrs = <String, String>{};
      var empty = false;
      while (true) {
        skipWs();
        if (i >= s.length) fail('Unclosed tag');
        final ch = s.codeUnitAt(i);
        if (ch == 0x3e) {
          i++;
          break;
        }
        if (ch == 0x2f) {
          if (i + 1 >= s.length || s.codeUnitAt(i + 1) != 0x3e) {
            fail('Bad tag');
          }
          i += 2;
          empty = true;
          break;
        }
        final an = readName();
        skipWs();
        if (i >= s.length || s.codeUnitAt(i) != 0x3d) fail('Bad attribute');
        i++;
        skipWs();
        if (i >= s.length) fail('Bad attribute');
        final q = s.codeUnitAt(i);
        if (q != 0x22 && q != 0x27) fail('Bad attribute');
        final end = s.indexOf(String.fromCharCode(q), i + 1);
        if (end < 0) fail('Unclosed attribute');
        final value = s.substring(i + 1, end);
        if (value.contains('<')) fail('Bad attribute');
        i = end + 1;
        if (attrs.containsKey(an)) fail('Repeated attribute');
        attrs[an] = _decode(value);
      }
      // Namespaces.
      var scope = top?.scope ?? const {'xml': _xmlNs};
      var copied = false;
      final plain = <String, String>{};
      final prefixed = <(String, String, String)>[];
      for (final e in attrs.entries) {
        final n = e.key;
        if (n == 'xmlns' || n.startsWith('xmlns:')) {
          if (!copied) {
            scope = Map.of(scope);
            copied = true;
          }
          final p = n == 'xmlns' ? '' : n.substring(6);
          if (n != 'xmlns' && p.isEmpty) fail('Bad namespace');
          scope[p] = e.value;
        } else {
          final k = n.indexOf(':');
          if (k < 0) {
            plain[n] = e.value;
          } else {
            prefixed.add((n.substring(0, k), n.substring(k + 1), e.value));
          }
        }
      }
      final colon = raw.indexOf(':');
      final String ns;
      final String local;
      if (colon < 0) {
        ns = scope[''] ?? '';
        local = raw;
      } else {
        final p = raw.substring(0, colon);
        local = raw.substring(colon + 1);
        final found = scope[p];
        if (found == null || local.isEmpty) fail('Unbound prefix');
        ns = found;
      }
      for (final (p, l, v) in prefixed) {
        final found = scope[p];
        if (found == null || l.isEmpty) fail('Unbound prefix');
        plain['{$found}$l'] = v;
      }
      final node = XmlNode(ns, local, plain);
      if (top != null) {
        top.node.children.add(node);
      } else {
        root = node;
      }
      if (!empty) {
        if (stack.length >= maxDepth) fail('Nested too deeply');
        stack.add(_Open(node, raw, scope));
      }
    }
    if (root == null) fail('No root element');
    return root;
  }

  /// Resolves references; anything but the five predefined entities and a
  /// valid numeric reference is refused.
  String _decode(String t) {
    if (!t.contains('&')) return t;
    final out = StringBuffer();
    var k = 0;
    while (k < t.length) {
      final c = t.codeUnitAt(k);
      if (c != 0x26) {
        out.writeCharCode(c);
        k++;
        continue;
      }
      final end = t.indexOf(';', k + 1);
      if (end < 0 || end - k > 12) fail('Bad reference');
      final ref = t.substring(k + 1, end);
      k = end + 1;
      switch (ref) {
        case 'lt':
          out.write('<');
        case 'gt':
          out.write('>');
        case 'amp':
          out.write('&');
        case 'quot':
          out.write('"');
        case 'apos':
          out.write("'");
        default:
          if (!ref.startsWith('#')) fail('An entity is not defined');
          final hex = ref.startsWith('#x');
          final digits = ref.substring(hex ? 2 : 1);
          final valid = RegExp(hex ? r'^[0-9a-fA-F]+$' : r'^[0-9]+$');
          final n = valid.hasMatch(digits)
              ? int.tryParse(digits, radix: hex ? 16 : 10)
              : null;
          if (n == null || !_xmlChar(n)) fail('Bad character reference');
          out.writeCharCode(n);
      }
    }
    return out.toString();
  }

  static bool _xmlChar(int n) =>
      n == 0x9 ||
      n == 0xa ||
      n == 0xd ||
      (n >= 0x20 && n <= 0xd7ff) ||
      (n >= 0xe000 && n <= 0xfffd) ||
      (n >= 0x10000 && n <= 0x10ffff);
}

// --- WebDAV multistatus ----------------------------------------------------

const String davNs = 'DAV:';
const String ownCloudNs = 'http://owncloud.org/ns';

/// A property's value: its text and the names (`{ns}local`) of the elements
/// inside it (`resourcetype` holds `{DAV:}collection` for a folder).
class DavProp {
  const DavProp(this.text, this.childNames);
  final String text;
  final Set<String> childNames;
}

/// The code in a `status` line; 0 when it can't be read.
int _statusCode(String line) {
  final m = RegExp(r'^\s*HTTP/\d+(?:\.\d+)?\s+(\d{3})').firstMatch(line);
  return m == null ? 0 : int.parse(m.group(1)!);
}

class DavPropstat {
  const DavPropstat(this.status, this.props);

  /// 0 when the status line couldn't be read.
  final int status;

  /// By `{ns}local`.
  final Map<String, DavProp> props;
  bool get ok => status >= 200 && status < 300;
}

class DavResponse {
  const DavResponse(this.hrefs, this.status, this.propstats);

  final List<String> hrefs;

  /// The response's own status, when it has one (0 when unreadable).
  final int? status;
  final List<DavPropstat> propstats;

  /// The response itself isn't a failure: it has no status of its own, or a
  /// 2xx one.
  bool get ok => status == null || (status! >= 200 && status! < 300);

  /// The property in a 2xx propstat. A 404 propstat for a property the item
  /// lacks is normal (RFC 4918 section 9.1): such a property is simply null.
  DavProp? prop(String ns, String local) {
    for (final p in propstats) {
      if (!p.ok) continue;
      final v = p.props['{$ns}$local'];
      if (v != null) return v;
    }
    return null;
  }
}

/// The responses of a 207 body. Throws [XmlParseException] when it isn't a
/// multistatus.
List<DavResponse> parseMultistatus(List<int> bytes, {int maxDepth = 64}) {
  final root = parseXml(bytes, maxDepth: maxDepth);
  if (!root.named(davNs, 'multistatus')) {
    throw XmlParseException('Not a multistatus reply');
  }
  final out = <DavResponse>[];
  for (final r in root.childrenNamed(davNs, 'response')) {
    final hrefs = [
      for (final h in r.childrenNamed(davNs, 'href')) h.text.trim(),
    ];
    if (hrefs.isEmpty || hrefs.any((h) => h.isEmpty)) {
      throw XmlParseException('A response had no href');
    }
    final st = r.child(davNs, 'status');
    final propstats = <DavPropstat>[];
    for (final ps in r.childrenNamed(davNs, 'propstat')) {
      final s = ps.child(davNs, 'status');
      final props = <String, DavProp>{};
      final prop = ps.child(davNs, 'prop');
      if (prop != null) {
        for (final p in prop.children) {
          props[p.qname] = DavProp(p.deepText.trim(), {
            for (final c in p.children) c.qname,
          });
        }
      }
      propstats.add(DavPropstat(s == null ? 0 : _statusCode(s.text), props));
    }
    out.add(
      DavResponse(hrefs, st == null ? null : _statusCode(st.text), propstats),
    );
  }
  return out;
}
