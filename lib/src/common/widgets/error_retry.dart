import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

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

  /// 把异常整理成一句人话：剥掉 FRB 的 `AnyhowException(…)` 外壳、丢掉
  /// `Stack backtrace:` 那一段、换行压成空格，过长的截断。
  ///
  /// Rust 侧的 anyhow 错误经 frb 包上一层 `AnyhowException`，`toString()` 里还
  /// 挂着十几行 `0: <unknown>` 的栈；原样塞进提示会把胶囊撑成一大团。
  static String describe(Object error, {int maxLength = 160}) {
    const List<String> prefixes = <String>['Exception: ', 'Error: '];
    const List<String> wrappers = <String>[
      'AnyhowException(',
      'PanicException(',
    ];
    String text = error.toString().trim();
    // 先砍栈，再剥外壳：栈尾巴上的 `)`（`  10: RustThreadStart)`）会让
    // `endsWith(')')` 误判成「外壳的收尾括号」，剥完就残留一个 `)`
    final RegExp tail = RegExp(r'\r?\n(?:\s*\r?\n|\s*Stack backtrace:)');
    final RegExpMatch? cut = tail.firstMatch(text);
    if (cut != null) {
      text = text.substring(0, cut.start);
    }
    // 内文自己也可能带括号（`BASS 错误 2 (无法打开文件)`），所以只去掉最外层那一对
    for (final String wrapper in wrappers) {
      if (text.startsWith(wrapper) && text.endsWith(')')) {
        text = text.substring(wrapper.length, text.length - 1).trim();
        break;
      }
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final String prefix in prefixes) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        break;
      }
    }
    if (text.isEmpty || text == 'Exception' || text == 'Error') {
      return '未知错误';
    }
    if (text.length > maxLength) {
      text = '${text.substring(0, maxLength).trimRight()}…';
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
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 56, color: scheme.error),
              const SizedBox(height: Spacing.sm),
              Text(
                title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                describe(error),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: Spacing.md),
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
