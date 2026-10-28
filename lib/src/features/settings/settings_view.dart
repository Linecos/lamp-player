import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_version.dart';
import '../../common/common.dart';
import '../../rust/api/player.dart' as rust;
import '../../rust/api/scan.dart';
import '../../theme/app_theme.dart';
import '../player/equalizer.dart';
import '../player/shortcuts.dart';
import 'equalizer_page.dart';
import 'listening_stats_page.dart';
import 'listening_stats_repository.dart';
import 'theme_controller.dart';

/// 设置页骨架。
///
/// 展示曲库统计与引擎状态；「外观 → 主题」可切换并持久化。
/// 「添加音乐目录」由曲库页负责扫描，本页展示进度、结果与失败重试。
class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.trackCount,
    required this.engineAvailable,
    this.statsRepository,
    this.exclusive = false,
    this.exclusiveActive = false,
    this.switchingOutput = false,
    this.outputInfo = '',
    this.onExclusiveChanged,
    this.closeToTray = true,
    this.onCloseToTrayChanged,
    this.eqEnabled = false,
    this.eqGains = const <double>[],
    this.eqPresetName,
    this.eqCustomPresets = const <EqualizerPreset>[],
    this.onEqualizerChanged,
    this.onEqPresetsChanged,
    this.devices = const <rust.PlayerDevice>[],
    this.outputDevice = -1,
    this.onOutputDeviceChanged,
    this.replayGain = false,
    this.onReplayGainChanged,
    this.crossfadeSeconds = 0,
    this.onCrossfadeChanged,
    this.onShowShortcuts,
    this.shortcuts = kDefaultShortcuts,
    this.flowBackground = true,
    this.onFlowBackgroundChanged,
    this.scanning = false,
    this.folders = const <String>[],
    this.onAddFolder,
    this.onRescanFolder,
    this.onRemoveFolder,
    this.scanFolder,
    this.scanReport,
    this.scanError,
    this.onRetry,
    this.pruningMissing = false,
    this.prunedMissingCount,
    this.pruneMissingError,
    this.onPruneMissing,
    this.query = '',
    this.matcher,
    this.onClearSearch,
  });

  final int trackCount;
  final bool engineAvailable;

  /// 听歌统计的数据源；不传则统计页自己走 Rust，测试注入假实现
  final ListeningStatsRepository? statsRepository;

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

  /// 当前套用的预设名；null 表示手动调的自定义曲线
  final String? eqPresetName;

  /// 用户自存的预设（内置 5 套不在此列）
  final List<EqualizerPreset> eqCustomPresets;

  /// 均衡器变化：`(enabled, gains, presetName)`；为空表示当前不可操作
  final void Function(bool enabled, List<double> gains, String? presetName)?
  onEqualizerChanged;

  /// 自存预设变化
  final ValueChanged<List<EqualizerPreset>>? onEqPresetsChanged;

  /// 可选的输出设备；第一项由设置页自己补「系统默认」
  final List<rust.PlayerDevice> devices;

  /// 当前选中的输出设备索引（`-1` = 系统默认）
  final int outputDevice;

  /// 切换输出设备；为空表示当前不可操作
  final ValueChanged<int>? onOutputDeviceChanged;

  /// 是否按标签的 ReplayGain 统一响度
  final bool replayGain;

  /// 切换 ReplayGain；为空表示当前不可操作
  final ValueChanged<bool>? onReplayGainChanged;

  /// 换曲交叉淡变时长（秒）；0 关闭
  final double crossfadeSeconds;

  /// 调整淡变时长；为空表示当前不可操作
  final ValueChanged<double>? onCrossfadeChanged;

  /// 打开「快捷键一览」；不传时这一行禁用（测试 / 精简场景）
  final VoidCallback? onShowShortcuts;

  /// 当前键位表：仅用于一览展示，实际绑定由 `LibraryPage.shortcuts` 决定
  final List<ShortcutBinding> shortcuts;

  /// 正在播放页是否启用封面流光背景
  final bool flowBackground;
  final ValueChanged<bool>? onFlowBackgroundChanged;

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

  /// 正在清理「文件已不存在」的曲库记录
  final bool pruningMissing;

  /// 最近一次清理的条数；为 null 表示还没清理过
  final int? prunedMissingCount;

  /// 清理失败原因；为 null 表示没有待处理的失败
  final Object? pruneMissingError;

  /// 触发清理；为空表示当前不可操作
  final VoidCallback? onPruneMissing;

  /// 常驻搜索框的关键词：非空时只留命中的设置行
  final String query;

  /// 自定义匹配（曲库页传拼音匹配进来）；为空时按大小写无关的子串判断
  final bool Function(String text, String query)? matcher;

  /// 清空搜索；为空表示不提供「清除搜索」入口
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) {
    final String query = this.query.trim();
    final bool searching = query.isNotEmpty;
    final List<Widget> children = <Widget>[];

    // 一组设置 = 分区标题 + 卡片；整组都没命中就一起收起来
    void section(String label, List<Widget> rows) {
      final List<Widget> kept = _filterRows(rows, query);
      if (kept.isEmpty) {
        return;
      }
      children.add(_SectionLabel(label));
      children.add(_SettingsCard(children: kept));
    }

    section('音乐库', <Widget>[
      _InfoRow(
        icon: Icons.library_music_outlined,
        title: '曲目数量',
        value: '$trackCount 首',
      ),
      _ActionRow(
        icon: Icons.insights_outlined,
        title: '听歌统计',
        subtitle: '累计时长、播放次数排行与每日热力图',
        onTap: () => _openStats(context),
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
      _ActionRow(
        icon: Icons.cleaning_services_outlined,
        title: '清理缺失文件',
        subtitle: pruningMissing ? '正在检查曲库记录…' : '移除磁盘上已不存在的曲目记录，不会删除音频文件',
        onTap: pruningMissing ? null : onPruneMissing,
        trailing: pruningMissing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    ]);
    // 扫描 / 清理的进度与结果属于临时状态，搜索时让路
    if (!searching) {
      if (!pruningMissing &&
          pruneMissingError != null &&
          onPruneMissing != null) {
        children.add(
          ErrorRetry(
            title: '清理失败',
            error: pruneMissingError!,
            onRetry: onPruneMissing!,
          ),
        );
      }
      if (!pruningMissing &&
          pruneMissingError == null &&
          prunedMissingCount != null) {
        children.add(_PruneSummary(count: prunedMissingCount!));
      }
    }
    section('音乐目录', <Widget>[
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
    ]);
    if (!searching) {
      if (scanning && scanFolder != null) {
        children.add(_ScanProgress(folder: scanFolder!));
      }
      if (!scanning && scanError != null && onRetry != null) {
        children.add(
          ErrorRetry(title: '扫描失败', error: scanError!, onRetry: onRetry!),
        );
      }
      if (!scanning && scanError == null && scanReport != null) {
        children.add(
          _ScanSummary(report: scanReport!, folder: scanFolder ?? ''),
        );
      }
    }
    section('播放', <Widget>[
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
            ? (exclusiveActive ? '设备由本应用独占，系统混音器不再参与' : '设备不支持或被占用，当前仍走共享输出')
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
      _ChoiceRow<int>(
        icon: Icons.speaker_outlined,
        title: '输出设备',
        subtitle: exclusiveActive
            ? '独占模式下固定用系统默认设备，关掉独占后生效'
            : '共享输出使用哪块声卡；切换时曲目会重新打开',
        value: outputDevice,
        choices: <(int, String)>[
          (-1, '系统默认'),
          for (final rust.PlayerDevice device in devices)
            (device.index, device.name),
        ],
        onChanged: onOutputDeviceChanged,
        choiceKey: const ValueKey<String>('settings-output-device'),
      ),
      _SwitchRow(
        icon: Icons.balance,
        title: 'ReplayGain 响度归一',
        switchKey: const ValueKey<String>('settings-replay-gain-switch'),
        subtitle: replayGain
            ? '按标签或现场分析的增益统一各首歌的音量，专辑之间不再忽大忽小'
            : '关闭时按原始音量播放（切换后从下一首起生效）',
        value: replayGain,
        onChanged: onReplayGainChanged,
      ),
      _ChoiceRow<int>(
        icon: Icons.compare_arrows,
        title: '换曲淡入淡出',
        subtitle: exclusiveActive ? '独占模式下只做新曲淡入（不重叠）' : '共享模式下新旧曲重叠交叉淡变，避免硬切',
        value: crossfadeSeconds.round(),
        choices: const <(int, String)>[
          (0, '关闭'),
          (1, '1 秒'),
          (2, '2 秒'),
          (4, '4 秒'),
          (6, '6 秒'),
          (8, '8 秒'),
        ],
        onChanged: onCrossfadeChanged == null
            ? null
            : (int seconds) => onCrossfadeChanged!(seconds.toDouble()),
        choiceKey: const ValueKey<String>('settings-crossfade'),
      ),
      _ActionRow(
        icon: Icons.keyboard_outlined,
        title: '快捷键',
        subtitle: '点一行再按组合键即可改键，也可以恢复默认',
        onTap: onShowShortcuts,
      ),
      _SwitchRow(
        icon: Icons.minimize,
        title: '关闭窗口时留在托盘',
        switchKey: const ValueKey<String>('settings-close-to-tray-switch'),
        subtitle: closeToTray ? '点 × 只隐藏窗口，音乐继续播放；从托盘菜单退出' : '点 × 直接退出应用',
        value: closeToTray,
        onChanged: onCloseToTrayChanged,
      ),
      _ActionRow(
        icon: Icons.equalizer,
        title: '均衡器',
        subtitle: eqEnabled
            ? '已开启 · ${eqPresetName ?? '自定义曲线'}'
            : '10 段参数均衡，可存多套预设',
        onTap: onEqualizerChanged == null
            ? null
            : () => _openEqualizer(context),
      ),
    ]);
    section('外观', <Widget>[
      const _ThemeRow(),
      const _AccentColorRow(),
      _SwitchRow(
        icon: Icons.auto_awesome,
        title: '动态流光背景',
        switchKey: const ValueKey<String>('settings-flow-background-switch'),
        subtitle: flowBackground ? '正在播放页跟随封面颜色缓慢流动' : '已关闭流光，只保留静态封面取色背景',
        value: flowBackground,
        onChanged: onFlowBackgroundChanged,
      ),
    ]);
    section('关于', <Widget>[
      _InfoRow(
        icon: Icons.info_outline,
        title: 'Lamp Player',
        subtitle: 'Flutter + Rust + BASS',
        value: appVersion,
      ),
    ]);

    if (children.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有匹配的设置项',
        message: '试试「主题」「输出设备」「均衡器」这类词，或清除搜索看全部设置。',
        action: onClearSearch == null
            ? null
            : TextButton(onPressed: onClearSearch, child: const Text('清除搜索')),
      );
    }

    return ListView(
      // 右侧留一条滚动条槽：桌面端滚动条浮在视口右缘，不留空会压住卡片边
      padding: const EdgeInsets.only(top: 4, right: 12, bottom: 16),
      children: children,
    );
  }

  /// 搜索时只留命中的行；没命中的行（含状态类小组件）一起收起来
  List<Widget> _filterRows(List<Widget> rows, String query) {
    if (query.isEmpty) {
      return rows;
    }
    final List<Widget> kept = <Widget>[];
    for (final Widget row in rows) {
      if (row is! _Searchable) {
        continue;
      }
      final _Searchable searchable = row as _Searchable;
      if (_hit(searchable.searchText, query)) {
        kept.add(row);
      }
    }
    return kept;
  }

  bool _hit(String text, String query) {
    final bool Function(String text, String query)? custom = matcher;
    if (custom != null) {
      return custom(text, query);
    }
    return text.toLowerCase().contains(query.toLowerCase());
  }

  void _openStats(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListeningStatsPage(repository: statsRepository),
      ),
    );
  }

  void _openEqualizer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EqualizerPage(
          enabled: eqEnabled,
          gains: eqGains,
          presetName: eqPresetName,
          customPresets: eqCustomPresets,
          onChanged: onEqualizerChanged,
          onCustomPresetsChanged: onEqPresetsChanged,
        ),
      ),
    );
  }
}

