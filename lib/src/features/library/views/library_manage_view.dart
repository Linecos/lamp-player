import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_toast.dart';
import '../../../common/common.dart';
import '../../../rust/api/db.dart' as db;
import '../../../rust/api/model.dart' show Track;
import '../library_revision.dart';
import '../library_sort.dart';
import '../widgets/quality_ring.dart';
import '../../../theme/tokens.dart';

/// 音乐库分区的主体。
///
/// 这一页是「看库」而不是「改设置」：顶部四个指标、中间两块等高面板
/// （音乐目录 / 被隐藏的歌曲），底部两块入口分别通往统计与清理缺失。
///
/// 版式按 Material 3：卡片只用一种层级手法（[ColorScheme.surfaceContainer]
/// 系列填充、不描边），圆角取 shape scale 上的 16，次要文字一律
/// [ColorScheme.onSurfaceVariant]（`outline` 只留给描边与禁用态）。
class LibraryManageView extends StatelessWidget {
  const LibraryManageView({
    super.key,
    required this.tracks,
    this.onOpenStats,
    this.scanning = false,
    this.folders = const <String>[],
    this.onAddFolder,
    this.onOpenFolder,
    this.onOpenTracks,
    this.onOpenAlbums,
    this.onOpenArtists,
    this.onRescanFolder,
    this.onRemoveFolder,
    this.scanFolder,
    this.scanError,
    this.onRetry,
    this.pruningMissing = false,
    this.prunedMissingCount,
    this.pruneMissingError,
    this.onPruneMissing,
    this.bottomPadding = 16,
    this.query = '',
    this.qualityBreakdown,
    this.qualitySelected,
    this.onSelectQuality,
  });

  /// 全库曲目：目录行的曲目数、顶部指标与音质分布都从这份数据算出来
  final List<Track> tracks;

  /// 音质分布统计（页面按 `_tracks` 身份缓存后传进来）；空则就地算一遍
  final QualityBreakdown? qualityBreakdown;

  /// 当前音质筛选档位；null 表示不筛
  final AudioQuality? qualitySelected;

  /// 点扇形 / 点图例切换筛选
  final ValueChanged<AudioQuality>? onSelectQuality;

  /// 打开「听歌统计」子页
  final VoidCallback? onOpenStats;

  /// 慢扫描才为真：短扫描不显示「正在扫描」，否则副标题一闪而过；
  /// 真正的并发保护在各操作自己的 `_scanning` 判断里
  final bool scanning;

  /// 已添加的音乐目录（按添加顺序）
  final List<String> folders;

  final VoidCallback? onAddFolder;

  /// 点某个目录：进这个目录的曲目子页
  final ValueChanged<String>? onOpenFolder;

  /// 点顶部指标卡：跳到对应分区
  final VoidCallback? onOpenTracks;
  final VoidCallback? onOpenAlbums;
  final VoidCallback? onOpenArtists;

  /// 重新扫描某个目录；为空表示当前不可操作（例如正在扫描）
  final ValueChanged<String>? onRescanFolder;

  /// 从列表移除某个目录（不删除已入库曲目）
  final ValueChanged<String>? onRemoveFolder;

  /// 当前（或最近一次）扫描的目录
  final String? scanFolder;

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

  /// 常驻搜索框的关键词：非空时只留路径命中的目录、标题命中的隐藏歌曲
  final String query;

  /// 页面里除音质卡与两块面板以外的固定占用（逻辑像素）：
  /// 顶部留白 4 + 指标卡 94 + 指标与音质卡之间 16 + 音质卡与面板之间 12 +
  /// 面板与入口之间 16 + 两块入口瓷贴 138 + 默认 16 的底部留白。
  ///
  /// 这些间距 / 高度是页面的手感值，改动时要同步这里（实测总高 ≤ 视口高度）；
  /// `library_manage_view_test` 里「小窗口下两个入口仍在折叠线以上」的用例
  /// 会兜住漏改。
  static const double _reservedHeight = 278;

