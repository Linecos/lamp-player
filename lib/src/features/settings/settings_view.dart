import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/common.dart';
import '../../rust/api/scan.dart';
import '../player/equalizer.dart';
import 'theme_controller.dart';

/// 设置页骨架。
///
/// 展示曲库统计与引擎状态；「外观 → 主题」可切换并持久化。
/// 「添加音乐目录」由曲库页负责扫描，本页展示进度、结果与失败重试。
class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.trackCount,
    required this.totalDurationSecs,
    required this.engineAvailable,
    this.exclusive = false,
    this.exclusiveActive = false,
    this.switchingOutput = false,
    this.outputInfo = '',
    this.onExclusiveChanged,
    this.closeToTray = true,
    this.onCloseToTrayChanged,
    this.eqEnabled = false,
    this.eqGains = const <double>[],
    this.onEqualizerChanged,
    this.scanning = false,
    this.folders = const <String>[],
    this.onAddFolder,
    this.onRescanFolder,
    this.onRemoveFolder,
    this.scanFolder,
    this.scanReport,
    this.scanError,
    this.onRetry,
  });

  final int trackCount;
  final double totalDurationSecs;
  final bool engineAvailable;

  /// 是否请求 WASAPI 独占输出（用户偏好）
  final bool exclusive;

  /// 引擎当前是否真的在独占（设备不支持时会是 false）
  final bool exclusiveActive;

  /// 正在切换输出，期间禁用开关
  final bool switchingOutput;

  /// 引擎给出的输出描述，例如「WASAPI 独占 · 48000 Hz · 2 声道」
  final String outputInfo;

  /// 切换独占开关；为空表示当前不可操作
  final ValueChanged<bool>? onExclusiveChanged;

  /// 关闭窗口时是否留在托盘（默认开启）
  final bool closeToTray;

  /// 切换「关闭到托盘」；为空表示当前不可操作（测试或未注入 AppLifecycle）
  final ValueChanged<bool>? onCloseToTrayChanged;

  /// 均衡器开关与各段增益（dB）
  final bool eqEnabled;
  final List<double> eqGains;

  /// 均衡器变化：`(enabled, gains)`；为空表示当前不可操作
  final void Function(bool enabled, List<double> gains)? onEqualizerChanged;

  final bool scanning;

  /// 已添加的音乐目录（按添加顺序）
  final List<String> folders;

  final VoidCallback? onAddFolder;

  /// 重新扫描某个目录；为空表示当前不可操作（例如正在扫描）
  final ValueChanged<String>? onRescanFolder;

  /// 从列表移除某个目录（不删除已入库曲目）
  final ValueChanged<String>? onRemoveFolder;

  /// 当前（或最近一次）扫描的目录，用于进度与结果展示。
  final String? scanFolder;

  /// 本次扫描结果；为 null 表示还没有成功扫描过。
  final ScanReport? scanReport;

  /// 本次扫描失败原因；为 null 表示没有待处理的失败。
  final Object? scanError;

  /// 重新扫描 [scanFolder]；为空时只展示错误，不提供重试。
  final VoidCallback? onRetry;

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
            _ActionRow(
              icon: Icons.create_new_folder_outlined,
              title: '添加音乐目录',
              subtitle: scanning ? '正在扫描并入库…' : '递归扫描子目录，按改动增量入库',
              onTap: scanning ? null : onAddFolder,
              trailing: scanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
          ],
        ),
        _SectionLabel('音乐目录'),
        _SettingsCard(
          children: <Widget>[
            if (folders.isEmpty)
              const _EmptyFolders()
            else
              for (final String folder in folders)
                _FolderRow(
                  folder: folder,
                  scanning: scanning && folder == scanFolder,
                  onRescan: onRescanFolder == null
                      ? null
                      : () => onRescanFolder!(folder),
                  onRemove: onRemoveFolder == null
                      ? null
                      : () => onRemoveFolder!(folder),
                ),
          ],
        ),
        if (scanning && scanFolder != null) _ScanProgress(folder: scanFolder!),
        if (!scanning && scanError != null && onRetry != null)
          ErrorRetry(title: '扫描失败', error: scanError!, onRetry: onRetry!),
        if (!scanning && scanError == null && scanReport != null)
          _ScanSummary(report: scanReport!, folder: scanFolder ?? ''),
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
            _SwitchRow(
              icon: Icons.surround_sound,
              title: '独占输出（WASAPI）',
              switchKey: const ValueKey<String>('settings-exclusive-switch'),
              subtitle: exclusive
                  ? (exclusiveActive
                        ? '设备由本应用独占，系统混音器不再参与'
                        : '设备不支持或被占用，当前仍走共享输出')
                  : '开启后绕过系统混音器；切换时会短暂中断播放',
              value: exclusive,
              busy: switchingOutput,
              onChanged: onExclusiveChanged,
            ),
            if (outputInfo.isNotEmpty)
              _OutputRow(
                info: outputInfo,
                active: exclusiveActive,
                available: engineAvailable,
              ),
            _SwitchRow(
              icon: Icons.minimize,
              title: '关闭窗口时留在托盘',
              switchKey: const ValueKey<String>(
                'settings-close-to-tray-switch',
              ),
              subtitle: closeToTray ? '点 × 只隐藏窗口，音乐继续播放；从托盘菜单退出' : '点 × 直接退出应用',
              value: closeToTray,
              onChanged: onCloseToTrayChanged,
            ),
            _EqualizerPanel(
              enabled: eqEnabled,
              gains: eqGains,
              onChanged: onEqualizerChanged,
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

  String _formatTotal(double seconds) {
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

/// 可点击的操作行，样式与只读信息行保持一致。
/// 带开关的设置行
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    this.busy = false,
    this.onChanged,
    this.switchKey,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool busy;
  final ValueChanged<bool>? onChanged;

  /// 给 Switch 本身挂 key：设置页里不止一个开关，测试按 key 定位
  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onChanged == null || busy ? null : () => onChanged!(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Switch(key: switchKey, value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// 输出详情：引擎实际用的模式与格式
class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.info,
    required this.active,
    required this.available,
  });

  final String info;
  final bool active;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color dot = !available
        ? scheme.outline
        : (active ? scheme.primary : scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.tune, size: 20, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('当前输出', style: theme.textTheme.bodyLarge),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  info,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
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

class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.folder});

  final String folder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '正在扫描 $folder',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanSummary extends StatelessWidget {
  const _ScanSummary({required this.report, required this.folder});

  final ScanReport report;
  final String folder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<String> parts = <String>[
      // upserted 是「入库或更新」的条数，不是纯新增
      '入库 ${report.upserted} 首',
      if (report.unchanged > 0) '跳过 ${report.unchanged} 首',
      if (report.pruned > 0) '清理 ${report.pruned} 条',
      if (report.failed > 0) '失败 ${report.failed} 个',
      if (report.walkErrors > 0) '无法读取 ${report.walkErrors} 个',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.check_circle_outline, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                '扫描完成',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(parts.join(' · '), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 2),
          Text(
            folder,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '耗时 ${(report.elapsedMs.toInt() / 1000).toStringAsFixed(1)} 秒',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 还没添加任何目录时的占位提示
class _EmptyFolders extends StatelessWidget {
  const _EmptyFolders();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.folder_off_outlined,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '还没有添加音乐目录，先在上方添加一个',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个目录：路径 + 重新扫描 / 移除
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.scanning,
    this.onRescan,
    this.onRemove,
  });

  final String folder;
  final bool scanning;
  final VoidCallback? onRescan;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              Icons.folder_open_outlined,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  scanning ? '正在扫描…' : '已添加',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              onPressed: onRescan,
              tooltip: '重新扫描',
              iconSize: 20,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            onPressed: onRemove,
            tooltip: '从列表移除',
            iconSize: 20,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

/// 10 段均衡器面板。
///
/// 推子拖动只改本地状态，松手（`onChangeEnd`）才下发——拖动每一帧都走一次
/// FFI 会卡顿，而且引擎侧要重建 10 个滤波器。
class _EqualizerPanel extends StatefulWidget {
  const _EqualizerPanel({
    required this.enabled,
    required this.gains,
    this.onChanged,
  });

  final bool enabled;
  final List<double> gains;
  final void Function(bool enabled, List<double> gains)? onChanged;

  @override
  State<_EqualizerPanel> createState() => _EqualizerPanelState();
}

class _EqualizerPanelState extends State<_EqualizerPanel> {
  late List<double> _gains = normalizeEqGains(widget.gains);

  @override
  void didUpdateWidget(_EqualizerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gains != widget.gains) {
      _gains = normalizeEqGains(widget.gains);
    }
  }

  void _commit() {
    widget.onChanged?.call(widget.enabled, List<double>.of(_gains));
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SwitchRow(
          icon: Icons.equalizer,
          title: '均衡器',
          switchKey: const ValueKey<String>('settings-equalizer-switch'),
          subtitle: enabled ? '10 段参数均衡，0 dB 为不改动' : '开启后可按频段调整音量',
          value: enabled,
          onChanged: widget.onChanged == null
              ? null
              : (bool value) => widget.onChanged!(value, _gains),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(
              children: <Widget>[
                for (int index = 0; index < _gains.length; index += 1)
                  _bandRow(context, index),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: isEqFlat(_gains)
                        ? null
                        : () {
                            setState(
                              () => _gains = normalizeEqGains(const <double>[]),
                            );
                            _commit();
                          },
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('全部归零'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bandRow(BuildContext context, int index) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double gain = _gains[index];
    final int rounded = gain.round();

    return Row(
      children: <Widget>[
        SizedBox(
          width: 48,
          child: Text(
            equalizerBandLabels[index],
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            key: ValueKey<String>('eq-band-$index'),
            value: gain,
            min: -equalizerMaxGain,
            max: equalizerMaxGain,
            divisions: (equalizerMaxGain * 2).round(),
            onChanged: (double value) => setState(() => _gains[index] = value),
            onChangeEnd: (_) => _commit(),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            rounded == 0
                ? '0 dB'
                : (rounded > 0 ? '+$rounded dB' : '$rounded dB'),
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
