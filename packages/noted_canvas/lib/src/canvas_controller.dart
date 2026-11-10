// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

import 'module_registry.dart';

/// Default size of a box created by clicking the canvas.
const double newBoxWidth = 360;
const double newBoxHeight = 40;

/// Smallest size the user can resize a box to.
const double minBoxWidth = 60;
const double minBoxHeight = 24;

/// The state of one open page: its model, selection, gestures and page-level
/// undo.
///
/// Listeners are notified when anything the canvas draws changes. Content
/// commits don't notify, because the box that made the edit already shows
/// it; they only call [onChanged] so the page can be saved.
class CanvasController extends ChangeNotifier {
  CanvasController(
    NotedPage page,
    this.modules, {
    this.onChanged,
    this.deviceName,
    int Function()? clock,
    bool readOnly = false,
  }) : _page = page,
       // ignore: prefer_initializing_formals
       _readOnly = readOnly,
       _clock = clock ?? _systemClock;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;

  final ModuleRegistry modules;

  /// This computer's name. Content written here is stamped with it and the
  /// time (`noted.device`, `noted.at`); null means don't stamp.
  final String? deviceName;

  final int Function() _clock;

  int? get _stampTime => deviceName == null ? null : _clock();

  /// Called after every change to the page model, for autosave.
  final void Function(NotedPage page)? onChanged;

  final PageHistory _history = PageHistory();
  NotedPage _page;
  String? _selectedId;
  String? _editingId;
  String? _autofocusId;
  String? _gestureId;
  Bounds? _gestureStart;
  bool _gestureStartFixed = false;
  bool _gestureFixesHeight = false;
  int _toolSessions = 0;
  bool _disposed = false;
  bool _readOnly;

  NotedPage get page => _page;

  /// A read-only controller shows its page but never changes it: every
  /// mutation (creating, editing, moving, resizing, deleting, undo, conflict
  /// resolution, renaming) is ignored and [onChanged] is never called, so the
  /// page is never saved. Changes made by someone else ([applyExternal]) are
  /// still shown. Switching to read-only drops any gesture or editing state in
  /// progress. Changing it notifies the listeners.
  bool get readOnly => _readOnly;
  set readOnly(bool value) {
    if (_readOnly == value || _disposed) return;
    _readOnly = value;
    if (value) {
      _editingId = null;
      _autofocusId = null;
      _gestureId = null;
      _gestureStart = null;
    }
    _notify();
  }

  /// The box with the selection frame.
  String? get selectedId => _selectedId;

  /// The box whose editor has keyboard focus.
  String? get editingId => _editingId;

  /// A box being dragged or resized. Page bounds don't change until the
  /// gesture ends (0016).
  bool get isInteracting => _gestureId != null || _toolSessions > 0;

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  /// Returns true once for a box that was just created, so its editor takes
  /// focus.
  bool takeAutofocus(String id) {
    if (_autofocusId != id) return false;
    _autofocusId = null;
    return true;
  }

  /// Creates a box of the default type with its top-left corner at [at].
  /// Throws a [StateError] on a read-only controller.
  BoxRecord createBoxAt(Bounds at) {
    if (_readOnly) throw StateError('The page is read-only.');
    final codec = modules.defaultModule.codec;
    final box = createBox(
      codec,
      Bounds(at.x, at.y, newBoxWidth, newBoxHeight),
      device: deviceName,
      at: _stampTime,
    );
    _history.record(PageChange.added(box.id));
    _selectedId = box.id;
    _autofocusId = box.id;
    _set(_page.insertNode(box));
    return box;
  }

  void select(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    _notify();
  }

  /// Reports that a box's editor gained or lost keyboard focus. A box that
  /// loses focus while empty is discarded.
  void setEditing(String id, bool focused) {
    if (_disposed) return;
    if (focused) {
      _editingId = id;
      _selectedId = id;
      _notify();
      return;
    }
    // Another box may already have reported gaining focus, so don't assume
    // this box is still the one being edited.
    if (_editingId == id) _editingId = null;
    if (_readOnly) {
      _notify();
      return;
    }
    if (_isEmpty(id)) {
      _history.forgetAdded(id);
      if (_selectedId == id) _selectedId = null;
      _set(_page.removeNode(id));
    } else {
      _notify();
    }
  }

  /// Saves new content for box [id] through its codec. Returns the updated
  /// record, or null if the box is gone.
  BoxRecord? commit(String id, Object? data) {
    if (_readOnly) return null;
    final box = _page.node(id);
    if (box is! BoxRecord) return null;
    final codec = modules.codecs.codecFor(box.typeId);
    if (codec == null) return null;
    final next = commitBox(box, codec, data, device: deviceName, at: _stampTime);
    _page = _page.replaceNode(next);
    onChanged?.call(_page);
    return next;
  }