  static const double _minPanelHeight = 184;
  static const double _maxPanelHeight = 340;
  static const double minQualityHeight = 168;
  static const double maxQualityHeight = 208;

  /// 音质卡高度：窗口越矮越薄。
  ///
  /// 以前写死 208，在 720~760 这类「1080p + 150% 缩放」的窗口里会把下面
  /// 两个入口（听歌统计 / 清理缺失文件）推到折叠线以下——页面能滚，但第一屏
  /// 看不见入口。现在跟着可用高度收，最薄留 168（环形图直径 144）。
  static double qualityHeightFor(double viewportHeight) {
    if (!viewportHeight.isFinite || viewportHeight <= 0) {
      return maxQualityHeight;
    }
    return (viewportHeight * 0.26).clamp(minQualityHeight, maxQualityHeight);
  }

  /// 两块面板的高度：吃掉音质卡与入口之外剩下的空间，再夹进舒服的区间。
  ///
  /// 两块始终等高（外层 `SizedBox` 撑住，里面各自滚）。窗口很高时封顶 340，
  /// 不再跟着长；窗口矮的时候优先保证下面两个入口留在第一屏内。
  static double panelHeightFor(
    double viewportHeight, {
    double bottomPadding = 16,
  }) {
    if (!viewportHeight.isFinite || viewportHeight <= 0) {
      return 260;
    }
    final double reserved = _reservedHeight - 16 + bottomPadding;
    final double room =
        viewportHeight -
        reserved -
        qualityHeightFor(viewportHeight) -
        _foldSlack;
    return room.clamp(_minPanelHeight, _maxPanelHeight);
  }

  /// 折叠线以上的余量：留一点呼吸，不贴着窗口底边算
  static const double _foldSlack = 8;

