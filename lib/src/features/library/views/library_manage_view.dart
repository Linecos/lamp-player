import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_toast.dart';
import '../../../common/common.dart';
import '../../../rust/api/db.dart' as db;
import '../../../rust/api/model.dart' show Track;
import '../../../rust/api/scan.dart';
import '../library_revision.dart';

/// 音乐库分区的主体。
///
/// 这一页是「看库」而不是「改设置」：顶部四个指标、中间每个目录一张封面
/// 画廊卡、底部三块瓷贴分别通往统计 / 隐藏歌曲 / 清理缺失。管理动作都收在
/// 各自的卡片里，不再排成设置那样的整行条目。
class LibraryManageView extends StatelessWidget {
  const LibraryManageView({
    super.key,
    required this.tracks,
    this.onOpenStats,
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
    this.bottomPadding = 16,
    this.query = '',
  });

  /// 全库曲目：目录卡的数量、时长与封面拼贴都从这份数据算出来
  final List<Track> tracks;

  /// 打开「听歌统计」子页
  final VoidCallback? onOpenStats;

  final bool scanning;

  /// 已添加的音乐目录（按添加顺序）
  final List<String> folders;

  final VoidCallback? onAddFolder;

  /// 重新扫描某个目录；为空表示当前不可操作（例如正在扫描）
  final ValueChanged<String>? onRescanFolder;

  /// 从列表移除某个目录（不删除已入库曲目）
  final ValueChanged<String>? onRemoveFolder;

  /// 当前（或最近一次）扫描的目录
  final String? scanFolder;

  /// 本次扫描结果；为 null 表示还没有成功扫描过
  final ScanReport? scanReport;

  /// 本次扫描失败原因
  final Object? scanError;

  /// 重新扫描 [scanFolder]
  final VoidCallback? onRetry;

  /// 正在清理「文件已不存在」的曲库记录
  final bool pruningMissing;

  /// 最近一次清理的条数；为 null 表示还没清理过
  final int? prunedMissingCount;

  /// 清理失败原因
  final Object? pruneMissingError;

  /// 触发清理；为空表示当前不可操作
  final VoidCallback? onPruneMissing;

  /// 列表底部留白，给底部播放岛让位
  final double bottomPadding;

  /// 目录块与隐藏歌曲块的固定高度（块内滚动，不随内容变长）。
  ///
  /// 251 逻辑像素：本机 Windows 是 125% 缩放（AppliedDPI=120），屏幕标尺量到的
  /// 物理高度约 314。别按 314 写，那在标尺上会变成 392。
  static const double _panelHeight = 251;

  /// 常驻搜索框的关键词：非空时只留路径命中的目录
  final String query;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String query = this.query.trim().toLowerCase();
    final List<String> visible = query.isEmpty
        ? folders
        : folders
              .where((String folder) => folder.toLowerCase().contains(query))
              .toList(growable: false);

