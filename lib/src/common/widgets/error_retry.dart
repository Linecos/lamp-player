import 'package:flutter/material.dart';

/// 错误态：标题 + 错误摘要 + 重试按钮。
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({
    super.key,
    required this.error,
    required this.onRetry,
    this.title = '操作失败',
  });

  final Object error;
  final VoidCallback onRetry;
  final String title;

  /// 去掉 `Exception: ` / `Error: ` 前缀，空值返回「未知错误」。
  static String describe(Object error) {
    const List<String> prefixes = <String>['Exception: ', 'Error: '];
    String text = error.toString().trim();
    for (final String prefix in prefixes) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        break;
      }
    }
    if (text.isEmpty || text == 'Exception' || text == 'Error') {
      return '未知错误';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 56, color: scheme.error),
              const SizedBox(height: 12),
              Text(
                title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                describe(error),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
