import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/history_entry.dart';

/// Persistence boundary for scan history.
abstract interface class HistoryStore {
  /// Returns stored entries sorted for display. Unreadable records are dropped.
  Future<List<HistoryEntry>> load();

  Future<void> save(List<HistoryEntry> entries);
}

/// Stores history as a JSON document in the app's own documents directory.
///
/// History is device-local by design: no network access, no cloud sync, no
/// backup of decoded payloads (project spec §11). Writes go to a temporary file
/// that then replaces the real one, so an interrupted write cannot leave a
/// half-written history behind.
class JsonFileHistoryStore implements HistoryStore {
  JsonFileHistoryStore({this.fileName = 'scan_history.json'});

  /// Current on-disk document version, so a future format change can migrate
  /// rather than guess.
  static const int documentVersion = 1;

  final String fileName;

  File? _cachedFile;

  Future<File> _file() async {
    final cached = _cachedFile;
    if (cached != null) {
      return cached;
    }
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    _cachedFile = file;
    return file;
  }

  @override
  Future<List<HistoryEntry>> load() async {
    final file = await _file();
    if (!await file.exists()) {
      return const <HistoryEntry>[];
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      return const <HistoryEntry>[];
    } on FileSystemException {
      return const <HistoryEntry>[];
    }

    if (decoded is! Map) {
      return const <HistoryEntry>[];
    }

    final rawEntries = decoded['entries'];
    if (rawEntries is! List) {
      return const <HistoryEntry>[];
    }

    final entries = <HistoryEntry>[];
    for (final rawEntry in rawEntries) {
      final entry = HistoryEntry.fromJson(rawEntry);
      if (entry != null) {
        entries.add(entry);
      }
    }
    entries.sort(HistoryEntry.compareForDisplay);
    return entries;
  }

  @override
  Future<void> save(List<HistoryEntry> entries) async {
    final file = await _file();
    await file.parent.create(recursive: true);

    final document = jsonEncode({
      'version': documentVersion,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    });

    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(document, flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      // Some platforms refuse to replace an existing file with a rename; fall
      // back to a copy and remove the temporary file.
      await temporary.copy(file.path);
      await temporary.delete();
    }
  }
}
