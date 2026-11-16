// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noted_sync/src/webdav/webdav_xml.dart';

import 'remote_fake.dart';

/// What ids the fake server reports for its items.
enum FakeDavIds {
  /// None: the client falls back to the path.
  path,

  /// Nextcloud's `oc:fileid`.
  ocFileId,

  /// `DAV:resource-id` (RFC 5842).
  resourceId,

  /// Both of those.
  both,
}

/// How the XML is spelled (the client must not care).
enum FakeDavXml { prefixD, defaultNamespace, oddPrefix }

/// How `href`s are spelled.
enum FakeDavHrefs { absolutePath, absoluteUrl, relative }

/// A request the fake server saw.
class SeenDav {
  SeenDav(
    this.method,
    this.path,
    this.authorization,
    this.acceptEncoding,
    this.depth,
  );
  final String method;

  /// Decoded.
  final String path;
  final String? authorization;
  final String? acceptEncoding;
  final String? depth;
  @override
  String toString() => '$method $path';
}

class FakeDavNode {
  FakeDavNode(
    this.id,
    this.parent,
    this.name, {
    this.folder = false,
    List<int>? bytes,
  }) : bytes = bytes ?? const [];
  int id;
  int? parent;
  String name;
  bool folder;
  List<int> bytes;
  int ver = 1;
  bool gone = false;
}

class _Redirect {
  _Redirect(this.status, this.location, this.times);
  final int status;
  final String location;
  int times;
}

class _Fault {
  _Fault(this.method, this.status, this.retryAfter, this.lose, this.times);
  final String method;
  final int status;
  final String? retryAfter;
  final bool lose;
  int times;
}

/// An in-process stand-in for a WebDAV server (Nextcloud-like): `OPTIONS`,
/// `PROPFIND` at `Depth: 0` and `1`, and `GET`, under `/dav/`. It answers
/// anything else with 405, so a test can see that nothing is ever written.
/// Basic auth; ETags weak or strong, optionally gzip-tagged; 404 propstats for
/// properties an item lacks; faults and redirects a real server shows.
class FakeWebDav implements RemoteFake {
  FakeWebDav._(this._server);

  static const String mount = '/dav';
  static const String user = 'alice';

  static Future<FakeWebDav> start({FakeDavIds ids = FakeDavIds.path}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final d = FakeWebDav._(s)..ids = ids;
    d.nodes[0] = FakeDavNode(0, null, '', folder: true);
    unawaited(d._serve());
    return d;
  }

  final HttpServer _server;
  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  /// The address of the folder at [path] (relative to the account's top).
  Uri urlOf(String path) => origin.replace(
    pathSegments: [
      for (final s in mount.split('/'))
        if (s.isNotEmpty) s,
      ...path.split('/').where((s) => s.isNotEmpty),
      '',
    ],
  );

  @override
  Future<void> close() => _server.close(force: true);

  final Map<int, FakeDavNode> nodes = {};
  int _nextId = 1;

  /// The password the server accepts; others get 401.
  String password = 'app-password';

  // Behaviour switches.
  FakeDavIds ids = FakeDavIds.path;
  FakeDavXml xml = FakeDavXml.prefixD;
  FakeDavHrefs hrefs = FakeDavHrefs.absolutePath;

  /// ETags as `W/"..."` (in listings and on `GET`).
  bool weakEtags = false;

  /// A `GET` that accepts gzip is compressed, with an ETag tagged `-gzip` (as
  /// Apache's mod_deflate does), which differs from the listing's.
  bool gzipEtags = false;

  /// Files listed with no `getetag` (a 404 propstat for it).
  bool omitEtags = false;

  /// `GET` answers without an `ETag` header.
  bool omitGetEtag = false;

  /// `GET` answers with this `ETag` instead of the item's.
  String? getEtagOverride;

  /// Files listed with no `getcontentlength`.
  bool omitLengths = false;

  /// Added to every listed `getcontentlength` (the listing lies about size).
  int listedLengthExtra = 0;

  /// Paths (relative to the top) whose id properties are left out.
  final Set<String> noIdFor = {};

  /// Folders (relative to the top) whose listing is an empty multistatus.
  final Set<String> emptyListings = {};