/// 设置行的搜索索引：常驻搜索框按 [searchText] 过滤本页的行。
///
/// 索引直接取行自己展示的标题 / 副标题，改文案时不会漏更新。
abstract interface class _Searchable {
  String get searchText;
}

/// 一行「标题 + 下拉选择」，用于输出设备、淡变时长这类多选一设置。
class _ChoiceRow<T> extends StatefulWidget implements _Searchable {
  const _ChoiceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.choiceKey,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final T value;
  final List<(T, String)> choices;
  final ValueChanged<T>? onChanged;
  final Key? choiceKey;

  @override
  String get searchText => '$title $subtitle';

  @override
  State<_ChoiceRow<T>> createState() => _ChoiceRowState<T>();
}

class _ChoiceRowState<T> extends State<_ChoiceRow<T>> {
  /// 选完立刻收掉焦点：DropdownButton 会一直挂着高亮底色，看着像没生效
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 当前值可能已经不在列表里（设备被拔掉）：退到第一项，别让 Dropdown 断言失败
    final bool known = widget.choices.any(
      ((T, String) item) => item.$1 == widget.value,
    );
    final T current = known ? widget.value : widget.choices.first.$1;

    // 与 _SwitchRow / _InfoRow 保持同一套版式：40×40 圆形底 + 16 间距，
    // 否则这一行的图标既不圆、左边缘也对不齐旁边的行。
    return Padding(
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
            child: Icon(widget.icon, size: 20, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(widget.title, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  widget.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 设备名可能很长（"扬声器 (Realtek High Definition Audio)"）：
          // 限宽 + isExpanded 让它在框里截断，而不是把这一行撑破
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: DecoratedBox(
              // 选择框自带一层底：与左侧图标同色，文字才不会看着浮在卡片上
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                // 上下各 6：让胶囊和左侧 40 的图标圈差不多高
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                child: DropdownButton<T>(
                  key: widget.choiceKey,
                  focusNode: _focus,
                  value: current,
                  isDense: true,
                  isExpanded: true,
                  iconSize: 20,
                  iconEnabledColor: scheme.onSurfaceVariant,
                  // 选完不留高亮：焦点色透明，底色永远是上面那一层
                  focusColor: Colors.transparent,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(12),
                  dropdownColor: scheme.surfaceContainerHighest,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                  onChanged: widget.onChanged == null
                      ? null
                      : (T? next) {
                          _focus.unfocus();
                          if (next != null) {
                            widget.onChanged!(next);
                          }
                        },
                  items: <DropdownMenuItem<T>>[
                    for (final (T value, String label) item in widget.choices)
                      DropdownMenuItem<T>(
                        value: item.$1,
                        child: Text(
                          item.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    // 水平不缩进：分组标题要和下面的卡片左边缘对齐（卡片自身有内边距）
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
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

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

/// 可点击的操作行，样式与只读信息行保持一致。
/// 带开关的设置行
class _SwitchRow extends StatelessWidget implements _Searchable {
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
  String get searchText => '$title $subtitle';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      hoverColor: scheme.surfaceContainerHigh,
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
class _OutputRow extends StatelessWidget implements _Searchable {
  const _OutputRow({
    required this.info,
    required this.active,
    required this.available,
  });

  final String info;
  final bool active;
  final bool available;

  @override
  String get searchText => '输出格式 采样率 声道 $info';

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

class _ActionRow extends StatelessWidget implements _Searchable {
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

class _InfoRow extends StatelessWidget implements _Searchable {
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
  String get searchText => '$title ${subtitle ?? ''} $value';

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
class _ThemeRow extends StatelessWidget implements _Searchable {
  const _ThemeRow();

  @override
  String get searchText => '主题 浅色 深色 跟随系统 外观';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ThemeController? controller = ThemeScope.maybeOf(context);
    final ThemeMode mode = controller?.mode ?? ThemeMode.system;

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: controller == null ? null : () => _pick(context, controller),
      hoverColor: scheme.surfaceContainerHigh,
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

/// 强调色选择行：跟随系统强调色（动态取色）或预设色板。
///
/// 没有 [ThemeScope] 时退化为只读展示（如部分测试环境）。
class _AccentColorRow extends StatelessWidget implements _Searchable {
  const _AccentColorRow();

  @override
  String get searchText => '强调色 配色 调色板 风格 高对比 外观';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final ThemeController? controller = ThemeScope.maybeOf(context);
    final Color? seed = controller?.seedColor;
    final Color effective = controller?.effectiveSeed ?? AppTheme.defaultSeed;

    final String subtitle;
    if (seed != null) {
      subtitle = '自定义颜色';
    } else if (controller?.systemAccent != null) {
      subtitle = '跟随系统强调色，随 Windows 个性化变化';
    } else {
      subtitle = '读取不到系统强调色，暂用默认';
    }

    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: controller == null ? null : () => _pick(context, controller),
      hoverColor: scheme.surfaceContainerHigh,
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
                Icons.palette_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('强调色', style: theme.textTheme.bodyLarge),
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
            // 当前生效色的小圆点，一眼看出现在用的哪个色
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: effective,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant, width: 1),
              ),
            ),
            if (controller != null)
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  /// 配色选择弹窗：调色板风格下拉 + 四色调圆形色卡网格。
  ///
  /// 所有选择即时生效（写回 [ThemeController]），弹窗保持打开供继续预览，
  /// 点「完成」关闭。风格切换时色卡预览跟着变——预览与主题用同一个
  /// [AppTheme.schemeOf]，所见即所得。
  static void _pick(BuildContext context, ThemeController controller) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          // 读取 scope 注册依赖：控制器变化（选色 / 切风格）时弹窗内容跟着刷新
          final ThemeController current = ThemeScope.of(dialogContext);
          return AlertDialog(
            title: const Text('配色'),
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          '调色板风格',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<DynamicSchemeVariant>(
                            key: const ValueKey<String>('variant-dropdown'),
                            isExpanded: true,
                            value: current.schemeVariant,
                            items: <DropdownMenuItem<DynamicSchemeVariant>>[
                              for (final (
                                    DynamicSchemeVariant variant,
                                    String label,
                                  )
                                  in AppTheme.variantOptions)
                                DropdownMenuItem<DynamicSchemeVariant>(
                                  value: variant,
                                  child: Text(label),
                                ),
                            ],
                            onChanged: (DynamicSchemeVariant? variant) {
                              if (variant != null) {
                                unawaited(current.setSchemeVariant(variant));
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          '高对比',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Switch(
                          key: const ValueKey<String>(
                            'variant-high-contrast-switch',
                          ),
                          value: current.highContrast,
                          onChanged: (bool value) =>
                              unawaited(current.setHighContrast(value)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _tipLabel('强调色 · 首格跟随系统'),
                    const SizedBox(height: 8),
                    GridView.count(
                      crossAxisCount: 4,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.0,
                      children: <Widget>[
                        _SeedCard(
                          key: const ValueKey<String>('seed-card-system'),
                          selected: current.seedColor == null,
                          onTap: () => unawaited(current.setSeedColor(null)),
                          systemIcon: current.systemAccent == null
                              ? Icons.auto_awesome_motion_outlined
                              : Icons.auto_awesome_outlined,
                        ),
                        for (final Color color in AppTheme.presetSeeds)
                          _SeedCard(
                            key: ValueKey<String>(
                              'seed-card-${color.toARGB32()}',
                            ),
                            selected: current.seedColor == color,
                            onTap: () => unawaited(current.setSeedColor(color)),
                            preview: AppTheme.schemeOf(
                              color,
                              Brightness.light,
                              current.schemeVariant,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _tipLabel(String text) {
    return Builder(
      builder: (BuildContext context) => Text(
        text,
        style: Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

/// 色卡：圆角方形容器 + 四色调圆形预览 + 选中角标（右上角对勾圆）。
///
/// 底色与边框不能省：M3 弹窗背景就是 `surfaceContainerHigh`，
/// 未选中卡再用同色就完全隐形了。
class _SeedCard extends StatelessWidget {
  const _SeedCard({
    super.key,
    required this.selected,
    required this.onTap,
    this.preview,
    this.systemIcon,
  });

  final bool selected;
  final VoidCallback onTap;

  /// 非 null 时按它画四象限预览；null 时画系统强调色格（图标）。
  final ColorScheme? preview;
  final IconData? systemIcon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius radius = BorderRadius.circular(16);
    // 底色交给 Material，边框留给 Container：否则 InkWell 的水波纹会被盖住。
    return Material(
      color: selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        hoverColor: scheme.onSurface.withValues(alpha: 0.08),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: preview != null
                      ? _ToneQuad(
                          colors: <Color>[
                            preview!.primary,
                            preview!.inversePrimary,
                            preview!.primaryContainer,
                            preview!.secondary,
                          ],
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLowest,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            systemIcon ?? Icons.auto_awesome_outlined,
                            size: 22,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                ),
                if (selected)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                      child: Icon(
                        Icons.check,
                        size: 10,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 四象限圆形：直接画四个矩形再按圆形裁剪。
///
/// 不要改回 `ClipOval` + 嵌套 `Row`/`Column` 的写法——实测那组结构
/// 在实机上整批不渲染（布局尺寸正常但画不出来），CustomPaint 无此问题。
class _ToneQuad extends StatelessWidget {
  const _ToneQuad({required this.colors});

  /// 左上 / 右上 / 左下 / 右下
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ToneQuadPainter(colors));
  }
}

class _ToneQuadPainter extends CustomPainter {
  _ToneQuadPainter(this.colors);

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.clipPath(Path()..addOval(rect));
    final double halfW = size.width / 2;
    final double halfH = size.height / 2;
    final Paint paint = Paint();
    canvas.drawRect(Offset.zero & Size(halfW, halfH), paint..color = colors[0]);
    canvas.drawRect(
      Offset(halfW, 0) & Size(halfW, halfH),
      paint..color = colors[1],
    );
    canvas.drawRect(
      Offset(0, halfH) & Size(halfW, halfH),
      paint..color = colors[2],
    );
    canvas.drawRect(
      Offset(halfW, halfH) & Size(halfW, halfH),
      paint..color = colors[3],
    );
  }

  @override
  bool shouldRepaint(_ToneQuadPainter oldDelegate) =>
      oldDelegate.colors != colors;
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

/// 清理缺失文件的结果摘要
class _PruneSummary extends StatelessWidget {
  const _PruneSummary({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              count > 0 ? '已清理 $count 条缺失记录' : '没有发现缺失文件',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 还没添加任何目录时的占位提示
class _EmptyFolders extends StatelessWidget implements _Searchable {
  const _EmptyFolders();

  @override
  String get searchText => '音乐目录 还没有添加目录';

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
class _FolderRow extends StatelessWidget implements _Searchable {
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
  String get searchText => '音乐目录 $folder';

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