  /// A module asks for new bounds, for example to grow with its content.
  /// Not recorded for undo; ignored while the user drags that box.
  void requestBounds(String id, Bounds bounds) {
    if (_disposed || _readOnly || _gestureId == id) return;
    final box = _page.node(id);
    if (box is! BoxRecord) return;
    final next = box.withBounds(bounds);
    if (identical(next, box)) return;
    _set(_page.replaceNode(next));
  }

  /// Whether [box] sizes itself to its content: its type grows with content
  /// and the user hasn't set its height.
  bool isAutoHeight(BoxRecord box) =>
      modules.codecs.codecFor(box.typeId)?.sizing ==
          BoxSizing.growsWithContent &&
      !box.fixedHeight;

  void beginGesture(String id) {
    if (_readOnly) return;
    final box = _page.node(id);
    if (box is! BoxRecord) return;
    _gestureId = id;
    _gestureStart = box.bounds;
    _gestureStartFixed = box.fixedHeight;
    _gestureFixesHeight = false;
    _selectedId = id;
    _notify();
  }

  /// Moves or resizes the box under the pointer. [setsHeight] marks a resize
  /// that changes the height: a box that grows with its content keeps the
  /// height the user gave it from then on.
  void updateGesture(String id, Bounds bounds, {bool setsHeight = false}) {
    if (_gestureId != id) return;
    final box = _page.node(id);
    if (box is! BoxRecord) return;
    _gestureFixesHeight |= setsHeight;
    final next = box.withBounds(bounds);
    if (identical(next, box)) return;
    _page = _page.replaceNode(next);
    _notify();
  }

  void endGesture(String id) {
    if (_gestureId != id) return;
    final start = _gestureStart!;
    final startFixed = _gestureStartFixed;
    final fixes = _gestureFixesHeight;
    _gestureId = null;
    _gestureStart = null;
    final box = _page.node(id);
    if (box is! BoxRecord) {
      _notify();
      return;
    }
    final grows =
        modules.codecs.codecFor(box.typeId)?.sizing ==
        BoxSizing.growsWithContent;
    var next = fixes && grows ? box.withFixedHeight(true) : box;
    if (next.bounds != start || next.fixedHeight != startFixed) {
      final change = PageChange.bounds(id, start, fixedHeightBefore: startFixed);
      if (next.landed != null) {
        // The first move or resize places a landed box: the marker goes in
        // the same undo step.
        _history.record(PageChange.group([change, PageChange.landed(id, next.landed)]));
        next = next.withoutLanded();
      } else {
        _history.record(change);
      }
      _set(_page.replaceNode(next));
    } else {
      _notify();
    }
  }

  /// Returns a box whose height the user set to growing with its content.
  void setAutoHeight(String id) {
    if (_readOnly) return;
    final box = _page.node(id);
    if (box is! BoxRecord || !box.fixedHeight) return;
    _history.record(PageChange.bounds(id, box.bounds, fixedHeightBefore: true));
    _set(_page.replaceNode(box.withFixedHeight(false)));
  }

  /// Adds a box a tool built, with its content, on top. Recorded for undo.
  /// With [autofocus] the box is selected and its editor takes the keyboard
  /// focus, as a new note does.
  void insertBox(BoxRecord box, {bool autofocus = false}) {
    if (_readOnly) return;
    _history.record(PageChange.added(box.id));
    if (autofocus) {
      _selectedId = box.id;
      _autofocusId = box.id;
    }
    _set(_page.insertNode(box));
  }

  /// Whether [move] would change where node [id] sits in the z-order, and the
  /// page isn't read-only.
  bool canRestack(String id, StackMove move) =>
      !_readOnly && stackTarget(_page, id, move) != null;

  /// Moves node [id] in the z-order. One undo step. Every node, whatever its
  /// type, is moved verbatim. Returns false if nothing changed (read-only,
  /// missing, no id of its own, or already there). The selection is kept.
  bool restack(String id, StackMove move) {
    if (_readOnly) return false;
    final to = stackTarget(_page, id, move);
    if (to == null) return false;
    final i = _page.indexOf(id);
    _history.record(
      PageChange.order(
        id,
        after: i == 0 || !hasOwnId(_page.nodes[i - 1]) ? null : _page.nodes[i - 1].id,
        index: i,
      ),
    );
    _set(_page.moveNode(id, to));
    return true;
  }

