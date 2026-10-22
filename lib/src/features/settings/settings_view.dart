import 'dart:async';

import 'package:flutter/material.dart';

import 'theme_controller.dart';

/// 设置页骨架。
///
/// 展示曲库统计与引擎状态；「外观 → 主题」可切换并持久化。
/// 添加音乐目录、默认音量等交互待接入，未持久化的假开关不放。
class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.trackCount,
    required this.totalDurationSecs,
    required this.engineAvailable,
  });

  final int trackCount;
  final double totalDurationSecs;
  final bool engineAvailable;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      children: <Widget>[
        _SectionLabel('音乐库'),
        _SettingsCard(
          children: <Widget>[
            _InfoRow(
              icon: Icons.library_music_outlined,
              title: '曲目数量',
              value: '$trackCount 首',
            ),
            _InfoRow(
              icon: Icons.schedule,
              title: '总时长',
              value: _formatTotal(totalDurationSecs),
            ),
          ],
        ),
        _SectionLabel('播放'),
        _SettingsCard(
          children: <Widget>[
            _InfoRow(
              icon: Icons.graphic_eq,
              title: '播放引擎',
              value: engineAvailable ? '已接入' : '不可用（未加载 BASS）',
              valueColor: engineAvailable
                  ? null
                  : Theme.of(context).colorScheme.error,
            ),
          ],
        ),
        _SectionLabel('外观'),
        _SettingsCard(
          children: <Widget>[
            const _ThemeRow(),
            const _InfoRow(
              icon: Icons.palette_outlined,
              title: '强调色',
              subtitle: '由主题种子色生成',
              value: 'Amber',
            ),
          ],
        ),
        _SectionLabel('关于'),
        _SettingsCard(
          children: const <Widget>[
            _InfoRow(
              icon: Icons.info_outline,
              title: 'Lamp Player',
              subtitle: 'Flutter + Rust + BASS',
              value: '0.1.0',
            ),
          ],
        ),
      ],
    );
  }

  static String _formatTotal(double seconds) {
    final int total = seconds.round();
    if (total < 60) {
      return '$total 秒';
    }
    final int hours = total ~/ 3600;
    final int minutes = (total % 3600) ~/ 60;
    if (hours > 0) {
      return minutes > 0 ? '$hours 小时 $minutes 分钟' : '$hours 小时';
    }
    return '$minutes 分钟';
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.outlineVariant),
      ),
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
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.value,
    this.subtitle,
    this.valueColor,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
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
              color: valueColor ?? scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主题选择行：有 [ThemeScope] 时可点击切换，没有时退化为只读展示。
class _ThemeRow extends StatelessWidget {
  const _ThemeRow();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ThemeController? controller = ThemeScope.maybeOf(context);
    final ThemeMode mode = controller?.mode ?? ThemeMode.system;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: controller == null ? null : () => _pick(context, controller),
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
              child: Icon(
                Icons.light_mode_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('主题', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    _hint(mode),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _label(mode),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (controller != null)
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  static void _pick(BuildContext context, ThemeController controller) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('主题'),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final ThemeMode mode in ThemeMode.values)
                ListTile(
                  title: Text(_label(mode)),
                  trailing: mode == controller.mode
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    unawaited(controller.setMode(mode));
                    Navigator.of(dialogContext).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _label(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
    }
  }

  static String _hint(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '深浅色由系统决定';
      case ThemeMode.light:
        return '始终使用浅色';
      case ThemeMode.dark:
        return '始终使用深色';
    }
  }
}
