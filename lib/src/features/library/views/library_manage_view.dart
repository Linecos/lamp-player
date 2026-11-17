import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_toast.dart';
import '../../../common/common.dart';
import '../../../rust/api/db.dart' as db;
import '../../../rust/api/scan.dart';
import '../../settings/hidden_tracks_view.dart';
import '../../settings/widgets/settings_rows.dart';
import '../library_revision.dart';

/// 音乐库分区的主体：曲目数量、目录管理、隐藏与清理都收在这里。
///
/// 与听歌统计同一套「分区内切换」：左侧栏与播放岛不动，切子页只换内容。
class LibraryManageView extends StatelessWidget {
  const LibraryManageView({
    super.key,
    required this.trackCount,
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
    this.matcher,
    this.onClearSearch,
  });

  final int trackCount;

  /// 打开「听歌统计」子页：切换由分区容器负责
  final VoidCallback? onOpenStats;

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

  /// 列表底部留白，给底部播放岛让位
  final double bottomPadding;

  /// 常驻搜索框的关键词：非空时只留命中的行
  final String query;

  /// 自定义匹配（曲库页传拼音匹配进来）；为空时按大小写无关的子串判断
  final bool Function(String text, String query)? matcher;

  /// 清空搜索；为空表示不提供「清除搜索」入口
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) {
    final String query = this.query.trim();
    final List<Widget> children = <Widget>[];

    void section(String label, List<Widget> rows) {
      final List<Widget> kept = _filterRows(rows, query);
      if (kept.isEmpty) {
        return;
      }
      children.add(SettingsSectionLabel(label));
      children.add(SettingsCard(children: kept));
    }

    section('音乐库', <Widget>[
      SettingsInfoRow(
        icon: Icons.library_music_outlined,
        title: '曲目数量',
        value: '$trackCount 首',
      ),
      SettingsActionRow(
        icon: Icons.create_new_folder_outlined,
        title: '添加音乐目录',
        subtitle: scanning ? '正在扫描…' : '递归扫描，增量入库',
        onTap: scanning ? null : onAddFolder,
        trailing: scanning
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
      SettingsActionRow(
        icon: Icons.visibility_off_outlined,
        title: '被隐藏的歌曲',
        subtitle: '扫描时跳过，可在这里恢复',
        onTap: () => unawaited(_openHiddenTracks(context)),
      ),
      SettingsActionRow(
        icon: Icons.cleaning_services_outlined,
        title: '清理缺失文件',
        subtitle: pruningMissing ? '正在检查…' : '只删库记录，不动音频文件',
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

    section('统计', <Widget>[
      SettingsActionRow(
        key: const ValueKey<String>('library-open-stats'),
        icon: Icons.insights_outlined,
        title: '听歌统计',
        subtitle: '累计时长与次数排行',
        onTap: onOpenStats,
      ),
    ]);

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
    if (scanning && scanFolder != null) {
      children.add(_ScanProgress(folder: scanFolder!));
    }
    if (!scanning && scanError != null && onRetry != null) {
      children.add(
        ErrorRetry(title: '扫描失败', error: scanError!, onRetry: onRetry!),
      );
    }
    if (!scanning && scanError == null && scanReport != null) {
      children.add(_ScanSummary(report: scanReport!, folder: scanFolder ?? ''));
    }

    if (children.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有匹配的项目',
        message: '试试「目录」「隐藏」「统计」这类词，或清除搜索看全部。',
        action: onClearSearch == null
            ? null
            : TextButton(onPressed: onClearSearch, child: const Text('清除搜索')),
      );
    }

    return ListView(
      padding: EdgeInsets.only(top: 4, right: 12, bottom: bottomPadding),
      children: children,
    );
  }

  /// 搜索时只留命中的行；整组都没命中就连标题一起收起来
  List<Widget> _filterRows(List<Widget> rows, String query) {
    if (query.isEmpty) {
      return rows;
    }
    final List<Widget> kept = <Widget>[];
    for (final Widget row in rows) {
      if (row is! SettingsSearchable) {
        continue;
      }
      final SettingsSearchable searchable = row as SettingsSearchable;
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

  static Future<void> _openHiddenTracks(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => const _HiddenTracksDialog(),
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
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '耗时 ${(report.elapsedMs.toInt() / 1000).toStringAsFixed(1)} 秒',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
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
class _EmptyFolders extends StatelessWidget implements SettingsSearchable {
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
class _FolderRow extends StatelessWidget implements SettingsSearchable {
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
                    color: scheme.outline,
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

class _HiddenTracksDialog extends StatefulWidget {
  const _HiddenTracksDialog();

  @override
  State<_HiddenTracksDialog> createState() => _HiddenTracksDialogState();
}

class _HiddenTracksDialogState extends State<_HiddenTracksDialog> {
  List<db.HiddenTrack>? _items;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
        _error = '读取失败：${ErrorRetry.describe(error)}';
        _loading = false;
      });
    }
  }

  Future<void> _restore(db.HiddenTrack track) async {
    try {
      await db.unhideTracks(paths: <String>[track.path]);
      // 曲库页不在同一棵子树里，靠进程内通知让它重新拉一次列表
      markLibraryChanged();
      await _load();
      if (!mounted) {
        return;
      }
      AppToast.show(context, '已恢复：${track.title}');
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

    return AlertDialog(
      title: const Text('被隐藏的歌曲'),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        // 多了 40px 封面与一列信息，比原来的纯文字列表宽一点
        width: 560,
        height: 360,
        child: _buildBody(theme, scheme),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _error;
    if (error != null) {
      return Center(
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
        ),
      );
    }
    final List<db.HiddenTrack> items = _items ?? const <db.HiddenTrack>[];
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.visibility_off_outlined,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '没有被隐藏的歌曲',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '在曲目上右键「隐藏歌曲」会放到这里',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      );
    }

    return HiddenTracksView(items: items, onRestore: _restore);
  }
}