  @override
  Widget build(BuildContext context) {
    final String query = this.query.trim().toLowerCase();
    final List<String> visible = query.isEmpty
        ? folders
        : folders
              .where((String folder) => folder.toLowerCase().contains(query))
              .toList(growable: false);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SmoothListView(
          // 与设置页一致：不给滚动条留槽，否则左右内边距差 12
          padding: EdgeInsets.only(top: Spacing.xxs, bottom: bottomPadding),
          children: <Widget>[
            Row(
              children: <Widget>[
                _Metric(
                  icon: Icons.music_note,
                  onTap: onOpenTracks,
                  label: '曲目',
                  value: '${tracks.length}',
                  valueKey: const ValueKey<String>('library-count-tracks'),
                ),
                const SizedBox(width: Spacing.sm),
                _Metric(
                  icon: Icons.album_outlined,
                  onTap: onOpenAlbums,
                  label: '专辑',
                  value: '${_albumCount(tracks)}',
                  valueKey: const ValueKey<String>('library-count-albums'),
                ),
                const SizedBox(width: Spacing.sm),
                _Metric(
                  icon: Icons.person_outline,
                  onTap: onOpenArtists,
                  label: '艺术家',
                  value: '${_artistCount(tracks)}',
                  valueKey: const ValueKey<String>('library-count-artists'),
                ),
                const SizedBox(width: Spacing.sm),
                _Metric(
                  icon: Icons.schedule,
                  label: '总时长',
                  value: _formatHours(tracks),
                  unit: '小时',
                  valueKey: const ValueKey<String>('library-count-hours'),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),

            // 音质分布：环形图点扇区 = 音乐分区只看这一档
            SizedBox(
              height: qualityHeightFor(constraints.maxHeight),
              child: _QualityPanel(
                extent: qualityHeightFor(constraints.maxHeight),
                breakdown: qualityBreakdown ?? QualityBreakdown.of(tracks),
                selected: qualitySelected,
                onSelect: onSelectQuality,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            SizedBox(
              // 两块等高：里面各自滚，页面不让它们撑长
              height: panelHeightFor(
                constraints.maxHeight,
                bottomPadding: bottomPadding,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: _Panel(
                      key: const ValueKey<String>('library-panel-folders'),
                      title: '音乐目录',
                      count: '${folders.length} 个',
                      trailing: IconButton(
                        key: const ValueKey<String>('library-add-folder'),
                        tooltip: '添加音乐目录',
                        onPressed: scanning ? null : onAddFolder,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add, size: 18),
                      ),
                      child: _buildFolders(context, visible),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: KeyedSubtree(
                      key: const ValueKey<String>('library-panel-hidden'),
                      child: _HiddenTracksPanel(query: query),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.md),

            // 扫描进度只画在目录行里（那一行本来就在）：以前这里插一条
            // 进度 banner，页面高度一变，音质卡与两块面板按 maxHeight 算的
            // 高度跟着变，点一下「重新扫描」整页就缩一下再弹回来，看着像闪。
            if (!scanning && scanError != null && onRetry != null) ...<Widget>[
              ErrorRetry(title: '扫描失败', error: scanError!, onRetry: onRetry!),
              const SizedBox(height: Spacing.sm),
            ],

            // 与上面那 16 是同一个间距：入口瓷贴不该比别人离得远（原来这里是
            // 16 + 18 两段，没有 banner 时看着凭空多出一截空当）
            _ActionTile(
              key: const ValueKey<String>('library-open-stats'),
              // material-symbols:bar-chart-4-bars：内置集只有三柱的 bar_chart，
              // 四柱字形放在项目自带字体里
              icon: Icon(
                LampIcons.barChart4Bars,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              title: '听歌统计',
              caption: '累计时长与次数排行',
              onTap: onOpenStats,
            ),
            const SizedBox(height: Spacing.sm),
            _ActionTile(
              key: const ValueKey<String>('library-prune-missing'),
              icon: Icon(
                Icons.delete_sweep_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
              // 不可操作（正在扫描 / 正在清理）时 [onRun] 是 null，
              // 但这一块始终是「运行」型，不能在那几秒里变成可进入的箭头
              showsRun: true,
              onRun: pruningMissing ? null : onPruneMissing,
            ),
            if (!pruningMissing &&
                pruneMissingError != null &&
                onPruneMissing != null) ...<Widget>[
              const SizedBox(height: Spacing.sm),
              ErrorRetry(
                title: '清理失败',
                error: pruneMissingError!,
                onRetry: onPruneMissing!,
              ),
            ],
          ],
        );
      },
    );
  }

  /// 目录块的内容：空态、搜索结果空态、或一列目录行
  Widget _buildFolders(BuildContext context, List<String> visible) {
    if (folders.isEmpty) {
      return _PanelEmpty(
        icon: Icons.create_new_folder_outlined,
        title: '还没有音乐目录',
        caption: '添加一个文件夹，扫描会把里面的音频递归入库',
        action: FilledButton.tonalIcon(
          onPressed: scanning ? null : onAddFolder,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加音乐目录'),
        ),
      );
    }
    if (visible.isEmpty) {
      return const _PanelEmpty(
        icon: Icons.search_off,
        title: '没有匹配的音乐目录',
        caption: '清空搜索框看看全部目录',
      );
    }
    return SmoothScroll(
      builder: (BuildContext context, ScrollController controller) => ListView(
        controller: controller,
        padding: EdgeInsets.zero,
        children: <Widget>[
          for (final String folder in visible)
            _FolderRow(
              folder: folder,
              count: tracks
                  .where((Track track) => trackInFolder(track.path, folder))
                  .length,
              onOpen: onOpenFolder == null ? null : () => onOpenFolder!(folder),
              scanning: scanning && folder == scanFolder,
              onRescan: onRescanFolder == null || scanning
                  ? null
                  : () => onRescanFolder!(folder),
              onRemove: onRemoveFolder == null || scanning
                  ? null
                  : () => onRemoveFolder!(folder),
            ),
        ],
      ),
    );
  }
}

/// [path] 是否落在音乐目录 [folder] 里。
///
/// 反斜杠统一 + 小写比较：Windows 路径大小写不敏感，两种大小写写法必须算
/// 同一个目录；结尾的反斜杠也要先削掉，否则带不带尾巴会判成两个目录。
bool trackInFolder(String path, String folder) {
  String norm(String value) => value.replaceAll('/', r'\').toLowerCase();
  final String target = norm(folder).replaceAll(RegExp(r'\\+$'), '');
  final String source = norm(path);
  return source == target || source.startsWith('$target\\');
}

/// 专辑数与艺术家数。
///
/// 必须用**专辑分区 / 艺术家分区同一套键**：[albumGroupKey] 与
/// [splitTrackArtists]。自己拼 `album|artist` 的话，两边会差出好几张——
/// 没有标签的曲目在专辑分区是「未知专辑」一张卡，按裸字符串拼却会算成
/// 每个艺术家各一张；`A/B` 这种多艺术家曲目在艺术家分区是两个人，
/// 按裸字符串算又是各一次。这里只算键、不建分组，也不排序，代价是逐曲
/// 一次字符串拼接。
int _albumCount(List<Track> tracks) {
  final Set<String> keys = <String>{};
  for (final Track track in tracks) {
    keys.add(albumGroupKey(track));
  }
  return keys.length;
}

int _artistCount(List<Track> tracks) {
  final Set<String> names = <String>{};
  for (final Track track in tracks) {
    names.addAll(splitTrackArtists(track));
  }
  return names.length;
}

/// 总时长；100 小时以上不再显示小数（三位数再带 0.1 没人看）
String _formatHours(List<Track> tracks) {
  double seconds = 0;
  for (final Track track in tracks) {
    seconds += track.durationSecs;
  }
  final double hours = seconds / 3600;
  return hours >= 100 ? '${hours.round()}' : hours.toStringAsFixed(1);
}

/// 顶部一个指标：图标 + 标签 + 数字（单位小一号）
class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.valueKey,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final Key? valueKey;

  /// 点了跳到对应分区；为空表示这张卡只是数字
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Expanded(
      child: Material(
        // 层级：页面 surfaceContainerLow → 面板 High → 指标 Highest。
        // MD3 的卡片要么填充、要么描边，两样都上只会显得板
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: scheme.onSurface.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.md,
              Spacing.sm,
              Spacing.md,
              Spacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // 次要文字用 onSurfaceVariant：outline 是描边色，
                        // 铺在 12px 小字上会灰到看不清
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(text: value),
                      if (unit != null)
                        TextSpan(
                          text: ' $unit',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
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
        ),
      ),
    );
  }
}

/// 页面上的一个块：标题 + 计数胶囊 + 右上角动作 + 内容
class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.title,
    required this.child,
    this.count,
    this.trailing,
  });

  final String title;
  final String? count;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.sm,
        Spacing.sm,
      ),
      decoration: BoxDecoration(
        // 比页面底色（surfaceContainerLow）再上一档。以前用 surface，
        // 那比页面还暗，整块看着像挖下去的坑，和凸起的指标卡方向正好相反；
        // 用 container 又只差两个色阶，浅色下几乎看不出边界
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(
              right: Spacing.xxs,
              bottom: Spacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (count != null) ...<Widget>[
                  const SizedBox(width: Spacing.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Text(
                      count!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                ?trailing,
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 块内的空态：图标 + 标题 + 一句说明 + 可选动作
class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({
    required this.icon,
    required this.title,
    required this.caption,
    this.action,
  });

  final IconData icon;
  final String title;
  final String caption;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 空态是「这一块里什么都没有」的说明，不是列表项：图标、标题、说明、动作
    // 一律居中。以前按 ListView 排，图标被撑满宽度的 `Icon` 自己居中、文字却
    // 靠左，一块空白里左右不齐。
    // 块本身有固定高度，内容超了要能滚，不能溢出
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SmoothSingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - 16),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: 26, color: scheme.onSurfaceVariant),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    caption,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (action != null) ...<Widget>[
                    const SizedBox(height: Spacing.sm),
                    action!,
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 块内的一行目录：文件夹图标 + 路径 / 曲目数 + 「更多」菜单。
///
/// 重新扫描与移除收进菜单，而不是两个并排的图标：原来删除键离刷新键只有
/// 8px，点歪一下就少一个目录，而且移除没有确认。
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.count,
    required this.scanning,
    this.onOpen,
    this.onRescan,
    this.onRemove,
  });

  final String folder;
  final int count;
  final bool scanning;

  /// 点整行：进这个目录的曲目子页
  final VoidCallback? onOpen;
  final VoidCallback? onRescan;
  final VoidCallback? onRemove;

  Future<void> _confirmRemove(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移除这个目录？'),
        content: Text('$folder\n\n已入库的歌曲不会被删除，但下次扫描不会再从这个目录导入。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      onRemove?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    // 整行可点：点开是这个目录的曲目子页；右侧「更多」菜单仍是独立热区
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        hoverColor: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.xxs,
            Spacing.xxs,
            Spacing.xxs,
            Spacing.xxs,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(
                  Icons.folder_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Spacing.sm),
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
                        color: scanning
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 扫描中不换控件、只禁用：以前这里换成一个小转圈，那个转圈
              // 比「更多」按钮矮一截，行高跟着变，目录块里就闪一下
              PopupMenuButton<String>(
                tooltip: '更多操作',
                enabled: !scanning,
                icon: Icon(
                  Icons.more_vert,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                onSelected: (String action) {
                  if (action == 'rescan') {
                    onRescan?.call();
                  } else if (action == 'remove') {
                    unawaited(_confirmRemove(context));
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'rescan',
                    child: Text('重新扫描'),
                  ),
                  const PopupMenuItem<String>(
                    value: 'remove',
                    child: Text('移除目录…'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 块内的隐藏歌曲列表：封面 + 标题 / 艺术家 + 一键恢复，多了就在块内滚
class _HiddenTracksPanel extends StatefulWidget {
  const _HiddenTracksPanel({this.query = ''});

  /// 常驻搜索框的关键词：非空时按标题 / 艺术家 / 路径筛，和目录块同一口径
  final String query;

  @override
  State<_HiddenTracksPanel> createState() => _HiddenTracksPanelState();
}

class _HiddenTracksPanelState extends State<_HiddenTracksPanel> {
  List<db.HiddenTrack>? _items;
  bool _loading = true;
  String? _error;

  /// 隐藏歌曲列表滚轮平滑（见 [SmoothScrollController]）
  final SmoothScrollController _scroll = SmoothScrollController();

  @override
  void initState() {
    super.initState();
    // 曲库内容在别处变了（右键隐藏了歌、刚扫完目录）就重拉一次：这一块
    // 在分区快照里会一直活着，只在 initState 拉一次的话，新隐藏的歌要等
    // 切走再切回来才看得见
    libraryRevision.addListener(_reload);
    unawaited(_load());
  }

  @override
  void dispose() {
    libraryRevision.removeListener(_reload);
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final List<db.HiddenTrack> items = await db.hiddenTracks();
      if (!mounted) {
        return;
      }
      setState(() {
        _items = items;
        _error = null;
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
      // 列表靠 libraryRevision 的监听重拉，这里不用再手动 _load 一次
      markLibraryChanged();
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

    final List<db.HiddenTrack> all = _items ?? const <db.HiddenTrack>[];
    // 和目录块一样就地过滤：搜索框的提示语说的是「搜索目录或隐藏歌曲」，
    // 只筛目录的话，搜歌名会得到一句「没有匹配的音乐目录」，看着像功能坏了
    final String query = widget.query.trim().toLowerCase();
    final List<db.HiddenTrack> items = query.isEmpty
        ? all
        : all
              .where(
                (db.HiddenTrack track) =>
                    track.title.toLowerCase().contains(query) ||
                    track.artist.toLowerCase().contains(query) ||
                    track.path.toLowerCase().contains(query),
              )
              .toList(growable: false);

    final Widget body;
    if (_loading) {
      body = const _PanelEmpty(
        icon: Icons.hourglass_empty,
        title: '读取中…',
        caption: '正在查询被隐藏的歌曲',
      );
    } else if (_error != null) {
      body = _PanelEmpty(
        icon: Icons.error_outline,
        title: '读取失败',
        caption: _error!,
      );
    } else if (all.isEmpty) {
      body = const _PanelEmpty(
        icon: Icons.visibility_off_outlined,
        title: '没有被隐藏的歌曲',
        caption: '在歌曲上右键「隐藏」，就会出现在这里',
      );
    } else if (items.isEmpty) {
      body = const _PanelEmpty(
        icon: Icons.search_off,
        title: '没有匹配的隐藏歌曲',
        caption: '清空搜索框看看全部',
      );
    } else {
      body = ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        itemBuilder: (BuildContext context, int index) {
          final db.HiddenTrack track = items[index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
            child: Row(
              children: <Widget>[
                // 隐藏记录同样带着封面：只画一个音符图标，光看歌名认不出是哪首
                AlbumCover(path: track.coverPath, size: 36, radius: 12),
                const SizedBox(width: Spacing.sm),
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
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                IconButton.filledTonal(
                  onPressed: () => unawaited(_restore(track)),
                  tooltip: '恢复',
                  iconSize: 16,
                  style: IconButton.styleFrom(
                    fixedSize: const Size(36, 36),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.restore),
                ),
              ],
            ),
          );
        },
      );
    }

    return _Panel(
      title: '被隐藏的歌曲',
      count: _loading || _error != null ? null : '${all.length} 首',
      child: body,
    );
  }
}

/// 与目录行同构的一块入口：圆形图标 + 标题 / 说明 + 右侧箭头或运行按钮。
///
/// 传 [onRun] 的是「直接执行」类（清理缺失），整行不可点，只认按钮；
/// 其余整行可点，悬停 / 聚焦时底色抬一档、标题与箭头转成强调色。
class _ActionTile extends StatefulWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    this.title,
    required this.caption,
    this.onTap,
    this.onRun,
    this.busy = false,
    this.showsRun = false,
  });

  final Widget icon;
  final String? title;
  final String caption;
  final VoidCallback? onTap;
  final VoidCallback? onRun;
  final bool busy;

  /// 这一块是「直接执行」型（右侧显示运行按钮）而不是「可进入」型。
  ///
  /// 不能只按 [onRun] 是否为空判断：不可操作时（正在扫描 / 正在清理）传进来
  /// 的就是 null，那样这一块会突然换成可进入的箭头，看着像变成了另一个功能。
  final bool showsRun;

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool action = widget.showsRun || widget.busy;
    final bool active = !action && widget.onTap != null;
    final bool lit = active && (_hovered || _focused);

    return Material(
      color: lit ? scheme.surfaceContainerHighest : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(Radii.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: active ? widget.onTap : null,
        onHover: (bool value) => setState(() => _hovered = value),
        onFocusChange: (bool value) => setState(() => _focused = value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.md,
            Spacing.sm,
            Spacing.md,
            Spacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: widget.icon,
              ),
              const SizedBox(width: Spacing.md),
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
                        color: lit ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              if (action)
                widget.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    // 40 高是 MD3 按钮的最小触摸高度，比手写的文字胶囊好按
                    : OutlinedButton(
                        onPressed: widget.onRun,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(64, 40),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.md,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('运行'),
                      )
              else
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: lit ? scheme.primary : scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QualityPanel extends StatelessWidget {
  const _QualityPanel({
    required this.extent,
    required this.breakdown,
    this.selected,
    this.onSelect,
  });

  /// 卡片高度（由页面按窗口高度算，见 `qualityHeightFor`）
  final double extent;

  final QualityBreakdown breakdown;
  final AudioQuality? selected;
  final ValueChanged<AudioQuality>? onSelect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool empty = breakdown.total == 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.sm,
        Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 环形图在窄窗口里也能放下：直径跟着卡片高度走（上下各让 12）
          Center(
            child: QualityRing(
              key: const ValueKey<String>('library-quality-ring'),
              breakdown: breakdown,
              selected: selected,
              onSelect: empty ? null : onSelect,
              size: extent - 24,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '音质分布',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      empty
                          ? '还没有曲目'
                          : '大小 ${formatFileSize(breakdown.totalBytes)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.xs),
                Expanded(
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                          // 窄窗口放下「标签 + 比例条 + 数字」会挤，比例条先撤掉
                          final bool dense = constraints.maxWidth < 300;
                          return Column(
                            children: <Widget>[
                              for (final AudioQuality quality
                                  in AudioQuality.values)
                                Expanded(
                                  child: _QualityLegendRow(
                                    quality: quality,
                                    count: breakdown.countOf(quality),
                                    fraction: breakdown.fractionOf(quality),
                                    selected: selected == quality,
                                    // 选了别的档位就整体压暗，一眼看出「筛的是哪一档」
                                    dimmed:
                                        selected != null && selected != quality,
                                    dense: dense,
                                    onTap: empty || onSelect == null
                                        ? null
                                        : () => onSelect!(quality),
                                  ),
                                ),
                            ],
                          );
                        },
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

class _QualityLegendRow extends StatelessWidget {
  const _QualityLegendRow({
    required this.quality,
    required this.count,
    required this.fraction,
    required this.selected,
    required this.dimmed,
    required this.dense,
    this.onTap,
  });

  final AudioQuality quality;
  final int count;
  final double fraction;
  final bool selected;
  final bool dimmed;
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double alpha = dimmed ? 0.5 : 1;
    final Color accent = sliceColor(scheme, quality).withValues(alpha: alpha);
    final Color primaryText = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface.withValues(alpha: alpha);
    final Color secondaryText = selected
        ? scheme.onSecondaryContainer.withValues(alpha: 0.8)
        : scheme.onSurfaceVariant.withValues(alpha: alpha);

    // 定宽数字：四行的数字对齐成一列，占比不会随位数跳
    final TextStyle numberStyle = theme.textTheme.bodySmall!.copyWith(
      color: primaryText,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );

    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
          child: Row(
            children: <Widget>[
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              if (dense)
                Expanded(
                  child: Text(
                    '${qualityLabel(quality)} · ${qualityCaption(quality)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: secondaryText,
                    ),
                  ),
                )
              else ...<Widget>[
                SizedBox(
                  width: 148,
                  child: Text(
                    '${qualityLabel(quality)} · ${qualityCaption(quality)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: secondaryText,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                // 占比条把这个宽窗口里的大片空白用起来，长度 = 占比
                Expanded(
                  child: _ShareBar(
                    fraction: fraction,
                    color: accent,
                    track: selected
                        ? scheme.onSecondaryContainer.withValues(alpha: 0.12)
                        : scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
              ],
              SizedBox(
                width: 34,
                child: Text(
                  count == 0 ? '—' : '$count',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  style: numberStyle.copyWith(
                    fontWeight: FontWeight.w500,
                    color: count == 0 ? secondaryText : primaryText,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.xs),
              SizedBox(
                width: 46,
                child: Text(
                  _percentText(fraction),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  style: numberStyle.copyWith(
                    color: fraction <= 0 ? secondaryText : primaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一根按占比填充的细胶囊：轨道常驻，四档空着也看得出「四个格子」
class _ShareBar extends StatelessWidget {
  const _ShareBar({
    required this.fraction,
    required this.color,
    required this.track,
  });

  final double fraction;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 6,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction.clamp(0, 1),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: const SizedBox(height: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 占比文字；0 首时留一个短横，别显示一片「0.0%」
String _percentText(double fraction) =>
    fraction <= 0 ? '—' : '${(fraction * 100).toStringAsFixed(1)}%';