  /// Hrefs of files that a listing names although they aren't in the folder\n  /// (above it, or on another host).
  final List<String> strayHrefs = [];

  /// The host name `absoluteUrl` hrefs use (another name for the server).
  String? hrefHost;

  /// A `GET` that never ends: this many bytes per chunk, forever.
  int? endlessBody;

  /// Bytes of padding added to every listing (a comment).
  int padListing = 0;

  /// 207 bodies get this XML prepended after the declaration (for DOCTYPE
  /// tests).
  String? injectAfterDeclaration;

  /// Requests with `OPTIONS` lacking `DAV: 1`.
  bool omitDavHeader = false;

  /// Answers the listing's `status` for an item as this (by path).
  final Map<String, String> responseStatus = {};

  final Map<String, _Redirect> _redirects = {};

  /// Requests for [rel] (relative to the top) are redirected to [location],
  /// [times] times.
  void redirect(
    String rel,
    String location, {
    int status = 302,
    int times = 1 << 30,
  }) => _redirects[rel] = _Redirect(status, location, times);

  /// A folder asked for without its trailing slash is redirected to it (as
  /// Nextcloud does).
  bool redirectNoSlash = false;

  /// Called with the method and the decoded path before a request is answered
  /// (to change the server at that moment).
  void Function(String method, String path)? onRequest;

  final List<SeenDav> requests = [];
  final List<_Fault> _faults = [];

  // --- Building the tree ---------------------------------------------------

