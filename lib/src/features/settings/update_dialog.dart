import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_version.dart';
import '../../app/update_check.dart';
import '../../common/external_link.dart';
import '../../common/scroll/smooth_scroll.dart';
import '../../common/text/mini_markdown.dart';
import '../../theme/tokens.dart';

/// 有新版本时的弹窗：版本号 + 发布说明 + 「前往下载」。
///
/// 手动检查与自动检查共用；自动检查在后台只弹「有新版本」这一种，
/// 已是最新或失败都不打扰。
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  UpdateRelease release, {
  OpenExternalUrl openUrl = openExternalUrl,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        UpdateAvailableDialog(release: release, openUrl: openUrl),
  );
}

class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({
    super.key,
    required this.release,
    required this.openUrl,
  });

  final UpdateRelease release;
  final OpenExternalUrl openUrl;

  /// 发布说明区最高高度：说明再长也在弹窗里滚，别把按钮顶出屏幕
  static const double notesMaxHeight = 260;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String notes = release.notes.trim();

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      title: Row(
        children: <Widget>[
          Icon(Icons.system_update_alt, color: scheme.primary),
          const SizedBox(width: Spacing.sm),
          Expanded(child: Text('发现新版本 v${release.version}')),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '当前版本 v$appVersion',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            if (notes.isEmpty)
              Text('新版本已发布，点「前往下载」打开下载页。', style: theme.textTheme.bodyMedium)
            else
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: notesMaxHeight),
                padding: const EdgeInsets.all(Spacing.sm),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                // 发布说明可能很长，滚轮也要平滑
                child: SmoothSingleChildScrollView(
                  child: MiniMarkdown(
                    data: notes,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                    onOpenLink: (String url) => unawaited(openUrl(url)),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后再说'),
        ),
        FilledButton.icon(
          onPressed: () {
            unawaited(openUrl(release.downloadUrl));
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('前往下载'),
        ),
      ],
    );
  }
}
