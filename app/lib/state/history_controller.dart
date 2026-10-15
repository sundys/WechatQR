import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/history_store.dart';
import '../domain/content_classifier.dart';
import '../domain/history_entry.dart';
import '../domain/scan_source.dart';

/// Generates identifiers for new history rows. Injectable so tests are
/// deterministic.
typedef HistoryIdGenerator = String Function();

String _defaultIdGenerator() {
  final random = Random();
  final suffix = List<String>.generate(
    4,
    (_) => random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'),
  ).join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$suffix';
}

/// Owns the scan history list and keeps it persisted and in display order.
class HistoryController extends ChangeNotifier {
  HistoryController({required this._store, HistoryIdGenerator? idGenerator})
    : _generateId = idGenerator ?? _defaultIdGenerator;
  final HistoryStore _store;
  final HistoryIdGenerator _generateId;

  List<HistoryEntry> _entries = const <HistoryEntry>[];
  bool _loaded = false;

  /// Entries in display order: pinned first, then newest first.
  List<HistoryEntry> get entries => List<HistoryEntry>.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      // The controller owns display order, so it sorts here rather than
      // trusting each store to have done it — the invariant then holds for
      // every implementation.
      _entries = _sorted([...await _store.load()]);
    } catch (error) {
      // An unreadable store must not stop the app from scanning; the list
      // simply starts empty.
      _entries = const <HistoryEntry>[];
      debugPrint('History load failed: $error');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Appends a decoded payload. Callers decide *whether* to record (the
  /// "continuous scan" setting and de-duplication live in the scan flow).
  Future<HistoryEntry> add({
    required String content,
    required ScanSource source,
    required DateTime scannedAt,
  }) async {
    final entry = HistoryEntry(
      id: _generateId(),
      content: content,
      contentType: ContentClassifier.classify(content),
      scannedAt: scannedAt,
      source: source,
    );
    _entries = _sorted([..._entries, entry]);
    notifyListeners();
    await _persist();
    return entry;
  }

  /// Replaces an entry's content in place, keeping its id, pin state and
  /// position.
  Future<void> updateContent(String id, String content) async {
    final index = _indexOf(id);
    if (index < 0) {
      return;
    }
    _entries = _sorted([
      ..._entries.take(index),
      _entries[index].copyWith(content: content),
      ..._entries.skip(index + 1),
    ]);
    notifyListeners();
    await _persist();
  }

  /// Pins or unpins a row. Pinned rows order ahead of unpinned ones; within
  /// each group the normal newest-first order applies.
  Future<void> setPinned(String id, bool pinned) async {
    final index = _indexOf(id);
    if (index < 0 || _entries[index].isPinned == pinned) {
      return;
    }
    _entries = _sorted([
      ..._entries.take(index),
      _entries[index].copyWith(isPinned: pinned),
      ..._entries.skip(index + 1),
    ]);
    notifyListeners();
    await _persist();
  }

  Future<void> togglePin(String id) async {
    final index = _indexOf(id);
    if (index < 0) {
      return;
    }
    await setPinned(id, !_entries[index].isPinned);
  }

  /// Re-inserts an entry that was just deleted, used by the undo action on a
  /// single-row delete. A no-op if the id is already present.
  Future<void> restore(HistoryEntry entry) async {
    if (_entries.any((existing) => existing.id == entry.id)) {
      return;
    }
    _entries = _sorted([..._entries, entry]);
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    final index = _indexOf(id);
    if (index < 0) {
      return;
    }
    final remaining = [..._entries]..removeAt(index);
    _entries = remaining;
    notifyListeners();
    await _persist();
  }

  /// Deletes every entry. The UI is responsible for confirming first.
  Future<void> clear() async {
    if (_entries.isEmpty) {
      return;
    }
    _entries = const <HistoryEntry>[];
    notifyListeners();
    await _persist();
  }

  int _indexOf(String id) => _entries.indexWhere((entry) => entry.id == id);

  List<HistoryEntry> _sorted(List<HistoryEntry> entries) {
    entries.sort(HistoryEntry.compareForDisplay);
    return entries;
  }

  Future<void> _persist() async {
    try {
      await _store.save(_entries);
    } catch (error) {
      // The in-memory list stays authoritative for this session; the failure is
      // surfaced rather than silently swallowed.
      debugPrint('History save failed: $error');
    }
  }
}
