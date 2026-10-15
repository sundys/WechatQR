import 'package:flutter/material.dart';

import '../../app.dart';
import '../../domain/content_type.dart';
import '../../domain/history_entry.dart';
import '../../domain/scan_source.dart';
import '../../state/history_controller.dart';

/// Scan history, shown as a non-fullscreen sheet.
///
/// Rows are ordered by the controller (pinned first, then newest first) so the
/// order is stable across rebuilds and restarts. Destructive actions are either
/// confirmed (delete all) or undoable (single delete).
class HistorySheet extends StatelessWidget {
  const HistorySheet({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final history = scope.history;
    final clipboard = scope.scan;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final entries = history.entries;

        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('扫描历史', style: theme.textTheme.titleLarge),
                    ),
                    if (entries.isNotEmpty)
                      TextButton.icon(
                        // Delete-all is confirmed first (project spec §6.4).
                        onPressed: () => _confirmClearAll(context, history),
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('全部删除'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: entries.isEmpty
                    ? const _EmptyHistory()
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return _HistoryRow(
                            key: ValueKey(entry.id),
                            entry: entry,
                            onCopy: () =>
                                clipboard.copyToClipboard(entry.content),
                            onTogglePin: () => history.togglePin(entry.id),
                            onDelete: () => _deleteWithUndo(context, entry),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Deletes one row and offers a lightweight undo instead of a confirmation
  /// dialog (project spec §13).
  Future<void> _deleteWithUndo(BuildContext context, HistoryEntry entry) async {
    final history = AppScope.of(context).history;
    final messenger = ScaffoldMessenger.of(context);

    await history.remove(entry.id);

    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已删除该条记录'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => history.restore(entry),
        ),
      ),
    );
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    HistoryController history,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除全部历史记录？'),
        content: const Text('所有扫描记录将从本机删除，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await history.clear();
    }
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onCopy,
    required this.onTogglePin,
    required this.onDelete,
    super.key,
  });

  final HistoryEntry entry;
  final VoidCallback onCopy;
  final VoidCallback onTogglePin;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: ValueKey('dismiss-${entry.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: theme.colorScheme.errorContainer,
        child: Icon(Icons.delete, color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        leading: Icon(
          entry.isPinned ? Icons.push_pin : _iconFor(entry),
          color: entry.isPinned ? theme.colorScheme.primary : null,
        ),
        title: Text(
          // Preview is truncated; copy always uses the full payload.
          entry.preview(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${_formatTime(entry.scannedAt)} · ${_typeLabel(entry.contentType)}'
            ' · ${_sourceLabel(entry.source)}',
            style: theme.textTheme.bodySmall,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '复制',
              icon: const Icon(Icons.copy),
              onPressed: onCopy,
            ),
            IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showRowMenu(context),
            ),
          ],
        ),
        // Long press is the second route to the same menu, for users who do not
        // discover the swipe.
        onLongPress: () => _showRowMenu(context),
        onTap: onCopy,
      ),
    );
  }

  Future<void> _showRowMenu(BuildContext context) async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                entry.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(entry.isPinned ? '取消置顶' : '置顶'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onTogglePin();
              },
            ),
            ListTile(
              leading: Icon(Icons.copy),
              title: const Text('复制'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onCopy();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(
                '删除',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(HistoryEntry entry) => switch (entry.contentType) {
    ContentType.url => Icons.link,
    ContentType.text => Icons.notes,
    ContentType.other => Icons.data_object,
  };

  static String _typeLabel(ContentType type) => switch (type) {
    ContentType.url => '网址',
    ContentType.text => '文本',
    ContentType.other => '其他',
  };

  static String _sourceLabel(ScanSource source) => switch (source) {
    ScanSource.camera => '相机',
    ScanSource.gallery => '相册',
  };

  /// `yyyy-MM-dd HH:mm` in local time. Formatted by hand to avoid pulling in a
  /// date-formatting dependency for one line of text.
  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_toggle_off,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('暂无扫描记录', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '开启“连续扫描”后，识别结果会自动记录在这里。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
