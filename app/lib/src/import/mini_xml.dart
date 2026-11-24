// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'import_limits.dart';

/// What [parseXml] reports. Names and attribute names are the local part
/// (`w:p` is `p`, `r:id` is `id`).
abstract interface class XmlHandler {
  void start(String name, Map<String, String> attributes);
  void end(String name);

  /// Character data (references resolved, CDATA included), in pieces.
  void text(String text);
}

/// A tokenizer for the parts of an Office file that are read. A document
/// type declaration refuses the file (no entities are defined, so none can
/// grow); only the five predefined references and numeric references are
/// resolved, and a numeric reference that isn't a Unicode scalar value (0, a
/// surrogate, above 0x10FFFF) refuses the file; nesting deeper than
/// [maxDepth] refuses it. Throws an [ImportException].
void parseXml(String xml, XmlHandler handler, {int maxDepth = 256}) {
  const malformed = ImportException('has XML that can’t be read');
  final stack = <String>[];
  final n = xml.length;
  var i = 0;
  // Everything before a root element or after it is skipped.
  while (i < n) {
    final lt = xml.indexOf('<', i);
    if (lt < 0) {
      if (stack.isNotEmpty) throw malformed;
      _text(xml.substring(i), stack, handler);
      break;
    }
    if (lt > i) _text(xml.substring(i, lt), stack, handler);
    i = lt;
    if (xml.startsWith('<!--', i)) {
      final e = xml.indexOf('-->', i + 4);
      if (e < 0) throw malformed;
      i = e + 3;
    } else if (xml.startsWith('<![CDATA[', i)) {
      final e = xml.indexOf(']]>', i + 9);
      if (e < 0 || stack.isEmpty) throw malformed;
      handler.text(xml.substring(i + 9, e));
      i = e + 3;
    } else if (xml.startsWith('<!', i)) {
      throw const ImportException('has a document type declaration, which can’t be imported');
    } else if (xml.startsWith('<?', i)) {
      final e = xml.indexOf('?>', i + 2);
      if (e < 0) throw malformed;
      i = e + 2;
    } else if (xml.startsWith('</', i)) {
      final e = xml.indexOf('>', i + 2);
      if (e < 0 || stack.isEmpty) throw malformed;
      final name = _local(xml.substring(i + 2, e).trim());
      if (stack.removeLast() != name) throw malformed;
      handler.end(name);
      i = e + 1;
    } else {
      i = _startTag(xml, i + 1, stack, handler, maxDepth);
    }
  }
  if (stack.isNotEmpty) throw malformed;
}

void _text(String raw, List<String> stack, XmlHandler h) {
  if (stack.isEmpty) return;
  h.text(_resolve(raw));
}

String _local(String name) {
  final c = name.indexOf(':');
  return c < 0 ? name : name.substring(c + 1);
}

bool _space(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

int _startTag(String xml, int from, List<String> stack, XmlHandler h, int maxDepth) {
  const malformed = ImportException('has XML that can’t be read');
  final n = xml.length;
  var i = from;
  while (i < n && !_space(xml.codeUnitAt(i)) && xml[i] != '>' && xml[i] != '/') {
    i++;
  }
  final name = _local(xml.substring(from, i));
  if (name.isEmpty) throw malformed;
  final attrs = <String, String>{};
  var selfClosing = false;
  while (true) {
    while (i < n && _space(xml.codeUnitAt(i))) {
      i++;
    }
    if (i >= n) throw malformed;
    final c = xml[i];
    if (c == '>') {
      i++;
      break;
    }
    if (c == '/') {
      if (i + 1 >= n || xml[i + 1] != '>') throw malformed;
      selfClosing = true;
      i += 2;
      break;
    }
    final s = i;
    while (i < n && !_space(xml.codeUnitAt(i)) && xml[i] != '=' && xml[i] != '>' && xml[i] != '/') {
      i++;
    }
    final key = _local(xml.substring(s, i));
    while (i < n && _space(xml.codeUnitAt(i))) {
      i++;
    }
    if (i >= n || xml[i] != '=' || key.isEmpty) throw malformed;
    i++;
    while (i < n && _space(xml.codeUnitAt(i))) {
      i++;
    }
    if (i >= n || (xml[i] != '"' && xml[i] != "'")) throw malformed;
    final q = xml[i];
    final e = xml.indexOf(q, i + 1);
    if (e < 0) throw malformed;
    attrs[key] = _resolve(xml.substring(i + 1, e));
    i = e + 1;
  }
  if (stack.length >= maxDepth) throw const ImportException('is nested too deeply to import');
  h.start(name, attrs);
  if (selfClosing) {
    h.end(name);
  } else {
    stack.add(name);
  }
  return i;
}

/// [raw] with its references resolved.
String _resolve(String raw) {
  if (!raw.contains('&')) return raw;
  const malformed = ImportException('has XML that can’t be read');
  final out = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final amp = raw.indexOf('&', i);
    if (amp < 0) {
      out.write(raw.substring(i));
      break;
    }
    out.write(raw.substring(i, amp));
    final semi = raw.indexOf(';', amp + 1);
    if (semi < 0 || semi - amp > 12) throw malformed;
    final ref = raw.substring(amp + 1, semi);
    switch (ref) {
      case 'amp':
        out.write('&');
      case 'lt':
        out.write('<');
      case 'gt':
        out.write('>');
      case 'quot':
        out.write('"');
      case 'apos':
        out.write("'");
      default:
        if (!ref.startsWith('#') || ref.length < 2) throw malformed;
        final hex = ref[1] == 'x';
        final digits = ref.substring(hex ? 2 : 1);
        final cp = digits.isEmpty || !RegExp(hex ? r'^[0-9a-fA-F]+$' : r'^[0-9]+$').hasMatch(digits)
            ? null
            : int.tryParse(digits, radix: hex ? 16 : 10);
        if (cp == null || cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
          throw const ImportException('has an invalid character reference');
        }
        out.writeCharCode(cp);
    }
    i = semi + 1;
  }
  return out.toString();
}

/// An element with its children, for the small parts that are read whole.
final class XmlElement {
  XmlElement(this.name, this.attributes);

  final String name;
  final Map<String, String> attributes;

  /// Child elements and text (a [String]), in order.
  final List<Object> children = [];

  Iterable<XmlElement> get elements => children.whereType<XmlElement>();

  /// The first child element named [n], or null.
  XmlElement? child(String n) {
    for (final c in elements) {
      if (c.name == n) return c;
    }
    return null;
  }

  /// All the text under this element.
  String get text {
    final b = StringBuffer();
    void walk(XmlElement e) {
      for (final c in e.children) {
        if (c is String) {
          b.write(c);
        } else {
          walk(c as XmlElement);
        }
      }
    }

    walk(this);
    return b.toString();
  }
}

/// The root element of [xml], with the whole tree under it.
XmlElement parseXmlTree(String xml, {int maxDepth = 256}) {
  final b = _TreeBuilder();
  parseXml(xml, b, maxDepth: maxDepth);
  final root = b.root;
  if (root == null) throw const ImportException('has XML that can’t be read');
  return root;
}

class _TreeBuilder implements XmlHandler {
  final List<XmlElement> _open = [];
  XmlElement? root;

  @override
  void start(String name, Map<String, String> attributes) {
    final e = XmlElement(name, attributes);
    if (_open.isEmpty) {
      root ??= e;
    } else {
      _open.last.children.add(e);
    }
    _open.add(e);
  }

  @override
  void end(String name) => _open.removeLast();

  @override
  void text(String text) {
    if (_open.isNotEmpty && text.isNotEmpty) _open.last.children.add(text);
  }
}
