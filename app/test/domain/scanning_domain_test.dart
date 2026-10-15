import 'package:flutter_test/flutter_test.dart';
import 'package:wechatqr/domain/content_type.dart';
import 'package:wechatqr/domain/history_entry.dart';
import 'package:wechatqr/domain/scan_dedup.dart';
import 'package:wechatqr/domain/scan_result_policy.dart';
import 'package:wechatqr/domain/scan_settings.dart';
import 'package:wechatqr/domain/scan_source.dart';

void main() {
  group('HistoryEntry', () {
    HistoryEntry entry({
      required String id,
      bool pinned = false,
      required DateTime at,
      String content = 'x',
    }) {
      return HistoryEntry(
        id: id,
        content: content,
        contentType: ContentType.text,
        scannedAt: at,
        isPinned: pinned,
      );
    }

    test('orders pinned first, then newest first', () {
      final entries = [
        entry(id: 'a', at: DateTime(2026, 1, 1)),
        entry(id: 'b', at: DateTime(2026, 3, 1), pinned: true),
        entry(id: 'c', at: DateTime(2026, 2, 1)),
        entry(id: 'd', at: DateTime(2026, 4, 1), pinned: true),
      ]..sort(HistoryEntry.compareForDisplay);

      expect(entries.map((e) => e.id).toList(), ['d', 'b', 'c', 'a']);
    });

    test('breaks ties on id so the order is total and stable', () {
      final at = DateTime(2026, 1, 1);
      final entries = [entry(id: 'b', at: at), entry(id: 'a', at: at)]
        ..sort(HistoryEntry.compareForDisplay);

      expect(entries.map((e) => e.id).toList(), ['a', 'b']);
    });

    test('preview collapses whitespace and truncates', () {
      final long = entry(
        id: 'a',
        at: DateTime(2026, 1, 1),
        content: 'line one\n\n   line two ${'x' * 500}',
      );
      final preview = long.preview(maxLength: 20);
      expect(preview.length, 21); // 20 characters plus the ellipsis
      expect(preview.contains('\n'), isFalse);
      expect(preview.endsWith('…'), isTrue);
    });

    test('round-trips through JSON', () {
      final original = HistoryEntry(
        id: 'id-1',
        content: 'https://example.com',
        contentType: ContentType.url,
        scannedAt: DateTime.utc(2026, 5, 4, 3, 2, 1),
        isPinned: true,
        source: ScanSource.gallery,
      );

      final restored = HistoryEntry.fromJson(original.toJson())!;
      expect(restored, original);
      expect(restored.scannedAt.isUtc, isTrue);
    });

    test('drops damaged records instead of throwing', () {
      expect(HistoryEntry.fromJson(null), isNull);
      expect(HistoryEntry.fromJson('not a map'), isNull);
      expect(HistoryEntry.fromJson({'id': 'a'}), isNull);
      expect(
        HistoryEntry.fromJson({
          'id': '',
          'content': 'x',
          'scannedAt': '2026-01-01T00:00:00Z',
        }),
        isNull,
      );
      expect(
        HistoryEntry.fromJson({
          'id': 'a',
          'content': 'x',
          'scannedAt': 'whenever',
        }),
        isNull,
      );
    });

    test('falls back to defaults for unknown enum values', () {
      final restored = HistoryEntry.fromJson({
        'id': 'a',
        'content': 'x',
        'contentType': 'something-new',
        'source': 'something-new',
        'scannedAt': '2026-01-01T00:00:00Z',
      })!;
      expect(restored.contentType, ContentType.text);
      expect(restored.source, ScanSource.camera);
    });
  });

  group('ScanDedup', () {
    test('suppresses the same payload inside the window', () {
      final dedup = ScanDedup(window: const Duration(seconds: 3));
      final start = DateTime(2026, 1, 1, 12);

      expect(dedup.shouldEmit('abc', start), isTrue);
      expect(
        dedup.shouldEmit('abc', start.add(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        dedup.shouldEmit('abc', start.add(const Duration(seconds: 2))),
        isFalse,
      );
    });

    test('allows the same payload again once the window has passed', () {
      final dedup = ScanDedup(window: const Duration(seconds: 3));
      final start = DateTime(2026, 1, 1, 12);

      expect(dedup.shouldEmit('abc', start), isTrue);
      expect(
        dedup.shouldEmit('abc', start.add(const Duration(seconds: 3))),
        isTrue,
      );
    });

    test('a different payload is emitted immediately', () {
      final dedup = ScanDedup();
      final start = DateTime(2026, 1, 1, 12);

      expect(dedup.shouldEmit('abc', start), isTrue);
      expect(dedup.shouldEmit('xyz', start), isTrue);
      // ...and the earlier payload is now suppressed, because only the most
      // recent result is remembered.
      expect(dedup.shouldEmit('abc', start), isTrue);
    });

    test('suppress restarts the window without emitting', () {
      final dedup = ScanDedup(window: const Duration(seconds: 3));
      final start = DateTime(2026, 1, 1, 12);

      expect(dedup.shouldEmit('abc', start), isTrue);
      dedup.suppress('abc', start.add(const Duration(seconds: 10)));
      // Without the suppress call the window would have elapsed by now.
      expect(
        dedup.shouldEmit('abc', start.add(const Duration(seconds: 11))),
        isFalse,
      );
      expect(
        dedup.shouldEmit('abc', start.add(const Duration(seconds: 14))),
        isTrue,
      );
    });

    test('reset forgets the last result', () {
      final dedup = ScanDedup(window: const Duration(days: 1));
      final start = DateTime(2026, 1, 1, 12);

      expect(dedup.shouldEmit('abc', start), isTrue);
      dedup.reset();
      expect(dedup.shouldEmit('abc', start), isTrue);
    });
  });

  group('ScanResultPolicy', () {
    test('selects the first non-blank payload as primary', () {
      final selection = ScanResultPolicy.select(['first', 'second'])!;
      expect(selection.primary, 'first');
      expect(selection.isMulti, isTrue);
      expect(selection.all, ['first', 'second']);
    });

    test('keeps every result so nothing is silently dropped', () {
      final selection = ScanResultPolicy.select(['a', 'b', 'c'])!;
      expect(selection.all.length, 3);
    });

    test('skips blank payloads when choosing a primary', () {
      final selection = ScanResultPolicy.select(['  ', '', 'real'])!;
      expect(selection.primary, 'real');
      expect(selection.isMulti, isFalse);
    });

    test('returns null when there is nothing usable', () {
      expect(ScanResultPolicy.select(const []), isNull);
      expect(ScanResultPolicy.select(const ['  ', '']), isNull);
    });
  });

  group('ScanSettings persistence', () {
    test('defaults match the spec recommendations', () {
      const defaults = ScanSettings.defaults;
      expect(defaults.autoOpenWebsite, isFalse);
      expect(defaults.continuousScan, isTrue);
      expect(defaults.autoCopyClipboard, isTrue);
      expect(defaults.vibrationEnabled, isTrue);
      expect(defaults.themeMode.name, 'system');
    });

    test('round-trips through JSON', () {
      final settings = ScanSettings.defaults.copyWith(
        autoOpenWebsite: true,
        continuousScan: false,
        themeMode: ScanSettings.defaults.themeMode,
      );
      expect(ScanSettings.fromJson(settings.toJson()), settings);
    });

    test('falls back per-field for missing or mistyped values', () {
      final restored = ScanSettings.fromJson({
        'autoOpenWebsite': 'yes please',
        'continuousScan': false,
        'themeMode': 'ultraviolet',
      });
      expect(restored.autoOpenWebsite, isFalse);
      expect(restored.continuousScan, isFalse);
      expect(restored.themeMode, ScanSettings.defaults.themeMode);
    });
  });
}