    return ListView(
      padding: EdgeInsets.only(top: 4, right: 12, bottom: bottomPadding),
      children: <Widget>[
        Row(
          children: <Widget>[
            _Metric(
              label: '曲目',
              value: '${tracks.length}',
              valueKey: const ValueKey<String>('library-count-tracks'),
            ),
            const SizedBox(width: 10),
            _Metric(
              label: '专辑',
              value: '${_albumCount(tracks)}',
              valueKey: const ValueKey<String>('library-count-albums'),
            ),
            const SizedBox(width: 10),
            _Metric(
              label: '艺术家',
              value: '${_artistCount(tracks)}',
              valueKey: const ValueKey<String>('library-count-artists'),
            ),
            const SizedBox(width: 10),
            _Metric(
              label: '总时长',
              value: '${_formatHours(tracks)} 小时',
              valueKey: const ValueKey<String>('library-count-hours'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          // 两栏高度固定：目录和隐藏歌曲各自在块内滚动，页面不让它们撑长
          height: _panelHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _Panel(
                  key: const ValueKey<String>('library-panel-folders'),
                  title: '音乐目录',
                  count: '${folders.length} 个',
                  child: _buildFolders(context, visible),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Panel(
                  key: const ValueKey<String>('library-panel-hidden'),
                  title: '被隐藏的歌曲',
                  child: const _HiddenTracksPanel(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 扫描结果 / 失败重试：一次性的过程反馈，贴在目录块下方
        if (scanning && scanFolder != null) ...<Widget>[
          _ScanProgress(folder: scanFolder!),
          const SizedBox(height: 10),
        ],
        if (!scanning && scanError != null && onRetry != null) ...<Widget>[
          ErrorRetry(title: '扫描失败', error: scanError!, onRetry: onRetry!),
          const SizedBox(height: 10),
        ],
        if (!scanning && scanError == null && scanReport != null) ...<Widget>[
          _ScanSummary(report: scanReport!, folder: scanFolder ?? ''),
          const SizedBox(height: 10),
        ],

        const SizedBox(height: 18),
        _IconTile(
          key: const ValueKey<String>('library-open-stats'),
          // material-symbols:bar-chart-4-bars 没有内置字形：四柱 + 基线，自绘
          icon: _BarChart4Icon(size: 20, color: scheme.onSurfaceVariant),
          title: '听歌统计',
          caption: '累计时长与次数排行',
          onTap: onOpenStats,
        ),
        const SizedBox(height: 10),
        _IconTile(
          key: const ValueKey<String>('library-prune-missing'),
          icon: Icon(
            Icons.delete_sweep_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          title: '清理缺失文件',
          caption: pruningMissing
              ? '正在检查…'
              : prunedMissingCount == null
              ? '还没检查过'
              : prunedMissingCount == 0
              ? '没有发现缺失文件'
              : '已清理 $prunedMissingCount 条',
          busy: pruningMissing,
          onRun: pruningMissing ? null : onPruneMissing,
        ),
        if (!pruningMissing &&
            pruneMissingError != null &&
            onPruneMissing != null) ...<Widget>[
          const SizedBox(height: 10),
          ErrorRetry(
            title: '清理失败',
            error: pruneMissingError!,
            onRetry: onPruneMissing!,
          ),
        ],
      ],
    );
  }

  /// 目录块的内容：空态、搜索结果空态、或一列目录行
  Widget _buildFolders(BuildContext context, List<String> visible) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    if (folders.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          Text(
            '还没有添加音乐目录，先在上方添加一个',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: scanning ? null : onAddFolder,
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: const Text('添加音乐目录'),
            ),
          ),
        ],
      );
    }
    if (visible.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          Text(
            '没有匹配的音乐目录',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        for (int i = 0; i < visible.length; i += 1) ...<Widget>[
          if (i > 0)
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          _FolderRow(
            folder: visible[i],
            count: tracks
                .where((Track track) => _inFolder(track.path, visible[i]))
                .length,
            scanning: scanning && visible[i] == scanFolder,
            onRescan: onRescanFolder == null || scanning
                ? null
                : () => onRescanFolder!(visible[i]),
            onRemove: onRemoveFolder == null || scanning
                ? null
                : () => onRemoveFolder!(visible[i]),
          ),
        ],
      ],
    );
  }
}

/// [path] 是否落在 [folder] 里
bool _inFolder(String path, String folder) {
  String norm(String value) => value.replaceAll('/', r'\').toLowerCase();
  final String target = norm(folder).replaceAll(RegExp(r'\\+$'), '');
  final String source = norm(path);
  return source == target || source.startsWith('$target\\');
}

int _albumCount(List<Track> tracks) {
  final Set<String> keys = <String>{};
  for (final Track track in tracks) {
    keys.add('${track.album ?? ''}|${track.artist ?? ''}');
  }
  return keys.length;
}

int _artistCount(List<Track> tracks) {
  final Set<String> names = <String>{};
  for (final Track track in tracks) {
    final String? artist = track.artist;
    if (artist != null && artist.isNotEmpty) {
      names.add(artist);
    }
  }
  return names.length;
}

String _formatHours(List<Track> tracks) {
  double seconds = 0;
  for (final Track track in tracks) {
    seconds += track.durationSecs;
  }
  final double hours = seconds / 3600;
  return hours >= 100 ? '${hours.round()}' : hours.toStringAsFixed(1);
}

/// 顶部一个指标
class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              key: valueKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页面上的一个块：标题 + 右上角计数 + 内容
class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.title,
    required this.child,
    this.count,
  });

  final String title;
  final String? count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              if (count != null)
                Text(
                  count!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 块内的一行目录：文件夹图标 + 路径 / 曲目数 + 重新扫描 / 移除
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.count,
    required this.scanning,
    this.onRescan,
    this.onRemove,
  });