  /// Replaces box [id]'s data through its codec, optionally with new
  /// [bounds], and redraws. When [undo] is given, page undo replays it as a
  /// diff (and restores the old bounds) instead of keeping a copy of the
  /// content. Returns the updated record, or null if the box is gone.
  BoxRecord? editBox(String id, Object? data, {Bounds? bounds, BoxEdit? undo}) {
    if (_readOnly) return null;
    final box = _page.node(id);
    if (box is! BoxRecord) return null;
    final codec = modules.codecs.codecFor(box.typeId);
    if (codec == null) return null;
    var next = commitBox(box, codec, data, device: deviceName, at: _stampTime);
    if (bounds != null) next = next.withBounds(bounds);
    if (undo != null) {
      _history.record(
        PageChange.content(
          id,
          undo,
          boundsBefore: bounds == null ? null : box.bounds,
        ),
      );
    }
    _set(_page.replaceNode(next));
    return next;
  }

  /// Replaces the data of several boxes through their codecs as one undo
  /// step, for example when their attachments are embedded or moved to the
  /// folder. Boxes that are gone are skipped. Returns how many changed.
  int replaceBoxData(Map<String, Object?> dataById) {
    if (_readOnly) return 0;
    var page = _page;
    final before = <PageChange>[];
    dataById.forEach((id, data) {
      final box = page.node(id);
      if (box is! BoxRecord) return;
      final codec = modules.codecs.codecFor(box.typeId);
      if (codec == null) return;
      before.add(PageChange.replaced(box));
      page = page.replaceNode(commitBox(box, codec, data, device: deviceName, at: _stampTime));
    });
    if (before.isEmpty) return 0;
    _history.record(before.length == 1 ? before.single : PageChange.group(before));
    _set(page);
    return before.length;
  }

  /// Records a change that has already been applied, for example several
  /// erasures made during one eraser drag, kept as one undo step.
  void recordChange(PageChange change) {
    if (!_readOnly) _history.record(change);
  }

  /// A tool session started or ended. While one is running, page bounds
  /// stay fixed (0016). Ignored on a read-only controller.
  void beginToolSession() {
    if (!_readOnly) _toolSessions++;
  }

  void endToolSession() {
    if (_toolSessions > 0) _toolSessions--;
    _notify();
  }

  /// Deletes box [id]. Only boxes this device can run can be deleted;
  /// unsupported and foreign nodes are left alone (0035).
  ///
  /// Undo puts the box back as it is now, or as [undoTo] if given: a tool
  /// that emptied a box before deleting it passes the box as it was before,
  /// so one undo restores it whole.
  void delete(String id, {BoxRecord? undoTo}) {
    if (_readOnly) return;
    final box = _page.node(id);
    if (box is! BoxRecord || modules.codecs.codecFor(box.typeId) == null) {
      return;
    }
    _history.record(PageChange.removed(undoTo ?? box, _page.indexOf(id)));
    if (_selectedId == id) _selectedId = null;
    if (_editingId == id) _editingId = null;
    _set(_page.removeNode(id));
  }

  void undo() {
    if (_readOnly) return;
    final next = _history.undo(_page, modules.codecs);
    if (next != null) _set(next);
  }

  void redo() {
    if (_readOnly) return;
    final next = _history.redo(_page, modules.codecs);
    if (next != null) _set(next);
  }

  /// Chooses the page background. One undo step; ignored on a read-only
  /// controller or when the page already stores that choice.
  void setBackground(PageBackground value) {
    if (_readOnly) return;
    final next = _page.meta.withBackground(value);
    if (identical(next, _page.meta)) return;
    _history.record(PageChange.background(_page.meta.rawBackground));
    _set(_page.withMeta(next));
  }

  /// Replaces the page header, for example after a rename.
  void updateMeta(PageMeta meta) {
    if (!_readOnly) _set(_page.withMeta(meta));
  }

  /// Replaces the whole page with the result of merging a change made by
  /// someone else (0020). Not recorded for undo. [save] says whether the
  /// merged page differs from what is on disk and must be written.
  void applyExternal(NotedPage page, {bool save = true}) {
    if (_disposed) return;
    _page = page;
    if (_selectedId != null && _page.node(_selectedId!) == null) {
      _selectedId = null;
    }
    if (_editingId != null && _page.node(_editingId!) == null) {
      _editingId = null;
    }
    if (save && !_readOnly) onChanged?.call(_page);
    _notify();
  }

  /// The boxes that have another version waiting to be resolved (0020).
  List<BoxRecord> get conflictedBoxes => [
    for (final n in _page.nodes)
      if (n is BoxRecord && n.isConflicted) n,
  ];

