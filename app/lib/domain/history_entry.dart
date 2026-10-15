import 'content_type.dart';
import 'scan_source.dart';

/// One decoded payload kept in the local history.
///
/// Stored on the device only. Nothing here is uploaded, synced, or shared
/// implicitly (project spec §11).
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.content,
    required this.contentType,
    required this.scannedAt,
    this.isPinned = false,
    this.source = ScanSource.camera,
  });

  final String id;

  /// The payload exactly as decoded. Never interpreted as an instruction.
  final String content;

  final ContentType contentType;
  final DateTime scannedAt;
  final bool isPinned;
  final ScanSource source;

  HistoryEntry copyWith({
    String? content,
    ContentType? contentType,
    DateTime? scannedAt,
    bool? isPinned,
    ScanSource? source,
  }) {
    return HistoryEntry(
      id: id,
      content: content ?? this.content,
      contentType: contentType ?? this.contentType,
      scannedAt: scannedAt ?? this.scannedAt,
      isPinned: isPinned ?? this.isPinned,
      source: source ?? this.source,
    );
  }

  /// Display order: pinned entries first, then newest first.
  ///
  /// Ties break on [id] so the order is total and stable — the same list always
  /// renders in the same sequence, which is what keeps pinned rows from
  /// shuffling (project spec §6.4).
  static int compareForDisplay(HistoryEntry a, HistoryEntry b) {
    if (a.isPinned != b.isPinned) {
      return a.isPinned ? -1 : 1;
    }
    final byTime = b.scannedAt.compareTo(a.scannedAt);
    if (byTime != 0) {
      return byTime;
    }
    return a.id.compareTo(b.id);
  }

  /// Single-line preview for the history list: newlines and runs of whitespace
  /// collapse to one space, and the text is cut to [maxLength] characters.
  String preview({int maxLength = 120}) {
    final collapsed = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= maxLength) {
      return collapsed;
    }
    return '${collapsed.substring(0, maxLength)}…';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'content': content,
    'contentType': contentType.storageKey,
    'scannedAt': scannedAt.toIso8601String(),
    'isPinned': isPinned,
    'source': source.storageKey,
  };

  /// Rebuilds an entry from persisted JSON, or `null` when the record is too
  /// damaged to use (missing id/content/timestamp). Unreadable records are
  /// dropped rather than crashing the list.
  static HistoryEntry? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }

    final id = json['id'];
    final content = json['content'];
    final scannedAt = json['scannedAt'];
    if (id is! String || id.isEmpty || content is! String) {
      return null;
    }
    final parsedAt = scannedAt is String ? DateTime.tryParse(scannedAt) : null;
    if (parsedAt == null) {
      return null;
    }

    return HistoryEntry(
      id: id,
      content: content,
      contentType: ContentType.fromStorageKey(json['contentType']),
      scannedAt: parsedAt,
      isPinned: json['isPinned'] == true,
      source: ScanSource.fromStorageKey(json['source']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryEntry &&
      other.id == id &&
      other.content == content &&
      other.contentType == contentType &&
      other.scannedAt == scannedAt &&
      other.isPinned == isPinned &&
      other.source == source;

  @override
  int get hashCode =>
      Object.hash(id, content, contentType, scannedAt, isPinned, source);

  @override
  String toString() => 'HistoryEntry(id: $id, type: ${contentType.name})';
}
