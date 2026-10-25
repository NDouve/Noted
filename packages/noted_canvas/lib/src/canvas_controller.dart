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
  CanvasController(NotedPage page, this.modules, {this.onChanged}) : _page = page;

  final ModuleRegistry modules;

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
  bool _disposed = false;

  NotedPage get page => _page;

  /// The box with the selection frame.
  String? get selectedId => _selectedId;

  /// The box whose editor has keyboard focus.
  String? get editingId => _editingId;

  /// A box being dragged or resized. Page bounds don't change until the
  /// gesture ends (0016).
  bool get isInteracting => _gestureId != null;

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
  BoxRecord createBoxAt(Bounds at) {
    final codec = modules.defaultModule.codec;
    final box = createBox(
      codec,
      Bounds(at.x, at.y, newBoxWidth, newBoxHeight),
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
    final box = _page.node(id);
    if (box is! BoxRecord) return null;
    final codec = modules.codecs.codecFor(box.typeId);
    if (codec == null) return null;
    final next = commitBox(box, codec, data);
    _page = _page.replaceNode(next);
    onChanged?.call(_page);
    return next;
  }

  /// A module asks for new bounds, for example to grow with its content.
  /// Not recorded for undo; ignored while the user drags that box.
  void requestBounds(String id, Bounds bounds) {
    if (_disposed || _gestureId == id) return;
    final box = _page.node(id);
    if (box is! BoxRecord) return;
    final next = box.withBounds(bounds);
    if (identical(next, box)) return;
    _set(_page.replaceNode(next));
  }

  /// Whether [box] sizes itself to its content: its type grows with content
  /// and the user hasn't set its height.
  bool isAutoHeight(BoxRecord box) =>
      modules.codecs.codecFor(box.typeId)?.sizing == BoxSizing.growsWithContent &&
      !box.fixedHeight;

  void beginGesture(String id) {
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
    final grows = modules.codecs.codecFor(box.typeId)?.sizing == BoxSizing.growsWithContent;
    final next = fixes && grows ? box.withFixedHeight(true) : box;
    if (next.bounds != start || next.fixedHeight != startFixed) {
      _history.record(PageChange.bounds(id, start, fixedHeightBefore: startFixed));
      _set(_page.replaceNode(next));
    } else {
      _notify();
    }
  }

  /// Returns a box whose height the user set to growing with its content.
  void setAutoHeight(String id) {
    final box = _page.node(id);
    if (box is! BoxRecord || !box.fixedHeight) return;
    _history.record(PageChange.bounds(id, box.bounds, fixedHeightBefore: true));
    _set(_page.replaceNode(box.withFixedHeight(false)));
  }

  /// Deletes box [id]. Only boxes this device can run can be deleted;
  /// unsupported and foreign nodes are left alone (0035).
  void delete(String id) {
    final box = _page.node(id);
    if (box is! BoxRecord || modules.codecs.codecFor(box.typeId) == null) {
      return;
    }
    _history.record(PageChange.removed(box, _page.indexOf(id)));
    if (_selectedId == id) _selectedId = null;
    if (_editingId == id) _editingId = null;
    _set(_page.removeNode(id));
  }

  void undo() {
    final next = _history.undo(_page);
    if (next != null) _set(next);
  }

  void redo() {
    final next = _history.redo(_page);
    if (next != null) _set(next);
  }

  /// Replaces the page header, for example after a rename.
  void updateMeta(PageMeta meta) => _set(_page.withMeta(meta));

  bool _isEmpty(String id) {
    final box = _page.node(id);
    if (box is! BoxRecord) return false;
    final r = modules.codecs.resolve(box);
    return r is LiveBox && r.codec.isEmpty(r.data);
  }

  void _set(NotedPage page) {
    _page = page;
    if (_selectedId != null && _page.node(_selectedId!) == null) {
      _selectedId = null;
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
