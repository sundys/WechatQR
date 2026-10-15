import 'package:flutter/material.dart';

import '../../app.dart';
import '../../domain/content_classifier.dart';

/// Non-fullscreen sheet showing one decoded payload.
///
/// Long content scrolls inside a bounded box, so it can never push the controls
/// off screen or grow into a full page (project spec §6.1, §13).
class ScanResultSheet extends StatelessWidget {
  const ScanResultSheet({
    required this.onCopy,
    required this.onOpenLink,
    super.key,
  });

  final VoidCallback onCopy;
  final VoidCallback onOpenLink;

  @override
  Widget build(BuildContext context) {
    final scan = AppScope.of(context).scan;

    return ListenableBuilder(
      listenable: scan,
      builder: (context, _) {
        final result = scan.result;
        if (result == null) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final host = ContentClassifier.displayHost(result.primary);
        final maxContentHeight = MediaQuery.sizeOf(context).height * 0.42;

        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      result.isMulti ? '扫描结果（${result.all.length} 个）' : '扫描结果',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxContentHeight),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The payload is shown exactly as decoded and is never
                      // rendered as anything executable.
                      SelectableText(
                        result.primary,
                        style: theme.textTheme.bodyLarge,
                      ),
                      if (host != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.public,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                host,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (result.isMulti) ...[
                        const Divider(height: 32),
                        Text('本画面识别到的其他内容', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        // Nothing the engine returned is dropped silently.
                        for (final text in result.all.skip(1))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SelectableText(
                              text,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),

              if (scan.resultCopied || scan.resultLinkFailed) ...[
                const SizedBox(height: 12),
                _StatusLine(
                  copied: scan.resultCopied,
                  linkFailed: scan.resultLinkFailed,
                ),
              ],

              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy),
                      label: const Text('复制'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      // Only offered for a validated http(s) URL, so the button
                      // never implies a dangerous scheme can be opened.
                      onPressed: host == null ? null : onOpenLink,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('打开链接'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.copied, required this.linkFailed});

  final bool copied;
  final bool linkFailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (copied)
          Row(
            children: [
              Icon(
                Icons.check_circle,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text('已复制到剪贴板', style: theme.textTheme.bodySmall),
            ],
          ),
        if (linkFailed) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '无法自动打开链接，可复制后在浏览器中打开',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
