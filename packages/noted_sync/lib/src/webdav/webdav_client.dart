// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../clock.dart';
import '../remote_driver.dart';
import '../remote_tree.dart' show isSafeName;
import '../request_gate.dart';
import '../types.dart';
import 'webdav_xml.dart';

/// What an item's id is: the server's `DAV:resource-id` (RFC 5842), Nextcloud's
/// `oc:fileid`, or the path below the root.
enum DavIdKind {
  resourceId('resource-id'),
  fileId('fileid'),
  path('path');

  const DavIdKind(this.wire);

  /// The name saved in `connection.json`.
  final String wire;

  static DavIdKind? parse(String? s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// A listing that can't be taken as complete (a response that failed, a file
/// with no version, a cap passed, an item with no id): nothing is applied.
class WebDavIncomplete extends RemoteException {
  WebDavIncomplete(super.message);
}

/// A weak comparison of two ETags (RFC 9110 section 8.8.3.2): a leading `W/`
/// is ignored on both sides. Enough to see a change, not to write.
bool etagsMatch(String? a, String? b) {
  if (a == null || b == null) return false;
  return stripWeak(a) == stripWeak(b);
}

/// [etag] without a leading `W/`.
String stripWeak(String etag) {
  final t = etag.trim();
  return t.startsWith('W/') || t.startsWith('w/') ? t.substring(2) : t;
}

/// One item the server listed.
class DavNode {
  DavNode({
    required this.segments,
    required this.url,
    required this.folder,
    required this.etag,
    required this.size,
    required this.resourceId,
    required this.fileId,
  });

  /// The path below the root, each part decoded on its own. Empty for the
  /// root. A part may hold `/` or other characters no name can have; the
  /// engine skips and lists such an item.
  final List<String> segments;

  /// Where the server said it is (resolved against the request).
  final Uri url;
  final bool folder;
  final String? etag;
  final int size;
  final String? resourceId;
  final String? fileId;

  String get name => segments.isEmpty ? '' : segments.last;

  /// The path as one string, the parts re-encoded: the same for the same
  /// item however the server spelled its address, and never ambiguous.
  String get pathId => segments.map(Uri.encodeComponent).join('/');

  /// The id of this item for [kind]; null when the server didn't give one.
  String? idFor(DavIdKind kind) => switch (kind) {
    DavIdKind.resourceId => resourceId,
    DavIdKind.fileId => fileId,
    DavIdKind.path => segments.isEmpty ? '/' : pathId,
  };
}

/// One folder, listed one level deep.
class DavFolder {
  DavFolder(this.self, this.children, this.issues);
  final DavNode? self;
  final List<DavNode> children;
  final List<SyncIssue> issues;
}

/// A whole tree: the root first.
class DavListing {
  DavListing(this.nodes, this.issues);
  final List<DavNode> nodes;
  final List<SyncIssue> issues;
}

/// WebDAV (RFC 4918), the few calls the pull needs: `OPTIONS`, `PROPFIND`
/// and `GET`. Never anything that writes.
///
/// - The root must be https (loopback http with [allowLoopbackHttp], for
///   tests). A certificate that isn't trusted is refused, never skipped.
/// - Basic auth, with the app password the caller gives, goes only to the
///   root's origin. Redirects are followed by hand, same origin only, at most
///   [maxRedirects] hops; another origin is refused.
/// - Every request sends `Accept-Encoding: identity`, so lengths and ETags
///   describe the bytes received.
/// - At most [maxInFlight] requests at once. On 429 and 503 every request
///   waits for `Retry-After`; without it, 2 s doubling up to 5 min.
/// - A 401 is [RemoteUnauthorized] (signed out).
/// - Caps (N11): a response over [maxResponseBytes], a folder deeper than
///   [maxDepth], more than [maxFolders] folders or [maxItems] items make the
///   listing incomplete ([WebDavIncomplete]).
class WebDavClient {
  WebDavClient({
    required this.root,
    required String user,
    required String password,
    http.Client? client,
    Clock? clock,
    this.allowLoopbackHttp = false,
    this.maxInFlight = 4,
    this.maxRedirects = 5,
    this.maxThrottleRetries = 8,
    this.timeout = const Duration(seconds: 60),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.maxDepth = 32,
    this.maxFolders = 10000,
    this.maxItems = 100000,
  }) : _auth = 'Basic ${base64.encode(utf8.encode('$user:$password'))}',
       _client = client ?? http.Client(),
       _gate = RequestGate(
         clock: clock ?? const SystemClock(),
         maxInFlight: maxInFlight,
       ) {
    if (allowLoopbackHttp) {
      // Debug and test builds only: asserts are off in a release build, where
      // the flag is refused, so production can never switch it on.
      var debug = false;
      assert(debug = true);
      if (!debug) {
        throw RemoteRefused('Loopback http is for tests only');
      }
    }
    if (root.userInfo.isNotEmpty) {
      throw RemoteRefused('The address must not hold a user name');
    }
    if (!_allowed(root)) {
      throw RemoteRefused('WebDAV needs an https address');
    }
    try {
      _rootSegments = _decodedSegments(root.path);
    } on FormatException {
      throw RemoteRefused('The address is not valid');
    }
  }

  /// The chosen folder (or the account's top folder, for choosing one).
  final Uri root;
  final bool allowLoopbackHttp;
  final int maxInFlight;
  final int maxRedirects;
  final int maxThrottleRetries;
  final Duration timeout;
  final int maxResponseBytes;
  final int maxDepth;
  final int maxFolders;
  final int maxItems;

  final String _auth;
  final http.Client _client;
  final RequestGate _gate;
  late final List<String> _rootSegments;

  void close() => _client.close();

  // --- Calls ---------------------------------------------------------------

  /// `OPTIONS` on the root: the server must list class `1` in `DAV:`.
  Future<void> checkDav() => _call<void>(
    'OPTIONS',
    root,
    onResponse: (r, at) async {
      await _drain(r);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw _error(r.statusCode);
      }
      final dav = r.headers['dav'];
      final classes = (dav ?? '').split(',').map((s) => s.trim());
      if (!classes.contains('1')) {
        throw RemoteNotSupported('This address is not a WebDAV server');
      }
    },
  );

  /// One folder's own properties and its children (`PROPFIND`, `Depth: 1`).
  /// With [connecting], a file with no ETag is [RemoteNotSupported] rather
  /// than an incomplete listing.
  Future<DavFolder> listFolder(
    Uri url, {
    Set<DavIdKind> idProps = const {DavIdKind.resourceId, DavIdKind.fileId},
    bool connecting = false,
    bool hadChildren = false,
  }) async {
    final (at, responses) = await _propfind(url, 1, idProps);
    return _folderFrom(at, responses, connecting, hadChildren: hadChildren);
  }

  /// One item's own properties (`Depth: 0`).
  Future<DavNode> stat(
    Uri url, {
    Set<DavIdKind> idProps = const {DavIdKind.resourceId, DavIdKind.fileId},
  }) async {
    final (at, responses) = await _propfind(url, 0, idProps);
    final folder = _folderFrom(at, responses, false, selfOnly: true);
    final self = folder.self;
    if (self == null) {
      throw WebDavIncomplete('The server did not describe the item');
    }
    return self;
  }

  /// Every item below the root, folder by folder. Complete or an exception.
  /// [populated] holds the re-encoded paths ([DavNode.pathId]; the root is
  /// empty) of folders that held children before: a folder whose every child
  /// then comes back skipped makes the listing incomplete.
  Future<DavListing> list({
    Set<DavIdKind> idProps = const {DavIdKind.resourceId, DavIdKind.fileId},
    bool connecting = false,
    Set<String> populated = const {},
  }) async {
    final nodes = <DavNode>[];
    final issues = <SyncIssue>[];
    final seen = <String>{};
    final queue = <(Uri, int)>[(root, 0)];
    for (var q = 0; q < queue.length; q++) {
      if (q >= maxFolders) {
        throw WebDavIncomplete(
          'Too large to sync: more than $maxFolders folders',
        );
      }
      final (url, depth) = queue[q];
      final DavFolder f;
      try {
        f = await listFolder(
          url,
          idProps: idProps,
          connecting: connecting,
          hadChildren: populated.contains(_idPath(url)),
        );
      } on RemoteNotFound {
        if (q == 0) rethrow;
        throw WebDavIncomplete('A folder went away during the listing');
      }
      issues.addAll(f.issues);
      if (q == 0) {
        final self = f.self;
        if (self == null) {
          throw WebDavIncomplete('The server did not describe the folder');
        }
        if (!self.folder) throw RemoteNotFound('This is not a folder');
        nodes.add(self);
        seen.add('');
      } else {
        // Every folder must describe itself (its own address, a 2xx status, a
        // collection): an empty reply is not an empty folder.
        final self = f.self;
        if (self == null || !self.folder) {
          throw WebDavIncomplete('The server did not describe a folder');
        }
      }
      for (final c in f.children) {
        if (!seen.add(c.pathId)) continue;
        if (nodes.length >= maxItems) {
          throw WebDavIncomplete(
            'Too large to sync: more than $maxItems items',
          );
        }
        nodes.add(c);
        if (c.folder && isSafeName(c.name)) {
          if (depth + 1 > maxDepth) {
            throw WebDavIncomplete(
              'Too large to sync: folders deeper than $maxDepth',
            );
          }
          queue.add((c.url, depth + 1));
        }
      }
    }
    return DavListing(nodes, issues);
  }

  /// Downloads [url] into [dest] (written fresh), then checks it is still the
  /// version listed: the response's `ETag` weakly equals [etag], and the
  /// length is [size]. With no `ETag` on the response, a `PROPFIND Depth: 0`
  /// after it must show the same `getetag`. Anything else is [RemoteChanged].
  Future<void> download(
    Uri url, {
    required String etag,
    required int size,
    required File dest,
  }) async {
    final (sentEtag, at) = await _call<(String?, Uri)>(
      'GET',
      url,
      onResponse: (r, at) async {
        if (r.statusCode != 200) {
          await _drain(r);
          throw _error(r.statusCode);
        }
        final got = r.headers['etag'];
        if (got != null && !etagsMatch(got, etag)) {
          await _abandon(r);
          throw RemoteChanged('The version moved during the download');
        }
        final length = r.contentLength;
        if (length != null && length != size) {
          await _abandon(r);
          throw RemoteSizeMismatch('The size differs from the listing');
        }
        var written = 0;
        var over = false;
        final sink = dest.openWrite();
        try {
          await for (final c in r.stream.timeout(timeout)) {
            written += c.length;
            if (written > size) {
              // Longer than listed: stop reading now (leaving the loop cancels
              // the stream and closes the connection).
              over = true;
              break;
            }
            sink.add(c);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (over || written != size) {
          try {
            if (dest.existsSync()) dest.deleteSync();
          } on FileSystemException {
            // The engine removes its temp too.
          }
          throw RemoteSizeMismatch('The size differs from the listing');
        }
        return (got, at);
      },
    );
    if (sentEtag != null) return;
    final DavNode now;
    try {
      now = await stat(at, idProps: const {});
    } on RemoteNotFound {
      throw RemoteChanged('The file went during the download');
    }
    if (!etagsMatch(now.etag, etag)) {
      throw RemoteChanged('The version moved during the download');
    }
  }

  // --- Plumbing ------------------------------------------------------------

  bool _allowed(Uri u) {
    if (u.scheme == 'https') return u.host.isNotEmpty;
    if (u.scheme == 'http' && allowLoopbackHttp) {
      final h = u.host;
      return h == 'localhost' ||
          (InternetAddress.tryParse(h)?.isLoopback ?? false);
    }
    return false;
  }

  bool _sameOrigin(Uri u) =>
      u.hasScheme &&
      u.scheme == root.scheme &&
      u.host == root.host &&
      u.port == root.port;

  static List<String> _decodedSegments(String path) => [
    for (final s in path.split('/'))
      if (s.isNotEmpty) Uri.decodeComponent(s),
  ];

  /// [href] resolved against [at], or null when it isn't an address.
  Uri? _resolve(Uri at, String href) {
    try {
      return at.resolve(href);
    } on FormatException {
      return null;
    }
  }

  static const String _propfindHead =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
      '<d:resourcetype/><d:getetag/><d:getcontentlength/>'
      '<d:getlastmodified/>';

  Future<(Uri, List<DavResponse>)> _propfind(
    Uri url,
    int depth,
    Set<DavIdKind> idProps,
  ) {
    final body = StringBuffer(_propfindHead);
    if (idProps.contains(DavIdKind.resourceId)) body.write('<d:resource-id/>');
    if (idProps.contains(DavIdKind.fileId)) body.write('<oc:fileid/>');
    body.write('</d:prop></d:propfind>');
    return _call<(Uri, List<DavResponse>)>(
      'PROPFIND',
      url,
      headers: {
        'Depth': '$depth',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: utf8.encode(body.toString()),
      onResponse: (r, at) async {
        final bytes = await _bytes(r);
        if (r.statusCode != 207) throw _error(r.statusCode);
        try {
          return (at, parseMultistatus(bytes));
        } on XmlParseException {
          throw WebDavIncomplete(
            'The server sent a listing that can\'t be read',
          );
        }
      },
    );
  }

  /// The children of the folder [at] listed in [responses]. Anything that
  /// can't be trusted throws [WebDavIncomplete]; an address outside the root
  /// is skipped and listed.
  DavFolder _folderFrom(
    Uri at,
    List<DavResponse> responses,
    bool connecting, {
    bool hadChildren = false,
    bool selfOnly = false,
  }) {
    final issues = <SyncIssue>[];
    final base = _relative(at);
    if (base == null) {
      throw WebDavIncomplete('The server answered from another address');
    }
    DavNode? self;
    final kids = <DavNode>[];
    var skipped = 0;
    for (final r in responses) {
      final u = _resolve(at, r.hrefs.first);
      if (u == null) {
        skipped++;
        issues.add(
          const SyncIssue('', 'The server sent an address that can\'t be read'),
        );
        continue;
      }
      List<String>? rel;
      if (_sameOrigin(u) && u.userInfo.isEmpty) {
        try {
          rel = _relative(u);
        } on FormatException {
          rel = null;
        }
      }
      if (rel == null) {
        skipped++;
        issues.add(
          SyncIssue(_shown(base), 'An address outside the folder was skipped'),
        );
        continue;
      }
      final isSelf = _sameSegments(rel, base);
      final isChild =
          rel.length == base.length + 1 &&
          _sameSegments(rel, base, rel.length - 1);
      if (!isSelf && !isChild) {
        skipped++;
        issues.add(
          SyncIssue(_shown(rel), 'An address outside the folder was skipped'),
        );
        continue;
      }
      if (!isSelf && selfOnly) continue;
      if (!r.ok) {
        throw WebDavIncomplete('The server could not describe an item');
      }
      final node = _nodeFrom(r, u, rel, connecting);
      if (isSelf) {
        self ??= node;
      } else {
        kids.add(node);
      }
    }
    // A listing whose every entry was skipped (the server spells its own
    // address another way) says nothing about the folder: not "empty".
    // Only when the folder did hold something before, or the server did not
    // even describe the folder itself: an empty folder with one stray address
    // is just that.
    if (!selfOnly &&
        skipped > 0 &&
        kids.isEmpty &&
        (self == null || hadChildren)) {
      throw WebDavIncomplete(
        'The server listed only addresses outside the folder',
      );
    }
    return DavFolder(self, kids, issues);
  }

  /// The re-encoded path of [url] below the root, as [DavNode.pathId] gives it.
  String _idPath(Uri url) {
    try {
      return (_relative(url) ?? const <String>[])
          .map(Uri.encodeComponent)
          .join('/');
    } on FormatException {
      return '';
    }
  }

  static bool _sameSegments(List<String> a, List<String> b, [int? n]) {
    final len = n ?? a.length;
    if (a.length < len ||
        b.length < len ||
        (n == null && a.length != b.length)) {
      return false;
    }
    for (var i = 0; i < len; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _shown(List<String> rel) => rel.join('/');

  /// The decoded parts of [u]'s path below the root; null when it isn't below
  /// the root.
  List<String>? _relative(Uri u) {
    final List<String> segs;
    try {
      segs = _decodedSegments(u.path);
    } on FormatException {
      return null;
    }
    if (segs.length < _rootSegments.length) return null;
    for (var i = 0; i < _rootSegments.length; i++) {
      if (segs[i] != _rootSegments[i]) return null;
    }
    return segs.sublist(_rootSegments.length);
  }

  DavNode _nodeFrom(DavResponse r, Uri url, List<String> rel, bool connecting) {
    final type = r.prop(davNs, 'resourcetype');
    if (type == null) {
      throw WebDavIncomplete('The server did not say what an item is');
    }
    final folder = type.childNames.contains('{$davNs}collection');
    String? etag;
    var size = 0;
    if (!folder) {
      etag = r.prop(davNs, 'getetag')?.text;
      if (etag != null && etag.isEmpty) etag = null;
      if (etag == null) {
        if (connecting) {
          throw RemoteNotSupported('This server doesn\'t report file versions');
        }
        throw WebDavIncomplete('The server gave a file no version');
      }
      final n = int.tryParse(r.prop(davNs, 'getcontentlength')?.text ?? '');
      if (n == null || n < 0) {
        throw WebDavIncomplete('The server gave a file no size');
      }
      size = n;
    }
    String? id(String ns, String local) {
      final t = r.prop(ns, local)?.text;
      return t == null || t.isEmpty ? null : t;
    }

    return DavNode(
      segments: rel,
      url: url,
      folder: folder,
      etag: etag,
      size: size,
      resourceId: id(davNs, 'resource-id'),
      fileId: id(ownCloudNs, 'fileid'),
    );
  }

  Future<List<int>> _bytes(http.StreamedResponse r) async {
    final length = r.contentLength;
    if (length != null && length > maxResponseBytes) {
      await _abandon(r);
      throw WebDavIncomplete('Too large to sync: a listing is too big');
    }
    final b = BytesBuilder(copy: false);
    await for (final c in r.stream.timeout(timeout)) {
      b.add(c);
      if (b.length > maxResponseBytes) {
        throw WebDavIncomplete('Too large to sync: a listing is too big');
      }
    }
    return b.takeBytes();
  }

  Future<void> _drain(http.StreamedResponse r) async {
    try {
      await r.stream.drain<void>().timeout(timeout);
    } catch (_) {
      // Only draining.
    }
  }

  /// Stops reading a response that is no longer wanted (the connection goes).
  Future<void> _abandon(http.StreamedResponse r) async {
    try {
      await r.stream.listen((_) {}).cancel();
    } catch (_) {
      // Only abandoning.
    }
  }

  RemoteException _error(int status) {
    if (status == 404) return RemoteNotFound('Not found');
    if (status == 401) return RemoteUnauthorized('WebDAV refused the password');
    if (status == 405 || status == 501) {
      return RemoteNotSupported(
        'The server does not support this',
        statusCode: status,
      );
    }
    return RemoteException('HTTP $status', statusCode: status);
  }

  /// One request with its redirects: followed by hand, same origin only.
  Future<T> _call<T>(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    required Future<T> Function(http.StreamedResponse r, Uri at) onResponse,
  }) async {
    var uri = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final at = uri;
      Uri? next;
      T? value;
      var done = false;
      await _once(method, at, headers, body, (r) async {
        final s = r.statusCode;
        if (s == 301 || s == 302 || s == 303 || s == 307 || s == 308) {
          final loc = r.headers['location'];
          await _drain(r);
          if (loc == null) throw RemoteException('Redirect without a Location');
          next = _resolve(at, loc);
          if (next == null) {
            throw RemoteRefused('A redirect was not a valid address');
          }
          return;
        }
        value = await onResponse(r, at);
        done = true;
      });
      if (done) return value as T;
      final n = next!;
      if (!_sameOrigin(n) || !_allowed(n) || n.userInfo.isNotEmpty) {
        throw RemoteRefused('A redirect to another address was refused');
      }
      uri = n;
    }
    throw RemoteRefused('Too many redirects');
  }

  /// One request through the gate: waits out a pause, takes a slot, retries
  /// after 429 and 503, and turns every failure into a [RemoteException].
  Future<void> _once(
    String method,
    Uri uri,
    Map<String, String>? headers,
    List<int>? body,
    Future<void> Function(http.StreamedResponse r) onResponse,
  ) async {
    for (var attempt = 0; ; attempt++) {
      await _gate.enter();
      try {
        final req = http.Request(method, uri)
          ..followRedirects = false
          ..headers['Authorization'] = _auth
          ..headers['Accept-Encoding'] = 'identity';
        if (headers != null) req.headers.addAll(headers);
        if (body != null) req.bodyBytes = body;
        final r = await _client.send(req).timeout(timeout);
        if (r.statusCode == 429 || r.statusCode == 503) {
          await _drain(r);
          if (attempt >= maxThrottleRetries) {
            throw RemoteThrottled('Still throttled after $attempt retries');
          }
          _gate.pause(_gate.retryAfter(r.headers['retry-after']));
          continue;
        }
        if (r.statusCode == 401) {
          await _drain(r);
          throw _error(401);
        }
        _gate.reset();
        await onResponse(r);
        return;
      } on RemoteException {
        rethrow;
      } on FileSystemException {
        rethrow;
      } on TlsException {
        throw RemoteRefused('The server\'s certificate is not trusted');
      } on Exception catch (e) {
        // A client or socket error carries the address it was talking to.
        if (e.toString().contains('HandshakeException') ||
            e.toString().contains('CERTIFICATE_VERIFY_FAILED')) {
          throw RemoteRefused('The server\'s certificate is not trusted');
        }
        throw RemoteTransport(e);
      } finally {
        _gate.leave();
      }
    }
  }
}
