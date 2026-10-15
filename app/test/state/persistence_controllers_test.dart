import 'package:flutter_test/flutter_test.dart';
import 'package:wechatqr/data/history_store.dart';
import 'package:wechatqr/state/history_controller.dart';
import 'package:wechatqr/state/settings_controller.dart';
import 'package:wechatqr/domain/app_theme_mode.dart';
import 'package:wechatqr/domain/content_type.dart';
import 'package:wechatqr/domain/history_entry.dart';
import 'package:wechatqr/domain/scan_settings.dart';
import 'package:wechatqr/domain/scan_source.dart';

import '../support/fakes.dart';

void main() {
  group('HistoryController', () {
    late FakeHistoryStore store;
    late HistoryController controller;
    var counter = 0;

    setUp(() {
      counter = 0;
      store = FakeHistoryStore();
      controller = HistoryController(
        store: store,
        idGenerator: () => 'id-${counter++}',
      );
    });

    test('classifies content as it records it', () async {
      await controller.add(
        content: 'https://example.com',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 1),
      );
      await controller.add(
        content: 'plain text',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 2),
      );

      expect(controller.entries[1].contentType, ContentType.url);
      expect(controller.entries[0].contentType, ContentType.text);
    });

    test('keeps pinned entries on top and persists the pin', () async {
      final first = await controller.add(
        content: 'older',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 1),
      );
      await controller.add(
        content: 'newer',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 2),
      );

      expect(controller.entries.first.content, 'newer');

      await controller.togglePin(first.id);
      expect(controller.entries.first.content, 'older');
      expect(controller.entries.first.isPinned, isTrue);
      expect(store.saved.first.isPinned, isTrue);
    });

    test('unpins and restores the time order', () async {
      final first = await controller.add(
        content: 'older',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 1),
      );
      await controller.add(
        content: 'newer',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 2),
      );
      await controller.setPinned(first.id, true);
      await controller.setPinned(first.id, false);

      expect(controller.entries.first.content, 'newer');
    });

    test('removes a single entry and persists', () async {
      final entry = await controller.add(
        content: 'x',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 1),
      );
      await controller.remove(entry.id);

      expect(controller.entries, isEmpty);
      expect(store.saved, isEmpty);
    });

    test('restore undoes a delete and is idempotent', () async {
      final entry = await controller.add(
        content: 'x',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 1),
      );
      await controller.remove(entry.id);
      await controller.restore(entry);

      expect(controller.entries.length, 1);
      expect(controller.entries.single.id, entry.id);

      // Restoring twice must not duplicate the row.
      await controller.restore(entry);
      expect(controller.entries.length, 1);
    });

    test('clear empties the list and the store', () async {
      await controller.add(
        content: 'a',
        source: ScanSource.camera,
        scannedAt: DateTime(2026, 1, 1),
      );
      await controller.clear();

      expect(controller.entries, isEmpty);
      expect(store.saved, isEmpty);
    });

    test('reloads persisted entries in display order', () async {
      final entries = [
        HistoryEntry(
          id: 'a',
          content: 'unpinned-newest',
          contentType: ContentType.text,
          scannedAt: DateTime(2026, 3, 1),
        ),
        HistoryEntry(
          id: 'b',
          content: 'pinned-oldest',
          contentType: ContentType.text,
          scannedAt: DateTime(2026, 1, 1),
          isPinned: true,
        ),
      ];
      final reloaded = HistoryController(
        store: FakeHistoryStore(initial: entries),
      );
      await reloaded.load();

      expect(reloaded.entries.first.id, 'b');
    });

    test('starts empty when the store cannot be read', () async {
      final controller = HistoryController(store: _ThrowingHistoryStore());
      await controller.load();

      expect(controller.isLoaded, isTrue);
      expect(controller.entries, isEmpty);
    });
  });

  group('SettingsController', () {
    test('applies changes immediately and persists them', () async {
      final store = FakeSettingsStore();
      final controller = SettingsController(store: store);

      await controller.setAutoOpenWebsite(true);

      expect(controller.settings.autoOpenWebsite, isTrue);
      expect(store.saveCount, 1);
      expect(store.initial?.autoOpenWebsite, isTrue);
    });

    test('does not write when the value is unchanged', () async {
      final store = FakeSettingsStore();
      final controller = SettingsController(store: store);

      await controller.setContinuousScan(true); // already the default

      expect(store.saveCount, 0);
    });

    test('loads persisted settings over the defaults', () async {
      final store = FakeSettingsStore(
        initial: ScanSettings.defaults.copyWith(themeMode: AppThemeMode.dark),
      );
      final controller = SettingsController(store: store);
      await controller.load();

      expect(controller.settings.themeMode, AppThemeMode.dark);
    });

    test(
      'keeps the new value and records the error when saving fails',
      () async {
        final store = FakeSettingsStore(failOnSave: true);
        final controller = SettingsController(store: store);

        await controller.setVibrationEnabled(false);

        // The switch must not silently flip back on the user.
        expect(controller.settings.vibrationEnabled, isFalse);
        expect(controller.persistenceError, isNotNull);
      },
    );
  });
}

class _ThrowingHistoryStore implements HistoryStore {
  @override
  Future<List<HistoryEntry>> load() async => throw StateError('unreadable');

  @override
  Future<void> save(List<HistoryEntry> entries) async {}
}
