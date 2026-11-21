import 'package:flutter/material.dart';

/// 设置类页面的行索引：顶部常驻搜索框按 [searchText] 就地过滤。
///
/// 索引直接取行自己展示的标题 / 副标题，改文案时不会漏更新。
abstract interface class SettingsSearchable {
  String get searchText;
}

/// 分组标题。水平不缩进：要和下面卡片的左边缘对齐（卡片自身有内边距）。
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 卡片用 Material 承载底色：内部 InkWell 的水波纹与 hover 高光必须画在
/// Material 上，被不透明的 Container 盖住就完全看不见。
class SettingsCard extends StatelessWidget {
  const SettingsCard({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          children: <Widget>[
            for (int i = 0; i < children.length; i += 1) ...<Widget>[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: 64,
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 一行「图标 + 标题 + 说明 + 跳转」。
class SettingsActionRow extends StatelessWidget implements SettingsSearchable {
  const SettingsActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  String get searchText => '$title $subtitle';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      hoverColor: scheme.surfaceContainerHigh,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

/// 一行「图标 + 标题 + 右侧只读值」。
class SettingsInfoRow extends StatelessWidget implements SettingsSearchable {
  const SettingsInfoRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;

  /// 给了就整行可点（末尾补一个进入箭头），例如「关于」弹窗
  final VoidCallback? onTap;

  @override
  String get searchText => '$title ${subtitle ?? ''} $value';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      hoverColor: scheme.surfaceContainerHigh,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.bodyLarge),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (onTap != null) ...<Widget>[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            ],
          ],
        ),
      ),
    );
  }
}