  FakeDavNode? lookup(String path) {
    var cur = nodes[0]!;
    for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
      FakeDavNode? next;
      // An exact name first (a server may hold `Y` and `y` side by side).
      for (final exact in [true, false]) {
        for (final n in nodes.values) {
          if (!n.gone &&
              n.parent == cur.id &&
              (exact
                  ? n.name == seg
                  : n.name.toLowerCase() == seg.toLowerCase())) {
            next = n;
            break;
          }
        }
        if (next != null) break;
      }
      if (next == null) return null;
      cur = next;
    }
    return cur;
  }

  FakeDavNode _parentOf(String path) {
    final i = path.lastIndexOf('/');
    if (i < 0) return nodes[0]!;
    final p = lookup(path.substring(0, i));
    if (p == null) throw StateError('no folder ${path.substring(0, i)}');
    return p;
  }

  @override
  String addFolder(String path) {
    final segs = path.split('/');
    var cur = nodes[0]!;
    for (var k = 0; k < segs.length; k++) {
      var next = lookup(segs.sublist(0, k + 1).join('/'));
      if (next == null) {
        next = FakeDavNode(_nextId++, cur.id, segs[k], folder: true);
        nodes[next.id] = next;
      }
      cur = next;
    }
    return idOf(path);
  }

  @override
  String addFile(String path, List<int> bytes) {
    final i = path.lastIndexOf('/');
    if (i >= 0) addFolder(path.substring(0, i));
    final f = FakeDavNode(
      _nextId++,
      _parentOf(path).id,
      path.substring(i + 1),
      bytes: bytes,
    );
    nodes[f.id] = f;
    return _idOfNode(f);
  }

  @override
  String replaceFile(
    String path,
    List<int> bytes, {
    bool newId = false,
    bool withName = true,
  }) {
    final f = lookup(path)!;
    if (!newId) {
      f.bytes = bytes;
      f.ver++;
      return _idOfNode(f);
    }
    f.gone = true;
    return addFile(path, bytes);
  }

  @override
  void delete(String path, {bool withName = false}) {
    void mark(FakeDavNode x) {
      x.gone = true;
      for (final c
          in nodes.values.where((c) => c.parent == x.id && !c.gone).toList()) {
        mark(c);
      }
    }

    mark(lookup(path)!);
  }

  @override
  void rename(String path, String newName) {
    final f = lookup(path)!;
    f.name = newName;
    f.ver++;
  }

  @override
  void move(String path, String newParentPath) {
    final f = lookup(path)!;
    f.parent = lookup(newParentPath)!.id;
    f.ver++;
  }

  /// A file's id for the current [ids] mode, or the path.
  @override
  String idOf(String path) {
    final n = lookup(path)!;
    if (ids == FakeDavIds.path) {
      final segs = _pathOf(n);
      return segs.isEmpty ? '/' : segs.map(Uri.encodeComponent).join('/');
    }
    return _idOfNode(n);
  }

  String _idOfNode(FakeDavNode n) {
    switch (ids) {
      case FakeDavIds.path:
        final segs = _pathOf(n);
        return segs.isEmpty ? '/' : segs.map(Uri.encodeComponent).join('/');
      case FakeDavIds.ocFileId:
        return _ocId(n);
      case FakeDavIds.resourceId:
      case FakeDavIds.both:
        return _resourceId(n);
    }
  }

  String _ocId(FakeDavNode n) => '${n.id.toString().padLeft(8, '0')}ocfake';

  String _resourceId(FakeDavNode n) =>
      'urn:uuid:00000000-0000-0000-0000-${n.id.toString().padLeft(12, '0')}';

  List<String> _pathOf(FakeDavNode n) {
    final out = <String>[];
    var cur = n;
    while (cur.parent != null) {
      out.insert(0, cur.name);
      cur = nodes[cur.parent]!;
    }
    return out;
  }

  String _etag(FakeDavNode n) {
    final t = '"e${n.id}-${n.ver}"';
    return weakEtags ? 'W/$t' : t;
  }

  /// The next [times] requests with [method] get [status] (with `Retry-After`
  /// when given), or the connection is cut when [lose].
  void fail(
    String method, {
    int status = 503,
    String? retryAfter,
    bool lose = false,
    int times = 1,
  }) {
    _faults.add(_Fault(method, status, retryAfter, lose, times));
  }

  @override
  int get requestCount => requests.length;

  @override
  set onAnyRequest(void Function()? f) =>
      onRequest = f == null ? null : (_, _) => f();

  @override
  int get downloadCount => requests.where((r) => r.method == 'GET').length;

  @override
  void loseNextListing() => fail('PROPFIND', lose: true);

  @override
  void failDownloads({
    int status = 503,
    String? retryAfter,
    bool lose = false,
    int times = 1,
  }) => fail(
    'GET',
    status: status,
    retryAfter: retryAfter,
    lose: lose,
    times: times,
  );

  // --- Serving ---------------------------------------------------------------

  Future<void> _serve() async {
    await for (final req in _server) {
      unawaited(_handle(req));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final decoded = Uri.decodeComponent(req.uri.path);
    requests.add(
      SeenDav(
        req.method,
        decoded,
        req.headers.value('authorization'),
        req.headers.value('accept-encoding'),
        req.headers.value('depth'),
      ),
    );
    onRequest?.call(req.method, decoded);
    final body = await utf8.decoder.bind(req).join();
    try {
      for (final f in _faults) {
        if (f.times > 0 && f.method == req.method) {
          f.times--;
          if (f.lose) {
            final s = await req.response.detachSocket(writeHeaders: false);
            s.destroy();
            return;
          }
          req.response.statusCode = f.status;
          if (f.retryAfter != null) {
            req.response.headers.set('Retry-After', f.retryAfter!);
          }
          await req.response.close();
          return;
        }
      }
      final expected = 'Basic ${base64.encode(utf8.encode('$user:$password'))}';
      if (req.headers.value('authorization') != expected) {
        req.response.statusCode = 401;
        req.response.headers.set('WWW-Authenticate', 'Basic realm="fake"');
        await req.response.close();
        return;
      }
      final rel = _relPath(req.uri.path);
      if (rel == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final redirect = _redirects[rel];
      if (redirect != null && redirect.times > 0) {
        redirect.times--;
        req.response.statusCode = redirect.status;
        req.response.headers.set('Location', redirect.location);
        await req.response.close();
        return;
      }
      if (redirectNoSlash &&
          req.method == 'PROPFIND' &&
          !req.uri.path.endsWith('/') &&
          (lookup(rel)?.folder ?? false)) {
        req.response.statusCode = 301;
        req.response.headers.set('Location', '${req.uri.path}/');
        await req.response.close();
        return;
      }
      switch (req.method) {
        case 'OPTIONS':
          if (!omitDavHeader) req.response.headers.set('DAV', '1, 2, 3');
          req.response.headers.set(
            'Allow',
            'OPTIONS, GET, HEAD, PROPFIND, PUT, DELETE, MOVE',
          );
          await req.response.close();
        case 'PROPFIND':
          await _propfind(req, rel, body);
        case 'GET':
          await _get(req, rel);
        default:
          req.response.statusCode = 405;
          await req.response.close();
      }
    } catch (e) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {
        // Already closed.
      }
    }
  }

  /// The path below the mount, decoded part by part, joined with `/`; null
  /// when the request isn't under the mount.
  String? _relPath(String rawPath) {
    final segs = rawPath.split('/').where((s) => s.isNotEmpty).toList();
    final m = mount.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length < m.length) return null;
    for (var i = 0; i < m.length; i++) {
      if (segs[i] != m[i]) return null;
    }
    return segs.skip(m.length).map(Uri.decodeComponent).join('/');
  }

  Future<void> _get(HttpRequest req, String rel) async {
    final n = lookup(rel);
    if (n == null || n.folder) {
      req.response.statusCode = n == null ? 404 : 405;
      await req.response.close();
      return;
    }
    var bytes = n.bytes;
    var etag = _etag(n);
    final accepts = (req.headers.value('accept-encoding') ?? '').contains(
      'gzip',
    );
    if (gzipEtags && accepts) {
      bytes = gzip.encode(bytes);
      etag = etag.replaceFirst(RegExp(r'"$'), '-gzip"');
      req.response.headers.set('Content-Encoding', 'gzip');
    }
    if (!omitGetEtag) {
      req.response.headers.set('ETag', getEtagOverride ?? etag);
    }
    final endless = endlessBody;
    if (endless != null) {
      // Chunked, no length: runs until the client hangs up.
      req.response.headers.chunkedTransferEncoding = true;
      try {
        while (true) {
          req.response.add(List.filled(endless, 0x41));
          await req.response.flush();
          endlessSent += endless;
          if (endlessSent > (64 << 20)) break;
          await Future<void>.delayed(Duration.zero);
        }
      } catch (_) {
        return;
      }
    }
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  /// Bytes an endless body has sent so far.
  int endlessSent = 0;

  String _href(List<String> segs, bool folder, List<String> requestSegs) {
    final enc = segs.map(Uri.encodeComponent).join('/');
    switch (hrefs) {
      case FakeDavHrefs.absolutePath:
        return '$mount/$enc${folder && segs.isNotEmpty ? '/' : ''}';
      case FakeDavHrefs.absoluteUrl:
        return '${hrefHost == null ? origin : origin.replace(host: hrefHost)}$mount/$enc${folder && segs.isNotEmpty ? '/' : ''}';
      case FakeDavHrefs.relative:
        // Relative to the requested folder, which ends with a slash.
        if (folder && _sameList(segs, requestSegs)) return './';
        final name = Uri.encodeComponent(segs.last);
        return folder ? '$name/' : name;
    }
  }

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _propfind(HttpRequest req, String rel, String body) async {
    final self = lookup(rel);
    if (self == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    if (emptyListings.contains(rel)) {
      final bytes = utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:"/>',
      );
      req.response.statusCode = 207;
      req.response.contentLength = bytes.length;
      req.response.add(bytes);
      await req.response.close();
      return;
    }
    final depth = req.headers.value('depth') ?? 'infinity';
    if (depth != '0' && depth != '1') {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }
    // The properties asked for: by `{ns}local`; everything when no body.
    final asked = <String>{};
    if (body.trim().isNotEmpty) {
      final root = parseXml(utf8.encode(body));
      for (final p in root.child(davNs, 'prop')?.children ?? <XmlNode>[]) {
        asked.add(p.qname);
      }
    }
    final p = switch (xml) {
      FakeDavXml.prefixD => 'd:',
      FakeDavXml.defaultNamespace => '',
      FakeDavXml.oddPrefix => 'ns0:',
    };
    final decl = switch (xml) {
      FakeDavXml.prefixD => 'xmlns:d="DAV:"',
      FakeDavXml.defaultNamespace => 'xmlns="DAV:"',
      FakeDavXml.oddPrefix => 'xmlns:ns0="DAV:"',
    };
    final out = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?>${injectAfterDeclaration ?? ''}'
      '<${p}multistatus $decl xmlns:oc="http://owncloud.org/ns" '
      'xmlns:x="http://example.org/x">',
    );
    if (padListing > 0) out.write('<!--${'x' * padListing}-->');
    final here = _pathOf(self);
    final items = [
      self,
      if (depth == '1')
        ...(nodes.values.where((n) => !n.gone && n.parent == self.id).toList()
          ..sort((a, b) => a.name.compareTo(b.name))),
    ];
    for (final n in items) {
      final segs = _pathOf(n);
      final path = segs.join('/');
      final found = <String>[];
      final missing = <String>[];
      void prop(String q, String? xmlText) {
        if (asked.isNotEmpty && !asked.contains(q)) return;
        if (xmlText == null) {
          missing.add(q);
        } else {
          found.add(xmlText);
        }
      }

      String el(String ns, String local) =>
          ns == davNs ? '$p$local' : 'oc:$local';
      final hideIds = noIdFor.contains(path);
      prop(
        '{$davNs}resourcetype',
        n.folder
            ? '<${p}resourcetype><${p}collection/></${p}resourcetype>'
            : '<${p}resourcetype/>',
      );
      prop(
        '{$davNs}getetag',
        omitEtags && !n.folder
            ? null
            : '<${p}getetag>${_etag(n).replaceAll('"', '&quot;')}</${p}getetag>',
      );
      prop(
        '{$davNs}getcontentlength',
        n.folder || omitLengths
            ? null
            : '<${p}getcontentlength>${n.bytes.length + listedLengthExtra}</${p}getcontentlength>',
      );
      prop(
        '{$davNs}getlastmodified',
        '<${p}getlastmodified>${HttpDate.format(DateTime.utc(2026, 1, 1).add(Duration(seconds: n.ver)))}</${p}getlastmodified>',
      );
      prop(
        '{$davNs}resource-id',
        (ids == FakeDavIds.resourceId || ids == FakeDavIds.both) && !hideIds
            ? '<${el(davNs, 'resource-id')}><${p}href>${_resourceId(n)}</${p}href></${el(davNs, 'resource-id')}>'
            : null,
      );
      prop(
        '{$ownCloudNs}fileid',
        (ids == FakeDavIds.ocFileId || ids == FakeDavIds.both) && !hideIds
            ? '<oc:fileid>${_ocId(n)}</oc:fileid>'
            : null,
      );
      final status = responseStatus[path];
      out.write(
        '<${p}response><${p}href>${_href(segs, n.folder, here)}</${p}href>',
      );
      if (status != null) {
        out.write('<${p}status>$status</${p}status>');
      } else {
        if (found.isNotEmpty) {
          out.write(
            '<${p}propstat><${p}prop>${found.join()}</${p}prop>'
            '<${p}status>HTTP/1.1 200 OK</${p}status></${p}propstat>',
          );
        }
        if (missing.isNotEmpty) {
          out.write(
            '<${p}propstat><${p}prop>'
            '${missing.map((q) => '<${_missingName(q, p)}/>').join()}'
            '</${p}prop><${p}status>HTTP/1.1 404 Not Found</${p}status>'
            '</${p}propstat>',
          );
        }
      }
      out.write('</${p}response>');
    }
    for (final h in strayHrefs) {
      out.write(
        '<${p}response><${p}href>$h</${p}href><${p}propstat><${p}prop>'
        '<${p}resourcetype/><${p}getetag>&quot;s&quot;</${p}getetag>'
        '<${p}getcontentlength>1</${p}getcontentlength></${p}prop>'
        '<${p}status>HTTP/1.1 200 OK</${p}status></${p}propstat></${p}response>',
      );
    }
    out.write('</${p}multistatus>');
    final bytes = utf8.encode(out.toString());
    req.response.statusCode = 207;
    req.response.headers.contentType = ContentType(
      'application',
      'xml',
      charset: 'utf-8',
    );
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  String _missingName(String q, String p) {
    final m = RegExp(r'^\{(.*)\}(.*)$').firstMatch(q)!;
    return m.group(1) == davNs ? '$p${m.group(2)}' : 'oc:${m.group(2)}';
  }
}