  /// Whether any box on the page is conflicted.
  bool get hasConflicts => _page.nodes.any((n) => n is BoxRecord && n.isConflicted);

  /// The page's issues in reading order (landed boxes and conflicts). A box
  /// this device can't open (its module is off, or its type is in
  /// [disallowedTypes]) has an unreadable conflict: it is settled from its
  /// snapshots, never decoded (0035).
  List<PageIssue> issues({Set<String> disallowedTypes = const {}}) => pageIssues(
    _page,
    canOpen: (box) =>
        modules.moduleFor(box.typeId) != null &&
        modules.codecs.codecFor(box.typeId) != null &&
        !disallowedTypes.contains(box.typeId),
  );

  // Each resolution below is one undo step and uses the core helper of the
  // same name; [conflict] picks the recorded other version it is about (the
  // box's first if null).

  BoxRecord? _boxFor(String id) {
    final box = _page.node(id);
    return box is BoxRecord ? box : null;
  }

  /// Keeps this device's version of the conflicted box [id]; for a box the
  /// other side deleted, keeps the box.
  void resolveKeepMine(String id, {BoxConflict? conflict}) {
    final box = _boxFor(id);
    if (_readOnly || box == null || !box.isConflicted) return;
    final next = keepMine(_page, id, conflict: conflict);
    if (identical(next, _page)) return;
    _history.record(PageChange.replaced(box));
    _set(next);
  }

  /// Replaces the conflicted box [id] with the other version, verbatim.
  void resolveKeepTheirs(String id, {BoxConflict? conflict}) {
    final box = _boxFor(id);
    if (_readOnly || box == null) return;
    final next = keepOther(_page, id, conflict: conflict);
    if (identical(next, _page)) return;
    _history.record(PageChange.replaced(box));
    _set(next);
  }

  /// Keeps this device's version and adds the other as a new box with a new
  /// id beside it.
  void resolveKeepBoth(String id, {BoxConflict? conflict}) {
    final box = _boxFor(id);
    if (_readOnly || box == null) return;
    final next = placeBoth(_page, id, conflict: conflict);
    if (identical(next, _page)) return;
    final known = {for (final n in _page.nodes) n.id};
    _history.record(
      PageChange.group([
        PageChange.replaced(box),
        for (final n in next.nodes)
          if (!known.contains(n.id)) PageChange.added(n.id),
      ]),
    );
    _set(next);
  }

  /// Resolves the conflicted box [id] by saving [data] (decoded, as the box's
  /// codec takes it) as its content, and drops the resolved record. Returns
  /// false if the box is gone, isn't conflicted or this device can't run it.
  bool resolveWithData(String id, Object? data, {BoxConflict? conflict}) {
    final box = _boxFor(id);
    if (_readOnly || box == null || !box.isConflicted) return false;
    final codec = modules.codecs.codecFor(box.typeId);
    if (codec == null) return false;
    final next = acceptMerged(
      _page,
      id,
      codec,
      data,
      conflict: conflict,
      device: deviceName,
      at: _stampTime,
    );
    if (identical(next, _page)) return false;
    _history.record(PageChange.replaced(box));
    _set(next);
    return true;
  }

  /// Deletes the conflicted box [id], including a box the other side deleted
  /// that this side kept. Also works for boxes this device can't run.
  void resolveDelete(String id) {
    final box = _boxFor(id);
    if (_readOnly || box == null || !box.isConflicted) return;
    _history.record(PageChange.removed(box, _page.indexOf(id)));
    if (_selectedId == id) _selectedId = null;
    if (_editingId == id) _editingId = null;
    _set(deleteBox(_page, id));
  }

  /// "Leave it here": the landed box [id] stays where it is and its marker is
  /// cleared.
  void leaveLanded(String id) {
    final box = _boxFor(id);
    if (_readOnly || box == null || box.landed == null) return;
    _history.record(PageChange.landed(id, box.landed));
    _set(clearLanded(_page, id));
  }

  bool _isEmpty(String id) {
    final box = _page.node(id);
    if (box is! BoxRecord) return false;
    final r = modules.codecs.resolve(box);
    return r is LiveBox && r.codec.isEmpty(r.data);
  }

  void _set(NotedPage page) {
    if (_readOnly) return; // safety net: no mutator gets past its own guard
    _page = page;
    if (_selectedId != null && _page.node(_selectedId!) == null) {
      _selectedId = null;
    }
    if (_editingId != null && _page.node(_editingId!) == null) {
      _editingId = null;
    }
    onChanged?.call(_page);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
