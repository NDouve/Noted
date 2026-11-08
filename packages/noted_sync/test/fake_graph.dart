// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core.dart';

/// A request the fake server saw.
class SeenRequest {
  SeenRequest(this.path, this.query, this.authorization, this.at);
  final String path;
  final Map<String, String> query;
  final String? authorization;
  final int at;
  @override
  String toString() =>
      '$path ${query.isEmpty ? '' : query} auth=${authorization != null}';
}

class FakeItem {
  FakeItem(
    this.id,
    this.parent,
    this.name, {
    this.folder = false,
    List<int>? bytes,
  }) : bytes = bytes ?? const [];
  String id;
  String? parent;
  String name;
  bool folder;

  /// `remoteItem` (a shortcut) or `package` (a OneNote notebook), or null.
  String? facet;
  List<int> bytes;
  int ver = 1;
  bool gone = false;
}

class _Fault {
  _Fault(this.match, this.status, this.retryAfter, this.lose, this.times);
  final bool Function(String path) match;
  final int status;
  final String? retryAfter;
  final bool lose;
  int times;
}

/// An in-process stand-in for the parts of Microsoft Graph the pull uses:
/// items, children, delta pages and tokens, downloads by redirect, and the
/// faults a real service shows. Paths in its API are relative to the drive
/// root, so a test's "OneDrive folder" is e.g. `Noted`.
class FakeGraph {
  FakeGraph._(this._server);

  static const String driveId = 'drv1';
  static const String driveRootId = 'DRIVEROOT';