  final String folder;
  final int count;
  final bool scanning;
  final VoidCallback? onRescan;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.folder_open_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
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
                const SizedBox(height: 1),
                Text(
                  scanning ? '正在扫描…' : '$count 首',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scanning ? scheme.primary : scheme.outline,
                  ),
                ),
              ],
            ),
          ),
          if (scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              onPressed: onRescan,
              tooltip: '重新扫描',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            onPressed: onRemove,
            tooltip: '从列表移除',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

/// 块内的隐藏歌曲列表：就近展示，恢复一键完成，多了再走弹窗
class _HiddenTracksPanel extends StatefulWidget {
  const _HiddenTracksPanel();

  @override
  State<_HiddenTracksPanel> createState() => _HiddenTracksPanelState();
}

class _HiddenTracksPanelState extends State<_HiddenTracksPanel> {
  List<db.HiddenTrack>? _items;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<db.HiddenTrack> items = await db.hiddenTracks();
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = ErrorRetry.describe(error);
        _loading = false;
      });
    }
  }

  Future<void> _restore(db.HiddenTrack track) async {
    try {
      await db.unhideTracks(paths: <String>[track.path]);
      markLibraryChanged();
      if (!mounted) {
        return;
      }
      AppToast.show(context, '已恢复：${track.title}');
      await _load();
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppToast.show(context, '恢复失败：${ErrorRetry.describe(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? hint = theme.textTheme.bodySmall?.copyWith(
      color: scheme.outline,
    );

    if (_loading) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('读取中…', style: hint),
      );
    }
    final String? error = _error;
    if (error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('读取失败：$error', style: hint, maxLines: 3),
      );
    }
    final List<db.HiddenTrack> items = _items ?? const <db.HiddenTrack>[];
    if (items.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('没有被隐藏的歌曲', style: hint),
      );
    }

    // 块内自己滚动：条数再多也只是滚，不再有「查看全部」
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final db.HiddenTrack track = items[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: <Widget>[
              Icon(Icons.music_note_outlined, size: 16, color: scheme.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (track.artist.isNotEmpty)
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: hint,
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => unawaited(_restore(track)),
                tooltip: '恢复',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.undo),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 与目录卡同构的一行：圆形图标 + 标题 / 说明 + 右侧的进入箭头或运行按钮。
///
/// 传 [onRun] 的是「直接执行」类（清理缺失），整行不可点，只认按钮；
/// 其余整行可点，悬停 / 聚焦时底色抬一档、标题与箭头转成强调色。
class _IconTile extends StatefulWidget {
  const _IconTile({
    super.key,
    required this.icon,
    this.title,
    required this.caption,
    this.onTap,
    this.onRun,
    this.busy = false,
  });

  final Widget icon;
  final String? title;
  final String caption;
  final VoidCallback? onTap;
  final VoidCallback? onRun;
  final bool busy;

  @override
  State<_IconTile> createState() => _IconTileState();
}

class _IconTileState extends State<_IconTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool action = widget.onRun != null || widget.busy;
    final bool active = !action && widget.onTap != null;
    final bool lit = active && (_hovered || _focused);

    return Material(
      color: lit ? scheme.surfaceContainerHigh : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: lit ? scheme.outline : scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: active ? widget.onTap : null,
        onHover: (bool value) => setState(() => _hovered = value),
        onFocusChange: (bool value) => setState(() => _focused = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: widget.icon,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (widget.title != null) ...<Widget>[
                      Text(
                        widget.title!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: lit ? scheme.primary : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      widget.caption,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: lit ? scheme.primary : scheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (action)
                widget.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : InkWell(
                        onTap: widget.onRun,
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: widget.onRun == null
                                  ? scheme.outlineVariant
                                  : scheme.outline,
                            ),
                          ),
                          child: Text(
                            '运行',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: widget.onRun == null
                                  ? scheme.outline
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
              else
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: lit ? scheme.primary : scheme.outline,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.folder});

  final String folder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
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
                color: theme.colorScheme.outline,
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
      padding: const EdgeInsets.symmetric(horizontal: 8),
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
            '$folder · 耗时 ${(report.elapsedMs.toInt() / 1000).toStringAsFixed(1)} 秒',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 四柱柱状图（对齐 material-symbols:bar-chart-4-bars）。
///
/// 内置的 `bar_chart` 只有三根柱子、也没有基线，这里按同一比例自绘。
/// 注意：外层圆形底给的是 40×40 紧约束，**不能按 layout 尺寸缩放**——
/// 字形大小只认传入的 [size]，剩余空间居中留白，否则会比别的图标大一圈。
class _BarChart4Icon extends StatelessWidget {
  const _BarChart4Icon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BarChart4Painter(color, size));
  }
}

class _BarChart4Painter extends CustomPainter {
  const _BarChart4Painter(this.color, this.iconSize);

  final Color color;
  final double iconSize;

  /// 柱宽 4、间距 2，四根刚好铺满 1~23；基线略微超出柱组
  static const double _barWidth = 4;
  static const double _gap = 2;
  static const double _bottom = 19;
  static const List<double> _tops = <double>[11, 6, 9, 3];

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = iconSize / 24;
    canvas.translate((size.width - iconSize) / 2, (size.height - iconSize) / 2);
    canvas.scale(scale);
    final Paint paint = Paint()..color = color;

    for (int i = 0; i < _tops.length; i += 1) {
      final double left = 1 + i * (_barWidth + _gap);
      canvas.drawRect(
        Rect.fromLTRB(left, _tops[i], left + _barWidth, _bottom),
        paint,
      );
    }
    canvas.drawRect(const Rect.fromLTRB(1, 20.5, 23, 22), paint);
  }

  @override
  bool shouldRepaint(covariant _BarChart4Painter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.iconSize != iconSize;
}