  static Future<FakeGraph> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final g = FakeGraph._(s);
    g.items[driveRootId] = FakeItem(driveRootId, null, 'root', folder: true);
    unawaited(g._serve());
    return g;
  }

  final HttpServer _server;
  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');
  Future<void> close() => _server.close(force: true);

  final Map<String, FakeItem> items = {};
  final List<Map<String, dynamic>> _log = [];
  int _nextId = 1;
  int _clock = 0;

  /// The token the API accepts; others get 401.
  String expectedToken = 'tok';

  // Behaviour switches.
  bool folderDeltaSupported = true;
  bool omitRootInDelta = false;
  bool includeHashes = true;
  bool childrenFirst = false;
  bool duplicateItems = false;

  /// Delta links as `delta(token='...')` instead of `delta?token=...`.
  bool functionLinks = false;

  /// Business accounts leave cTag out of created and modified items.
  bool omitCTag = false;

  /// Items (by id) listed with no `parentReference`.
  final Set<String> noParentRef = {};

  /// A 404 for the folder form of delta (the item itself exists).
  bool folderDeltaNotFound = false;

  /// Downloads return altered bytes (the hash then doesn't match).
  bool corruptContent = false;
  int pageSize = 100;
  int childrenPageSize = 100;

  /// Where `/content` redirects to: null is this server's own storage path.
  String? redirectTo;

  /// Extra redirects before the content (to test the hop limit).
  int extraRedirects = 0;

  final List<SeenRequest> requests = [];
  int _epoch = 0;
  bool _expireUpload = false;
  final List<_Fault> _faults = [];

  /// Called with each request path before it is answered (for tests that
  /// change the server or take a snapshot at a moment).
  void Function(String path)? onRequest;

  /// Awaited before an API request is answered (to hold requests open).
  Future<void> Function(String path)? slow;

  /// When set, a delta page's next link and a 410's Location point here.
  String? foreignLink;

  // --- Building the drive --------------------------------------------------

  String _newId() => 'ID${_nextId++}';

  FakeItem? lookup(String path) {
    var cur = items[driveRootId]!;
    if (path.isEmpty) return cur;
    for (final seg in path.split('/')) {
      FakeItem? next;
      for (final i in items.values) {
        if (!i.gone &&
            i.parent == cur.id &&
            i.name.toLowerCase() == seg.toLowerCase()) {
          next = i;
          break;
        }
      }
      if (next == null) return null;
      cur = next;
    }
    return cur;
  }

  String idOf(String path) => lookup(path)!.id;

  FakeItem _parentOf(String path) {
    final i = path.lastIndexOf('/');
    if (i < 0) return items[driveRootId]!;
    final p = lookup(path.substring(0, i));
    if (p == null) throw StateError('no folder ${path.substring(0, i)}');
    return p;
  }

  String addFolder(String path) {
    final segs = path.split('/');
    var cur = items[driveRootId]!;
    for (var k = 0; k < segs.length; k++) {
      final s = segs[k];
      var next = lookup(segs.sublist(0, k + 1).join('/'));
      if (next == null) {
        next = FakeItem(_newId(), cur.id, s, folder: true);
        items[next.id] = next;
        _record(next);
      }
      cur = next;
    }
    return cur.id;
  }

  String addFile(String path, List<int> bytes, {String? id}) {
    final i = path.lastIndexOf('/');
    if (i >= 0) addFolder(path.substring(0, i));
    final f = FakeItem(
      id ?? _newId(),
      _parentOf(path).id,
      path.substring(i + 1),
      bytes: bytes,
    );
    items[f.id] = f;
    _record(f);
    return f.id;
  }

  /// Changes a file's content; [newId] is what a delete plus create by a
  /// sync client looks like.
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
      _record(f);
      return f.id;
    }
    f.gone = true;
    _recordDeleted(f, withName: withName);
    return addFile(path, bytes);
  }

  /// Deletes an item. A folder's descendants are not reported (as Graph
  /// does), unless [reportChildren].
  void delete(
    String path, {
    bool withName = false,
    bool reportChildren = false,
  }) {
    final f = lookup(path)!;
    void mark(FakeItem x, bool report) {
      x.gone = true;
      if (report) _recordDeleted(x, withName: withName);
      for (final c
          in items.values.where((c) => c.parent == x.id && !c.gone).toList()) {
        mark(c, reportChildren);
      }
    }

    mark(f, true);
  }

  void rename(String path, String newName) {
    final f = lookup(path)!;
    f.name = newName;
    f.ver++;
    _record(f);
  }

  void move(String path, String newParentPath) {
    final f = lookup(path)!;
    f.parent = lookup(newParentPath)!.id;
    f.ver++;
    _record(f);
  }

  /// Every delta token handed out so far becomes invalid (410).
  void expireTokens({bool uploadDifferences = false}) {
    _epoch++;
    _expireUpload = uploadDifferences;
  }

  /// The next [times] requests whose path contains [part] get [status] (with
  /// `Retry-After` when given), or the connection is cut when [lose].
  void fail(
    String part, {
    int status = 503,
    String? retryAfter,
    bool lose = false,
    int times = 1,
  }) {
    _faults.add(
      _Fault((p) => p.contains(part), status, retryAfter, lose, times),
    );
  }

  Map<String, dynamic> _json(FakeItem i, {bool? hashes}) => {
    'id': i.id,
    'name': i.name,
    'size': i.folder ? 0 : i.bytes.length,
    if (!omitCTag) 'cTag': 'c${i.id}.${i.ver}',
    'eTag': 'e${i.id}.${i.ver}',
    if (!noParentRef.contains(i.id))
      'parentReference': {'id': i.parent, 'driveId': driveId},
    if (i.id == driveRootId) 'root': <String, dynamic>{},
    if (i.facet == 'remoteItem') 'remoteItem': {'id': 'elsewhere'},
    if (i.facet == 'package') 'package': {'type': 'oneNote'},
    if (i.folder) 'folder': {'childCount': 0},
    if (!i.folder && i.facet == null)
      'file': {
        'hashes': {
          if (hashes ?? includeHashes)
            'quickXorHash': QuickXorHash.ofBytes(i.bytes),
        },
      },
  };

  void _record(FakeItem i) => _log.add(_json(i));

  /// Adds a shortcut (`remoteItem`) or a `package` item.
  String addSpecial(String path, String facet) {
    final i = path.lastIndexOf('/');
    if (i >= 0) addFolder(path.substring(0, i));
    final f = FakeItem(_newId(), _parentOf(path).id, path.substring(i + 1))
      ..facet = facet;
    items[f.id] = f;
    _record(f);
    return f.id;
  }

  /// Logs the item again as it is now (an update with no changes), e.g. after
  /// [noParentRef] was set for it.
  void touch(String path) => _record(lookup(path)!);

  void _recordDeleted(FakeItem i, {required bool withName}) {
    _log.add({
      'id': i.id,
      if (withName) 'name': i.name,
      'parentReference': {'id': i.parent, 'driveId': driveId},
      'deleted': <String, dynamic>{},
    });
  }

  /// Adds a raw entry to the delta log (for odd shapes).
  void logRaw(Map<String, dynamic> entry) => _log.add(entry);

  // --- Serving -------------------------------------------------------------

  Future<void> _serve() async {
    await for (final req in _server) {
      unawaited(_handle(req));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    requests.add(
      SeenRequest(
        path,
        req.uri.queryParameters,
        req.headers.value('authorization'),
        ++_clock,
      ),
    );
    onRequest?.call(path);
    if (slow != null && !path.startsWith('/storage/')) await slow!(path);
    try {
      for (final f in _faults) {
        if (f.times > 0 && f.match(path)) {
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
      if (path.startsWith('/storage/')) {
        await _storage(req);
      } else if (path.startsWith('/redirect/')) {
        final n = int.parse(
          path.substring('/redirect/'.length).split('/').first,
        );
        final id = path.split('/').last;
        req.response.statusCode = 302;
        req.response.headers.set(
          'Location',
          n > 1 ? '/redirect/${n - 1}/$id' : '/storage/$id/${items[id]!.ver}',
        );
        await req.response.close();
      } else {
        await _api(req);
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

  Future<void> _storage(HttpRequest req) async {
    if (req.headers.value('authorization') != null) {
      req.response.statusCode = 400;
      await _body(req, {
        'error': {
          'code': 'invalidAuthenticationToken',
          'message': 'no Authorization here',
        },
      });
      return;
    }
    final id = req.uri.pathSegments[1];
    final it = items[id];
    if (it == null || it.gone) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.add(
      corruptContent && it.bytes.isNotEmpty
          ? [it.bytes.first ^ 1, ...it.bytes.skip(1)]
          : it.bytes,
    );
    await req.response.close();
  }

  Future<void> _body(HttpRequest req, Object json, {int? status}) async {
    if (status != null) req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(json));
    await req.response.close();
  }

  Future<void> _error(
    HttpRequest req,
    int status,
    String code, {
    String? inner,
    Map<String, String>? headers,
  }) async {
    req.response.statusCode = status;
    headers?.forEach(req.response.headers.set);
    await _body(req, {
      'error': {
        'code': code,
        'message': code,
        if (inner != null) 'innerError': {'code': inner},
      },
    });
  }

  Future<void> _api(HttpRequest req) async {
    if (req.headers.value('authorization') != 'Bearer $expectedToken') {
      await _error(req, 401, 'InvalidAuthenticationToken');
      return;
    }
    final seg = req.uri.pathSegments;
    // v1.0 / drives|me / <d>|drive / ...
    if (seg.length < 3 || seg[0] != 'v1.0') {
      await _error(req, 404, 'itemNotFound');
      return;
    }
    List<String> rest;
    if (seg[1] == 'me' && seg[2] == 'drive') {
      rest = seg.sublist(3);
    } else if (seg[1] == 'drives' && seg.length >= 3) {
      rest = seg.sublist(3);
    } else {
      await _error(req, 404, 'itemNotFound');
      return;
    }
    String scopeId;
    String tail;
    if (rest.isNotEmpty && rest[0] == 'root') {
      scopeId = driveRootId;
      tail = rest.length > 1 ? rest[1] : '';
    } else if (rest.length >= 2 && rest[0] == 'items') {
      scopeId = rest[1];
      tail = rest.length > 2 ? rest[2] : '';
    } else {
      await _error(req, 404, 'itemNotFound');
      return;
    }
    final it = items[scopeId];
    if (it == null || it.gone) {
      await _error(req, 404, 'itemNotFound');
      return;
    }
    String? functionToken;
    final fn = RegExp(r"^delta\(token='(.*)'\)$").firstMatch(tail);
    if (fn != null) {
      functionToken = fn.group(1);
      tail = 'delta';
    }
    switch (tail) {
      case '':
        await _body(req, _json(it));
      case 'children':
        await _children(req, it);
      case 'delta':
        await _delta(
          req,
          it,
          isDriveRoot: rest[0] == 'root',
          functionToken: functionToken,
        );
      case 'content':
        if (it.folder) {
          await _error(req, 400, 'invalidRequest');
        } else {
          req.response.statusCode = 302;
          final target =
              redirectTo ??
              (extraRedirects > 0
                  ? '/redirect/$extraRedirects/${it.id}'
                  : '/storage/${it.id}/${it.ver}');
          req.response.headers.set('Location', target);
          await req.response.close();
        }
      default:
        await _error(req, 404, 'itemNotFound');
    }
  }

  Future<void> _children(HttpRequest req, FakeItem it) async {
    final kids =
        items.values.where((c) => !c.gone && c.parent == it.id).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final skip = int.tryParse(req.uri.queryParameters['skip'] ?? '') ?? 0;
    final page = kids.skip(skip).take(childrenPageSize).toList();
    final more = skip + page.length < kids.length;
    await _body(req, {
      'value': [for (final k in page) _json(k)],
      if (more)
        '@odata.nextLink': origin
            .replace(
              path: req.uri.path,
              queryParameters: {
                ...req.uri.queryParameters,
                'skip': '${skip + page.length}',
              },
            )
            .toString(),
    });
  }

  bool _under(FakeItem i, String scopeId) {
    var cur = i;
    var guard = 0;
    while (guard++ < 100) {
      if (cur.id == scopeId) return true;
      final p = cur.parent == null ? null : items[cur.parent];
      if (p == null) return false;
      cur = p;
    }
    return false;
  }

  Future<void> _delta(
    HttpRequest req,
    FakeItem scope, {
    required bool isDriveRoot,
    String? functionToken,
  }) async {
    if (!isDriveRoot && folderDeltaNotFound) {
      await _error(req, 404, 'itemNotFound');
      return;
    }
    if (!isDriveRoot && !folderDeltaSupported) {
      await _error(req, 400, 'notSupported', inner: 'notSupported');
      return;
    }
    final enc = functionToken ?? req.uri.queryParameters['token'];
    final q = enc == null
        ? <String, String>{}
        : (jsonDecode(utf8.decode(base64Url.decode(enc))) as Map)
              .cast<String, String>();
    final t = q['t'];
    final basePath = req.uri.path.substring(
      0,
      req.uri.path.indexOf('/delta') + '/delta'.length,
    );
    int? tokenN;
    if (t != null && t != 'full') {
      final parts = t.split('.');
      tokenN = int.parse(parts[0]);
      if (int.parse(parts[1]) != _epoch) {
        final restart = origin
            .replace(path: basePath, queryParameters: null)
            .toString();
        await _error(
          req,
          410,
          'resyncRequired',
          inner: _expireUpload
              ? 'resyncChangesUploadDifferences'
              : 'resyncChangesApplyDifferences',
          headers: {'Location': foreignLink ?? restart},
        );
        return;
      }
    }
    final end = int.tryParse(q['e'] ?? '') ?? _log.length;
    final List<Map<String, dynamic>> all;
    if (t == null || t == 'full') {
      var live = items.values
          .where((i) => !i.gone && i.id != driveRootId)
          .toList();
      if (!isDriveRoot) {
        live = live.where((i) => _under(i, scope.id)).toList();
      }
      if (isDriveRoot) live.add(items[driveRootId]!);
      if (omitRootInDelta) live.removeWhere((i) => i.id == scope.id);
      int depth(FakeItem i) {
        var d = 0;
        var c = i;
        while (c.parent != null && items[c.parent] != null) {
          c = items[c.parent]!;
          d++;
        }
        return d;
      }

      live.sort(
        (a, b) => childrenFirst
            ? depth(b).compareTo(depth(a))
            : depth(a).compareTo(depth(b)),
      );
      all = [for (final i in live) _json(i)];
      if (duplicateItems && live.isNotEmpty) all.add(_json(live.last));
    } else {
      final from = tokenN!;
      all = [];
      for (final e in _log.sublist(from, end)) {
        if (e['deleted'] != null) {
          all.add(e);
          continue;
        }
        final it = items[e['id']];
        if (isDriveRoot || it == null || _under(it, scope.id)) all.add(e);
      }
      if (omitRootInDelta) all.removeWhere((e) => e['id'] == scope.id);
    }
    final skip = int.tryParse(q['s'] ?? '') ?? 0;
    final page = all.skip(skip).take(pageSize).toList();
    final more = skip + page.length < all.length;
    Uri link(Map<String, String> params) {
      final tok = base64Url.encode(utf8.encode(jsonEncode(params)));
      return functionLinks
          ? origin.replace(path: "$basePath(token='$tok')")
          : origin.replace(path: basePath, queryParameters: {'token': tok});
    }

    await _body(req, {
      'value': page,
      if (more)
        '@odata.nextLink':
            foreignLink ??
            link({'t': t ?? 'full', 'e': '$end', 's': '${skip + page.length}'})
                .toString()
      else
        '@odata.deltaLink': link({'t': '$end.$_epoch'}).toString(),
    });
  }
}
